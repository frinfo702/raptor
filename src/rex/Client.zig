//! A connection to the rap server for programs that show its blocks, such
//! as the app: control requests and their responses, events, and blocks
//! bound to local terminals.
//!
//! A reader thread owns the socket's input. It hands each response to the
//! thread waiting for it, each event to the event callback, and each data
//! frame of a bound block straight to that block's terminal (a
//! `Feed.Sink`). A binding sends the terminal's input, size and focus back
//! as `in`, `size` and `focus` frames.
//!
//! When the connection drops, the reader reconnects to the same socket and
//! resubscribes every bound block with `since_seq`, so a short outage
//! costs a replay of the missed output rather than a snapshot. It also
//! renews the latest `session.subscribe`. The event callback hears
//! `{"event":"server_disconnected"}` and `{"event":"server_reconnected"}`.
const Client = @This();

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const Feed = @import("Feed.zig");
const protocol = @import("protocol.zig");

const log = std.log.scoped(.rap_client);

/// Gets each event's JSON, on the reader thread. It must not wait for a
/// response, since only the reader thread could deliver it.
pub const EventFn = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void;

alloc: Allocator,
io: std.Io,
path: [:0]u8,
reader: std.Thread = undefined,

/// Guards the fields below, and writes to `fd`.
lock: std.Io.Mutex = .init,
/// Broadcast when a response arrives, a subscription is answered, or the
/// connection drops.
cond: std.Io.Condition = .init,
/// The socket, or -1 while reconnecting. Only the reader changes it.
fd: posix.fd_t,
closing: bool = false,
next_id: i64 = 1,
/// Requests waiting for their responses.
pending: std.ArrayList(*Pending) = .empty,
bindings: std.ArrayList(*Binding) = .empty,
/// The latest `session.subscribe` request, renewed on reconnect.
events_request: ?[]u8 = null,
on_event: ?EventFn = null,
event_userdata: ?*anyopaque = null,

/// Held by the reader while it feeds a bound terminal, so that unbinding
/// can wait until the terminal is no longer fed. A terminal never waits
/// for the app while fed, so the app's thread may wait for this.
feed_lock: std.Io.Mutex = .init,

const Pending = struct {
    id: i64,
    response: ?[]u8 = null,
    /// The connection dropped before the response came.
    dropped: bool = false,
};

/// How to start a server when none is running.
pub const Launch = struct {
    /// The `rap` executable.
    exe: []const u8,
    /// The environment to start it from. The server keeps only
    /// `protocol.daemon_env`, and `RAP_AUTOSTART=0` disables launching.
    env: *const EnvMap,
    /// Seconds, as `rap server run --idle-timeout` takes them.
    idle_timeout: ?[]const u8 = null,
};

/// Connect to the server at `path`, starting one with `launch` if none is
/// running.
pub fn connect(alloc: Allocator, io: std.Io, path: []const u8, launch: ?Launch) !*Client {
    const fd = try dial(alloc, io, path, launch);
    errdefer _ = c.close(fd);
    const self = try alloc.create(Client);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc, .io = io, .path = try alloc.dupeSentinel(u8, path, 0), .fd = fd };
    errdefer alloc.free(self.path);
    self.reader = try std.Thread.spawn(.{}, readLoop, .{self});
    return self;
}

/// Disconnect and free the client and its bindings. Terminals bound to it
/// must not send input any more.
pub fn deinit(self: *Client) void {
    self.lock.lockUncancelable(self.io);
    self.closing = true;
    // Wake the reader.
    if (self.fd >= 0) _ = c.shutdown(self.fd, c.SHUT.RDWR);
    self.lock.unlock(self.io);
    self.reader.join();

    if (self.fd >= 0) _ = c.close(self.fd);
    for (self.bindings.items) |b| {
        b.feed.deinit(self.alloc);
        self.alloc.free(b.block);
        self.alloc.destroy(b);
    }
    self.bindings.deinit(self.alloc);
    self.pending.deinit(self.alloc);
    if (self.events_request) |r| self.alloc.free(r);
    self.alloc.free(self.path);
    self.alloc.destroy(self);
}

/// Connect to the server at `path`, starting one with `launch` if none is
/// running. `Unreachable` means there is still no server.
pub fn dial(alloc: Allocator, io: std.Io, path: []const u8, launch: ?Launch) !posix.fd_t {
    const fd = protocol.connect(path) catch |err| fd: {
        if (err != error.Unreachable) return err;
        const l = launch orelse return err;
        if (l.env.get("RAP_AUTOSTART")) |v| if (std.mem.eql(u8, v, "0")) return err;
        try launchServer(alloc, io, l, path);
        break :fd try protocol.connect(path);
    };
    noSigpipe(fd);
    return fd;
}

