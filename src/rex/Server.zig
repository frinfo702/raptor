//! The rap server: one process per user that owns every session, window
//! and block, and answers clients over a Unix socket and, with `tailnet`,
//! over its node's tailnet address.
//!
//! Everything runs on one libxev loop thread: the listener, every client
//! socket, every block's pty and child, and a tick timer for idle exit.
//! The object model is session -> window (a tab) -> block (a pane), and
//! each window lays its blocks out in a split tree. Every change to what a
//! session looks like bumps its `revision`.
//!
//! Clients mirror blocks through data-plane streams. Every subscriber of a
//! block gets the same bytes in the same order: a snapshot or a replay
//! from the block's ring, then each chunk of pty output and each resize.
//! Writes to a client never block. A client that falls behind by more
//! than its outbox cap loses that stream's queued output and gets a fresh
//! snapshot once it has caught up, so one slow client never holds up the
//! loop, a pty, or another client.
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
const dataplane = @import("dataplane.zig");
const ids = @import("ids.zig");
const layout = @import("layout.zig");
const listdir = @import("listdir.zig");
const proc = @import("proc.zig");
const protocol = @import("protocol.zig");
const shell = @import("shell.zig");
const tailscale = @import("tailscale.zig");
const program_status = @import("../terminal/osc/parsers/program_status.zig");

const log = std.log.scoped(.rex_server);

/// How often the server checks for idleness and signals. Blocks also
/// compress their scrollback once they have been quiet for a whole tick,
/// the renderer's idle interval.
const tick_ms = 250;

/// The pause between bounded compression steps, as in the renderer, so
/// clients and ptys are served while blocks compress.
const compress_step_ms = 1;

/// Set from a signal handler to make the server exit.
pub var signaled: std.atomic.Value(bool) = .init(false);

pub const Options = struct {
    socket_path: [:0]const u8,

    /// The environment the server was started with. Only the names in
    /// `protocol.daemon_env` are kept.
    env: *const EnvMap,

    /// Exit once there have been no sessions and no clients for this long.
    idle_timeout_ms: u64 = 30_000,

    /// Ghostty's shell integration for the blocks' shells.
    shell_integration: shell.Integration = .{},

    /// The directory of the `rap` binary, appended to the blocks' PATH.
    bin_dir: ?[]const u8 = null,

    /// Also listen on this node's tailnet address.
    tailnet: ?Tailnet = null,
};

pub const Tailnet = struct {
    port: u16 = tailscale.default_port,
    /// The login names of other Tailscale users who may connect, besides
    /// the node's own user. They get its shell. Must outlive the server.
    allow: []const []const u8 = &.{},
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
    /// The block whose program asked for this window (`rap run` or `rap new`
    /// inside a block), so clients can show it under that program's tab.
    parent: ?ids.Uuid = null,
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
    /// What programs say they are doing (OSC 7501), for Activity Mode,
    /// least recently updated first. The root record has the id "".
    records: std.ArrayList(Record) = .empty,
    /// An OSC 7501 report arrived since the last full reset, so the
    /// root record is no longer inferred from titles and OSC 9;4.
    reported: bool = false,
    /// Wall-clock ms of the latest output.
    last_activity: ?i64 = null,
    /// The foreground process at the latest tick, to notice it change.
    fg_pid: ?posix.pid_t = null,
    fg_name: [proc.max_name]u8 = undefined,
    fg_name_len: usize = 0,
    /// Requests answered when the child exits.
    waiters: std.ArrayList(Waiter) = .empty,
    /// Data-plane subscriptions to this block.
    streams: std.ArrayList(*Stream) = .empty,
    /// Recent output, kept while there are streams.
    ring: ?*dataplane.Ring = null,
    /// The client whose size requests set the grid size: the one that most
    /// recently focused the block or sent it input.
    owner: ?*Client = null,
    /// The seq of the latest resize. Output from before it can't be
    /// replayed, since replay carries no grid markers.
    grid_seq: ?u64 = null,
    /// The terminal's compression activity at the last tick, and when its
    /// last compression pass finished.
    activity: ?u64 = null,
    compressed: ?u64 = null,
    /// In the server's `compress_queue`.
    queued: bool = false,
};

/// One program status record: an OSC 7501 report, or until a program
/// reports one, a root record inferred from the title or OSC 9;4. While
/// working or blocked, a status inferred from a spinner in the title
/// holds against one from progress. The strings are slices of `buf`.
const Record = struct {
    buf: []u8 = &.{},
    id: []const u8 = "",
    state: []const u8,
    kind: ?[]const u8 = null,
    progress: ?u8 = null,
    app: ?[]const u8 = null,
    title: ?[]const u8 = null,
    msg: ?[]const u8 = null,
    source: enum { osc7501, title, progress },
    updated_at: i64,
};

/// The most records a block keeps. A new one past this removes the one
/// updated least recently.
const max_records = 256;

/// One client's subscription to one block.
const Stream = struct {
    id: u32,
    client: *Client,
    pane: *Pane,
    /// What the client must get before live output.
    need: union(enum) {
        none,
        snapshot,
        /// Output after this seq, from the ring.
        replay: u64,
    } = .snapshot,
    /// The size the client asks for, applied while it owns the block.
    want: ?protocol.Size = null,
};

const Waiter = struct {
    client: *Client,
    id: ?i64,
};

/// Who a client is.
const Principal = union(enum) {
    /// A process of this user on this machine.
    unix: protocol.Peer,
    /// A tailnet node, its user, and its `ip:port`, as WhoIs names them.
    /// The strings are slices of `buf`.
    tailscale: struct { buf: []u8, login: []const u8, node: []const u8, addr: []const u8 },
};

const Client = struct {
    server: *Server,
    id: ids.Uuid,
    fd: posix.fd_t,
    principal: Principal,
    poll_c: xev.Completion = .{},
    /// The read poll is on the loop.
    reading: bool = true,
    write_c: xev.Completion = .{},
    /// A write of `outbox.pending()` is on the loop.
    writing: bool = false,
    outbox: dataplane.Outbox = .{},
    streams: std.ArrayList(*Stream) = .empty,
    next_stream: u32 = 1,
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
/// The tailnet listener, or -1, and where it listens.
tailnet_fd: posix.fd_t = -1,
tailnet_c: xev.Completion = .{},
tailnet_addr: ?[]u8 = null,
/// The Tailscale user whose nodes may connect: this node's, unless it is
/// tagged.
tailnet_user: ?i64 = null,
tailnet_allow: []const []const u8 = &.{},
timer: xev.Timer,
timer_c: xev.Completion = .{},
compress_timer: xev.Timer,
compress_c: xev.Completion = .{},
compress_armed: bool = false,
/// Quiet blocks that may have scrollback left to compress.
compress_queue: std.ArrayList(*Pane) = .empty,
env: EnvMap,
shell_integration: shell.Integration,
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
            // std.c has no fstat on Linux; statx is the libc replacement there.
            var st: if (builtin.os.tag == .linux) std.os.linux.Statx else c.Stat = undefined;
            const rc = if (builtin.os.tag == .linux)
                c.statx(dir_fd, "", std.os.linux.AT.EMPTY_PATH, .{ .UID = true, .MODE = true }, &st)
            else
                c.fstat(dir_fd, &st);
            if (rc != 0) return error.SocketDir;
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

    var tailnet_fd: posix.fd_t = -1;
    errdefer if (tailnet_fd >= 0) {
        _ = c.close(tailnet_fd);
    };
    var tailnet_addr: ?[]u8 = null;
    errdefer if (tailnet_addr) |a| alloc.free(a);
    var tailnet_user: ?i64 = null;
    if (opts.tailnet) |t| {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const st = tailscale.status(arena.allocator(), io) catch return error.TailscaleUnavailable;
        const where: std.Io.net.Ip4Address = .{ .bytes = st.self.ip, .port = t.port };
        tailnet_fd = try protocol.listenTcp(where);
        tailnet_addr = try std.fmt.allocPrint(alloc, "{f}", .{where});
        tailnet_user = st.self.user;
        if (tailnet_user == null and t.allow.len == 0)
            log.warn("this node is tagged, so only users named by --allow may connect over the tailnet", .{});
    }

    var env: EnvMap = .init(alloc);
    errdefer env.deinit();
    for (protocol.daemon_env) |k| if (opts.env.get(k)) |v| try env.put(k, v);
    if (opts.bin_dir) |dir| try appendPath(alloc, &env, dir);

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
        .tailnet_fd = tailnet_fd,
        .tailnet_addr = tailnet_addr,
        .tailnet_user = tailnet_user,
        .tailnet_allow = if (opts.tailnet) |t| t.allow else &.{},
        .timer = try .init(),
        .compress_timer = try .init(),
        .env = env,
        .shell_integration = opts.shell_integration,
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
    if (self.tailnet_fd >= 0) xev.TCP.initFd(self.tailnet_fd).poll(&self.loop, &self.tailnet_c, .read, Server, self, onTailnetListen);
    self.timer.run(&self.loop, &self.timer_c, tick_ms, Server, self, onTick);
    log.info("listening on {s}", .{self.socket_path});
    if (self.tailnet_addr) |a| log.info("listening on the tailnet at {s}", .{a});
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
    self.compress_queue.deinit(self.alloc);
    self.unlinkSocket();
    _ = c.close(self.listen_fd);
    if (self.tailnet_fd >= 0) _ = c.close(self.tailnet_fd);
    if (self.tailnet_addr) |a| self.alloc.free(a);
    _ = c.close(self.lock_fd);
    self.timer.deinit();
    self.compress_timer.deinit();
    self.loop.deinit();
    self.env.deinit();
    self.alloc.destroy(self.read_buf);
    self.alloc.free(self.socket_path);
    self.alloc.destroy(self);
}

fn nowMs(self: *const Server) i64 {
    return std.Io.Clock.awake.now(self.io).toMilliseconds();
}

