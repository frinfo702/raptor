//! The rap server: one process per user that owns every session, window
//! and block, and answers clients over a Unix socket.
//!
//! Everything runs on one libxev loop thread: the listener, every client
//! socket, every block's pty and child, and a tick timer for idle exit.
//! The object model is session -> window (a tab) -> block (a pane), and
//! each window lays its blocks out in a split tree. Every change to what a
//! session looks like bumps its `revision`.
//!
//! See `protocol.zig` for framing and message shapes.
const Server = @This();

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const Stringify = std.json.Stringify;
const build_config = @import("../build_config.zig");
const xev = @import("../global.zig").xev;
const Block = @import("Block.zig");
const ids = @import("ids.zig");
const layout = @import("layout.zig");
const protocol = @import("protocol.zig");

const log = std.log.scoped(.rex_server);

/// How often the server checks for idleness and signals.
const tick_ms = 250;

/// Set from a signal handler to make the server exit.
pub var signaled: std.atomic.Value(bool) = .init(false);

pub const Options = struct {
    socket_path: [:0]const u8,

    /// The environment the server was started with. Only the names in
    /// `protocol.daemon_env` are kept.
    env: *const EnvMap,

    /// Exit once there have been no sessions and no clients for this long.
    idle_timeout_ms: u64 = 30_000,
};

const Tree = layout.Tree(*Pane);

const Session = struct {
    id: ids.Uuid,
    label: []u8,
    revision: u64 = 0,
    windows: std.ArrayList(*Window) = .empty,
    active: ?*Window = null,
    /// Variables from the client that created the session, given to
    /// every block in it.
    env: EnvMap,
    /// The working directory of new blocks, from the creating client.
    cwd: ?[:0]u8,
};

const Window = struct {
    id: ids.Uuid,
    label: []u8,
    session: *Session,
    tree: Tree,
    focused: *Pane,
    zoomed: ?*Pane = null,
};

/// A block as the server tracks it. The API calls it a block; `Block` is
/// the engine running its child and terminal.
const Pane = struct {
    server: *Server,
    id: ids.Uuid,
    label: []u8 = &.{},
    session_id: ids.Uuid,
    /// Null once the block is closed. A closed block lingers in `dying`
    /// until its child is gone.
    window: ?*Window = null,
    block: *Block = undefined,
    /// Only backends that read for us need a buffer per block.
    own_buf: ?*Block.ReadBuffer = null,
    title: std.ArrayList(u8) = .empty,
    pwd: std.ArrayList(u8) = .empty,
    exit_code: ?u32 = null,
    /// Requests answered when the child exits.
    waiters: std.ArrayList(Waiter) = .empty,
};

const Waiter = struct {
    client: *Client,
    id: ?i64,
};

const Client = struct {
    server: *Server,
    id: ids.Uuid,
    fd: posix.fd_t,
    peer: protocol.Peer,
    poll_c: xev.Completion = .{},
    in: std.ArrayList(u8) = .empty,
    subscribed: bool = false,
    /// Only events of this session (and server-wide ones) are sent.
    filter: ?ids.Uuid = null,
    /// Its socket was shut down; it is dropped from its own callback.
    closing: bool = false,
};

alloc: Allocator,
io: std.Io,
loop: xev.Loop,
read_buf: *Block.ReadBuffer,
socket_path: [:0]u8,
socket_unlinked: bool = false,
lock_fd: posix.fd_t,
listen_fd: posix.fd_t,
listen_c: xev.Completion = .{},
timer: xev.Timer,
timer_c: xev.Completion = .{},
env: EnvMap,
idle_timeout_ms: u64,
idle_since: ?i64 = null,
started_ms: i64,
stopping: bool = false,

sessions: std.ArrayList(*Session) = .empty,
clients: std.ArrayList(*Client) = .empty,
/// Closed blocks whose engine still has work on the loop.
dying: std.ArrayList(*Pane) = .empty,
/// The exit codes of the latest blocks whose program exited, so that a
/// wait or write arriving after the block is gone still gets an answer.
exited: [64]struct { id: ids.Uuid, code: u32 } = @splat(.{ .id = @splat(0), .code = 0 }),
exited_next: usize = 0,
/// Clients dropped during this loop iteration, then during the previous
/// one. A client is freed only after the loop has run once more so that
/// its disarmed poll is gone before its fd number can be reused.
dead: std.ArrayList(*Client) = .empty,
reap: std.ArrayList(*Client) = .empty,

/// Take the server lock and listen on the socket. Fails with
/// `AlreadyRunning` if another server holds the lock.
pub fn create(alloc: Allocator, io: std.Io, opts: Options) !*Server {
    const self = try alloc.create(Server);
    errdefer alloc.destroy(self);

    const path = try alloc.dupeSentinel(u8, opts.socket_path, 0);
    errdefer alloc.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        const dirz = try alloc.dupeSentinel(u8, dir, 0);
        defer alloc.free(dirz);
        if (c.mkdir(dirz, 0o700) != 0 and posix.errno(-1) != .EXIST) return error.SocketDir;
        const default = try protocol.defaultSocketPath(alloc, opts.env);
        defer alloc.free(default);
        if (std.mem.eql(u8, path, default)) {
            const dir_fd = c.open(dirz, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
            if (dir_fd < 0) return error.SocketDir;
            defer _ = c.close(dir_fd);
            var st: c.Stat = undefined;
            if (c.fstat(dir_fd, &st) != 0) return error.SocketDir;
            if (st.uid != c.getuid() or st.mode & 0o022 != 0) return error.SocketDirUnsafe;
        }
    }

    // Only the lock holder may touch the socket path, so a stale socket
    // left by a crashed server is removed here and nowhere else.
    const lock_path = try std.fmt.allocPrintSentinel(alloc, "{s}.lock", .{path}, 0);
    defer alloc.free(lock_path);
    const lock_fd = c.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (lock_fd < 0) return error.LockFailed;
    errdefer _ = c.close(lock_fd);
    if (c.flock(lock_fd, c.LOCK.EX | c.LOCK.NB) != 0) return error.AlreadyRunning;
    _ = c.unlink(path);

    const addr = try protocol.sockaddr(path);
    const fd = try protocol.unixSocket();
    errdefer _ = c.close(fd);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) return error.BindFailed;
    errdefer _ = c.unlink(path);
    _ = c.chmod(path, 0o600);
    if (c.listen(fd, 64) != 0) return error.ListenFailed;
    protocol.setNonblocking(fd, true);

    var env: EnvMap = .init(alloc);
    errdefer env.deinit();
    for (protocol.daemon_env) |k| if (opts.env.get(k)) |v| try env.put(k, v);

    const read_buf = try alloc.create(Block.ReadBuffer);
    errdefer alloc.destroy(read_buf);
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    self.* = .{
        .alloc = alloc,
        .io = io,
        .loop = loop,
        .read_buf = read_buf,
        .socket_path = path,
        .lock_fd = lock_fd,
        .listen_fd = fd,
        .timer = try .init(),
        .env = env,
        .idle_timeout_ms = opts.idle_timeout_ms,
        .started_ms = undefined,
    };
    self.started_ms = self.nowMs();
    return self;
}

