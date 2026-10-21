//! What runs in a block: the foreground process of its pty, and what and
//! where a process is. macOS asks libproc and sysctl; Linux reads /proc.
//! Every lookup returns null for a process that is gone or not ours.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const Allocator = std.mem.Allocator;

const darwin = builtin.os.tag.isDarwin();

/// The longest name `name` returns.
pub const max_name = 64;

/// The longest path `path` and `cwd` return.
pub const max_path = 4096;

/// What the API reports about a process.
pub const Info = struct {
    pid: posix.pid_t,
    name: ?[]const u8,
    path: ?[]const u8,
    argv0: ?[]const u8,
    /// The script an interpreter runs ("/usr/local/bin/gemini" for node), which
    /// names the program when argv[0] is just "node" or "python3".
    argv1: ?[]const u8,
};

/// The foreground process group of the terminal behind `pty_fd`. Its
/// leader is the program the user is talking to: the shell at a prompt,
/// or the job it started.
pub fn foreground(pty_fd: posix.fd_t) ?posix.pid_t {
    const pgrp = tcgetpgrp(pty_fd);
    return if (pgrp > 0) pgrp else null;
}

/// Describe a process, with strings allocated in `alloc`.
pub fn describe(alloc: Allocator, pid: posix.pid_t) Allocator.Error!Info {
    var name_buf: [max_name]u8 = undefined;
    var path_buf: [max_path]u8 = undefined;
    const args = try argv(alloc, pid);
    return .{
        .pid = pid,
        .name = if (name(pid, &name_buf)) |n| try alloc.dupe(u8, n) else null,
        .path = if (path(pid, &path_buf)) |p| try alloc.dupe(u8, p) else null,
        .argv0 = args[0],
        .argv1 = args[1],
    };
}

/// The process's short command name, as `ps -c` shows it.
pub fn name(pid: posix.pid_t, buf: *[max_name]u8) ?[]const u8 {
    if (comptime darwin) {
        const n = proc_name(pid, buf, buf.len);
        return if (n > 0) buf[0..@intCast(n)] else null;
    }
    var p: [32]u8 = undefined;
    const n = readFile(std.fmt.bufPrintSentinel(&p, "/proc/{d}/comm", .{pid}, 0) catch unreachable, buf) orelse return null;
    return std.mem.trimEnd(u8, n, "\n");
}

/// The process's executable.
pub fn path(pid: posix.pid_t, buf: *[max_path]u8) ?[]const u8 {
    if (comptime darwin) {
        const n = proc_pidpath(pid, buf, buf.len);
        return if (n > 0) buf[0..@intCast(n)] else null;
    }
    var p: [32]u8 = undefined;
    return readLink(std.fmt.bufPrintSentinel(&p, "/proc/{d}/exe", .{pid}, 0) catch unreachable, buf);
}

/// The process's working directory.
pub fn cwd(pid: posix.pid_t, buf: *[max_path]u8) ?[]const u8 {
    if (comptime darwin) {
        var info: VnodePathInfo = undefined;
        if (proc_pidinfo(pid, proc_pidvnodepathinfo, 0, &info, @sizeOf(VnodePathInfo)) != @sizeOf(VnodePathInfo)) return null;
        const dir = std.mem.sliceTo(&info.cdir_path, 0);
        if (dir.len == 0) return null;
        @memcpy(buf[0..dir.len], dir);
        return buf[0..dir.len];
    }
    var p: [32]u8 = undefined;
    return readLink(std.fmt.bufPrintSentinel(&p, "/proc/{d}/cwd", .{pid}, 0) catch unreachable, buf);
}

/// The process's argv[0] and argv[1], allocated in `alloc`.
pub fn argv(alloc: Allocator, pid: posix.pid_t) Allocator.Error![2]?[]const u8 {
    var out: [2]?[]const u8 = .{ null, null };
    if (comptime darwin) {
        // KERN_PROCARGS2 is argc, the exec path, NUL padding, then argv, then env.
        var argmax: c_int = 0;
        var len: usize = @sizeOf(c_int);
        const argmax_mib = [_]c_int{ c.CTL.KERN, c.KERN.ARGMAX };
        if (c.sysctl(&argmax_mib, argmax_mib.len, &argmax, &len, null, 0) != 0 or argmax <= 0) return out;
        const buf = try alloc.alloc(u8, @intCast(argmax));
        defer alloc.free(buf);
        len = buf.len;
        const mib = [_]c_int{ c.CTL.KERN, c.KERN.PROCARGS2, pid };
        if (c.sysctl(&mib, mib.len, buf.ptr, &len, null, 0) != 0 or len <= @sizeOf(c_int)) return out;
        const argc = std.mem.readInt(c_int, buf[0..@sizeOf(c_int)], builtin.cpu.arch.endian());
        var rest: []const u8 = buf[@sizeOf(c_int)..len];
        rest = rest[(std.mem.indexOfScalar(u8, rest, 0) orelse return out)..];
        rest = std.mem.trimStart(u8, rest, "\x00");
        for (0..@min(2, @max(argc, 0))) |i| {
            const arg = std.mem.sliceTo(rest, 0);
            if (arg.len > 0) out[i] = try alloc.dupe(u8, arg);
            rest = rest[@min(rest.len, arg.len + 1)..];
        }
        return out;
    }
    var p: [32]u8 = undefined;
    var buf: [max_path]u8 = undefined;
    const cmdline = readFile(std.fmt.bufPrintSentinel(&p, "/proc/{d}/cmdline", .{pid}, 0) catch unreachable, &buf) orelse return out;
    var it = std.mem.splitScalar(u8, cmdline, 0);
    for (&out) |*o| {
        const arg = it.next() orelse break;
        if (arg.len > 0) o.* = try alloc.dupe(u8, arg);
    }
    return out;
}

/// Up to `buf.len` bytes of a file.
fn readFile(file: [:0]const u8, buf: []u8) ?[]u8 {
    const fd = c.open(file, .{ .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    return if (n > 0) buf[0..@intCast(n)] else null;
}

fn readLink(link: [:0]const u8, buf: []u8) ?[]const u8 {
    const n = c.readlink(link, buf.ptr, buf.len);
    return if (n > 0) buf[0..@intCast(n)] else null;
}

// std.posix.tcgetpgrp calls a std.c binding that doesn't exist.
extern "c" fn tcgetpgrp(fd: posix.fd_t) posix.pid_t;
extern "c" fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;

const proc_pidvnodepathinfo = 9;

/// `struct proc_vnodepathinfo`: the working directory, then the root
/// directory, each a 152-byte `struct vnode_info` and a MAXPATHLEN path.
const VnodePathInfo = extern struct {
    cdir_info: [152]u8,
    cdir_path: [1024]u8,
    rdir_info: [152]u8,
    rdir_path: [1024]u8,
};

test "rex proc: describe this process" {
    if (comptime !darwin and builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const info = try describe(arena.allocator(), c.getpid());
    try testing.expect(info.name.?.len > 0);
    try testing.expect(std.mem.endsWith(u8, info.path.?, info.name.?) or info.name.?.len >= 15);
    try testing.expect(info.argv0.?.len > 0);

    var buf: [max_path]u8 = undefined;
    try testing.expect(std.fs.path.isAbsolute(cwd(c.getpid(), &buf).?));
    try testing.expectEqual(null, name(-1, buf[0..max_name]));
}