/// Milliseconds since the Unix epoch, for timestamps clients show.
fn wallMs(self: *const Server) i64 {
    return std.Io.Clock.real.now(self.io).toMilliseconds();
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
    for (self.sessions.items) |s| for (s.windows.items) |w| self.tickTree(w.tree.root);
    self.armCompress();
    // The tick also bounds how long a loop iteration can wait while
    // shutting down.
    self.timer.run(loop, comp, tick_ms, Server, self, onTick);
    return .disarm;
}

fn tickTree(self: *Server, node: *Tree.Node) void {
    switch (node.*) {
        .leaf => |pane| {
            self.pollForeground(pane);
            self.queueQuiet(pane);
        },
        .split => |s| {
            self.tickTree(s.a);
            self.tickTree(s.b);
        },
    }
}

/// Queue the block if its terminal had no compression activity since the
/// last tick and has not been compressed since its last activity.
fn queueQuiet(self: *Server, pane: *Pane) void {
    const activity = pane.block.term.compressionActivity();
    if (pane.activity != activity) {
        pane.activity = activity;
        return;
    }
    if (pane.queued or pane.compressed == activity) return;
    self.compress_queue.append(self.alloc, pane) catch return;
    pane.queued = true;
}

/// Report a new foreground process. The name is compared too, so a
/// process that execs (or a job seen between its fork and exec) is
/// reported again once it runs its program.
// ponytail: polled each tick, so a change shows up to `tick_ms` late.
fn pollForeground(self: *Server, pane: *Pane) void {
    const pid = proc.foreground(pane.block.pty.master) orelse return;
    var buf: [proc.max_name]u8 = undefined;
    const name = proc.name(pid, &buf) orelse "";
    if (pane.fg_pid == pid and std.mem.eql(u8, pane.fg_name[0..pane.fg_name_len], name)) return;
    pane.fg_pid = pid;
    @memcpy(pane.fg_name[0..name.len], name);
    pane.fg_name_len = name.len;

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const info = proc.describe(arena.allocator(), pid) catch return;
    self.emit("process_changed", &pane.session_id, .{ .block = prefixed("block", &pane.id), .foreground = info });
}

fn armCompress(self: *Server) void {
    if (self.compress_armed or self.compress_queue.items.len == 0) return;
    self.compress_armed = true;
    self.compress_timer.run(&self.loop, &self.compress_c, compress_step_ms, Server, self, onCompress);
}

/// One bounded compression step of the first queued block. A block that
/// became active again leaves the queue until it is quiet for a tick.
fn onCompress(
    self_: ?*Server,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    const self = self_.?;
    self.compress_armed = false;
    _ = r catch return .disarm;
    if (self.compress_queue.items.len == 0) return .disarm;
    const pane = self.compress_queue.items[0];
    const term = &pane.block.term;
    const done = if (term.compressionActivity() != pane.activity) true else switch (term.compress(.incremental)) {
        .pending => false,
        .complete, .unsupported => done: {
            pane.compressed = pane.activity;
            break :done true;
        },
    };
    if (done) {
        _ = self.compress_queue.orderedRemove(0);
        pane.queued = false;
    }
    self.armCompress();
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
    _ = r catch |err| if (err == error.Canceled) return .disarm;
    self_.?.acceptAll(self_.?.listen_fd);
    return Block.rearm(comp);
}

fn onTailnetListen(
    self_: ?*Server,
    _: *xev.Loop,
    comp: *xev.Completion,
    _: xev.TCP,
    r: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    _ = r catch |err| if (err == error.Canceled) return .disarm;
    self_.?.acceptAll(self_.?.tailnet_fd);
    return Block.rearm(comp);
}

/// Accept every waiting client of the Unix socket or the tailnet listener.
fn acceptAll(self: *Server, listen_fd: posix.fd_t) void {
    while (true) {
        const fd = c.accept(listen_fd, null, null);
        if (fd < 0) break;
        protocol.setCloexec(fd);
        if (comptime builtin.os.tag.isDarwin()) {
            const on: c_int = 1;
            _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &on, @sizeOf(c_int));
        }
        const principal = (if (listen_fd == self.listen_fd) unixPrincipal(fd) else self.tailnetPrincipal(fd)) orelse {
            _ = c.close(fd);
            continue;
        };
        self.addClient(fd, principal);
    }
}

/// A Unix socket client, if it runs as this user.
fn unixPrincipal(fd: posix.fd_t) ?Principal {
    const p = protocol.peer(fd) catch return null;
    if (p.uid != c.getuid()) {
        log.warn("rejecting client uid={d} pid={d}", .{ p.uid, p.pid });
        return null;
    }
    return .{ .unix = p };
}

/// A tailnet client, if its node's user may use this server. One that may
/// not is told why.
// ponytail: WhoIs blocks the loop for a LocalAPI round trip, about a
// millisecond (its 2 s timeout at worst); ask off the loop if that shows.
fn tailnetPrincipal(self: *Server, fd: posix.fd_t) ?Principal {
    protocol.setNodelay(fd);
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const addr = std.fmt.allocPrint(alloc, "{f}", .{protocol.peerAddress(fd) orelse return null}) catch return null;
    const node = tailscale.whois(alloc, self.io, addr) catch |err| {
        log.warn("rejecting tailnet client {s}: whois failed: {t}", .{ addr, err });
        refuse(fd, "the server could not ask Tailscale who {s} is", .{addr});
        return null;
    };
    if (!allowed(self.tailnet_user, self.tailnet_allow, node)) {
        const who = if (node.user == null) "tagged node" else node.login;
        log.warn("rejecting tailnet client {s} ({s} on {s})", .{ addr, who, node.name });
        refuse(fd, "{s} on {s} may not use this server", .{ who, node.name });
        return null;
    }
    const buf = std.mem.concat(self.alloc, u8, &.{ node.login, node.name, addr }) catch return null;
    const login = buf[0..node.login.len];
    const name = buf[login.len..][0..node.name.len];
    return .{ .tailscale = .{ .buf = buf, .login = login, .node = name, .addr = buf[login.len + name.len ..] } };
}

/// Whether a tailnet node may use the server: its user is the server
/// node's own (`owner`), or one that `allow` names. A tagged node has no
/// user, so it may not.
fn allowed(owner: ?i64, allow: []const []const u8, node: tailscale.Node) bool {
    const user = node.user orelse return false;
    if (owner) |o| if (o == user) return true;
    if (node.login.len == 0) return false;
    for (allow) |login| if (std.ascii.eqlIgnoreCase(login, node.login)) return true;
    return false;
}

/// Tell a client it may not connect: `{"event":"refused","message":...}`.
fn refuse(fd: posix.fd_t, comptime fmt: []const u8, args: anytype) void {
    var msg_buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    Stringify.value(.{ .event = "refused", .message = msg }, .{}, &w) catch return;
    protocol.writeFrame(fd, .json, w.buffered()) catch {};
}

test "rex Server: who may connect over the tailnet" {
    const testing = std.testing;
    const mine: tailscale.Node = .{ .name = "box", .ip = .{ 100, 96, 1, 3 }, .user = 7, .login = "me@github" };
    const theirs: tailscale.Node = .{ .name = "pal", .ip = .{ 100, 96, 1, 4 }, .user = 8, .login = "Pal@github" };
    const tagged: tailscale.Node = .{ .name = "ci", .ip = .{ 100, 96, 1, 5 }, .user = null };
    try testing.expect(allowed(7, &.{}, mine));
    try testing.expect(!allowed(7, &.{}, theirs));
    try testing.expect(allowed(7, &.{"pal@github"}, theirs));
    try testing.expect(!allowed(7, &.{""}, tagged));
    // A tagged server has no user of its own.
    try testing.expect(!allowed(null, &.{}, mine));
    try testing.expect(allowed(null, &.{"me@github"}, mine));

    // A refused client hears why.
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(0, c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer for (fds) |fd| {
        _ = c.close(fd);
    };
    refuse(fds[0], "{s} on {s} may not use this server", .{ theirs.login, theirs.name });
    const frame = try protocol.readFrame(testing.allocator, fds[1]);
    defer testing.allocator.free(frame.payload);
    try testing.expectEqualStrings(
        \\{"event":"refused","message":"Pal@github on pal may not use this server"}
    , frame.payload);
}

fn freePrincipal(self: *Server, p: Principal) void {
    switch (p) {
        .unix => {},
        .tailscale => |t| self.alloc.free(t.buf),
    }
}

fn addClient(self: *Server, fd: posix.fd_t, principal: Principal) void {
    // Reads and writes never block the loop: they use MSG_DONTWAIT, and a
    // write that doesn't fit waits on the loop. libxev's io_uring backend
    // needs a blocking socket to wait on, the others a nonblocking one.
    protocol.setNonblocking(fd, xev.backend != .io_uring);

    const cl = self.alloc.create(Client) catch {
        self.freePrincipal(principal);
        _ = c.close(fd);
        return;
    };
    cl.* = .{ .server = self, .id = ids.uuidv7(self.io), .fd = fd, .principal = principal };
    self.clients.append(self.alloc, cl) catch {
        self.alloc.destroy(cl);
        self.freePrincipal(principal);
        _ = c.close(fd);
        return;
    };
    xev.TCP.initFd(fd).poll(&self.loop, &cl.poll_c, .read, Client, cl, onClient);
    const id = prefixed("client", &cl.id);
    switch (principal) {
        .unix => |p| self.emit("client_connected", null, .{ .client = id, .uid = p.uid, .pid = p.pid }),
        .tailscale => |t| self.emit("client_connected", null, .{
            .client = id,
            .transport = "tailscale",
            .login = t.login,
            .node = t.node,
        }),
    }
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
        cl.reading = false;
        if (!cl.writing) self.dropClient(cl);
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
        if (h.len > protocol.max_frame) return self.closeClient(cl);
        const end = off + protocol.header_len + h.len;
        if (cl.in.items.len < end) break;
        const payload = cl.in.items[off + protocol.header_len .. end];
        if (h.type == .json) self.handleFrame(cl, payload) else self.handleData(cl, h.type, payload);
        off = end;
    }
    cl.in.replaceRangeAssumeCapacity(0, off, &.{});
    // New streams and resets get their snapshots after the replies.
    self.pump(cl);
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
    while (cl.streams.items.len > 0) self.removeStream(cl.streams.items[cl.streams.items.len - 1]);
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
    self.freePrincipal(cl.principal);
    cl.in.deinit(self.alloc);
    cl.outbox.deinit(self.alloc);
    // Streams are left only if the client was never dropped, and then
    // their blocks are gone too.
    for (cl.streams.items) |st| self.alloc.destroy(st);
    cl.streams.deinit(self.alloc);
    self.alloc.destroy(cl);
}