/// A write to a closed socket must fail rather than kill the process.
fn noSigpipe(fd: posix.fd_t) void {
    if (comptime builtin.os.tag.isDarwin()) {
        const on: c_int = 1;
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, std.mem.asBytes(&on), @sizeOf(c_int));
    }
}

/// Set the event callback.
pub fn setEventCallback(self: *Client, cb: ?EventFn, userdata: ?*anyopaque) void {
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    self.on_event = cb;
    self.event_userdata = userdata;
}

/// Send a request, `{"method":...,"params":{...}}`, and wait for its
/// response. The client sets the id. The response is the server's JSON,
/// `{"id":...,"result":...}` or `{"id":...,"error":{...}}`, and the caller
/// owns it. Requests made while the connection is down, or interrupted by
/// it dropping, fail with `Disconnected`.
pub fn request(self: *Client, json: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    var req = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch
        return error.BadRequest;
    if (req != .object) return error.BadRequest;
    const method = req.object.get("method") orelse return error.BadRequest;
    if (method != .string) return error.BadRequest;

    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    var p: Pending = .{ .id = self.next_id };
    self.next_id += 1;
    try req.object.put(arena.allocator(), "id", .{ .integer = p.id });
    try self.sendJsonLocked(req);
    if (std.mem.eql(u8, method.string, "session.subscribe")) {
        const copy = try self.alloc.dupe(u8, json);
        if (self.events_request) |old| self.alloc.free(old);
        self.events_request = copy;
    }

    try self.pending.append(self.alloc, &p);
    defer for (self.pending.items, 0..) |q, i| if (q == &p) {
        _ = self.pending.swapRemove(i);
        break;
    };
    while (p.response == null and !p.dropped) self.cond.waitUncancelable(self.io, &self.lock);
    return p.response orelse error.Disconnected;
}

fn sendJsonLocked(self: *Client, v: anytype) !void {
    if (self.fd < 0) return error.Disconnected;
    var buf: std.Io.Writer.Allocating = .init(self.alloc);
    defer buf.deinit();
    try std.json.Stringify.value(v, .{}, &buf.writer);
    try protocol.writeFrame(self.fd, .json, buf.written());
}

/// Send a request whose response the reader drops, or a binding takes.
fn sendLocked(self: *Client, method: []const u8, params: anytype) !i64 {
    const id = self.next_id;
    self.next_id += 1;
    try self.sendJsonLocked(.{ .id = id, .method = method, .params = params });
    return id;
}

fn sendDataLocked(self: *Client, t: protocol.FrameType, fields: anytype, tail: []const u8) void {
    if (self.fd < 0) return;
    const frame = protocol.encodeData(self.alloc, t, fields, tail) catch return;
    defer self.alloc.free(frame);
    // A failed write means the connection dropped; the reader handles it.
    protocol.writeAll(self.fd, frame) catch {};
}

