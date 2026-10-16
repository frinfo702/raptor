//! The wire protocol between the rap server and its clients, and the
//! socket plumbing both sides share.
//!
//! Every message is a frame: `u32 length | u8 type | payload`, the length
//! being the payload's byte count, little endian. Control frames carry one
//! JSON object:
//!
//! - request:  {"id":1,"method":"session.list","params":{...}}
//! - response: {"id":1,"result":{...}} or {"id":1,"error":{"code":"target","message":"..."}}
//! - event:    {"event":"block_created","session":"session:...",...}
//!
//! Events reach only clients that called `session.subscribe`.
//!
//! The data plane streams blocks in binary frames. `block.subscribe`
//! answers with a `stream` id and the block's full id, and every data
//! frame starts with that stream id. `block.unsubscribe` ends a stream.
//! Each block counts the bytes its program has written as `seq`; a client
//! that has applied everything through `seq` is in sync at that point.
//! After subscribing the client gets either a snapshot (`snap` chunks at
//! `base_seq`) or, when it passed a `since_seq` the server can still
//! replay, `out` frames from there. Then live `out` and `grid` frames
//! follow in stream order. See `Snap`, `Out`, `Grid`, `In`, `Size` and
//! `Focus` for the payloads.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const Allocator = std.mem.Allocator;
const Ip4Address = std.Io.net.Ip4Address;
const tailscale = @import("tailscale.zig");

pub const version = 1;

pub const FrameType = enum(u8) {
    json = 1,
    snap = 2,
    out = 3,
    grid = 4,
    in = 5,
    size = 6,
    focus = 7,
    _,
};

/// S->C: one chunk of a snapshot of the block's terminal at `base_seq`.
/// The snapshot bytes follow. A new `first` chunk discards any snapshot
/// still being received for the stream.
pub const Snap = struct {
    stream: u32,
    base_seq: u64,
    flags: SnapFlags,
};

pub const SnapFlags = packed struct(u8) {
    first: bool = false,
    last: bool = false,
    _: u6 = 0,
};

/// S->C: pty output. The bytes follow, and `seq` counts the block's
/// output through them.
pub const Out = struct {
    stream: u32,
    seq: u64,
};

/// S->C: the block's grid became `cols` x `rows` after the output through
/// `seq`. The owning client's id ("client:...") follows, if any.
pub const Grid = struct {
    stream: u32,
    seq: u64,
    cols: u16,
    rows: u16,
};

/// C->S: input for the program (keys, paste, mouse), already encoded.
/// The bytes follow. Sending input makes the client the size owner.
pub const In = struct {
    stream: u32,
};

/// C->S: the grid size this client would like. It applies while the
/// client owns the block's size.
pub const Size = struct {
    stream: u32,
    cols: u16,
    rows: u16,
    cell_w_px: u16,
    cell_h_px: u16,
};

/// C->S: the client focused (1) or unfocused (0) the block. Focusing it
/// makes the client the size owner.
pub const Focus = struct {
    stream: u32,
    focused: u8,
};

/// The byte length of a data frame's fixed fields.
fn fixedLen(comptime T: type) usize {
    var n: usize = 0;
    inline for (@typeInfo(T).@"struct".field_types) |F| n += @sizeOf(F);
    return n;
}

/// A complete data frame: header, the fields of `fields` in order (little
/// endian), then `tail`. The caller owns the result.
pub fn encodeData(
    alloc: Allocator,
    t: FrameType,
    fields: anytype,
    tail: []const u8,
) Allocator.Error![]u8 {
    const T = @TypeOf(fields);
    const len = fixedLen(T) + tail.len;
    const buf = try alloc.alloc(u8, header_len + len);
    buf[0..header_len].* = header(len, t);
    var off: usize = header_len;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        const Int = @Int(.unsigned, @bitSizeOf(F));
        const v: Int = @bitCast(@field(fields, name));
        std.mem.writeInt(Int, buf[off..][0..@sizeOf(Int)], v, .little);
        off += @sizeOf(Int);
    }
    @memcpy(buf[off..], tail);
    return buf;
}