/// Serve until stopped, idle, or signaled. Every block is hung up before
/// this returns.
pub fn run(self: *Server) !void {
    xev.TCP.initFd(self.listen_fd).poll(&self.loop, &self.listen_c, .read, Server, self, onListen);
    self.timer.run(&self.loop, &self.timer_c, tick_ms, Server, self, onTick);
    log.info("listening on {s}", .{self.socket_path});
    while (!self.stopping) {
        try self.loop.run(.once);
        self.reapDead();
    }
    self.unlinkSocket();

    // Hang up every child and every client, then give them a moment to go.
    while (self.sessions.items.len > 0) self.killSession(self.sessions.items[self.sessions.items.len - 1]);
    for (self.clients.items) |cl| self.closeClient(cl);
    const deadline = self.nowMs() + 2000;
    while ((self.dying.items.len > 0 or self.clients.items.len > 0) and self.nowMs() < deadline) {
        try self.loop.run(.once);
        self.reapDead();
    }
    if (self.dying.items.len > 0) log.warn("{d} blocks did not exit", .{self.dying.items.len});
}

/// Free the server. Blocks whose child never exited are leaked.
pub fn destroy(self: *Server) void {
    self.reapDead();
    self.reapDead();
    for (self.clients.items) |cl| self.freeClient(cl);
    self.clients.deinit(self.alloc);
    self.dead.deinit(self.alloc);
    self.reap.deinit(self.alloc);
    self.dying.deinit(self.alloc);
    self.sessions.deinit(self.alloc);
    self.unlinkSocket();
    _ = c.close(self.listen_fd);
    _ = c.close(self.lock_fd);
    self.timer.deinit();
    self.loop.deinit();
    self.env.deinit();
    self.alloc.destroy(self.read_buf);
    self.alloc.free(self.socket_path);
    self.alloc.destroy(self);
}

fn nowMs(self: *const Server) i64 {
    return std.Io.Clock.awake.now(self.io).toMilliseconds();
}

fn unlinkSocket(self: *Server) void {
    if (self.socket_unlinked) return;
    self.socket_unlinked = true;
    _ = c.unlink(self.socket_path);
}

fn onTick(
    self_: ?*Server,
    loop: *xev.Loop,
    comp: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch return .disarm;
    const self = self_.?;
    if (signaled.load(.monotonic) and !self.stopping) {
        log.info("signaled, stopping", .{});
        self.stopping = true;
    }
    if (self.sessions.items.len == 0 and self.clients.items.len == 0) {
        const now = self.nowMs();
        const since = self.idle_since orelse now;
        self.idle_since = since;
        if (!self.stopping and now - since >= self.idle_timeout_ms) {
            log.info("idle, stopping", .{});
            self.stopping = true;
        }
    } else self.idle_since = null;
    // The tick also bounds how long a loop iteration can wait while
    // shutting down.
    self.timer.run(loop, comp, tick_ms, Server, self, onTick);
    return .disarm;
}

fn reapDead(self: *Server) void {
    for (self.reap.items) |cl| self.freeClient(cl);
    self.reap.clearRetainingCapacity();
    std.mem.swap(std.ArrayList(*Client), &self.reap, &self.dead);

    var i: usize = 0;
    while (i < self.dying.items.len) {
        const pane = self.dying.items[i];
        if (!pane.block.isDone()) {
            i += 1;
            continue;
        }
        _ = self.dying.swapRemove(i);
        pane.block.destroy();
        self.freePane(pane);
    }
}

// Clients

fn onListen(
    self_: ?*Server,
    _: *xev.Loop,
    comp: *xev.Completion,
    _: xev.TCP,
    r: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const self = self_.?;
    _ = r catch |err| if (err == error.Canceled) return .disarm;
    while (true) {
        const fd = c.accept(self.listen_fd, null, null);
        if (fd < 0) break;
        self.addClient(fd);
    }
    return Block.rearm(comp);
}

fn addClient(self: *Server, fd: posix.fd_t) void {
    protocol.setCloexec(fd);
    // Writes block, bounded by a send timeout, so replies stay ordered.
    // Reads never block: they use MSG_DONTWAIT after readiness.
    // ponytail: a stuck reader stalls the loop up to the timeout per
    // write; the data plane needs per-client queues with a cap.
    protocol.setNonblocking(fd, false);
    const timeout: posix.timeval = .{ .sec = 5, .usec = 0 };
    // macOS fails this with EINVAL once the peer is gone; the read below
    // notices that.
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDTIMEO, &timeout, @sizeOf(posix.timeval));

    const p = protocol.peer(fd) catch {
        _ = c.close(fd);
        return;
    };
    if (p.uid != c.getuid()) {
        log.warn("rejecting client uid={d} pid={d}", .{ p.uid, p.pid });
        _ = c.close(fd);
        return;
    }

    const cl = self.alloc.create(Client) catch {
        _ = c.close(fd);
        return;
    };
    cl.* = .{ .server = self, .id = ids.uuidv7(self.io), .fd = fd, .peer = p };
    self.clients.append(self.alloc, cl) catch {
        self.alloc.destroy(cl);
        _ = c.close(fd);
        return;
    };
    xev.TCP.initFd(fd).poll(&self.loop, &cl.poll_c, .read, Client, cl, onClient);
    self.emit("client_connected", null, .{
        .client = prefixed("client", &cl.id),
        .uid = p.uid,
        .pid = p.pid,
    });
}

fn onClient(
    cl_: ?*Client,
    _: *xev.Loop,
    comp: *xev.Completion,
    _: xev.TCP,
    r: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const cl = cl_.?;
    const self = cl.server;
    // A spurious wakeup is harmless: the read below doesn't block.
    _ = r catch {};
    if (!cl.closing) self.readClient(cl);
    if (cl.closing) {
        self.dropClient(cl);
        return .disarm;
    }
    return Block.rearm(comp);
}