/// One block shown in one local terminal. The client owns its bindings;
/// they live until the client is freed, since a terminal may send input
/// through one after it is unbound.
pub const Binding = struct {
    client: *Client,
    /// The terminal, while bound.
    sink: ?Feed.Sink = null,
    /// The block: as given to `bind` until the server answers, then its
    /// full id.
    block: []u8 = &.{},
    feed: Feed = .{},
    stream: ?u32 = null,
    /// The id of an unanswered `block.subscribe`.
    sub_id: ?i64 = null,
    /// It resubscribed after a frame failed to apply, and no snapshot has
    /// loaded since.
    resynced: bool = false,

    /// Input for the program, already encoded.
    pub fn write(b: *Binding, bytes: []const u8) void {
        const cl = b.client;
        cl.lock.lockUncancelable(cl.io);
        defer cl.lock.unlock(cl.io);
        const s = b.stream orelse return;
        cl.sendDataLocked(.in, protocol.In{ .stream = s }, bytes);
    }

    /// The terminal's view now fits `cols` x `rows` cells over
    /// `width_px` x `height_px` pixels.
    pub fn resize(b: *Binding, cols: u16, rows: u16, width_px: u32, height_px: u32) void {
        if (cols == 0 or rows == 0) return;
        const cl = b.client;
        cl.lock.lockUncancelable(cl.io);
        defer cl.lock.unlock(cl.io);
        const s = b.stream orelse return;
        cl.sendDataLocked(.size, protocol.Size{
            .stream = s,
            .cols = cols,
            .rows = rows,
            .cell_w_px = std.math.lossyCast(u16, width_px / cols),
            .cell_h_px = std.math.lossyCast(u16, height_px / rows),
        }, "");
    }

    pub fn focus(b: *Binding, focused: bool) void {
        const cl = b.client;
        cl.lock.lockUncancelable(cl.io);
        defer cl.lock.unlock(cl.io);
        const s = b.stream orelse return;
        cl.sendDataLocked(.focus, protocol.Focus{ .stream = s, .focused = @intFromBool(focused) }, "");
    }

    // The callbacks of an external termio backend (termio.External), with
    // the binding as their userdata.

    pub fn onWrite(ud: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
        fromUserdata(ud).write(ptr[0..len]);
    }

    pub fn onResize(ud: ?*anyopaque, cols: u16, rows: u16, width_px: u32, height_px: u32) callconv(.c) void {
        fromUserdata(ud).resize(cols, rows, width_px, height_px);
    }

    pub fn onFocus(ud: ?*anyopaque, focused: bool) callconv(.c) void {
        fromUserdata(ud).focus(focused);
    }

    fn fromUserdata(ud: ?*anyopaque) *Binding {
        return @ptrCast(@alignCast(ud.?));
    }
};

/// A new, unbound binding, which the client owns.
pub fn newBinding(self: *Client) !*Binding {
    const b = try self.alloc.create(Binding);
    errdefer self.alloc.destroy(b);
    b.* = .{ .client = self };
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    try self.bindings.append(self.alloc, b);
    return b;
}

/// Show `block` (an id, or anything else `block.subscribe` resolves) in
/// `sink`: subscribe to it and wait for the server to accept. The sink
/// gets a snapshot, then the block's output and resizes, on the reader
/// thread. Rebinding first unbinds.
pub fn bind(self: *Client, b: *Binding, block: []const u8, sink: Feed.Sink) !void {
    self.unbind(b);
    // Nothing feeds an unbound binding.
    b.feed.deinit(self.alloc);
    b.feed = .{};
    b.resynced = false;

    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    const id = try self.alloc.dupe(u8, block);
    self.alloc.free(b.block);
    b.block = id;
    b.sink = sink;
    self.subscribeLocked(b);
    while (b.sub_id != null) self.cond.waitUncancelable(self.io, &self.lock);
    if (b.stream == null) {
        b.sink = null;
        return error.BindFailed;
    }
}

/// Stop feeding the binding's terminal and drop its input. Once this
/// returns, the reader no longer touches the terminal.
pub fn unbind(self: *Client, b: *Binding) void {
    {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (b.stream) |s| _ = self.sendLocked("block.unsubscribe", .{ .stream = s }) catch {};
        b.stream = null;
        b.sub_id = null;
        b.sink = null;
    }
    // Wait out a frame being applied.
    self.feed_lock.lockUncancelable(self.io);
    self.feed_lock.unlock(self.io);
}

/// Subscribe to the binding's block on the current connection, from where
/// its terminal left off if it has loaded a snapshot.
fn subscribeLocked(self: *Client, b: *Binding) void {
    b.stream = null;
    b.sub_id = if (b.feed.loaded)
        self.sendLocked("block.subscribe", .{ .block = b.block, .since_seq = b.feed.seq }) catch null
    else
        self.sendLocked("block.subscribe", .{ .block = b.block }) catch null;
}

// The reader thread

fn readLoop(self: *Client) void {
    while (true) {
        const frame = protocol.readFrame(self.alloc, self.fd) catch |err| {
            if (err != error.EndOfStream) log.info("connection lost: {t}", .{err});
            if (!self.reconnect()) return;
            continue;
        };
        switch (frame.type) {
            // Takes the payload.
            .json => self.handleJson(frame.payload),
            .snap, .out, .grid => {
                defer self.alloc.free(frame.payload);
                self.handleData(frame.type, frame.payload);
            },
            else => self.alloc.free(frame.payload),
        }
    }
}