/// The fixed fields of a data frame payload and the bytes after them, or
/// null if the payload is too short.
pub fn decodeData(comptime T: type, payload: []const u8) ?struct { T, []const u8 } {
    if (payload.len < fixedLen(T)) return null;
    var result: T = undefined;
    var off: usize = 0;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        const Int = @Int(.unsigned, @bitSizeOf(F));
        const v = std.mem.readInt(Int, payload[off..][0..@sizeOf(Int)], .little);
        @field(result, name) = @bitCast(v);
        off += @sizeOf(Int);
    }
    return .{ result, payload[off..] };
}

/// The only variables the server keeps from whoever started it, so that
/// one client's environment never leaks into another client's sessions.
pub const daemon_env = [_][]const u8{
    "HOME",           "USER",   "LOGNAME",  "SHELL",  "PATH",
    "LANG",           "LC_ALL", "LC_CTYPE", "TMPDIR", "XDG_RUNTIME_DIR",
    "XDG_STATE_HOME",
};

/// The variables a client hands to the sessions it creates.
pub const session_env = [_][]const u8{ "SSH_AUTH_SOCK", "DISPLAY", "WAYLAND_DISPLAY" };

pub const header_len = 5;

/// Larger frames are a protocol error.
pub const max_frame = 16 * 1024 * 1024;

/// Why a request failed. Each maps to a CLI exit code.
pub const ErrorCode = enum {
    /// The request was malformed.
    usage,
    /// The target session, window, or block is missing or ambiguous.
    target,
    /// Anything else.
    fail,
};

pub fn header(len: usize, t: FrameType) [header_len]u8 {
    var h: [header_len]u8 = undefined;
    std.mem.writeInt(u32, h[0..4], @intCast(len), .little);
    h[4] = @backingInt(t);
    return h;
}

/// The length and type of the frame at the start of `buf`, if its header
/// is complete.
pub fn parseHeader(buf: []const u8) ?struct { len: usize, type: FrameType } {
    if (buf.len < header_len) return null;
    return .{
        .len = std.mem.readInt(u32, buf[0..4], .little),
        .type = @fromBackingInt(@intCast(buf[4])),
    };
}

pub const WriteError = error{WriteFailed};