fn send(self: *Server, cl: *Client, payload: []const u8) void {
    if (cl.closing) return;
    // A client that reads none of its replies and events is dropped
    // rather than queued for without bound.
    if (cl.outbox.counted + payload.len > 2 * dataplane.Outbox.cap) {
        log.info("dropping client that stopped reading", .{});
        return self.closeClient(cl);
    }
    const frame = self.alloc.alloc(u8, protocol.header_len + payload.len) catch
        return self.closeClient(cl);
    frame[0..protocol.header_len].* = protocol.header(payload.len, .json);
    @memcpy(frame[protocol.header_len..], payload);
    self.queue(cl, .{ .bytes = frame, .kind = .control });
}

fn queue(self: *Server, cl: *Client, f: dataplane.Outbox.Frame) void {
    cl.outbox.push(self.alloc, f) catch return self.closeClient(cl);
    self.flush(cl);
}

/// Write queued frames until the socket is full, then have the loop
/// finish the oldest one once the client reads.
fn flush(self: *Server, cl: *Client) void {
    if (cl.writing or cl.closing) return;
    const flags: u32 = c.MSG.DONTWAIT | if (builtin.os.tag == .linux) c.MSG.NOSIGNAL else 0;
    while (cl.outbox.pending()) |rest| {
        const n = c.send(cl.fd, rest.ptr, rest.len, flags);
        if (n < 0) switch (posix.errno(n)) {
            .INTR => continue,
            .AGAIN => {
                cl.writing = true;
                xev.TCP.initFd(cl.fd).write(&self.loop, &cl.write_c, .{ .slice = rest }, Client, cl, onWrite);
                return;
            },
            else => return self.closeClient(cl),
        };
        cl.outbox.consume(self.alloc, @intCast(n));
    }
}