fn handleJson(self: *Client, payload: []u8) void {
    var keep = false;
    defer if (!keep) self.alloc.free(payload);
    const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, payload, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const msg = parsed.value.object;

    if (msg.get("id")) |id| {
        if (id != .integer) return;
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        defer self.cond.broadcast(self.io);
        for (self.pending.items) |p| if (p.id == id.integer) {
            p.response = payload;
            keep = true;
            return;
        };
        for (self.bindings.items) |b| if (b.sub_id == id.integer) {
            b.sub_id = null;
            self.subscribed(b, msg.get("result"));
            return;
        };
        // A subscription whose binding was unbound or resubscribed since.
        const result = msg.get("result") orelse return;
        if (result != .object) return;
        const stream = result.object.get("stream") orelse return;
        if (stream == .integer) _ = self.sendLocked("block.unsubscribe", .{ .stream = stream.integer }) catch {};
        return;
    }

    const event = msg.get("event") orelse return;
    if (event == .string and std.mem.eql(u8, event.string, "child_exited")) self.exited(msg);
    self.emit(payload);
}

/// The server answered a binding's `block.subscribe`.
fn subscribed(self: *Client, b: *Binding, result: ?std.json.Value) void {
    const r = result orelse {
        // Its block is gone.
        b.sink = null;
        return;
    };
    if (r != .object) return;
    const stream = r.object.get("stream") orelse return;
    const block = r.object.get("block") orelse return;
    if (stream != .integer or block != .string) return;
    const id = self.alloc.dupe(u8, block.string) catch return;
    self.alloc.free(b.block);
    b.block = id;
    b.stream = std.math.cast(u32, stream.integer);
}

/// Tell the terminals bound to an exited block.
fn exited(self: *Client, msg: std.json.ObjectMap) void {
    const block = msg.get("block") orelse return;
    const code = msg.get("exit_code") orelse return;
    if (block != .string or code != .integer) return;
    self.lock.lockUncancelable(self.io);
    self.feed_lock.lockUncancelable(self.io);
    defer self.feed_lock.unlock(self.io);
    var sinks: std.ArrayList(Feed.Sink) = .empty;
    defer sinks.deinit(self.alloc);
    for (self.bindings.items) |b| if (b.sink != null and std.mem.eql(u8, b.block, block.string))
        sinks.append(self.alloc, b.sink.?) catch {};
    self.lock.unlock(self.io);
    for (sinks.items) |s| s.exited(std.math.lossyCast(u32, code.integer));
}

/// Call the event callback with `json`.
fn emit(self: *Client, json: []const u8) void {
    self.lock.lockUncancelable(self.io);
    const cb = self.on_event;
    const ud = self.event_userdata;
    self.lock.unlock(self.io);
    const f = cb orelse return;
    const z = self.alloc.dupeSentinel(u8, json, 0) catch return;
    defer self.alloc.free(z);
    f(ud, z.ptr);
}

fn handleData(self: *Client, t: protocol.FrameType, payload: []const u8) void {
    if (payload.len < 4) return;
    const stream = std.mem.readInt(u32, payload[0..4], .little);
    self.lock.lockUncancelable(self.io);
    const b = for (self.bindings.items) |b| {
        if (b.stream == stream) break b;
    } else {
        // Unbound, or not yet bound again after a resync.
        self.lock.unlock(self.io);
        return;
    };
    const sink = b.sink.?;
    self.feed_lock.lockUncancelable(self.io);
    self.lock.unlock(self.io);
    const ok = if (b.feed.apply(self.alloc, t, payload, sink)) true else |err| ok: {
        log.warn("resyncing block {s} after {t}", .{ b.block, err });
        break :ok false;
    };
    if (ok and b.feed.loaded) b.resynced = false;
    self.feed_lock.unlock(self.io);
    if (ok) return;

    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    if (b.stream != stream) return;
    _ = self.sendLocked("block.unsubscribe", .{ .stream = stream }) catch {};
    if (b.resynced) {
        log.warn("unbinding block {s}, which fails to load", .{b.block});
        b.stream = null;
        b.sink = null;
        return;
    }
    // Start over from a snapshot.
    b.resynced = true;
    b.feed.loaded = false;
    self.subscribeLocked(b);
}