/// Write all of `data` to a blocking socket.
pub fn writeAll(fd: posix.fd_t, data: []const u8) WriteError!void {
    const flags: u32 = if (builtin.os.tag == .linux) c.MSG.NOSIGNAL else 0;
    var rest = data;
    while (rest.len > 0) {
        const n = c.send(fd, rest.ptr, rest.len, flags);
        if (n < 0) {
            if (posix.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        rest = rest[@intCast(n)..];
    }
}

pub fn writeFrame(fd: posix.fd_t, t: FrameType, payload: []const u8) WriteError!void {
    const h = header(payload.len, t);
    try writeAll(fd, &h);
    try writeAll(fd, payload);
}

pub const ReadError = error{ EndOfStream, ReadFailed, FrameTooLarge } || Allocator.Error;

fn readExact(fd: posix.fd_t, buf: []u8) ReadError!void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = c.read(fd, buf[got..].ptr, buf.len - got);
        if (n < 0) {
            if (posix.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) return error.EndOfStream;
        got += @intCast(n);
    }
}

/// Read one frame from a blocking socket. The caller owns the payload.
pub fn readFrame(alloc: Allocator, fd: posix.fd_t) ReadError!struct { type: FrameType, payload: []u8 } {
    var h: [header_len]u8 = undefined;
    try readExact(fd, &h);
    const info = parseHeader(&h).?;
    if (info.len > max_frame) return error.FrameTooLarge;
    const payload = try alloc.alloc(u8, info.len);
    errdefer alloc.free(payload);
    try readExact(fd, payload);
    return .{ .type = info.type, .payload = payload };
}

/// The socket path a client uses: `-S`, else `RAP_SERVER`, else the
/// per-user default.
pub fn socketPath(
    alloc: Allocator,
    env: *const std.process.Environ.Map,
    flag: ?[]const u8,
) ![:0]u8 {
    if (flag orelse env.get("RAP_SERVER")) |p| if (p.len > 0) return alloc.dupeSentinel(u8, p, 0);
    return defaultSocketPath(alloc, env);
}

/// `socketPath`, made absolute, since the server and the programs in its
/// blocks run elsewhere. Allocates more than the result; use an arena.
pub fn resolveSocketPath(
    alloc: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    flag: ?[]const u8,
) ![:0]u8 {
    const path = try socketPath(alloc, env, flag);
    if (std.fs.path.isAbsolute(path)) return path;
    const cwd = try std.process.currentPathAlloc(io, alloc);
    const abs = try std.fs.path.resolve(alloc, &.{ cwd, path });
    return alloc.dupeSentinel(u8, abs, 0);
}

/// The server a client talks to: `resolveSocketPath`, unless `-S` or
/// `RAP_SERVER` is `host[:port]` for a node on the tailnet and no file
/// here; then that node's `ip:port`. Allocates more than the result; use
/// an arena.
pub fn resolveServer(
    alloc: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    flag: ?[]const u8,
) ![:0]u8 {
    const s = flag orelse env.get("RAP_SERVER") orelse "";
    tailnet: {
        if (s.len == 0 or std.mem.indexOfScalar(u8, s, '/') != null) break :tailnet;
        if (std.Io.Dir.cwd().access(io, s, .{})) |_| break :tailnet else |_| {}
        const colon = std.mem.lastIndexOfScalar(u8, s, ':');
        const port = if (colon) |i| std.fmt.parseInt(u16, s[i + 1 ..], 10) catch break :tailnet else tailscale.default_port;
        const host = s[0 .. colon orelse s.len];
        const st = tailscale.status(alloc, io) catch break :tailnet;
        const node = for (st.peers) |p| {
            if (p.named(host)) break p;
        } else if (st.self.named(host)) st.self else break :tailnet;
        return std.fmt.allocPrintSentinel(alloc, "{f}", .{Ip4Address{ .bytes = node.ip, .port = port }}, 0);
    }
    return resolveSocketPath(alloc, io, env, flag);
}

/// The address of a tailnet server as `resolveServer` gives it: `ip:port`
/// in Tailscale's 100.64.0.0/10.
pub fn tailnetAddress(server: []const u8) ?Ip4Address {
    const colon = std.mem.lastIndexOfScalar(u8, server, ':') orelse return null;
    const port = std.fmt.parseInt(u16, server[colon + 1 ..], 10) catch return null;
    const addr = Ip4Address.parse(server[0..colon], port) catch return null;
    if (addr.bytes[0] != 100 or addr.bytes[1] & 0xc0 != 64) return null;
    return addr;
}

extern "c" fn confstr(name: c_int, buf: ?[*]u8, len: usize) usize;
const _CS_DARWIN_USER_TEMP_DIR = 65537;

/// `$(getconf DARWIN_USER_TEMP_DIR)rap/default.sock` on macOS, else
/// `$XDG_RUNTIME_DIR/rap/default.sock` or `/tmp/rap-<uid>/default.sock`.
/// The directory is private to the user.
pub fn defaultSocketPath(alloc: Allocator, env: *const std.process.Environ.Map) ![:0]u8 {
    if (comptime builtin.os.tag.isDarwin()) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.len);
        if (n > 1 and n <= buf.len) {
            const dir = std.mem.trimEnd(u8, buf[0 .. n - 1], "/");
            return std.fmt.allocPrintSentinel(alloc, "{s}/rap/default.sock", .{dir}, 0);
        }
    }
    if (env.get("XDG_RUNTIME_DIR")) |dir| if (dir.len > 0)
        return std.fmt.allocPrintSentinel(alloc, "{s}/rap/default.sock", .{dir}, 0);
    return std.fmt.allocPrintSentinel(alloc, "/tmp/rap-{d}/default.sock", .{c.getuid()}, 0);
}