fn onWrite(
    cl_: ?*Client,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const cl = cl_.?;
    const self = cl.server;
    cl.writing = false;
    if (r) |n| {
        if (!cl.closing) cl.outbox.consume(self.alloc, n);
    } else |_| self.closeClient(cl);
    if (cl.closing) {
        if (!cl.reading) self.dropClient(cl);
        return .disarm;
    }
    // Like libxev's own write queue, the next write may reuse the
    // completion from its callback.
    self.flush(cl);
    self.pump(cl);
    return .disarm;
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
        .output => |data| {
            pane.last_activity = self.wallMs();
            self.forwardOutput(pane, data);
        },
        .write_pty => {},
        .title_changed => |t| {
            pane.title.clearRetainingCapacity();
            pane.title.appendSlice(self.alloc, t) catch {};
            self.emit("title_changed", &pane.session_id, .{ .block = id, .title = t });
            self.titleStatus(pane, t);
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
        .progress_report => |p| {
            self.emit("progress_report", &pane.session_id, .{
                .block = id,
                .state = @tagName(p.state),
                .progress = p.progress,
            });
            self.progressStatus(pane, p);
        },
        .clipboard_write => self.emit("clipboard_written", &pane.session_id, .{ .block = id }),
        .program_status => |p| self.programStatus(pane, p),
        // A new prompt ends whatever was working or waiting on the user.
        .prompt_start => self.removeRecords(pane, .live, "prompt"),
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

// Program status

/// What clients see of a record: the OSC 7501 keys, with `id` null for
/// the root record and `app` taken from the nearest ancestor that has
/// one when the record has none.
const RecordView = struct {
    id: ?[]const u8,
    state: []const u8,
    kind: ?[]const u8,
    msg: ?[]const u8,
    progress: ?u8,
    app: ?[]const u8,
    title: ?[]const u8,
    updated_at: i64,
};

fn recordView(pane: *const Pane, r: *const Record) RecordView {
    return .{
        .id = if (r.id.len > 0) r.id else null,
        .state = r.state,
        .kind = r.kind,
        .msg = r.msg,
        .progress = r.progress,
        .app = r.app orelse inheritedApp(pane, r.id),
        .title = r.title,
        .updated_at = r.updated_at,
    };
}

/// Every record of a block, as a JSON array of `RecordView`.
const RecordsView = struct {
    pane: *const Pane,

    pub fn jsonStringify(self: RecordsView, w: *Stringify) Stringify.Error!void {
        try w.beginArray();
        for (self.pane.records.items) |*r| try w.write(recordView(self.pane, r));
        try w.endArray();
    }
};

fn findRecord(pane: *const Pane, id: []const u8) ?*Record {
    for (pane.records.items) |*r| if (std.mem.eql(u8, r.id, id)) return r;
    return null;
}

/// The app of the nearest ancestor of `id` that has one: "a/b" asks
/// "a", then the root record.
fn inheritedApp(pane: *const Pane, id: []const u8) ?[]const u8 {
    var parent = id;
    while (parent.len > 0) {
        parent = parent[0 .. std.mem.lastIndexOfScalar(u8, parent, '/') orelse 0];
        if (findRecord(pane, parent)) |p| if (p.app) |a| return a;
    }
    return null;
}

/// The root record, which session.view shows as the block's status.
fn rootView(pane: *const Pane) ?RecordView {
    return recordView(pane, findRecord(pane, "") orelse return null);
}

/// An OSC 7501 report. A full reset reports a clear with no body, which
/// a program can't send.
fn programStatus(self: *Server, pane: *Pane, p: program_status.Report) void {
    const reset = p.data.len == 0;
    pane.reported = !reset;
    if (p.state == .clear) {
        const id = p.readOption(.id) orelse return self.removeRecords(pane, .all, if (reset) "reset" else "clear");
        return self.removeRecords(pane, .{ .subtree = id }, "clear");
    }
    var title_buf: [program_status.max_title_bytes]u8 = undefined;
    var title: std.Io.Writer = .fixed(&title_buf);
    p.writeText(.title, &title) catch {};
    var msg_buf: [program_status.max_msg_bytes]u8 = undefined;
    var msg: std.Io.Writer = .fixed(&msg_buf);
    p.writeText(.msg, &msg) catch {};
    self.setRecord(pane, .{
        .id = p.readOption(.id) orelse "",
        .state = @tagName(p.state),
        .kind = if (p.readOption(.kind)) |k| @tagName(k) else null,
        .progress = p.readOption(.progress),
        .app = p.readOption(.app),
        .title = if (title.end > 0) title.buffered() else null,
        .msg = if (msg.end > 0) msg.buffered() else null,
        .source = .osc7501,
        .updated_at = self.wallMs(),
    }, "report");
}

/// Replace the record with `r.id`, or add it, and report it. `r`'s
/// strings are copied.
fn setRecord(self: *Server, pane: *Pane, r: Record, reason: []const u8) void {
    var rec = r;
    rec.buf = std.mem.concat(self.alloc, u8, &.{ r.id, r.app orelse "", r.title orelse "", r.msg orelse "" }) catch return;
    var off: usize = 0;
    inline for (.{ "id", "app", "title", "msg" }) |f| {
        if (@as(?[]const u8, @field(r, f))) |v| {
            @field(rec, f) = rec.buf[off..][0..v.len];
            off += v.len;
        }
    }

    if (findRecord(pane, r.id)) |old| {
        self.alloc.free(old.buf);
        _ = pane.records.orderedRemove(old - pane.records.items.ptr);
    } else if (pane.records.items.len >= max_records) {
        self.removeRecords(pane, .{ .exact = pane.records.items[0].id }, "evicted");
    }
    pane.records.append(self.alloc, rec) catch return self.alloc.free(rec.buf);

    const view = recordView(pane, &pane.records.items[pane.records.items.len - 1]);
    self.emit("program_status_changed", &pane.session_id, .{
        .block = prefixed("block", &pane.id),
        .id = view.id,
        .record = view,
        .reason = reason,
    });
}

const Removal = union(enum) {
    all,
    /// The record and every record beneath it.
    subtree: []const u8,
    exact: []const u8,
    /// Working and blocked records, which end when the block's child exits
    /// or a new OSC 133 A prompt begins.
    live,
};

/// Remove the records `which` selects, and report their ids.
fn removeRecords(self: *Server, pane: *Pane, which: Removal, reason: []const u8) void {
    const n = pane.records.items.len;
    const removed = self.alloc.alloc(?[]const u8, n) catch return;
    defer self.alloc.free(removed);
    const bufs = self.alloc.alloc([]u8, n) catch return;
    defer self.alloc.free(bufs);

    var gone: usize = 0;
    var i: usize = 0;
    while (i < pane.records.items.len) {
        const r = pane.records.items[i];
        const hit = switch (which) {
            .all => true,
            .exact => |id| std.mem.eql(u8, r.id, id),
            .subtree => |id| std.mem.startsWith(u8, r.id, id) and
                (r.id.len == id.len or r.id[id.len] == '/'),
            .live => live(&r),
        };
        if (!hit) {
            i += 1;
            continue;
        }
        removed[gone] = if (r.id.len > 0) r.id else null;
        bufs[gone] = r.buf;
        gone += 1;
        _ = pane.records.orderedRemove(i);
    }
    defer for (bufs[0..gone]) |b| self.alloc.free(b);
    if (gone == 0) return;
    self.emit("program_status_removed", &pane.session_id, .{
        .block = prefixed("block", &pane.id),
        .ids = removed[0..gone],
        .reason = reason,
    });
}

fn live(r: *const Record) bool {
    return std.mem.eql(u8, r.state, "working") or std.mem.eql(u8, r.state, "blocked");
}

/// Set a root record inferred from the title or progress, unless a
/// program has reported its status, or a working or blocked status from
/// a stronger source holds. Only a change is reported.
fn inferStatus(
    self: *Server,
    pane: *Pane,
    source: @FieldType(Record, "source"),
    state: []const u8,
    progress: ?u8,
    msg: []const u8,
) void {
    if (pane.reported) return;
    if (findRecord(pane, "")) |s| {
        if (@backingInt(s.source) < @backingInt(source) and live(s)) return;
        if (s.source == source and std.mem.eql(u8, s.state, state) and s.progress == progress and
            std.mem.eql(u8, s.msg orelse "", msg)) return;
    }
    self.setRecord(pane, .{
        .state = state,
        .progress = progress,
        .msg = if (msg.len > 0) msg else null,
        .source = source,
        .updated_at = self.wallMs(),
    }, "inferred");
}

fn working(pane: *const Pane) bool {
    const s = findRecord(pane, "") orelse return false;
    return std.mem.eql(u8, s.state, "working");
}

/// OSC 9;4: a shown progress bar is working, and removing it after
/// that is done.
fn progressStatus(self: *Server, pane: *Pane, p: @FieldType(Block.Event, "progress_report")) void {
    const state: []const u8 = switch (p.state) {
        .set, .indeterminate => "working",
        .@"error" => "error",
        .pause => "idle",
        .remove => if (working(pane)) "done" else return,
    };
    self.inferStatus(pane, .progress, state, if (p.state == .set) p.progress else null, "");
}

/// A title that starts with a braille spinner (Claude Code, and other
/// programs animating one) is working, with the rest of the title as its
/// message. The first other title after that is done.
fn titleStatus(self: *Server, pane: *Pane, title: []const u8) void {
    const t = splitTitle(title);
    if (t.spinner) return self.inferStatus(pane, .title, "working", null, t.text);
    const s = findRecord(pane, "") orelse return;
    if (s.source == .title and working(pane)) self.inferStatus(pane, .title, "done", null, t.text);
}

/// A title without its leading symbol, such as Claude Code's "✳ " or a
/// spinner frame, and whether that symbol is a braille spinner.
fn splitTitle(title: []const u8) struct { spinner: bool, text: []const u8 } {
    const len = std.unicode.utf8ByteSequenceLength(if (title.len > 0) title[0] else 0) catch 1;
    const cp = if (len <= title.len) std.unicode.utf8Decode(title[0..len]) catch 0 else 0;
    // Letters, digits and punctuation start ordinary titles.
    if (cp < 0x2000) return .{ .spinner = false, .text = title };
    return .{
        .spinner = cp >= 0x2800 and cp <= 0x28FF,
        .text = std.mem.trimStart(u8, title[len..], " "),
    };
}

test "rex Server: titles with a leading symbol" {
    const testing = std.testing;
    const spin = splitTitle("⠂ Fixing the bug");
    try testing.expect(spin.spinner);
    try testing.expectEqualStrings("Fixing the bug", spin.text);
    const idle = splitTitle("✳ Claude Code");
    try testing.expect(!idle.spinner);
    try testing.expectEqualStrings("Claude Code", idle.text);
    const plain = splitTitle("nvim README.md");
    try testing.expect(!plain.spinner);
    try testing.expectEqualStrings("nvim README.md", plain.text);
    try testing.expect(!splitTitle("").spinner);
}

// Data plane

fn forwardOutput(self: *Server, pane: *Pane, data: []const u8) void {
    if (pane.streams.items.len == 0) return;
    pane.ring.?.push(data);
    const seq = pane.block.seq;
    for (pane.streams.items) |st| if (st.need == .none)
        self.queueData(st, .out, protocol.Out{ .stream = st.id, .seq = seq }, data);
    // A snapshot put off by an unfinished escape sequence may work now.
    for (pane.streams.items) |st| if (st.need != .none) self.pump(st.client);
}

/// Queue a data frame for the stream. Past the outbox cap, drop what the
/// stream has queued instead and resend it as a snapshot later.
fn queueData(self: *Server, st: *Stream, t: protocol.FrameType, fields: anytype, tail: []const u8) void {
    const cl = st.client;
    if (cl.closing) return;
    const frame = protocol.encodeData(self.alloc, t, fields, tail) catch return self.closeClient(cl);
    if (!cl.outbox.fits(frame.len)) {
        self.alloc.free(frame);
        return self.resync(st);
    }
    self.queue(cl, .{ .bytes = frame, .kind = .data, .stream = st.id });
}

/// Drop what the stream has queued; it gets a snapshot once the client
/// has read everything queued before.
fn resync(self: *Server, st: *Stream) void {
    st.client.outbox.dropStream(self.alloc, st.id);
    st.need = .snapshot;
}

/// Bring the client's waiting streams up to date: replays at once,
/// snapshots once the client has read everything queued.
fn pump(self: *Server, cl: *Client) void {
    for (cl.streams.items) |st| {
        if (cl.closing) return;
        if (st.need == .replay) self.replay(st, st.need.replay);
        if (st.need == .snapshot and cl.outbox.isEmpty()) self.sendSnapshot(st);
    }
}

/// Send the output after `since` from the ring, or fall back to a
/// snapshot if the ring no longer has all of it.
fn replay(self: *Server, st: *Stream, since: u64) void {
    const pane = st.pane;
    const resized = if (pane.grid_seq) |g| since <= g else false;
    const parts = (if (resized) null else pane.ring.?.since(since)) orelse {
        st.need = .snapshot;
        return;
    };
    st.need = .none;
    var seq = since;
    for (parts) |part| if (part.len > 0) {
        if (st.need != .none) return;
        seq += part.len;
        self.queueData(st, .out, protocol.Out{ .stream = st.id, .seq = seq }, part);
    };
}

fn sendSnapshot(self: *Server, st: *Stream) void {
    const cl = st.client;
    // Encoding decodes compressed pages into big temporary buffers. Freed
    // to malloc, they would stay in the server's footprint.
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var buf: std.Io.Writer.Allocating = .init(arena.allocator());
    st.pane.block.snapshot(arena.allocator(), &buf.writer) catch |err| switch (err) {
        // Retried after the block's next output.
        error.ContinuationUnavailable => return,
        else => {
            log.warn("snapshot failed err={t}", .{err});
            return self.closeClient(cl);
        },
    };
    st.need = .none;

    const bytes = buf.written();
    const chunk = 64 * 1024;
    var off: usize = 0;
    while (true) {
        const end = @min(off + chunk, bytes.len);
        const frame = protocol.encodeData(self.alloc, .snap, protocol.Snap{
            .stream = st.id,
            .base_seq = st.pane.block.seq,
            .flags = .{ .first = off == 0, .last = end == bytes.len },
        }, bytes[off..end]) catch return self.closeClient(cl);
        cl.outbox.push(self.alloc, .{ .bytes = frame, .kind = .snap, .stream = st.id }) catch
            return self.closeClient(cl);
        if (end == bytes.len) break;
        off = end;
    }
    self.flush(cl);
}

fn findStream(cl: *Client, id: u32) ?*Stream {
    for (cl.streams.items) |st| if (st.id == id) return st;
    return null;
}

fn removePtr(comptime T: type, list: *std.ArrayList(*T), item: *T) void {
    for (list.items, 0..) |it, i| if (it == item) {
        _ = list.swapRemove(i);
        return;
    };
}

fn removeStream(self: *Server, st: *Stream) void {
    const pane = st.pane;
    removePtr(Stream, &st.client.streams, st);
    removePtr(Stream, &pane.streams, st);
    if (pane.owner == st.client) {
        for (pane.streams.items) |other| {
            if (other.client == st.client) break;
        } else pane.owner = null;
    }
    if (pane.streams.items.len == 0) if (pane.ring) |r| {
        self.alloc.destroy(r);
        pane.ring = null;
    };
    self.alloc.destroy(st);
}

/// A data frame from a client. Frames for a stream that is gone are
/// ignored, since the client may not have heard yet.
fn handleData(self: *Server, cl: *Client, t: protocol.FrameType, payload: []const u8) void {
    switch (t) {
        .in => {
            const f, const bytes = protocol.decodeData(protocol.In, payload) orelse return self.closeClient(cl);
            const st = findStream(cl, f.stream) orelse return;
            if (st.pane.exit_code != null) return;
            st.pane.block.write(bytes) catch |err| return log.warn("dropping input err={t}", .{err});
            self.claim(st);
        },
        .size => {
            const f, _ = protocol.decodeData(protocol.Size, payload) orelse return self.closeClient(cl);
            const st = findStream(cl, f.stream) orelse return;
            if (f.cols < 1 or f.cols > 1000 or f.rows < 1 or f.rows > 1000) return;
            st.want = f;
            if (st.pane.owner == null or st.pane.owner == cl) self.claim(st);
        },
        .focus => {
            const f, _ = protocol.decodeData(protocol.Focus, payload) orelse return self.closeClient(cl);
            const st = findStream(cl, f.stream) orelse return;
            if (f.focused != 0) self.claim(st);
        },
        else => self.closeClient(cl),
    }
}

/// Make the stream's client the block's size owner, at its size.
fn claim(self: *Server, st: *Stream) void {
    const pane = st.pane;
    const changed = pane.owner != st.client;
    pane.owner = st.client;
    const want = st.want orelse return;
    const term = &pane.block.term;
    if (!changed and want.cols == term.cols and want.rows == term.rows) return;
    self.resizePane(pane, want);
}

/// Resize the block between two pty reads and mark that point in every
/// stream, so that every mirror reflows at the same output as the server.
fn resizePane(self: *Server, pane: *Pane, size: protocol.Size) void {
    pane.block.resize(size.cols, size.rows, size.cell_w_px, size.cell_h_px) catch |err| {
        log.warn("resizing block failed err={t}", .{err});
        return;
    };
    const seq = pane.block.seq;
    pane.grid_seq = seq;
    var owner_buf: [prefixed("client", &@splat(0)).len]u8 = undefined;
    const owner: []const u8 = if (pane.owner) |o| owner: {
        owner_buf = prefixed("client", &o.id);
        break :owner &owner_buf;
    } else "";
    for (pane.streams.items) |st| if (st.need == .none) self.queueData(st, .grid, protocol.Grid{
        .stream = st.id,
        .seq = seq,
        .cols = size.cols,
        .rows = size.rows,
    }, owner);
    self.emit("size_changed", &pane.session_id, .{
        .block = prefixed("block", &pane.id),
        .cols = size.cols,
        .rows = size.rows,
        .owner = owner,
    });
}

/// Append `dir` to PATH unless it is already there, last so the user's
/// own commands win, as Ghostty does for its binary in a surface.
fn appendPath(alloc: Allocator, env: *EnvMap, dir: []const u8) !void {
    const path = env.get("PATH") orelse "";
    if (path.len == 0) return env.put("PATH", dir);
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |entry| if (std.mem.eql(u8, entry, dir)) return;
    const joined = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ path, dir });
    defer alloc.free(joined);
    try env.put("PATH", joined);
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
    for (pane.records.items) |r| self.alloc.free(r.buf);
    pane.records.deinit(self.alloc);
    pane.waiters.deinit(self.alloc);
    pane.streams.deinit(self.alloc);
    if (pane.ring) |r| self.alloc.destroy(r);
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

    const given = try req.command();
    const command = given orelse args: {
        const sh = try req.arena.dupeSentinel(u8, self.env.get("SHELL") orelse "/bin/sh", 0);
        break :args try req.arena.dupe([:0]const u8, &.{sh});
    };
    const integrated = self.shell_integration.apply(req.arena, command, &env) catch |err| args: {
        log.warn("shell integration failed: {t}", .{err});
        break :args command;
    };
    // The user's shell starts as a login shell, as in Ghostty; a given
    // command runs as is.
    const args = if (given == null) try shell.login(req.arena, integrated) else integrated;
    const cwd = if (req.str("cwd")) |p| try req.arena.dupeSentinel(u8, p, 0) else s.cwd orelse
        if (self.env.get("HOME")) |h| try req.arena.dupeSentinel(u8, h, 0) else null;

    // Starting the block forks the server.
    for (self.sessions.items) |other| for (try sessionPanes(other, req.arena)) |p| p.block.hidePagesFromChildren();
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
        .parent = try self.parentBlock(req),
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

/// The open block named by the request's `parent` param, if any.
fn parentBlock(self: *Server, req: *Request) Error!?ids.Uuid {
    const q = req.str("parent") orelse return null;
    if (!std.mem.startsWith(u8, q, "block:") or q.len != "block:".len + 36) return null;
    const id = q["block:".len..][0..36];
    for (self.sessions.items) |s| for (try sessionPanes(s, req.arena)) |pane| {
        if (std.mem.eql(u8, &pane.id, id)) return pane.id;
    };
    return null;
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
    if (pane.queued) removePtr(Pane, &self.compress_queue, pane);
    while (pane.streams.items.len > 0) self.removeStream(pane.streams.items[pane.streams.items.len - 1]);
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

    /// A positive integer, at most `max`.
    fn count(self: *Request, key: []const u8, default: usize, max: usize) Error!usize {
        const v = self.get(key) orelse return default;
        if (v != .integer or v.integer < 1) return self.fail(error.Usage, "{s} must be a positive integer", .{key});
        return @min(@as(usize, @intCast(v.integer)), max);
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
    .{ "server.stats", &serverStats },
    .{ "server.stop", &serverStop },
    .{ "session.list", &sessionList },
    .{ "session.create", &sessionCreate },
    .{ "session.view", &sessionView },
    .{ "session.subscribe", &sessionSubscribe },
    .{ "session.new_window", &sessionNewWindow },
    .{ "session.new_split", &sessionNewSplit },
    .{ "session.move_block", &sessionMoveBlock },
    .{ "session.resize_split", &sessionResizeSplit },
    .{ "session.close_window", &sessionCloseWindow },
    .{ "session.zoom_block", &sessionZoomBlock },
    .{ "session.focus", &sessionFocus },
    .{ "session.set_label", &sessionSetLabel },
    .{ "session.set_window_label", &sessionSetWindowLabel },
    .{ "session.describe_block", &sessionDescribeBlock },
    .{ "session.kill", &sessionKill },
    .{ "block.close", &blockClose },
    .{ "block.method", &blockMethod },
    .{ "block.subscribe", &blockSubscribe },
    .{ "block.unsubscribe", &blockUnsubscribe },
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

/// Find one item by full id, then label, then 1-based position (except
/// for blocks, whose positions count within a window), then an id suffix
/// of at least 4 characters.
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

    if (comptime !std.mem.eql(u8, kind, "block")) {
        if (std.fmt.parseInt(usize, query, 10)) |pos| {
            if (pos >= 1 and pos <= items.len) return items[pos - 1];
        } else |_| {}
    }

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
            return req.fail(error.Target, "no block {s} in that window", .{q});
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
        .tailnet = self.tailnet_addr,
        .sessions = self.sessions.items.len,
        .clients = self.clients.items.len,
        .uptime_ms = self.nowMs() - self.started_ms,
    });
}