/// Reconnect after the connection dropped. False if the client is
/// closing instead.
fn reconnect(self: *Client) bool {
    {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        if (self.closing) return false;
        for (self.pending.items) |p| p.dropped = true;
        for (self.bindings.items) |b| {
            b.stream = null;
            b.sub_id = null;
        }
        self.cond.broadcast(self.io);
    }
    self.emit("{\"event\":\"server_disconnected\"}");

    // ponytail: retries forever without relaunching a server that died;
    // the app offers a restart for that (T10).
    var delay_ms: i64 = 10;
    while (true) {
        std.Io.sleep(self.io, .fromMilliseconds(delay_ms), .awake) catch {};
        delay_ms = @min(delay_ms * 2, 1000);
        const fd = protocol.connect(self.path) catch {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            if (self.closing) return false;
            continue;
        };
        noSigpipe(fd);

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.closing) {
            _ = c.close(fd);
            return false;
        }
        self.fd = fd;
        for (self.bindings.items) |b| if (b.sink != null) self.subscribeLocked(b);
        if (self.events_request) |json| renew: {
            var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, json, .{}) catch break :renew;
            defer parsed.deinit();
            const params = parsed.value.object.get("params") orelse .null;
            _ = self.sendLocked("session.subscribe", params) catch {};
        }
        break;
    }
    self.emit("{\"event\":\"server_reconnected\"}");
    return true;
}

/// Where the background server logs.
fn logPath(alloc: Allocator, env: *const EnvMap) !?[]u8 {
    const home = env.get("HOME") orelse return null;
    if (comptime builtin.os.tag.isDarwin())
        return try std.fmt.allocPrint(alloc, "{s}/Library/Logs/Raptor/server.log", .{home});
    if (env.get("XDG_STATE_HOME")) |dir| if (dir.len > 0)
        return try std.fmt.allocPrint(alloc, "{s}/raptor/server.log", .{dir});
    return try std.fmt.allocPrint(alloc, "{s}/.local/state/raptor/server.log", .{home});
}

/// Start `rap server run` in its own session with a minimal environment,
/// output going to the log, and wait for it to listen on `socket_path`.
pub fn launchServer(gpa: Allocator, io: std.Io, launch: Launch, socket_path: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const env = launch.env;
    const exe = try alloc.dupeSentinel(u8, launch.exe, 0);

    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ exe, "server", "run", "-S", try alloc.dupeSentinel(u8, socket_path, 0) });
    if (launch.idle_timeout) |t| try argv.appendSlice(alloc, &.{ "--idle-timeout", try alloc.dupeSentinel(u8, t, 0) });
    try argv.append(alloc, null);

    var envp: std.ArrayList(?[*:0]const u8) = .empty;
    for (protocol.daemon_env) |k| if (env.get(k)) |v|
        try envp.append(alloc, try std.fmt.allocPrintSentinel(alloc, "{s}={s}", .{ k, v }, 0));
    try envp.append(alloc, null);

    const log_fd: c_int = log: {
        const path = try logPath(alloc, env) orelse break :log -1;
        std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?) catch {};
        const pathz = try alloc.dupeSentinel(u8, path, 0);
        break :log c.open(pathz, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    };
    const home: ?[:0]u8 = if (env.get("HOME")) |h| try alloc.dupeSentinel(u8, h, 0) else null;

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.setsid();
        const devnull = c.open("/dev/null", .{ .ACCMODE = .RDWR });
        _ = c.dup2(devnull, 0);
        _ = c.dup2(if (log_fd >= 0) log_fd else devnull, 1);
        _ = c.dup2(if (log_fd >= 0) log_fd else devnull, 2);
        if (home) |h| _ = c.chdir(h);
        _ = c.execve(exe, @ptrCast(argv.items.ptr), @ptrCast(envp.items.ptr));
        c._exit(127);
    }
    if (log_fd >= 0) _ = c.close(log_fd);

    // A cold start of a debug build takes a moment.
    for (0..200) |_| {
        if (protocol.connect(socket_path)) |fd| {
            _ = c.close(fd);
            // Reap it when it exits, since this process may outlive it.
            if (std.Thread.spawn(.{}, reap, .{pid})) |t| t.detach() else |_| {}
            return;
        } else |_| {}
        var status: c_int = 0;
        if (c.waitpid(pid, &status, c.W.NOHANG) == pid) {
            // It lost a race with another server starting on this socket.
            if (protocol.connect(socket_path)) |fd| {
                _ = c.close(fd);
                return;
            } else |_| return error.ServerFailedToStart;
        }
        try std.Io.sleep(io, .fromMilliseconds(25), .awake);
    }
    return error.ServerStartTimedOut;
}

fn reap(pid: c.pid_t) void {
    var status: c_int = 0;
    while (c.waitpid(pid, &status, 0) < 0 and posix.errno(-1) == .INTR) {}
}