pub fn sockaddr(path: []const u8) error{NameTooLong}!c.sockaddr.un {
    var addr: c.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

/// Set close-on-exec so children the server spawns never inherit `fd`.
pub fn setCloexec(fd: posix.fd_t) void {
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
}

pub fn setNonblocking(fd: posix.fd_t, on: bool) void {
    const fl = c.fcntl(fd, c.F.GETFL);
    const nb: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    _ = c.fcntl(fd, c.F.SETFL, if (on) fl | nb else fl & ~nb);
}

pub fn unixSocket() error{SocketFailed}!posix.fd_t {
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    setCloexec(fd);
    return fd;
}

pub const ConnectError = error{ Unreachable, NameTooLong, SocketFailed, ForeignServer };

/// Connect to the server: a socket path, or a tailnet server's address
/// from `resolveServer`. `Unreachable` means no server is listening, and
/// `ForeignServer` that another user's process is.
pub fn connect(server: []const u8) ConnectError!posix.fd_t {
    // WireGuard has authenticated the node, and its server checks us.
    if (tailnetAddress(server)) |addr| return dialTcp(addr, 5000);
    const fd = try dialUnix(server);
    errdefer _ = c.close(fd);
    const p = peer(fd) catch return error.ForeignServer;
    if (p.uid != c.getuid()) return error.ForeignServer;
    return fd;
}

/// Connect to the Unix socket at `path`, whoever listens there.
pub fn dialUnix(path: []const u8) ConnectError!posix.fd_t {
    const addr = try sockaddr(path);
    const fd = try unixSocket();
    errdefer _ = c.close(fd);
    while (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) {
        if (posix.errno(-1) != .INTR) return error.Unreachable;
    }
    return fd;
}

fn sockaddrIn(addr: Ip4Address) c.sockaddr.in {
    return .{ .port = std.mem.nativeToBig(u16, addr.port), .addr = @bitCast(addr.bytes) };
}

fn tcpSocket() error{SocketFailed}!posix.fd_t {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    setCloexec(fd);
    return fd;
}

/// Send keystrokes as they come rather than batched.
pub fn setNodelay(fd: posix.fd_t) void {
    const on: c_int = 1;
    _ = c.setsockopt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, std.mem.asBytes(&on), @sizeOf(c_int));
}

/// Connect to `addr` over TCP within `timeout_ms`, since a node that is
/// offline never answers.
pub fn dialTcp(addr: Ip4Address, timeout_ms: c_int) ConnectError!posix.fd_t {
    const fd = try tcpSocket();
    errdefer _ = c.close(fd);
    const sa = sockaddrIn(addr);
    setNonblocking(fd, true);
    if (c.connect(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in)) != 0) {
        if (posix.errno(-1) != .INPROGRESS) return error.Unreachable;
        var pfd = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.OUT, .revents = 0 }};
        if (c.poll(&pfd, 1, timeout_ms) != 1) return error.Unreachable;
        var err: c_int = 0;
        var len: c.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &err, &len) != 0 or err != 0) return error.Unreachable;
    }
    setNonblocking(fd, false);
    setNodelay(fd);
    return fd;
}

/// Listen on `addr` over TCP, nonblocking.
pub fn listenTcp(addr: Ip4Address) error{ SocketFailed, AddressInUse, BindFailed, ListenFailed }!posix.fd_t {
    const fd = try tcpSocket();
    errdefer _ = c.close(fd);
    // A restarted server may listen while its old connections linger.
    const on: c_int = 1;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, std.mem.asBytes(&on), @sizeOf(c_int));
    const sa = sockaddrIn(addr);
    if (c.bind(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in)) != 0)
        return if (posix.errno(-1) == .ADDRINUSE) error.AddressInUse else error.BindFailed;
    if (c.listen(fd, 64) != 0) return error.ListenFailed;
    setNonblocking(fd, true);
    return fd;
}

/// The address of the other end of a TCP connection.
pub fn peerAddress(fd: posix.fd_t) ?Ip4Address {
    var sa: c.sockaddr.in = undefined;
    var len: c.socklen_t = @sizeOf(c.sockaddr.in);
    if (c.getpeername(fd, @ptrCast(&sa), &len) != 0 or sa.family != c.AF.INET) return null;
    return .{ .bytes = @bitCast(sa.addr), .port = std.mem.bigToNative(u16, sa.port) };
}

pub const Peer = struct {
    uid: c.uid_t,
    gid: c.gid_t,
    /// Zero if unknown.
    pid: c.pid_t = 0,
};

extern "c" fn getpeereid(fd: c_int, uid: *c.uid_t, gid: *c.gid_t) c_int;