fn readClient(self: *Server, cl: *Client) void {
    var budget: usize = 256 * 1024;
    var eof = false;
    while (budget > 0) {
        cl.in.ensureUnusedCapacity(self.alloc, 16 * 1024) catch return self.closeClient(cl);
        const buf = cl.in.unusedCapacitySlice();
        const n = c.recv(cl.fd, buf.ptr, buf.len, c.MSG.DONTWAIT);
        if (n < 0) switch (posix.errno(n)) {
            .INTR => continue,
            .AGAIN => break,
            else => {
                eof = true;
                break;
            },
        };
        if (n == 0) {
            eof = true;
            break;
        }
        cl.in.items.len += @intCast(n);
        budget -|= @intCast(n);
    }

    var off: usize = 0;
    while (!cl.closing) {
        const h = protocol.parseHeader(cl.in.items[off..]) orelse break;
        if (h.len > protocol.max_frame or h.type != .json) return self.closeClient(cl);
        const end = off + protocol.header_len + h.len;
        if (cl.in.items.len < end) break;
        self.handleFrame(cl, cl.in.items[off + protocol.header_len .. end]);
        off = end;
    }
    cl.in.replaceRangeAssumeCapacity(0, off, &.{});
    if (eof) self.closeClient(cl);
}

/// Shut the client's socket. It is dropped from its own poll callback,
/// which the shutdown wakes.
fn closeClient(self: *Server, cl: *Client) void {
    _ = self;
    if (cl.closing) return;
    cl.closing = true;
    _ = c.shutdown(cl.fd, posix.SHUT.RDWR);
}

fn dropClient(self: *Server, cl: *Client) void {
    for (self.clients.items, 0..) |other, i| if (other == cl) {
        _ = self.clients.orderedRemove(i);
        break;
    };
    for (self.sessions.items) |s| for (s.windows.items) |w| self.dropWaiters(w.tree.root, cl);
    for (self.dying.items) |pane| removeWaiters(pane, cl);
    self.dead.append(self.alloc, cl) catch self.freeClient(cl);
    self.emit("client_disconnected", null, .{ .client = prefixed("client", &cl.id) });
}

fn dropWaiters(self: *Server, node: *Tree.Node, cl: *Client) void {
    switch (node.*) {
        .leaf => |pane| removeWaiters(pane, cl),
        .split => |s| {
            self.dropWaiters(s.a, cl);
            self.dropWaiters(s.b, cl);
        },
    }
}

fn removeWaiters(pane: *Pane, cl: *Client) void {
    var i: usize = 0;
    while (i < pane.waiters.items.len) {
        if (pane.waiters.items[i].client == cl) {
            _ = pane.waiters.swapRemove(i);
        } else i += 1;
    }
}

fn freeClient(self: *Server, cl: *Client) void {
    _ = c.close(cl.fd);
    cl.in.deinit(self.alloc);
    self.alloc.destroy(cl);
}

fn send(self: *Server, cl: *Client, payload: []const u8) void {
    if (cl.closing) return;
    protocol.writeFrame(cl.fd, .json, payload) catch {
        log.info("dropping client that stopped reading", .{});
        self.closeClient(cl);
    };
}

fn respond(self: *Server, cl: *Client, id: ?i64, result: []const u8) void {
    var buf: std.Io.Writer.Allocating = .init(self.alloc);
    defer buf.deinit();
    writeId(&buf.writer, id) catch return;
    buf.writer.print(",\"result\":{s}}}", .{result}) catch return;
    self.send(cl, buf.written());
}

fn respondError(self: *Server, cl: *Client, id: ?i64, code: protocol.ErrorCode, msg: []const u8) void {
    var buf: std.Io.Writer.Allocating = .init(self.alloc);
    defer buf.deinit();
    writeId(&buf.writer, id) catch return;
    buf.writer.print(",\"error\":{f}}}", .{std.json.fmt(.{ .code = code, .message = msg }, .{})}) catch return;
    self.send(cl, buf.written());
}

fn writeId(w: *std.Io.Writer, id: ?i64) std.Io.Writer.Error!void {
    if (id) |v| try w.print("{{\"id\":{d}", .{v}) else try w.writeAll("{\"id\":null");
}

// Events

/// The API form of an id, such as "block:01a0...".
fn prefixed(comptime kind: []const u8, id: *const ids.Uuid) [kind.len + 1 + 36]u8 {
    return (kind ++ ":").* ++ id.*;
}

/// Send an event to every subscriber. `fields` is a struct of extra
/// fields. Events with no session go to every subscriber.
fn emit(self: *Server, comptime name: []const u8, session: ?*const ids.Uuid, fields: anytype) void {
    for (self.clients.items) |cl| {
        if (cl.subscribed and !cl.closing) break;
    } else return;

    var buf: std.Io.Writer.Allocating = .init(self.alloc);
    defer buf.deinit();
    var w: Stringify = .{ .writer = &buf.writer };
    (blk: {
        w.beginObject() catch |err| break :blk err;
        w.objectField("event") catch |err| break :blk err;
        w.write(name) catch |err| break :blk err;
        if (session) |id| {
            w.objectField("session") catch |err| break :blk err;
            w.write(prefixed("session", id)) catch |err| break :blk err;
        }
        inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |f| {
            w.objectField(f) catch |err| break :blk err;
            w.write(@field(fields, f)) catch |err| break :blk err;
        }
        w.endObject() catch |err| break :blk err;
    }) catch return;

    for (self.clients.items) |cl| {
        if (!cl.subscribed) continue;
        if (session != null and cl.filter != null and !std.mem.eql(u8, &cl.filter.?, session.?)) continue;
        self.send(cl, buf.written());
    }
}

fn viewChanged(self: *Server, s: *Session) void {
    s.revision += 1;
    self.emit("session_view_changed", &s.id, .{ .revision = s.revision });
}

// Block engine events

