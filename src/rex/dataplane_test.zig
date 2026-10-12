//! Integration tests of the data plane: a real server on a private socket
//! and headless clients that mirror its blocks.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const testing = std.testing;
const Mirror = @import("Mirror.zig");
const Server = @import("Server.zig");
const protocol = @import("protocol.zig");

const alloc = testing.allocator;

/// A server running on its own thread.
pub const Harness = struct {
    path: [:0]u8,
    server: *Server,
    thread: std.Thread,
    env: std.process.Environ.Map,

    var count: usize = 0;

    pub fn start(self: *Harness) !void {
        // A client that goes away mid-write must not kill the test.
        var act: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
        posix.sigaction(.PIPE, &act, null);

        count += 1;
        // Directly in /tmp: sun_path is short.
        self.path = try std.fmt.allocPrintSentinel(alloc, "/tmp/rex-dp-{d}-{d}.sock", .{ c.getpid(), count }, 0);
        errdefer alloc.free(self.path);
        self.env = .init(alloc);
        errdefer self.env.deinit();
        try self.env.put("PATH", "/usr/bin:/bin");
        self.server = try Server.create(alloc, testing.io, .{ .socket_path = self.path, .env = &self.env });
        self.thread = try std.Thread.spawn(.{}, (struct {
            fn run(srv: *Server) void {
                srv.run() catch |err| std.debug.panic("server failed: {t}", .{err});
            }
        }).run, .{self.server});
    }

    pub fn stop(self: *Harness) void {
        if (Conn.open(self.path)) |conn_| {
            var conn = conn_;
            defer conn.close();
            if (conn.call("server.stop", .{})) |r| r.deinit() else |_| {}
        } else |_| {}
        self.thread.join();
        self.server.destroy();
        const lock = std.fmt.allocPrintSentinel(alloc, "{s}.lock", .{self.path}, 0) catch unreachable;
        defer alloc.free(lock);
        _ = c.unlink(lock);
        alloc.free(self.path);
        self.env.deinit();
    }
};

/// A client connection. Data frames it reads go to the mirror of their
/// stream.
const Conn = struct {
    fd: posix.fd_t,
    next_id: i64 = 1,
    mirrors: std.ArrayList(struct { stream: u32, mirror: *Mirror }) = .empty,
    /// The type of every data frame read, in order.
    seen: std.ArrayList(protocol.FrameType) = .empty,
    /// The newest `out` frame's bytes.
    last_out: std.ArrayList(u8) = .empty,

    fn open(path: []const u8) !Conn {
        const fd = try protocol.connect(path);
        // Fail rather than hang if the server never sends what we wait for.
        const tv: posix.timeval = .{ .sec = 10, .usec = 0 };
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVTIMEO, &tv, @sizeOf(posix.timeval));
        return .{ .fd = fd };
    }

    fn close(self: *Conn) void {
        _ = c.close(self.fd);
        self.mirrors.deinit(alloc);
        self.seen.deinit(alloc);
        self.last_out.deinit(alloc);
    }

    /// Read one frame. JSON frames are returned for the caller to free.
    fn readOne(self: *Conn) !?[]u8 {
        const frame = try protocol.readFrame(alloc, self.fd);
        if (frame.type == .json) return frame.payload;
        defer alloc.free(frame.payload);
        try self.seen.append(alloc, frame.type);
        const stream = std.mem.readInt(u32, frame.payload[0..4], .little);
        for (self.mirrors.items) |m| if (m.stream == stream) {
            if (frame.type == .out) {
                self.last_out.clearRetainingCapacity();
                try self.last_out.appendSlice(alloc, frame.payload[12..]);
            }
            try m.mirror.apply(frame.type, frame.payload);
            return null;
        };
        return error.UnknownStream;
    }

    /// Call a method and return its result, reading data frames meanwhile.
    fn call(self: *Conn, method: []const u8, params: anytype) !std.json.Parsed(std.json.Value) {
        const id = self.next_id;
        self.next_id += 1;
        var req: std.Io.Writer.Allocating = .init(alloc);
        defer req.deinit();
        try req.writer.print("{f}", .{std.json.fmt(.{ .id = id, .method = method, .params = params }, .{})});
        try protocol.writeFrame(self.fd, .json, req.written());

        var prefix_buf: [32]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buf, "{{\"id\":{d},", .{id});
        while (true) {
            const payload = try self.readOne() orelse continue;
            defer alloc.free(payload);
            if (!std.mem.startsWith(u8, payload, prefix)) continue;
            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
            if (parsed.value.object.get("error")) |e| {
                std.debug.print("{s} failed: {f}\n", .{ method, std.json.fmt(e, .{}) });
                parsed.deinit();
                return error.RequestFailed;
            }
            return parsed;
        }
    }

    /// Subscribe `m` to the block and return the stream id.
    fn subscribe(self: *Conn, m: *Mirror, block: []const u8, since: ?u64) !u32 {
        const r = if (since) |s|
            try self.call("block.subscribe", .{ .block = block, .since_seq = s })
        else
            try self.call("block.subscribe", .{ .block = block });
        defer r.deinit();
        const stream: u32 = @intCast(result(r).object.get("stream").?.integer);
        try self.mirrors.append(alloc, .{ .stream = stream, .mirror = m });
        return stream;
    }

    fn send(self: *Conn, t: protocol.FrameType, fields: anytype, tail: []const u8) !void {
        const frame = try protocol.encodeData(alloc, t, fields, tail);
        defer alloc.free(frame);
        try protocol.writeAll(self.fd, frame);
    }

    /// Read until the mirror has applied the block's output through `seq`.
    fn syncTo(self: *Conn, m: *const Mirror, seq: u64) !void {
        while (m.term == null or m.feed.seq < seq) if (try self.readOne()) |p| alloc.free(p);
        try testing.expectEqual(seq, m.feed.seq);
    }
};

