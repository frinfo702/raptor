//! Entrypoint for `rap`, the Raptor command line tool and server.
//!
//! This sits at the root of `src/` so that the server can import shared
//! modules such as `pty.zig`, `Command.zig` and the terminal core.
const std = @import("std");
const posix = std.posix;
const options = @import("build_options");
const global = @import("global.zig");
const exit = @import("rap/exit.zig");
const cli = @import("rap/cli.zig");
const Server = @import("rex/Server.zig");
const protocol = @import("rex/protocol.zig");

pub const ExitCode = exit.Code;

const usage = cli.usage;

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    const argv = if (args.len > 0) args[1..] else args;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    const code = if (try serverRunArgs(alloc, init.io, init.environ_map, argv)) |a|
        try serverRun(init, a, stderr)
    else
        try run(alloc, init.io, init.environ_map, argv, stdout, stderr);
    try stdout.flush();
    try stderr.flush();
    return @backingInt(code);
}

/// Run the command named by `args` (excluding argv[0]).
fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) std.Io.Writer.Error!ExitCode {
    if (args.len == 0) {
        try stderr.writeAll(usage);
        return .usage;
    }

    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "version")) {
        try stdout.print("rap {s}\n", .{options.app_version_string});
        return .ok;
    }
    if (std.mem.eql(u8, cmd, "help")) {
        try stdout.writeAll(usage);
        return .ok;
    }
    return cli.run(alloc, io, env, args, stdout, stderr);
}

/// The parsed arguments if they are `rap server run` on this machine.
fn serverRunArgs(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    argv: []const []const u8,
) !?cli.Args {
    var bad: []const u8 = "";
    const a = cli.parse(alloc, argv, &bad) catch return null;
    if (a.words.len != 2 or !std.mem.eql(u8, a.words[0], "server") or
        !std.mem.eql(u8, a.words[1], "run")) return null;
    if (try cli.sshDestination(alloc, io, env, a.server) != null) return null;
    return a;
}

fn onSignal(_: posix.SIG) callconv(.c) void {
    Server.signaled.store(true, .monotonic);
}

/// `rap server run`: serve in the foreground until stopped or idle.
fn serverRun(init: std.process.Init, args: cli.Args, stderr: *std.Io.Writer) !ExitCode {
    const alloc = init.arena.allocator();
    const idle_ms: u64 = if (args.idle_timeout) |t| ms: {
        const secs = std.fmt.parseFloat(f64, t) catch std.math.nan(f64);
        if (!(secs >= 0 and secs <= 1e9)) {
            try stderr.print("rap: invalid --idle-timeout '{s}'\n", .{t});
            return .usage;
        }
        break :ms @intFromFloat(secs * 1000);
    } else 30_000;
    const path = try protocol.resolveSocketPath(alloc, init.io, init.environ_map, args.server);

    // The pty and process code expects Ghostty's global state.
    try global.init(.{ .tool = init.minimal });
    defer global.deinit();

    var act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.TERM, &act, null);
    posix.sigaction(.INT, &act, null);
    act.handler = .{ .handler = posix.SIG.IGN };
    posix.sigaction(.HUP, &act, null);
    posix.sigaction(.PIPE, &act, null);

    const server = Server.create(init.gpa, global.io(), .{
        .socket_path = path,
        .env = init.environ_map,
        .idle_timeout_ms = idle_ms,
        .shell_integration = .load(alloc),
    }) catch |err| {
        switch (err) {
            error.AlreadyRunning => try stderr.print("rap: server already running on {s}\n", .{path}),
            else => try stderr.print("rap: starting server on {s} failed: {t}\n", .{ path, err }),
        }
        return .fail;
    };
    defer server.destroy();
    try server.run();
    return .ok;
}

fn testRun(args: []const []const u8, expected: ExitCode, out: []const u8, err: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    try std.testing.expectEqual(expected, try run(arena.allocator(), std.testing.io, &env, args, &stdout.writer, &stderr.writer));
    try std.testing.expectEqualStrings(out, stdout.written());
    try std.testing.expectEqualStrings(err, stderr.written());
}

test "rap version" {
    try testRun(&.{"version"}, .ok, "rap " ++ options.app_version_string ++ "\n", "");
}

test "rap help" {
    try testRun(&.{"help"}, .ok, usage, "");
}

test "rap without a command is a usage error" {
    try testRun(&.{}, .usage, "", usage);
}

test "rap unknown command is a usage error" {
    try testRun(&.{"nope"}, .usage, "", "rap: unknown command 'nope'\n\n" ++ usage);
}

test "rap unknown flag is a usage error" {
    try testRun(&.{"--version"}, .usage, "", "rap: unknown flag '--version'\n");
}

test "rap without a server exits 4" {
    try testRun(&.{ "-S", "/nonexistent/rap.sock", "ls" }, .unreachable_server, "", "rap: no server running on /nonexistent/rap.sock\n");
}

test "rap run of a program not on PATH exits 127 without a server" {
    try testRun(
        &.{ "-S", "/nonexistent/rap.sock", "run", "--", "raptor-no-such-program" },
        @fromBackingInt(@intCast(127)),
        "",
        "rap: raptor-no-such-program: command not found\n",
    );
}

test "rap exit codes" {
    try std.testing.expectEqual(0, @backingInt(ExitCode.ok));
    try std.testing.expectEqual(1, @backingInt(ExitCode.fail));
    try std.testing.expectEqual(2, @backingInt(ExitCode.usage));
    try std.testing.expectEqual(3, @backingInt(ExitCode.target));
    try std.testing.expectEqual(4, @backingInt(ExitCode.unreachable_server));
    try std.testing.expectEqual(130, @backingInt(ExitCode.interrupted));
}

test {
    _ = cli;
    _ = @import("rex/main.zig");
}