/// Memory use: the server's phys_footprint where the OS reports it, the
/// figure Activity Monitor shows, and each block's terminal pages.
fn serverStats(self: *Server, req: *Request, w: *Stringify) Error!void {
    try w.beginObject();
    try w.objectField("pid");
    try w.write(c.getpid());
    try w.objectField("phys_footprint");
    try w.write(physFootprint());
    try w.objectField("blocks");
    try w.beginArray();
    for (self.sessions.items) |s| for (try sessionPanes(s, req.arena)) |pane| {
        const primary = pane.block.term.screens.get(.primary).?;
        const alternate = pane.block.term.screens.get(.alternate);
        try w.write(.{
            .id = prefixed("block", &pane.id),
            .session = s.label,
            .rows = primary.pages.total_rows,
            .primary = primary.memoryUsage(),
            .alternate = if (alternate) |a| a.memoryUsage() else null,
        });
    };
    try w.endArray();
    try w.endObject();
}

fn physFootprint() ?u64 {
    if (comptime !builtin.os.tag.isDarwin()) return null;
    var info: c.task_vm_info_data_t = undefined;
    var n: c.mach_msg_type_number_t = c.TASK.VM.INFO_COUNT;
    if (c.task_info(c.mach_task_self(), c.TASK.VM.INFO, @ptrCast(&info), &n) != 0) return null;
    return info.phys_footprint;
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
        .status = rootView(pane),
        .program_status = RecordsView{ .pane = pane },
        .last_activity = pane.last_activity,
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
        try w.objectField("parent");
        try w.write(if (win.parent) |*p| prefixed("block", p) else null);
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
        const id = prefixed("client", &cl.id);
        switch (cl.principal) {
            .unix => |p| try w.write(.{
                .id = id,
                .principal = .{ .kind = "peer", .transport = "unix", .uid = p.uid, .gid = p.gid, .pid = p.pid },
            }),
            .tailscale => |t| try w.write(.{
                .id = id,
                .principal = .{ .kind = "peer", .transport = "tailscale", .login = t.login, .node = t.node, .addr = t.addr },
            }),
        }
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

/// Move a block beside another of its window, as a pane dropped on
/// another pane's edge.
fn sessionMoveBlock(self: *Server, req: *Request, w: *Stringify) Error!void {
    const t = try self.resolve(req);
    const q = req.str("target") orelse return req.fail(error.Usage, "target is required", .{});
    const target = try match(Pane, "block", try t.window.tree.leaves(req.arena), q, req);
    if (target == t.pane) return req.fail(error.Usage, "a block can't move beside itself", .{});
    const d = req.str("direction") orelse return req.fail(error.Usage, "direction is required", .{});
    const dir: layout.Dir, const before = if (std.mem.eql(u8, d, "left"))
        .{ .horizontal, true }
    else if (std.mem.eql(u8, d, "right"))
        .{ .horizontal, false }
    else if (std.mem.eql(u8, d, "up"))
        .{ .vertical, true }
    else if (std.mem.eql(u8, d, "down"))
        .{ .vertical, false }
    else
        return req.fail(error.Usage, "direction must be left, right, up, or down", .{});
    t.window.tree.move(self.alloc, t.pane, target, dir, before) catch |err| return switch (err) {
        error.NotFound => unreachable,
        error.OutOfMemory => error.OutOfMemory,
    };
    t.window.focused = t.pane;
    t.window.zoomed = null;
    self.viewChanged(t.session);
    try w.write(.{});
}

/// Set the share of the split between a block and another of its window
/// that the block's side takes, as a divider dragged between two panes.
/// The block must be on the split's first side: left of or above the target.
fn sessionResizeSplit(self: *Server, req: *Request, w: *Stringify) Error!void {
    const t = try self.resolve(req);
    const q = req.str("target") orelse return req.fail(error.Usage, "target is required", .{});
    const target = try match(Pane, "block", try t.window.tree.leaves(req.arena), q, req);
    const ratio: f64 = switch (req.get("ratio") orelse return req.fail(error.Usage, "ratio is required", .{})) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return req.fail(error.Usage, "ratio must be a number", .{}),
    };
    if (!(ratio > 0 and ratio < 1)) return req.fail(error.Usage, "ratio must be between 0 and 1", .{});
    t.window.tree.resize(t.pane, target, ratio) catch
        return req.fail(error.Usage, "the block must be left of or above the target", .{});
    self.viewChanged(t.session);
    try w.write(.{});
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
        "bell",            "child_exited",    "clipboard_written",      "desktop_notification",
        "process_changed", "progress_report", "program_status_changed", "program_status_removed",
        "pwd_changed",     "title_changed",
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

fn blockSubscribe(self: *Server, req: *Request, w: *Stringify) Error!void {
    const pane = (try self.resolve(req)).pane;
    const since: ?u64 = if (req.get("since_seq")) |v| since: {
        if (v != .integer or v.integer < 0) return req.fail(error.Usage, "since_seq must be a non-negative integer", .{});
        break :since @intCast(v.integer);
    } else null;
    const cl = req.client;
    try cl.streams.ensureUnusedCapacity(self.alloc, 1);
    try pane.streams.ensureUnusedCapacity(self.alloc, 1);
    const st = try self.alloc.create(Stream);
    errdefer self.alloc.destroy(st);
    if (pane.ring == null) {
        const ring = try self.alloc.create(dataplane.Ring);
        ring.* = .{ .end = pane.block.seq };
        pane.ring = ring;
    }
    st.* = .{
        .id = cl.next_stream,
        .client = cl,
        .pane = pane,
        .need = if (since) |s| .{ .replay = s } else .snapshot,
    };
    cl.next_stream +%= 1;
    cl.streams.appendAssumeCapacity(st);
    pane.streams.appendAssumeCapacity(st);
    // The snapshot or replay follows the reply.
    try w.write(.{ .stream = st.id, .block = prefixed("block", &pane.id) });
}

fn blockUnsubscribe(self: *Server, req: *Request, w: *Stringify) Error!void {
    const v = req.get("stream") orelse return req.fail(error.Usage, "missing stream", .{});
    const id = if (v == .integer) std.math.cast(u32, v.integer) else null;
    // A stream that is gone went with its block.
    if (findStream(req.client, id orelse return req.fail(error.Usage, "stream must be a stream id", .{}))) |st|
        self.removeStream(st);
    try w.write(.{});
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
    .{ "list_dir", &methodListDir },
    .{ "process", &methodProcess },
    .{ "program_status", &methodProgramStatus },
    .{ "reset", &methodReset },
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
    // Reading scrollback restores compressed pages without counting as
    // activity, so compress them again once the block is quiet.
    if (all) pane.compressed = null;
    try w.write(.{ .text = text, .seq = pane.block.seq });
}

/// Resend every stream of the block from a fresh snapshot.
fn methodReset(pane: *Pane, _: *Request, w: *Stringify) Error!void {
    const self = pane.server;
    for (pane.streams.items) |st| self.resync(st);
    for (pane.streams.items) |st| self.pump(st.client);
    try w.write(.{});
}

/// The status records programs have reported (OSC 7501).
fn methodProgramStatus(pane: *Pane, _: *Request, w: *Stringify) Error!void {
    try w.write(.{ .records = RecordsView{ .pane = pane } });
}

/// The block's child, and the foreground process: the program the user
/// is talking to.
fn methodProcess(pane: *Pane, req: *Request, w: *Stringify) Error!void {
    const fg = if (pane.exit_code == null) proc.foreground(pane.block.pty.master) else null;
    try w.write(.{
        .pid = pane.block.pid,
        .exit_code = pane.exit_code,
        .foreground = if (fg) |pid| try proc.describe(req.arena, pid) else null,
    });
}

/// The entries under `path` (default "."), resolved as the foreground
/// program would, to `depth` levels (default 1). With `query`, only the
/// paths that fuzzily match it. At most `limit` entries (default 5000).
fn methodListDir(pane: *Pane, req: *Request, w: *Stringify) Error!void {
    const self = pane.server;
    for ([_][]const u8{ "path", "query" }) |key| if (req.get(key)) |v| if (v != .string)
        return req.fail(error.Usage, "{s} must be a string", .{key});
    const root = try self.resolvePath(pane, req, req.str("path") orelse ".");
    const query = req.str("query");
    const r = listdir.list(req.arena, self.io, root, .{
        .depth = @intCast(try req.count("depth", 1, 32)),
        .query = if (query != null and query.?.len > 0) query else null,
        .limit = try req.count("limit", listdir.default_limit, listdir.max_scanned),
    }) catch |err| return req.fail(error.Fail, "listing {s} failed: {t}", .{ root, err });
    try w.beginObject();
    try w.objectField("path");
    try w.write(root);
    try w.objectField("entries");
    try w.beginArray();
    for (r.entries) |e| try w.write(.{ .name = e.name, .kind = @tagName(e.kind) });
    try w.endArray();
    try w.objectField("truncated");
    try w.write(r.truncated);
    try w.endObject();
}

/// An absolute path for `path` as the block's foreground program would
/// resolve it: from its working directory, with `~` as the home directory.
fn resolvePath(self: *Server, pane: *Pane, req: *Request, path: []const u8) Error![]const u8 {
    if (std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/")) {
        const home = pane.window.?.session.env.get("HOME") orelse self.env.get("HOME") orelse
            return req.fail(error.Fail, "HOME is not set", .{});
        return try std.fs.path.resolveAlloc(req.arena, &.{ home, path[@min(path.len, 2)..] });
    }
    var buf: [proc.max_path]u8 = undefined;
    const fg = proc.foreground(pane.block.pty.master) orelse pane.block.pid;
    const cwd = proc.cwd(fg, &buf) orelse proc.cwd(pane.block.pid, &buf) orelse
        return req.fail(error.Fail, "the block's working directory is unknown", .{});
    return try std.fs.path.resolveAlloc(req.arena, &.{ cwd, path });
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

    // Directly in /tmp: a socket under a deep checkout's .zig-cache can
    // exceed sun_path (104 bytes on macOS).
    const path = try std.fmt.allocPrintSentinel(alloc, "/tmp/rex-test-{d}.sock", .{c.getpid()}, 0);
    defer alloc.free(path);
    const lock_path = try std.fmt.allocPrintSentinel(alloc, "{s}.lock", .{path}, 0);
    defer alloc.free(lock_path);
    defer _ = c.unlink(lock_path);
    defer _ = c.unlink(path);

    var env: EnvMap = .init(alloc);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("FOO", "leaked");

    const server = try Server.create(alloc, testing.io, .{ .socket_path = path, .env = &env, .bin_dir = "/opt/rap" });
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
        \\{"id":1,"method":"session.create","params":{"label":"demo","command":["/bin/sh","-c","echo FOO=$FOO; echo PATH=$PATH; echo SESSION=$RAP_SESSION; sleep 30"]}}
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
            try testing.expect(std.mem.indexOf(u8, captured, "PATH=/usr/bin:/bin:/opt/rap") != null);
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

    const split_parsed = try std.json.parseFromSlice(std.json.Value, alloc, split, .{});
    defer split_parsed.deinit();
    const second = split_parsed.value.object.get("result").?.object.get("block").?.string;

    // A resized split keeps its ratio when focus moves to the other block,
    // as a click on the other pane after dragging the divider.
    const resize_req = try std.fmt.allocPrint(alloc,
        \\{{"id":56,"method":"session.resize_split","params":{{"session":"demo","block":"1","target":"{s}","ratio":0.3}}}}
    , .{second});
    defer alloc.free(resize_req);
    const resized = try T.call(fd, resize_req);
    defer alloc.free(resized);
    try testing.expectEqualStrings("{\"id\":56,\"result\":[]}", resized);
    const focus_req = try std.fmt.allocPrint(alloc,
        \\{{"id":57,"method":"session.focus","params":{{"session":"demo","block":"{s}"}}}}
    , .{second});
    defer alloc.free(focus_req);
    const focused = try T.call(fd, focus_req);
    defer alloc.free(focused);
    const resized_view = try T.call(fd,
        \\{"id":58,"method":"session.view","params":{"session":"demo"}}
    );
    defer alloc.free(resized_view);
    try testing.expect(std.mem.indexOf(u8, resized_view, "\"type\":\"vertical\",\"ratio\":0.3,") != null);
    // The block must be on the split's first side, and the ratio inside it.
    const view_parsed = try std.json.parseFromSlice(std.json.Value, alloc, resized_view, .{});
    defer view_parsed.deinit();
    const first = view_parsed.value.object.get("result").?.object.get("windows").?.array.items[0]
        .object.get("blocks").?.array.items[0].object.get("id").?.string;
    for ([_][2][]const u8{ .{ second, first }, .{ first, second } }, [_][]const u8{ "0.3", "1" }) |pair, ratio| {
        const bad_req = try std.fmt.allocPrint(alloc,
            \\{{"id":59,"method":"session.resize_split","params":{{"session":"demo","block":"{s}","target":"{s}","ratio":{s}}}}}
        , .{ pair[0], pair[1], ratio });
        defer alloc.free(bad_req);
        const refused = try T.call(fd, bad_req);
        defer alloc.free(refused);
        try testing.expect(std.mem.indexOf(u8, refused, "\"error\"") != null);
    }

    // Moving the first block below the second puts the second on top, and
    // the view shows it rather than the old layout.
    const move_req = try std.fmt.allocPrint(alloc,
        \\{{"id":53,"method":"session.move_block","params":{{"session":"demo","block":"1","target":"{s}","direction":"down"}}}}
    , .{second});
    defer alloc.free(move_req);
    const moved = try T.call(fd, move_req);
    defer alloc.free(moved);
    try testing.expectEqualStrings("{\"id\":53,\"result\":[]}", moved);
    const moved_view = try T.call(fd,
        \\{"id":54,"method":"session.view","params":{"session":"demo"}}
    );
    defer alloc.free(moved_view);
    const top = try std.fmt.allocPrint(alloc, "\"layout\":{{\"type\":\"vertical\",\"ratio\":0.5,\"a\":{{\"type\":\"block\",\"block\":\"{s}\"}}", .{second});
    defer alloc.free(top);
    try testing.expect(std.mem.indexOf(u8, moved_view, top) != null);
    const beside_itself = try std.fmt.allocPrint(alloc,
        \\{{"id":55,"method":"session.move_block","params":{{"session":"demo","block":"{s}","target":"{s}","direction":"up"}}}}
    , .{ second, second });
    defer alloc.free(beside_itself);
    const refused_move = try T.call(fd, beside_itself);
    defer alloc.free(refused_move);
    try testing.expect(std.mem.indexOf(u8, refused_move, "\"error\"") != null);

    // Block positions count within the active window only.
    const window = try T.call(fd,
        \\{"id":51,"method":"session.new_window","params":{"session":"demo","command":["/bin/sh","-c","sleep 30"]}}
    );
    defer alloc.free(window);
    const out_of_range = try T.call(fd,
        \\{"id":52,"method":"block.method","params":{"session":"demo","block":"2","method":"size"}}
    );
    defer alloc.free(out_of_range);
    try testing.expect(std.mem.indexOf(u8, out_of_range, "\"code\":\"target\"") != null);

    // A window asked for from inside a block names that block as its parent;
    // an unknown parent is dropped.
    const block_at = std.mem.indexOf(u8, created, "\"block\":\"").? + "\"block\":\"".len;
    const parent = created[block_at..][0 .. "block:".len + 36];
    const child_req = try std.fmt.allocPrint(alloc,
        \\{{"id":53,"method":"session.new_window","params":{{"session":"demo","parent":"{s}","command":["/bin/sh","-c","sleep 30"]}}}}
    , .{parent});
    defer alloc.free(child_req);
    const child = try T.call(fd, child_req);
    defer alloc.free(child);
    const orphan = try T.call(fd,
        \\{"id":54,"method":"session.new_window","params":{"session":"demo","parent":"block:nope","command":["/bin/sh","-c","sleep 30"]}}
    );
    defer alloc.free(orphan);
    const family = try T.call(fd,
        \\{"id":55,"method":"session.view","params":{"session":"demo"}}
    );
    defer alloc.free(family);
    const needle = try std.fmt.allocPrint(alloc, "\"parent\":\"{s}\"", .{parent});
    defer alloc.free(needle);
    try testing.expectEqual(1, std.mem.count(u8, family, needle));
    try testing.expectEqual(3, std.mem.count(u8, family, "\"parent\":null"));

    const killed = try T.call(fd,
        \\{"id":6,"method":"session.kill","params":{"session":"demo"}}
    );
    defer alloc.free(killed);
    const list = try T.call(fd,
        \\{"id":7,"method":"session.list"}
    );
    defer alloc.free(list);
    try testing.expectEqualStrings("{\"id\":7,\"result\":{\"sessions\":[]}}", list);

    // Scrollback of a quiet block is compressed, and the stats show it.
    const big = try T.call(fd,
        \\{"id":9,"method":"session.create","params":{"label":"big","command":["/bin/sh","-c","yes line | head -n 2000; sleep 30"]}}
    );
    defer alloc.free(big);
    tries = 0;
    while (true) : (tries += 1) {
        const stats = try T.call(fd,
            \\{"id":10,"method":"server.stats"}
        );
        defer alloc.free(stats);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, stats, .{});
        defer parsed.deinit();
        const usage = parsed.value.object.get("result").?.object.get("blocks").?.array.items[0].object.get("primary").?.object.get("pages").?;
        if (usage.object.get("compressed_pages").?.integer > 0) break;
        if (tries == 1000) return error.TestUnexpectedResult;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }

    const stopped = try T.call(fd,
        \\{"id":8,"method":"server.stop"}
    );
    defer alloc.free(stopped);
    try testing.expectError(error.Unreachable, protocol.connect(path));
}