fn result(r: std.json.Parsed(std.json.Value)) std.json.Value {
    return r.value.object.get("result").?;
}

/// The server's text and seq of the block, all of it or the visible part.
fn format(conn: *Conn, block: []const u8, all: bool) !struct { text: []u8, seq: u64 } {
    const r = try conn.call("block.method", .{ .block = block, .method = "format", .scope = if (all) "all" else "viewport" });
    defer r.deinit();
    const res = result(r).object;
    return .{
        .text = try alloc.dupe(u8, res.get("text").?.string),
        .seq = @intCast(res.get("seq").?.integer),
    };
}

/// Poll until the visible screen shows `needle` and return the seq.
fn waitText(conn: *Conn, block: []const u8, needle: []const u8) !u64 {
    for (0..1000) |_| {
        const f = try format(conn, block, false);
        defer alloc.free(f.text);
        if (std.mem.indexOf(u8, f.text, needle) != null) return f.seq;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
    return error.Timeout;
}

/// Expect every mirror to hold exactly the server's text at the same seq.
fn expectMirrors(conn: *Conn, block: []const u8, mirrors: []const *Mirror) !void {
    const f = try format(conn, block, true);
    defer alloc.free(f.text);
    for (mirrors) |m| {
        try testing.expectEqual(f.seq, m.feed.seq);
        const text = try m.plainAll(alloc);
        defer alloc.free(text);
        try testing.expectEqualStrings(f.text, text);
    }
}

fn createSession(conn: *Conn, script: []const u8) ![]u8 {
    const r = try conn.call("session.create", .{
        .label = "dp",
        .cols = 80,
        .rows = 24,
        .command = [_][]const u8{ "/bin/sh", "-c", script },
    });
    defer r.deinit();
    return alloc.dupe(u8, result(r).object.get("block").?.string);
}

fn countSnaps(conn: *const Conn) usize {
    return std.mem.count(protocol.FrameType, conn.seen.items, &.{.snap});
}

test "rex data plane: mirrors, reconnect, reset, and owner resize" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    var a = try Conn.open(h.path);
    var a_open = true;
    defer if (a_open) a.close();
    // 70-column lines, so that narrowing the grid reflows every one.
    const line = "the quick brown fox jumps over the lazy dog and keeps on running";
    const block = try createSession(&a, "read x; " ++
        "awk 'BEGIN{for(i=1;i<=5000;i++) printf \"%05d " ++ line ++ "\\n\", i}'; read x; " ++
        "awk 'BEGIN{for(i=5001;i<=10000;i++) printf \"%05d " ++ line ++ "\\n\", i}'; exec cat");
    defer alloc.free(block);

    // A subscribes before any output, B halfway through it.
    var ma: Mirror = .init(alloc, testing.io);
    defer ma.deinit();
    const sa = try a.subscribe(&ma, block, null);
    try a.send(.in, protocol.In{ .stream = sa }, "go\n");
    try a.syncTo(&ma, try waitText(&a, block, "05000 the quick"));

    var b = try Conn.open(h.path);
    defer b.close();
    var mb: Mirror = .init(alloc, testing.io);
    defer mb.deinit();
    const sb = try b.subscribe(&mb, block, null);
    try b.syncTo(&mb, ma.feed.seq);
    try testing.expect(mb.feed.seq > 5000 * line.len);

    try a.send(.in, protocol.In{ .stream = sa }, "go\n");
    const done = try waitText(&a, block, "10000 the quick");
    try a.syncTo(&ma, done);
    try b.syncTo(&mb, done);
    try expectMirrors(&a, block, &.{ &ma, &mb });
    const all = try ma.plainAll(alloc);
    defer alloc.free(all);
    try testing.expect(std.mem.count(u8, all, "\n") >= 10_000);
    try testing.expectEqual(1, ma.feed.snapshots);
    try testing.expectEqual(1, mb.feed.snapshots);

    // A drops its connection and comes back while the output it missed
    // is still in the ring: it gets only that output, no snapshot.
    a.close();
    a_open = false;
    try b.send(.in, protocol.In{ .stream = sb }, "hello\n");
    const echoed = try waitText(&b, block, "hello\nhello");
    var a2 = try Conn.open(h.path);
    defer a2.close();
    const sa2 = try a2.subscribe(&ma, block, ma.feed.seq);
    try a2.syncTo(&ma, echoed);
    try b.syncTo(&mb, echoed);
    try testing.expect(a2.seen.items.len > 0);
    try testing.expectEqual(0, countSnaps(&a2));
    try testing.expectEqual(1, ma.feed.snapshots);
    try expectMirrors(&a2, block, &.{ &ma, &mb });

    // A reset resends every stream as a snapshot.
    (try a2.call("block.method", .{ .block = block, .method = "reset" })).deinit();
    while (ma.feed.snapshots < 2) if (try a2.readOne()) |p| alloc.free(p);
    while (mb.feed.snapshots < 2) if (try b.readOne()) |p| alloc.free(p);
    try expectMirrors(&a2, block, &.{ &ma, &mb });

    // B sent input last, so it owns the size and A's request waits until
    // A focuses the block.
    try a2.send(.size, protocol.Size{ .stream = sa2, .cols = 50, .rows = 30, .cell_w_px = 8, .cell_h_px = 16 }, "");
    {
        const r = try a2.call("block.method", .{ .block = block, .method = "size" });
        defer r.deinit();
        try testing.expectEqual(80, result(r).object.get("cols").?.integer);
    }
    const rows_before = ma.term.?.screens.active.pages.total_rows;
    try a2.send(.focus, protocol.Focus{ .stream = sa2, .focused = 1 }, "");
    while (ma.term.?.cols != 50) if (try a2.readOne()) |p| alloc.free(p);
    while (mb.term.?.cols != 50) if (try b.readOne()) |p| alloc.free(p);
    try testing.expectEqual(protocol.FrameType.grid, b.seen.items[b.seen.items.len - 1]);
    try testing.expectEqual(30, mb.term.?.rows);
    try expectMirrors(&a2, block, &.{ &ma, &mb });
    // The 70-column lines now wrap.
    try testing.expect(ma.term.?.screens.active.pages.total_rows != rows_before);
}