fn onBlockEvent(block: *Block, event: Block.Event) void {
    const pane: *Pane = @ptrCast(@alignCast(block.userdata.?));
    const self = pane.server;
    const id = prefixed("block", &pane.id);
    switch (event) {
        .output, .write_pty => {},
        .title_changed => |t| {
            pane.title.clearRetainingCapacity();
            pane.title.appendSlice(self.alloc, t) catch {};
            self.emit("title_changed", &pane.session_id, .{ .block = id, .title = t });
        },
        .pwd_changed => |p| {
            pane.pwd.clearRetainingCapacity();
            pane.pwd.appendSlice(self.alloc, p) catch {};
            self.emit("pwd_changed", &pane.session_id, .{ .block = id, .pwd = p });
        },
        .bell => self.emit("bell", &pane.session_id, .{ .block = id }),
        .desktop_notification => |n| self.emit("desktop_notification", &pane.session_id, .{
            .block = id,
            .title = n.title,
            .body = n.body,
        }),
        .progress_report => |p| self.emit("progress_report", &pane.session_id, .{
            .block = id,
            .state = @tagName(p.state),
            .progress = p.progress,
        }),
        .clipboard_write => self.emit("clipboard_written", &pane.session_id, .{ .block = id }),
        .program_status => |p| self.emit("program_status_changed", &pane.session_id, .{
            .block = id,
            .state = @tagName(p.state),
        }),
        .child_exited => |e| {
            pane.exit_code = e.exit_code;
            self.exited[self.exited_next % self.exited.len] = .{ .id = pane.id, .code = e.exit_code };
            self.exited_next += 1;
            var result: [32]u8 = undefined;
            const body = std.fmt.bufPrint(&result, "{{\"exit_code\":{d}}}", .{e.exit_code}) catch unreachable;
            for (pane.waiters.items) |waiter| self.respond(waiter.client, waiter.id, body);
            pane.waiters.clearAndFree(self.alloc);
            self.emit("child_exited", &pane.session_id, .{ .block = id, .exit_code = e.exit_code });
            // A pane goes away with its program.
            self.closePane(pane);
        },
    }
}

// Model

fn sessionByLabel(self: *Server, label: []const u8) ?*Session {
    for (self.sessions.items) |s| if (std.mem.eql(u8, s.label, label)) return s;
    return null;
}

fn freePane(self: *Server, pane: *Pane) void {
    if (pane.own_buf) |b| self.alloc.destroy(b);
    self.alloc.free(pane.label);
    pane.title.deinit(self.alloc);
    pane.pwd.deinit(self.alloc);
    pane.waiters.deinit(self.alloc);
    self.alloc.destroy(pane);
}

/// Start a block in session `s` from the request's `command`, `cwd`,
/// `cols`, and `rows`. It belongs to no window yet.
fn spawnPane(self: *Server, s: *Session, req: *Request) Error!*Pane {
    const pane = try self.alloc.create(Pane);
    errdefer self.alloc.destroy(pane);
    pane.* = .{ .server = self, .id = ids.uuidv7(self.io), .session_id = s.id };

    var env = try self.env.clone(req.arena);
    var it = s.env.iterator();
    while (it.next()) |e| try env.put(e.key_ptr.*, e.value_ptr.*);
    try env.put("RAP_SERVER", self.socket_path);
    try env.put("RAP_SESSION", &prefixed("session", &s.id));
    try env.put("RAP_BLOCK", &prefixed("block", &pane.id));
    try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");

    const args = try req.command() orelse args: {
        const shell = try req.arena.dupeSentinel(u8, self.env.get("SHELL") orelse "/bin/sh", 0);
        break :args try req.arena.dupe([:0]const u8, &.{shell});
    };
    const cwd = if (req.str("cwd")) |p| try req.arena.dupeSentinel(u8, p, 0) else s.cwd orelse
        if (self.env.get("HOME")) |h| try req.arena.dupeSentinel(u8, h, 0) else null;

    if (!Block.kqueue) pane.own_buf = try self.alloc.create(Block.ReadBuffer);
    errdefer if (pane.own_buf) |b| self.alloc.destroy(b);
    pane.block = Block.create(self.alloc, &self.loop, pane.own_buf orelse self.read_buf, .{
        .args = args,
        .env = &env,
        .cwd = cwd,
        .cols = req.size("cols", 80),
        .rows = req.size("rows", 24),
        .on_event = &onBlockEvent,
        .userdata = pane,
    }) catch |err| return req.fail(error.Fail, "starting {s} failed: {t}", .{ args[0], err });
    return pane;
}

/// Open a window with one new block in session `s`.
fn newWindow(self: *Server, s: *Session, req: *Request, label: ?[]const u8) Error!*Window {
    const pane = try self.spawnPane(s, req);
    errdefer {
        pane.block.kill();
        self.dying.append(self.alloc, pane) catch {};
    }
    const w = try self.alloc.create(Window);
    errdefer self.alloc.destroy(w);
    w.* = .{
        .id = ids.uuidv7(self.io),
        .label = undefined,
        .session = s,
        .tree = try .init(self.alloc, pane),
        .focused = pane,
    };
    errdefer w.tree.deinit(self.alloc);
    w.label = if (label) |l|
        try self.alloc.dupe(u8, l)
    else if (s.windows.items.len == 0)
        try self.alloc.dupe(u8, "Primary")
    else
        try std.fmt.allocPrint(self.alloc, "Window {s}", .{w.id[28..]});
    errdefer self.alloc.free(w.label);
    try s.windows.append(self.alloc, w);
    pane.window = w;
    s.active = w;

    const wid = prefixed("window", &w.id);
    self.emit("window_created", &s.id, .{ .window = wid, .label = w.label });
    self.emit("block_created", &s.id, .{ .block = prefixed("block", &pane.id), .window = wid });
    self.emit("active_window_changed", &s.id, .{ .window = wid });
    self.viewChanged(s);
    return w;
}

/// Close a block: hang up its child and drop it from its window. The
/// window closes with its last block, and the session with its last window.
fn closePane(self: *Server, pane: *Pane) void {
    const w = pane.window orelse return;
    if (w.tree.count() == 1) return self.closeWindow(w);
    w.tree.remove(self.alloc, pane);
    if (w.focused == pane) w.focused = w.tree.first();
    if (w.zoomed == pane) w.zoomed = null;
    self.retirePane(pane);
    self.viewChanged(w.session);
}

fn retirePane(self: *Server, pane: *Pane) void {
    const w = pane.window.?;
    pane.window = null;
    self.emit("block_closed", &w.session.id, .{
        .block = prefixed("block", &pane.id),
        .window = prefixed("window", &w.id),
    });
    pane.block.kill();
    // ponytail: on OOM the block is leaked rather than freed under the loop.
    self.dying.append(self.alloc, pane) catch {};
}

fn closeWindow(self: *Server, w: *Window) void {
    const s = w.session;
    while (w.tree.count() > 1) {
        const pane = w.tree.first();
        w.tree.remove(self.alloc, pane);
        self.retirePane(pane);
    }
    self.retirePane(w.tree.first());
    w.tree.deinit(self.alloc);

    for (s.windows.items, 0..) |other, i| if (other == w) {
        _ = s.windows.orderedRemove(i);
        break;
    };
    self.emit("window_closed", &s.id, .{ .window = prefixed("window", &w.id) });
    self.alloc.free(w.label);
    self.alloc.destroy(w);

    if (s.windows.items.len == 0) return self.destroySession(s);
    if (s.active == w) {
        const active = s.windows.items[s.windows.items.len - 1];
        s.active = active;
        self.emit("active_window_changed", &s.id, .{ .window = prefixed("window", &active.id) });
    }
    self.viewChanged(s);
}