test "rex Server: foreground process, list_dir, and program status" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const path = try std.fmt.allocPrintSentinel(alloc, "/tmp/rex-test-chrome-{d}.sock", .{c.getpid()}, 0);
    defer alloc.free(path);
    const lock_path = try std.fmt.allocPrintSentinel(alloc, "{s}.lock", .{path}, 0);
    defer alloc.free(lock_path);
    defer _ = c.unlink(lock_path);
    defer _ = c.unlink(path);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a/b");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/b/c.txt", .data = "" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    var env: EnvMap = .init(alloc);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");

    const server = try Server.create(alloc, io, .{ .socket_path = path, .env = &env });
    defer server.destroy();
    const thread = try std.Thread.spawn(.{}, (struct {
        fn run(srv: *Server) void {
            srv.run() catch |err| std.debug.panic("server failed: {t}", .{err});
        }
    }).run, .{server});
    defer thread.join();

    const T = struct {
        fn read(sock: posix.fd_t) ![]u8 {
            var pfd = [_]posix.pollfd{.{ .fd = sock, .events = posix.POLL.IN, .revents = 0 }};
            if (try posix.poll(&pfd, 10_000) == 0) return error.Timeout;
            return (try protocol.readFrame(testing.allocator, sock)).payload;
        }
        fn call(sock: posix.fd_t, req: []const u8) ![]u8 {
            try protocol.writeFrame(sock, .json, req);
            return read(sock);
        }
        fn has(payload: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, payload, needle) != null;
        }
    };

    const events = try protocol.connect(path);
    defer _ = c.close(events);
    alloc.free(try T.call(events,
        \\{"id":1,"method":"session.subscribe"}
    ));

    const fd = try protocol.connect(path);
    defer _ = c.close(fd);
    // "aGkgdGhlcmU=" is "hi there" in base64.
    const new = try std.fmt.allocPrint(alloc,
        \\{{"id":2,"method":"session.create","params":{{"label":"chrome","cwd":"{s}","command":["/bin/sh","-c","printf '\\033]7501;state=working:msg=aGkgdGhlcmU=\\033\\\\'; exec sleep 30"]}}}}
    , .{root});
    defer alloc.free(new);
    alloc.free(try T.call(fd, new));

    // The status and the program the shell execs arrive as events.
    var status = false;
    var sleeping = false;
    while (!status or !sleeping) {
        const ev = try T.read(events);
        defer alloc.free(ev);
        if (T.has(ev, "\"event\":\"program_status_changed\"")) {
            try testing.expect(T.has(ev, "\"state\":\"working\",\"kind\":null,\"msg\":\"hi there\""));
            try testing.expect(T.has(ev, "\"progress\":null,\"app\":null,\"title\":null,\"updated_at\":1"));
            try testing.expect(!T.has(ev, "\"source\""));
            status = true;
        }
        if (T.has(ev, "\"event\":\"process_changed\"") and T.has(ev, "\"name\":\"sleep\"")) sleeping = true;
    }

    const process = try T.call(fd,
        \\{"id":3,"method":"block.method","params":{"session":"chrome","method":"process"}}
    );
    defer alloc.free(process);
    try testing.expect(T.has(process, "\"foreground\":{\"pid\":"));
    try testing.expect(T.has(process, "\"name\":\"sleep\""));

    const listed = try T.call(fd,
        \\{"id":4,"method":"block.method","params":{"session":"chrome","method":"list_dir","depth":3}}
    );
    defer alloc.free(listed);
    try testing.expect(T.has(listed, "{\"name\":\"a/b/c.txt\",\"kind\":\"file\"}"));
    try testing.expect(T.has(listed, "\"truncated\":false"));
    const missing = try T.call(fd,
        \\{"id":5,"method":"block.method","params":{"session":"chrome","method":"list_dir","path":"nope"}}
    );
    defer alloc.free(missing);
    try testing.expect(T.has(missing, "\"code\":\"fail\""));

    const view = try T.call(fd,
        \\{"id":6,"method":"session.view","params":{"session":"chrome"}}
    );
    defer alloc.free(view);
    try testing.expect(T.has(view, "\"status\":{\"id\":null,\"state\":\"working\""));
    try testing.expect(T.has(view, "\"last_activity\":1"));

    // A plain title leaves a progress bar's working status alone.
    alloc.free(try T.call(fd,
        \\{"id":7,"method":"session.create","params":{"label":"dl","command":["/bin/sh","-c","printf '\\033]9;4;1;50\\033\\\\\\033]0;Downloading foo\\007'; exec sleep 30"]}}
    ));
    while (true) {
        const ev = try T.read(events);
        defer alloc.free(ev);
        try testing.expect(!T.has(ev, "\"state\":\"done\""));
        if (T.has(ev, "\"title\":\"Downloading foo\"")) break;
    }
    const dl = try T.call(fd,
        \\{"id":8,"method":"session.view","params":{"session":"dl"}}
    );
    defer alloc.free(dl);
    try testing.expect(T.has(dl, "\"status\":{\"id\":null,\"state\":\"working\",\"kind\":null,\"msg\":null,\"progress\":50,"));

    const bad = try T.call(fd,
        \\{"id":9,"method":"block.method","params":{"session":"chrome","method":"list_dir","path":2024}}
    );
    defer alloc.free(bad);
    try testing.expect(T.has(bad, "\"code\":\"usage\""));

    alloc.free(try T.call(fd,
        \\{"id":10,"method":"server.stop"}
    ));
}