test "rex data plane: a stalled client neither delays others nor stays stale" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    var a = try Conn.open(h.path);
    defer a.close();
    // Several times the 1 MiB outbox cap, in enough lines to prune
    // scrollback long after A's snapshot, which comes before the output.
    const block = try createSession(&a,
        \\read x; yes 'output that a stalled client cannot keep up with' | head -n 80000; echo done; exec cat
    );
    defer alloc.free(block);

    // B takes its first snapshot, then stops reading.
    var b = try Conn.open(h.path);
    defer b.close();
    var mb: Mirror = .init(alloc, testing.io);
    defer mb.deinit();
    _ = try b.subscribe(&mb, block, null);
    while (mb.term == null) if (try b.readOne()) |p| alloc.free(p);

    var ma: Mirror = .init(alloc, testing.io);
    defer ma.deinit();
    const sa = try a.subscribe(&ma, block, null);
    try a.send(.in, protocol.In{ .stream = sa }, "go\n");
    try a.syncTo(&ma, try waitText(&a, block, "done"));

    // With B still not reading, A's input echoes back promptly.
    for (0..5) |_| {
        const start = std.Io.Clock.awake.now(testing.io).toMilliseconds();
        try a.send(.in, protocol.In{ .stream = sa }, "ping\n");
        while (std.mem.indexOf(u8, a.last_out.items, "ping") == null) if (try a.readOne()) |p| alloc.free(p);
        a.last_out.clearRetainingCapacity();
        const elapsed = std.Io.Clock.awake.now(testing.io).toMilliseconds() - start;
        try testing.expect(elapsed < 50);
    }
    // The loop above stops at the tty echo; wait for cat's copies too.
    const seq = try waitText(&a, block, "ping\nping\nping\nping\nping\nping\nping\nping\nping\nping");
    try a.syncTo(&ma, seq);

    // B catches up from a fresh snapshot once it reads again.
    while (mb.feed.snapshots < 2) if (try b.readOne()) |p| alloc.free(p);
    try b.syncTo(&mb, seq);
    try expectMirrors(&a, block, &.{ &ma, &mb });
}