/// Close every window, which destroys the session.
fn killSession(self: *Server, s: *Session) void {
    var n = s.windows.items.len;
    while (n > 0) : (n -= 1) self.closeWindow(s.windows.items[n - 1]);
}

fn destroySession(self: *Server, s: *Session) void {
    for (self.sessions.items, 0..) |other, i| if (other == s) {
        _ = self.sessions.orderedRemove(i);
        break;
    };
    self.emit("session_destroyed", &s.id, .{ .label = s.label });
    for (self.clients.items) |cl| if (cl.filter) |f| if (std.mem.eql(u8, &f, &s.id)) self.closeClient(cl);
    self.alloc.free(s.label);
    if (s.cwd) |p| self.alloc.free(p);
    s.env.deinit();
    s.windows.deinit(self.alloc);
    self.alloc.destroy(s);
}

// Requests

const Error = error{ Usage, Target, Fail, Deferred } || Allocator.Error || Stringify.Error;

const Request = struct {
    arena: Allocator,
    client: *Client,
    id: ?i64,
    params: ?std.json.ObjectMap,
    /// Why the request failed.
    msg: []const u8 = "",

    fn fail(self: *Request, err: Error, comptime fmt: []const u8, args: anytype) Error {
        self.msg = std.fmt.allocPrint(self.arena, fmt, args) catch "out of memory";
        return err;
    }

    fn get(self: *const Request, key: []const u8) ?std.json.Value {
        return (self.params orelse return null).get(key);
    }

    fn str(self: *const Request, key: []const u8) ?[]const u8 {
        const v = self.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    fn flag(self: *const Request, key: []const u8) ?bool {
        const v = self.get(key) orelse return null;
        return if (v == .bool) v.bool else null;
    }

    fn size(self: *const Request, key: []const u8, default: u16) u16 {
        const v = self.get(key) orelse return default;
        if (v != .integer or v.integer < 1 or v.integer > 1000) return default;
        return @intCast(v.integer);
    }

    /// The `command` argv, if given.
    fn command(self: *Request) Error!?[]const [:0]const u8 {
        const v = self.get("command") orelse return null;
        if (v != .array or v.array.items.len == 0) return self.fail(error.Usage, "command must be a non-empty array of strings", .{});
        const args = try self.arena.alloc([:0]const u8, v.array.items.len);
        for (v.array.items, args) |item, *arg| {
            if (item != .string) return self.fail(error.Usage, "command must be a non-empty array of strings", .{});
            arg.* = try self.arena.dupeSentinel(u8, item.string, 0);
        }
        return args;
    }
};

const Handler = *const fn (*Server, *Request, *Stringify) Error!void;

const methods = std.StaticStringMap(Handler).initComptime(.{
    .{ "server.version", &serverVersion },
    .{ "server.status", &serverStatus },
    .{ "server.stop", &serverStop },
    .{ "session.list", &sessionList },
    .{ "session.create", &sessionCreate },
    .{ "session.view", &sessionView },
    .{ "session.subscribe", &sessionSubscribe },
    .{ "session.new_window", &sessionNewWindow },
    .{ "session.new_split", &sessionNewSplit },
    .{ "session.close_window", &sessionCloseWindow },
    .{ "session.zoom_block", &sessionZoomBlock },
    .{ "session.focus", &sessionFocus },
    .{ "session.set_label", &sessionSetLabel },
    .{ "session.set_window_label", &sessionSetWindowLabel },
    .{ "session.describe_block", &sessionDescribeBlock },
    .{ "session.kill", &sessionKill },
    .{ "block.close", &blockClose },
    .{ "block.method", &blockMethod },
    .{ "block.wait", &blockWait },
});

fn handleFrame(self: *Server, cl: *Client, payload: []const u8) void {
    var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch
        return self.respondError(cl, null, .usage, "request is not JSON");
    if (root != .object) return self.respondError(cl, null, .usage, "request is not an object");
    const id: ?i64 = if (root.object.get("id")) |v| (if (v == .integer) v.integer else null) else null;
    const method = if (root.object.get("method")) |v| (if (v == .string) v.string else "") else "";
    const params = if (root.object.get("params")) |v| (if (v == .object) v.object else null) else null;

    const handler = methods.get(method) orelse
        return self.respondError(cl, id, .usage, "unknown method");
    var req: Request = .{
        .arena = arena,
        .client = cl,
        .id = id,
        .params = params,
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    var w: Stringify = .{ .writer = &out.writer };
    handler(self, &req, &w) catch |err| return switch (err) {
        error.Deferred => {},
        error.Usage => self.respondError(cl, id, .usage, req.msg),
        error.Target => self.respondError(cl, id, .target, req.msg),
        error.Fail => self.respondError(cl, id, .fail, req.msg),
        error.OutOfMemory, error.WriteFailed => self.respondError(cl, id, .fail, @errorName(err)),
    };
    self.respond(cl, id, out.written());
}

/// Find one item by full id, then label, then 1-based position, then an
/// id suffix of at least 4 characters.
fn match(
    comptime T: type,
    comptime kind: []const u8,
    items: []const *T,
    query: []const u8,
    req: *Request,
) Error!*T {
    const bare = if (std.mem.startsWith(u8, query, kind ++ ":")) query[kind.len + 1 ..] else query;
    for (items) |it| if (std.mem.eql(u8, &it.id, bare)) return it;

    var found: ?*T = null;
    var n: usize = 0;
    for (items) |it| if (std.mem.eql(u8, it.label, query)) {
        found = it;
        n += 1;
    };
    if (n == 1) return found.?;
    if (n > 1) return req.fail(error.Target, "{s} '{s}' is ambiguous", .{ kind, query });

    if (std.fmt.parseInt(usize, query, 10)) |pos| {
        if (pos >= 1 and pos <= items.len) return items[pos - 1];
    } else |_| {}

    if (bare.len >= 4) {
        for (items) |it| if (std.mem.endsWith(u8, &it.id, bare)) {
            found = it;
            n += 1;
        };
        if (n == 1) return found.?;
        if (n > 1) return req.fail(error.Target, "{s} '{s}' is ambiguous", .{ kind, query });
    }
    return req.fail(error.Target, "no {s} '{s}'", .{ kind, query });
}

fn sessionPanes(s: *Session, alloc: Allocator) Allocator.Error![]*Pane {
    var list: std.ArrayList(*Pane) = .empty;
    for (s.windows.items) |w| {
        const leaves = try w.tree.leaves(alloc);
        try list.appendSlice(alloc, leaves);
    }
    return list.items;
}

const Target = struct {
    session: *Session,
    window: *Window,
    pane: *Pane,
};

/// Resolve the `session`, `window`, and `block` params. A missing session
/// is the block's session, else the newest one; a missing window is the
/// block's window, else the active one; a missing block is the window's
/// focused block. Block positions count within the window, so a block
/// position alone targets the newest session.
fn resolve(self: *Server, req: *Request) Error!Target {
    const block_q = req.str("block");
    const s: *Session = if (req.str("session")) |q|
        try match(Session, "session", self.sessions.items, q, req)
    else if (block_q != null and req.str("window") == null and
        std.meta.isError(std.fmt.parseInt(usize, block_q.?, 10)))
    s: {
        var all: std.ArrayList(*Pane) = .empty;
        for (self.sessions.items) |sess| try all.appendSlice(req.arena, try sessionPanes(sess, req.arena));
        break :s (try match(Pane, "block", all.items, block_q.?, req)).window.?.session;
    } else if (self.sessions.items.len > 0)
        self.sessions.items[self.sessions.items.len - 1]
    else
        return req.fail(error.Target, "no sessions", .{});

    var w: *Window = if (req.str("window")) |q|
        try match(Window, "window", s.windows.items, q, req)
    else
        s.active.?;

    const pane: *Pane = if (block_q) |q| pane: {
        const in_window = try w.tree.leaves(req.arena);
        if (std.fmt.parseInt(usize, q, 10)) |pos| {
            if (pos >= 1 and pos <= in_window.len) break :pane in_window[pos - 1];
        } else |_| {}
        const pane = try match(Pane, "block", try sessionPanes(s, req.arena), q, req);
        if (req.str("window") != null and pane.window != w)
            return req.fail(error.Target, "block '{s}' is not in that window", .{q});
        break :pane pane;
    } else w.focused;
    w = pane.window.?;
    return .{ .session = s, .window = w, .pane = pane };
}

fn serverVersion(_: *Server, _: *Request, w: *Stringify) Error!void {
    try w.write(.{
        .version = build_config.version_string,
        .protocol = protocol.version,
    });
}

fn serverStatus(self: *Server, _: *Request, w: *Stringify) Error!void {
    try w.write(.{
        .version = build_config.version_string,
        .protocol = protocol.version,
        .pid = c.getpid(),
        .socket = self.socket_path,
        .sessions = self.sessions.items.len,
        .clients = self.clients.items.len,
        .uptime_ms = self.nowMs() - self.started_ms,
    });
}

fn serverStop(self: *Server, _: *Request, w: *Stringify) Error!void {
    // The socket is gone by the time the client hears back.
    self.unlinkSocket();
    self.stopping = true;
    try w.write(.{});
}

fn writeSessionSummary(s: *Session, w: *Stringify) Error!void {
    var blocks: usize = 0;
    for (s.windows.items) |win| blocks += win.tree.count();
    try w.write(.{
        .id = prefixed("session", &s.id),
        .label = s.label,
        .revision = s.revision,
        .windows = s.windows.items.len,
        .blocks = blocks,
        .active_window = prefixed("window", &s.active.?.id),
    });
}

fn sessionList(self: *Server, _: *Request, w: *Stringify) Error!void {
    try w.beginObject();
    try w.objectField("sessions");
    try w.beginArray();
    for (self.sessions.items) |s| try writeSessionSummary(s, w);
    try w.endArray();
    try w.endObject();
}

fn sessionCreate(self: *Server, req: *Request, w: *Stringify) Error!void {
    const win = try self.createSession(req);
    if (req.flag("wait") orelse false) {
        try win.focused.waiters.append(self.alloc, .{ .client = req.client, .id = req.id });
        return error.Deferred;
    }
    const s = win.session;
    try w.write(.{
        .session = prefixed("session", &s.id),
        .label = s.label,
        .window = prefixed("window", &win.id),
        .block = prefixed("block", &win.focused.id),
    });
}

/// Create a session with one window from the request's `label`, `env`,
/// `cwd`, and `command`.
fn createSession(self: *Server, req: *Request) Error!*Window {
    var name_buf: [40]u8 = undefined;
    const label = if (req.str("label")) |l| label: {
        if (l.len == 0) return req.fail(error.Usage, "session name is empty", .{});
        if (self.sessionByLabel(l) != null) return req.fail(error.Fail, "session '{s}' already exists", .{l});
        break :label l;
    } else label: {
        for (0..50) |_| {
            const name = ids.sessionName(self.io, &name_buf);
            if (self.sessionByLabel(name) == null) break :label name;
        }
        var n: usize = 2;
        while (true) : (n += 1) {
            const name = std.fmt.bufPrint(&name_buf, "session-{d}", .{n}) catch unreachable;
            if (self.sessionByLabel(name) == null) break :label name;
        }
    };

    const s = try self.alloc.create(Session);
    errdefer self.alloc.destroy(s);
    s.* = .{
        .id = ids.uuidv7(self.io),
        .label = try self.alloc.dupe(u8, label),
        .env = .init(self.alloc),
        .cwd = null,
    };
    errdefer {
        self.alloc.free(s.label);
        s.env.deinit();
        if (s.cwd) |p| self.alloc.free(p);
    }
    if (req.get("env")) |v| if (v == .object) {
        var it = v.object.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .string) try s.env.put(e.key_ptr.*, e.value_ptr.string);
    };
    if (req.str("cwd")) |p| s.cwd = try self.alloc.dupeSentinel(u8, p, 0);

    try self.sessions.append(self.alloc, s);
    errdefer _ = self.sessions.pop();
    self.emit("session_created", &s.id, .{ .label = s.label });
    return self.newWindow(s, req, null) catch |err| {
        self.emit("session_destroyed", &s.id, .{ .label = s.label });
        return err;
    };
}

const LeafWriter = struct {
    pub fn writeLeaf(_: LeafWriter, w: *Stringify, pane: *Pane) Stringify.Error!void {
        try w.objectField("block");
        try w.write(prefixed("block", &pane.id));
    }
};

fn writePane(pane: *Pane, w: *Stringify) Error!void {
    const term = &pane.block.term;
    try w.write(.{
        .id = prefixed("block", &pane.id),
        .label = pane.label,
        .flavor = "terminal.shell",
        .pid = pane.block.pid,
        .title = pane.title.items,
        .pwd = pane.pwd.items,
        .cols = term.cols,
        .rows = term.rows,
        .exit_code = pane.exit_code,
    });
}

fn sessionView(self: *Server, req: *Request, w: *Stringify) Error!void {
    const s = (try self.resolve(req)).session;
    try w.beginObject();
    try w.objectField("id");
    try w.write(prefixed("session", &s.id));
    try w.objectField("label");
    try w.write(s.label);
    try w.objectField("revision");
    try w.write(s.revision);
    try w.objectField("active_window");
    try w.write(prefixed("window", &s.active.?.id));
    try w.objectField("windows");
    try w.beginArray();
    for (s.windows.items) |win| {
        try w.beginObject();
        try w.objectField("id");
        try w.write(prefixed("window", &win.id));
        try w.objectField("label");
        try w.write(win.label);
        try w.objectField("active");
        try w.write(win == s.active);
        try w.objectField("focused_block");
        try w.write(prefixed("block", &win.focused.id));
        try w.objectField("zoomed");
        try w.write(if (win.zoomed) |z| prefixed("block", &z.id) else null);
        try w.objectField("layout");
        try win.tree.write(w, LeafWriter{});
        try w.objectField("blocks");
        try w.beginArray();
        for (try win.tree.leaves(req.arena)) |pane| try writePane(pane, w);
        try w.endArray();
        try w.endObject();
    }
    try w.endArray();
    try w.objectField("clients");
    try w.beginArray();
    for (self.clients.items) |cl| {
        const f = cl.filter orelse continue;
        if (!std.mem.eql(u8, &f, &s.id)) continue;
        try w.write(.{
            .id = prefixed("client", &cl.id),
            .principal = .{
                .kind = "peer",
                .transport = "unix",
                .uid = cl.peer.uid,
                .gid = cl.peer.gid,
                .pid = cl.peer.pid,
            },
        });
    }
    try w.endArray();
    try w.endObject();
}

fn sessionSubscribe(self: *Server, req: *Request, w: *Stringify) Error!void {
    req.client.filter = if (req.str("session") != null) (try self.resolve(req)).session.id else null;
    req.client.subscribed = true;
    try w.write(.{});
}

fn sessionNewWindow(self: *Server, req: *Request, w: *Stringify) Error!void {
    const s = if (req.str("session") == null and self.sessions.items.len == 0)
        return req.fail(error.Target, "no sessions", .{})
    else
        (try self.resolve(req)).session;
    const win = try self.newWindow(s, req, req.str("label"));
    if (req.flag("wait") orelse false) {
        try win.focused.waiters.append(self.alloc, .{ .client = req.client, .id = req.id });
        return error.Deferred;
    }
    try w.write(.{
        .window = prefixed("window", &win.id),
        .block = prefixed("block", &win.focused.id),
    });
}

fn sessionNewSplit(self: *Server, req: *Request, w: *Stringify) Error!void {
    const t = try self.resolve(req);
    const dir: layout.Dir = dir: {
        const d = req.str("direction") orelse "right";
        if (std.mem.eql(u8, d, "right")) break :dir .horizontal;
        if (std.mem.eql(u8, d, "down")) break :dir .vertical;
        return req.fail(error.Usage, "direction must be right or down", .{});
    };
    const pane = try self.spawnPane(t.session, req);
    t.window.tree.split(self.alloc, t.pane, pane, dir) catch |err| {
        pane.block.kill();
        self.dying.append(self.alloc, pane) catch {};
        return switch (err) {
            error.NotFound => unreachable,
            error.OutOfMemory => error.OutOfMemory,
        };
    };
    pane.window = t.window;
    t.window.focused = pane;
    t.window.zoomed = null;
    self.emit("block_created", &t.session.id, .{
        .block = prefixed("block", &pane.id),
        .window = prefixed("window", &t.window.id),
    });
    self.viewChanged(t.session);
    try w.write(.{ .block = prefixed("block", &pane.id) });
}

fn sessionCloseWindow(self: *Server, req: *Request, w: *Stringify) Error!void {
    self.closeWindow((try self.resolve(req)).window);
    try w.write(.{});
}

fn sessionZoomBlock(self: *Server, req: *Request, w: *Stringify) Error!void {
    const t = try self.resolve(req);
    const zoom = req.flag("zoom") orelse (t.window.zoomed != t.pane);
    t.window.zoomed = if (zoom) t.pane else null;
    if (zoom) t.window.focused = t.pane;
    self.viewChanged(t.session);
    try w.write(.{ .zoomed = zoom });
}

fn sessionFocus(self: *Server, req: *Request, w: *Stringify) Error!void {
    const t = try self.resolve(req);
    if (req.str("block") != null) t.window.focused = t.pane;
    if (t.session.active != t.window) {
        t.session.active = t.window;
        self.emit("active_window_changed", &t.session.id, .{ .window = prefixed("window", &t.window.id) });
    }
    self.viewChanged(t.session);
    try w.write(.{
        .window = prefixed("window", &t.window.id),
        .block = prefixed("block", &t.window.focused.id),
    });
}

fn newLabel(self: *Server, req: *Request, old: *[]u8) Error![]const u8 {
    const label = req.str("label") orelse return req.fail(error.Usage, "label is required", .{});
    const dup = try self.alloc.dupe(u8, label);
    self.alloc.free(old.*);
    old.* = dup;
    return dup;
}

fn sessionSetLabel(self: *Server, req: *Request, w: *Stringify) Error!void {
    const s = (try self.resolve(req)).session;
    if (req.str("label")) |l| if (self.sessionByLabel(l)) |other| if (other != s)
        return req.fail(error.Fail, "session '{s}' already exists", .{l});
    const label = try self.newLabel(req, &s.label);
    self.emit("session_label_changed", &s.id, .{ .label = label });
    self.viewChanged(s);
    try w.write(.{});
}

fn sessionSetWindowLabel(self: *Server, req: *Request, w: *Stringify) Error!void {
    const t = try self.resolve(req);
    const label = try self.newLabel(req, &t.window.label);
    self.emit("window_label_changed", &t.session.id, .{ .window = prefixed("window", &t.window.id), .label = label });
    self.viewChanged(t.session);
    try w.write(.{});
}

fn sessionDescribeBlock(self: *Server, req: *Request, w: *Stringify) Error!void {
    const t = try self.resolve(req);
    try w.beginObject();
    try w.objectField("session");
    try w.write(prefixed("session", &t.session.id));
    try w.objectField("window");
    try w.write(prefixed("window", &t.window.id));
    try w.objectField("block");
    try writePane(t.pane, w);
    try w.objectField("methods");
    try w.write(block_methods.keys());
    try w.objectField("events");
    try w.write([_][]const u8{
        "bell",            "child_exited",           "clipboard_written", "desktop_notification",
        "progress_report", "program_status_changed", "pwd_changed",       "title_changed",
    });
    try w.endObject();
}

fn sessionKill(self: *Server, req: *Request, w: *Stringify) Error!void {
    self.killSession((try self.resolve(req)).session);
    try w.write(.{});
}

fn blockClose(self: *Server, req: *Request, w: *Stringify) Error!void {
    self.closePane((try self.resolve(req)).pane);
    try w.write(.{});
}

/// The exit code of the `block` param if it names, by full id, a block
/// whose program has exited.
fn exitedCode(self: *Server, req: *Request) ?u32 {
    const q = req.str("block") orelse return null;
    const bare = if (std.mem.startsWith(u8, q, "block:")) q["block:".len..] else q;
    for (self.exited) |e| if (std.mem.eql(u8, &e.id, bare)) return e.code;
    return null;
}

fn blockWait(self: *Server, req: *Request, w: *Stringify) Error!void {
    if (self.exitedCode(req)) |code| return w.write(.{ .exit_code = code });
    const pane = (try self.resolve(req)).pane;
    try pane.waiters.append(self.alloc, .{ .client = req.client, .id = req.id });
    return error.Deferred;
}

const BlockMethod = *const fn (*Pane, *Request, *Stringify) Error!void;

const block_methods = std.StaticStringMap(BlockMethod).initComptime(.{
    .{ "format", &methodFormat },
    .{ "process", &methodProcess },
    .{ "size", &methodSize },
    .{ "title", &methodTitle },
    .{ "write", &methodWrite },
});

fn blockMethod(self: *Server, req: *Request, w: *Stringify) Error!void {
    const name = req.str("method") orelse return req.fail(error.Usage, "method is required", .{});
    const method = block_methods.get(name) orelse return req.fail(error.Usage, "unknown block method '{s}'", .{name});
    if (method == &methodWrite and self.exitedCode(req) != null)
        return req.fail(error.Fail, "the block's program has exited", .{});
    const pane = (try self.resolve(req)).pane;
    try method(pane, req, w);
}

/// Plain text of the visible screen, or with `"scope":"all"` the whole
/// scrollback too.
fn methodFormat(pane: *Pane, req: *Request, w: *Stringify) Error!void {
    const all = if (req.str("scope")) |s| std.mem.eql(u8, s, "all") else false;
    const screen = pane.block.term.screens.active;
    const text = screen.dumpStringAlloc(req.arena, if (all) .{ .screen = .{} } else .{ .viewport = .{} }) catch |err|
        return req.fail(error.Fail, "formatting failed: {t}", .{err});
    try w.write(.{ .text = text });
}

fn methodProcess(pane: *Pane, _: *Request, w: *Stringify) Error!void {
    try w.write(.{ .pid = pane.block.pid, .exit_code = pane.exit_code });
}

fn methodSize(pane: *Pane, _: *Request, w: *Stringify) Error!void {
    try w.write(.{ .cols = pane.block.term.cols, .rows = pane.block.term.rows });
}

fn methodTitle(pane: *Pane, _: *Request, w: *Stringify) Error!void {
    try w.write(.{ .title = pane.title.items });
}

fn methodWrite(pane: *Pane, req: *Request, w: *Stringify) Error!void {
    const data = req.str("data") orelse return req.fail(error.Usage, "data is required", .{});
    try pane.block.write(data);
    try w.write(.{ .written = data.len });
}

test "rex Server: sessions over the socket" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const path = try std.fmt.allocPrintSentinel(alloc, "{s}/s.sock", .{dir_buf[0..dir_len]}, 0);
    defer alloc.free(path);

    var env: EnvMap = .init(alloc);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("FOO", "leaked");

    const server = try Server.create(alloc, testing.io, .{ .socket_path = path, .env = &env });
    defer server.destroy();
    try testing.expectError(error.AlreadyRunning, Server.create(alloc, testing.io, .{ .socket_path = path, .env = &env }));

    const thread = try std.Thread.spawn(.{}, (struct {
        fn run(srv: *Server) void {
            srv.run() catch |err| std.debug.panic("server failed: {t}", .{err});
        }
    }).run, .{server});
    defer thread.join();

    const fd = try protocol.connect(path);
    defer _ = c.close(fd);
    const T = struct {
        fn call(sock: posix.fd_t, req: []const u8) ![]u8 {
            try protocol.writeFrame(sock, .json, req);
            const frame = try protocol.readFrame(testing.allocator, sock);
            return frame.payload;
        }
    };

    const created = try T.call(fd,
        \\{"id":1,"method":"session.create","params":{"label":"demo","command":["/bin/sh","-c","echo FOO=$FOO; echo SESSION=$RAP_SESSION; sleep 30"]}}
    );
    defer alloc.free(created);
    try testing.expect(std.mem.indexOf(u8, created, "\"label\":\"demo\"") != null);

    const missing = try T.call(fd,
        \\{"id":2,"method":"block.method","params":{"session":"nope","method":"format"}}
    );
    defer alloc.free(missing);
    try testing.expect(std.mem.indexOf(u8, missing, "\"code\":\"target\"") != null);

    // The child's output shows up in the server's terminal, and only
    // allowed variables reach it.
    var tries: usize = 0;
    while (true) : (tries += 1) {
        const captured = try T.call(fd,
            \\{"id":3,"method":"block.method","params":{"session":"demo","method":"format"}}
        );
        defer alloc.free(captured);
        if (std.mem.indexOf(u8, captured, "SESSION=session:") != null) {
            try testing.expect(std.mem.indexOf(u8, captured, "leaked") == null);
            break;
        }
        if (tries == 200) return error.TestUnexpectedResult;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }

    const split = try T.call(fd,
        \\{"id":4,"method":"session.new_split","params":{"session":"1","direction":"down","command":["/bin/sh","-c","sleep 30"]}}
    );
    defer alloc.free(split);
    const view = try T.call(fd,
        \\{"id":5,"method":"session.view","params":{"session":"demo"}}
    );
    defer alloc.free(view);
    try testing.expect(std.mem.indexOf(u8, view, "\"type\":\"vertical\"") != null);
    try testing.expect(std.mem.indexOf(u8, view, "\"revision\":2") != null);

    const killed = try T.call(fd,
        \\{"id":6,"method":"session.kill","params":{"session":"demo"}}
    );
    defer alloc.free(killed);
    const list = try T.call(fd,
        \\{"id":7,"method":"session.list"}
    );
    defer alloc.free(list);
    try testing.expectEqualStrings("{\"id\":7,\"result\":{\"sessions\":[]}}", list);

    const stopped = try T.call(fd,
        \\{"id":8,"method":"server.stop"}
    );
    defer alloc.free(stopped);
    try testing.expectError(error.Unreachable, protocol.connect(path));
}