/// The credentials of the process on the other end of a Unix socket.
pub fn peer(fd: posix.fd_t) error{Unsupported}!Peer {
    switch (builtin.os.tag) {
        .linux => {
            const ucred = extern struct { pid: c.pid_t, uid: c.uid_t, gid: c.gid_t };
            var cred: ucred = undefined;
            var len: c.socklen_t = @sizeOf(ucred);
            if (c.getsockopt(fd, c.SOL.SOCKET, std.os.linux.SO.PEERCRED, &cred, &len) != 0)
                return error.Unsupported;
            return .{ .uid = cred.uid, .gid = cred.gid, .pid = cred.pid };
        },
        else => {
            var p: Peer = .{ .uid = undefined, .gid = undefined };
            if (getpeereid(fd, &p.uid, &p.gid) != 0) return error.Unsupported;
            if (comptime builtin.os.tag.isDarwin()) {
                const SOL_LOCAL = 0;
                const LOCAL_PEERPID = 2;
                var len: c.socklen_t = @sizeOf(c.pid_t);
                if (c.getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &p.pid, &len) != 0) p.pid = 0;
            }
            return p;
        },
    }
}

test "rex protocol: frame header round trip" {
    const h = header(300, .json);
    const info = parseHeader(&h).?;
    try std.testing.expectEqual(300, info.len);
    try std.testing.expectEqual(FrameType.json, info.type);
    try std.testing.expect(parseHeader(h[0..4]) == null);
}

test "rex protocol: data frame round trip" {
    const alloc = std.testing.allocator;
    const frame = try encodeData(alloc, .snap, Snap{
        .stream = 7,
        .base_seq = 1 << 40,
        .flags = .{ .first = true },
    }, "bytes");
    defer alloc.free(frame);
    const info = parseHeader(frame).?;
    try std.testing.expectEqual(FrameType.snap, info.type);
    try std.testing.expectEqual(frame.len - header_len, info.len);

    const fields, const tail = decodeData(Snap, frame[header_len..]).?;
    try std.testing.expectEqual(7, fields.stream);
    try std.testing.expectEqual(1 << 40, fields.base_seq);
    try std.testing.expect(fields.flags.first and !fields.flags.last);
    try std.testing.expectEqualStrings("bytes", tail);
    try std.testing.expect(decodeData(Size, "short") == null);
}

test "rex protocol: frames over a socket pair carry peer credentials" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(0, c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer for (fds) |fd| {
        _ = c.close(fd);
    };

    try writeFrame(fds[0], .json, "{\"id\":1}");
    const frame = try readFrame(std.testing.allocator, fds[1]);
    defer std.testing.allocator.free(frame.payload);
    try std.testing.expectEqual(FrameType.json, frame.type);
    try std.testing.expectEqualStrings("{\"id\":1}", frame.payload);

    const p = try peer(fds[1]);
    try std.testing.expectEqual(c.getuid(), p.uid);
}

test "rex protocol: socket path precedence" {
    const alloc = std.testing.allocator;
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("RAP_SERVER", "/tmp/env.sock");

    const flag = try socketPath(alloc, &env, "/tmp/flag.sock");
    defer alloc.free(flag);
    try std.testing.expectEqualStrings("/tmp/flag.sock", flag);
    const from_env = try socketPath(alloc, &env, null);
    defer alloc.free(from_env);
    try std.testing.expectEqualStrings("/tmp/env.sock", from_env);

    _ = env.swapRemove("RAP_SERVER");
    const default = try socketPath(alloc, &env, null);
    defer alloc.free(default);
    try std.testing.expect(std.mem.endsWith(u8, default, "/default.sock"));
    try std.testing.expect(default.len < (c.sockaddr.un{ .path = undefined }).path.len);
}

test "rex protocol: tailnet addresses" {
    const addr = tailnetAddress("100.96.1.3:7277").?;
    try std.testing.expectEqualSlices(u8, &.{ 100, 96, 1, 3 }, &addr.bytes);
    try std.testing.expectEqual(7277, addr.port);
    try std.testing.expect(tailnetAddress("100.127.255.1:1") != null);
    // Off the tailnet, or no address at all.
    for ([_][]const u8{ "100.128.0.1:7277", "10.0.0.1:7277", "100.96.1.3", "/tmp/100.96.1.3:7277", "box:7277" }) |s|
        try std.testing.expect(tailnetAddress(s) == null);
}

test "rex protocol: a socket path is no tailnet server" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try std.testing.expectEqualStrings("/tmp/s.sock", try resolveServer(arena.allocator(), std.testing.io, &env, "/tmp/s.sock"));
    const rel = try resolveServer(arena.allocator(), std.testing.io, &env, "raptor-no-such-node.sock");
    try std.testing.expect(std.fs.path.isAbsolute(rel) and tailnetAddress(rel) == null);
}