test "rex Server: program status protocol" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const path = try std.fmt.allocPrintSentinel(alloc, "/tmp/rex-test-status-{d}.sock", .{c.getpid()}, 0);
    defer alloc.free(path);
    const lock_path = try std.fmt.allocPrintSentinel(alloc, "{s}.lock", .{path}, 0);
    defer alloc.free(lock_path);
    defer _ = c.unlink(lock_path);
    defer _ = c.unlink(path);

    var env: EnvMap = .init(alloc);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");

    const server = try Server.create(alloc, io, .{ .socket_path = path, .env = &env });
    defer server.destroy();
    const thread = try std.Thread.spawn(.{}, (struct {
        fn run(srv: *Server) void {
            srv.run() catch |err| std.debug.panic("server failed: {t}", .{err});
        }
    }).run, .{server});
    defer thread.join();

    const events = try protocol.connect(path);
    defer _ = c.close(events);
    const fd = try protocol.connect(path);
    defer _ = c.close(fd);

    const T = struct {
        events: posix.fd_t,
        fd: posix.fd_t,

        fn read(sock: posix.fd_t) ![]u8 {
            var pfd = [_]posix.pollfd{.{ .fd = sock, .events = posix.POLL.IN, .revents = 0 }};
            if (try posix.poll(&pfd, 10_000) == 0) return error.Timeout;
            return (try protocol.readFrame(testing.allocator, sock)).payload;
        }
        fn call(t: @This(), req: anytype) ![]u8 {
            const json = try std.json.Stringify.valueAlloc(testing.allocator, req, .{});
            defer testing.allocator.free(json);
            try protocol.writeFrame(t.fd, .json, json);
            return read(t.fd);
        }
        /// Run `out` in a new session, and return the status events it
        /// causes, one per line.
        fn run(t: @This(), label: []const u8, out: []const u8) ![]u8 {
            const script = try std.mem.concat(testing.allocator, u8, &.{ out, "; printf '\x1b]0;end\x07'; exec sleep 30" });
            defer testing.allocator.free(script);
            testing.allocator.free(try t.call(.{ .id = 2, .method = "session.create", .params = .{
                .label = label,
                .command = &[_][]const u8{ "/bin/sh", "-c", script },
            } }));
            var got: std.ArrayList(u8) = .empty;
            errdefer got.deinit(testing.allocator);
            while (true) {
                const ev = try read(t.events);
                defer testing.allocator.free(ev);
                if (has(ev, "\"title\":\"end\"")) return got.toOwnedSlice(testing.allocator);
                if (!has(ev, "\"event\":\"program_status_")) continue;
                try got.appendSlice(testing.allocator, ev);
                try got.append(testing.allocator, '\n');
            }
        }
        fn records(t: @This(), label: []const u8) ![]u8 {
            return t.call(.{ .id = 3, .method = "block.method", .params = .{ .session = label, .method = "program_status" } });
        }
        fn has(payload: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, payload, needle) != null;
        }
        fn count(payload: []const u8, needle: []const u8) usize {
            return std.mem.count(u8, payload, needle);
        }
    };
    const t: T = .{ .events = events, .fd = fd };
    try protocol.writeFrame(events, .json,
        \\{"id":1,"method":"session.subscribe"}
    );
    testing.allocator.free(try T.read(events));

    // The specification's "One program" example, ended with ST. The done
    // record survives a new prompt, and once a program has reported,
    // OSC 9;4 no longer sets the status.
    {
        const ev = try t.run("brew", "printf '%s' '" ++
            "\x1b]7501;state=working:app=brew:msg=SW5zdGFsbGluZyB1cGRhdGVz\x1b\\" ++
            "\x1b]7501;state=blocked:kind=auth:app=brew:msg=UGFzc3dvcmQgcmVxdWlyZWQgdG8gaW5zdGFsbCB1cGRhdGVz\x1b\\" ++
            "\x1b]7501;state=working:app=brew:msg=SW5zdGFsbGluZyB1cGRhdGVz\x1b\\" ++
            "\x1b]7501;state=done:app=brew:msg=VXBncmFkZWQgMTIgcGFja2FnZXM=\x1b\\" ++
            "\x1b]133;A\x07\x1b]9;4;1;50\x07'");
        defer alloc.free(ev);
        try testing.expectEqual(4, T.count(ev, "\"event\":\"program_status_changed\""));
        try testing.expectEqual(4, T.count(ev, "\"reason\":\"report\""));
        try testing.expect(!T.has(ev, "program_status_removed"));
        try testing.expect(T.has(ev, "\"id\":null,\"record\":{\"id\":null,\"state\":\"blocked\",\"kind\":\"auth\"," ++
            "\"msg\":\"Password required to install updates\",\"progress\":null,\"app\":\"brew\",\"title\":null,\"updated_at\":1"));

        const view = try t.call(.{ .id = 4, .method = "session.view", .params = .{ .session = "brew" } });
        defer alloc.free(view);
        try testing.expect(T.has(view, "\"status\":{\"id\":null,\"state\":\"done\",\"kind\":null,\"msg\":\"Upgraded 12 packages\",\"progress\":null,\"app\":\"brew\""));
        // The root record, as the status and as the only record.
        try testing.expect(T.has(view, "\"program_status\":[{\"id\":null,\"state\":\"done\""));
        try testing.expectEqual(2, T.count(view, "\"state\":"));
    }

    // The "Several records" example, stopped while eu-west is blocked:
    // the root still says working, and the regions take app from it.
    const deploy_start = "\x1b]7501;state=working:app=deploy:msg=RGVwbG95aW5nIHYyLjQuMQ==\x07" ++
        "\x1b]7501;state=working:id=us-east:title=VVMgRWFzdA==:progress=40:msg=UHVzaGluZyBpbWFnZQ==\x07" ++
        "\x1b]7501;state=blocked:kind=permission:id=eu-west:title=RVUgV2VzdA==:msg=QXBwcm92ZSBkZXBsb3kgdG8gZXUtd2VzdCAocHJvZHVjdGlvbik/\x07";
    {
        const ev = try t.run("deploy-mid", "printf '%s' '" ++ deploy_start ++ "'");
        defer alloc.free(ev);
        try testing.expect(T.has(ev, "\"id\":\"eu-west\",\"record\":{\"id\":\"eu-west\",\"state\":\"blocked\",\"kind\":\"permission\"," ++
            "\"msg\":\"Approve deploy to eu-west (production)?\",\"progress\":null,\"app\":\"deploy\",\"title\":\"EU West\""));
        const recs = try t.records("deploy-mid");
        defer alloc.free(recs);
        try testing.expect(T.has(recs, "{\"records\":[{\"id\":null,\"state\":\"working\",\"kind\":null,\"msg\":\"Deploying v2.4.1\""));
        try testing.expect(T.has(recs, "{\"id\":\"us-east\",\"state\":\"working\",\"kind\":null,\"msg\":\"Pushing image\",\"progress\":40,\"app\":\"deploy\",\"title\":\"US East\""));
        try testing.expectEqual(3, T.count(recs, "\"state\":"));
    }

    // The whole example: clearing the regions leaves the root's done.
    {
        const ev = try t.run("deploy", "printf '%s' '" ++ deploy_start ++
            "\x1b]7501;state=done:id=us-east:title=VVMgRWFzdA==:msg=SGVhbHRoeQ==\x07" ++
            "\x1b]7501;state=clear:id=us-east\x07" ++
            "\x1b]7501;state=clear:id=eu-west\x07" ++
            "\x1b]7501;state=done:app=deploy:msg=RGVwbG95ZWQgdG8gMyByZWdpb25z\x07'");
        defer alloc.free(ev);
        try testing.expect(T.has(ev, "\"ids\":[\"us-east\"],\"reason\":\"clear\""));
        try testing.expect(T.has(ev, "\"ids\":[\"eu-west\"],\"reason\":\"clear\""));
        const recs = try t.records("deploy");
        defer alloc.free(recs);
        try testing.expect(T.has(recs, "{\"records\":[{\"id\":null,\"state\":\"done\",\"kind\":null,\"msg\":\"Deployed to 3 regions\""));
        try testing.expectEqual(1, T.count(recs, "\"state\":"));
    }

    // Clearing removes a subtree, a malformed id never falls back to the
    // root, a prompt drops working and blocked records, and a full reset
    // drops the rest and lets OSC 9;4 set the status again.
    {
        const ev = try t.run("life", "printf '%s' '" ++
            "\x1b]7501;state=working:app=a\x07" ++
            "\x1b]7501;state=blocked:kind=question:id=x\x07" ++
            "\x1b]7501;state=done:id=d\x07" ++
            "\x1b]7501;state=idle:id=i\x07" ++
            "\x1b]7501;state=working:id=build\x07" ++
            "\x1b]7501;state=working:id=build/test\x07" ++
            "\x1b]7501;state=working:id=buildx\x07" ++
            "\x1b]7501;state=clear:id=a//b\x07" ++
            "\x1b]7501;state=sleeping\x07" ++
            "\x1b]7501;state=clear:id=build\x07" ++
            "\x1b]133;A\x07" ++
            "\x1bc" ++
            "\x1b]9;4;1;50\x07'");
        defer alloc.free(ev);
        try testing.expectEqual(7, T.count(ev, "\"reason\":\"report\""));
        try testing.expectEqual(3, T.count(ev, "program_status_removed"));
        try testing.expect(T.has(ev, "\"ids\":[\"build\",\"build/test\"],\"reason\":\"clear\""));
        try testing.expect(T.has(ev, "\"ids\":[null,\"x\",\"buildx\"],\"reason\":\"prompt\""));
        try testing.expect(T.has(ev, "\"ids\":[\"d\",\"i\"],\"reason\":\"reset\""));
        try testing.expect(T.has(ev, "\"state\":\"working\",\"kind\":null,\"msg\":null,\"progress\":50,\"app\":null,\"title\":null,\"updated_at\":1"));
        try testing.expect(T.has(ev, "\"reason\":\"inferred\""));
    }

    // Past 256 records, the one updated least recently goes.
    {
        const ev = try t.run("many", "i=0; while [ $i -le 256 ]; do printf '\\033]7501;state=idle:id=r%d\\007' $i; i=$((i+1)); done");
        defer alloc.free(ev);
        try testing.expectEqual(257, T.count(ev, "\"reason\":\"report\""));
        try testing.expect(T.has(ev, "\"ids\":[\"r0\"],\"reason\":\"evicted\""));
        const recs = try t.records("many");
        defer alloc.free(recs);
        try testing.expectEqual(max_records, T.count(recs, "\"state\":"));
        try testing.expect(T.has(recs, "{\"records\":[{\"id\":\"r1\","));
    }

    alloc.free(try t.call(.{ .id = 5, .method = "server.stop" }));
}
