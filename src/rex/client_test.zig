//! Tests of the client library against a real server on a private socket.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const testing = std.testing;
const Client = @import("Client.zig");
const Feed = @import("Feed.zig");
const Mirror = @import("Mirror.zig");
const Harness = @import("dataplane_test.zig").Harness;

const alloc = testing.allocator;

/// The events a client delivered, one JSON object per line.
const Events = struct {
    lock: std.Io.Mutex = .init,
    lines: std.ArrayList(u8) = .empty,

    fn deinit(self: *Events) void {
        self.lines.deinit(alloc);
    }

    fn on(ud: ?*anyopaque, json: [*:0]const u8) callconv(.c) void {
        const self: *Events = @ptrCast(@alignCast(ud.?));
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        self.lines.appendSlice(alloc, std.mem.span(json)) catch unreachable;
        self.lines.append(alloc, '\n') catch unreachable;
    }

    fn count(self: *Events, needle: []const u8) usize {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        return std.mem.count(u8, self.lines.items, needle);
    }

    /// Wait until `needle` has come `n` times.
    fn wait(self: *Events, needle: []const u8, n: usize) !void {
        for (0..1000) |_| {
            if (self.count(needle) >= n) return;
            try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
        }
        return error.Timeout;
    }
};

/// A mirror that also records its block's exit.
const TestSink = struct {
    mirror: Mirror,
    exit_code: std.atomic.Value(i64) = .init(-1),

    fn sink(self: *TestSink) Feed.Sink {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Feed.Sink.VTable = .{
        .load = struct {
            fn f(ctx: *anyopaque, bytes: []const u8) anyerror!void {
                return from(ctx).mirror.load(bytes);
            }
        }.f,
        .output = struct {
            fn f(ctx: *anyopaque, bytes: []const u8) void {
                from(ctx).mirror.output(bytes);
            }
        }.f,
        .grid = struct {
            fn f(ctx: *anyopaque, cols: u16, rows: u16) anyerror!void {
                return from(ctx).mirror.grid(cols, rows);
            }
        }.f,
        .exited = struct {
            fn f(ctx: *anyopaque, code: u32) void {
                from(ctx).exit_code.store(code, .release);
            }
        }.f,
    };

    fn from(ctx: *anyopaque) *TestSink {
        return @ptrCast(@alignCast(ctx));
    }
};

/// Make a request and return its result.
fn call(client: *Client, req: anytype) !std.json.Parsed(std.json.Value) {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try std.json.Stringify.value(req, .{}, &buf.writer);
    const resp = try client.request(buf.written());
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{ .allocate = .alloc_always });
    if (parsed.value.object.get("error")) |e| {
        std.debug.print("request failed: {f}\n", .{std.json.fmt(e, .{})});
        parsed.deinit();
        return error.RequestFailed;
    }
    return parsed;
}

fn result(r: std.json.Parsed(std.json.Value)) std.json.Value {
    return r.value.object.get("result").?;
}

/// Wait until the server's text has `needle` and the bound mirror holds
/// exactly that text, at the same seq.
fn waitSynced(client: *Client, b: *Client.Binding, m: *Mirror, needle: []const u8) !void {
    for (0..1000) |_| {
        const r = try call(client, .{
            .method = "block.method",
            .params = .{ .block = b.block, .method = "format", .scope = "all" },
        });
        defer r.deinit();
        const want = result(r).object.get("text").?.string;
        const seq: u64 = @intCast(result(r).object.get("seq").?.integer);

        const synced = synced: {
            client.feed_lock.lockUncancelable(testing.io);
            defer client.feed_lock.unlock(testing.io);
            if (std.mem.indexOf(u8, want, needle) == null or m.term == null or b.feed.seq != seq) break :synced false;
            const got = try m.plainAll(alloc);
            defer alloc.free(got);
            break :synced std.mem.eql(u8, want, got);
        };
        if (synced) return;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
    return error.Timeout;
}

fn waitBound(client: *Client, b: *Client.Binding) !void {
    for (0..1000) |_| {
        {
            client.lock.lockUncancelable(testing.io);
            defer client.lock.unlock(testing.io);
            if (b.stream != null) return;
        }
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
    return error.Timeout;
}

test "rex client: requests, events, and a bound block across a reconnect" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    var events: Events = .{};
    defer events.deinit();
    const client = try Client.connect(alloc, testing.io, h.path, null);
    defer client.deinit();
    client.setEventCallback(Events.on, &events);

    {
        const resp = try client.request("{\"method\":\"session.list\",\"params\":{}}");
        defer alloc.free(resp);
        try testing.expectEqualStrings("{\"id\":1,\"result\":{\"sessions\":[]}}", resp);
    }
    try testing.expectError(error.BadRequest, client.request("[]"));
    (try call(client, .{ .method = "session.subscribe", .params = .{} })).deinit();

    const block = block: {
        const r = try call(client, .{ .method = "session.create", .params = .{
            .label = "cl",
            .cols = 80,
            .rows = 24,
            .command = [_][]const u8{ "/bin/sh", "-c", "read x; awk 'BEGIN{for(i=1;i<=1000;i++) printf \"%05d line\\n\", i}'; exec cat" },
        } });
        defer r.deinit();
        break :block try alloc.dupe(u8, result(r).object.get("block").?.string);
    };
    defer alloc.free(block);
    try events.wait("\"session_created\"", 1);

    var ts: TestSink = .{ .mirror = .init(alloc, testing.io) };
    defer ts.mirror.deinit();
    const b = try client.newBinding();
    defer client.unbind(b);
    // By an id suffix, which the server answers with the full id. With the
    // dash, it never reads as a position.
    try client.bind(b, block[block.len - 13 ..], ts.sink());
    try testing.expectEqualStrings(block, b.block);

    // Input goes to the program as `in` frames.
    b.write("go\n");
    try waitSynced(client, b, &ts.mirror, "01000 line");
    try testing.expectEqual(1, b.feed.snapshots);

    // Drop the connection. The client resubscribes from where the mirror
    // left off, which the server replays without a snapshot, and renews
    // the event subscription.
    {
        client.lock.lockUncancelable(testing.io);
        defer client.lock.unlock(testing.io);
        _ = c.shutdown(client.fd, c.SHUT.RDWR);
    }
    try events.wait("\"server_reconnected\"", 1);
    try testing.expectEqual(1, events.count("\"server_disconnected\""));
    try waitBound(client, b);
    b.write("again\n");
    try waitSynced(client, b, &ts.mirror, "again\nagain");
    try testing.expectEqual(1, b.feed.snapshots);
    (try call(client, .{ .method = "session.set_label", .params = .{ .session = "cl", .label = "cl2" } })).deinit();
    try events.wait("\"session_label_changed\"", 1);

    // Having sent input, the client owns the size.
    b.resize(50, 30, 500, 600);
    for (0..1000) |_| {
        client.feed_lock.lockUncancelable(testing.io);
        const cols = ts.mirror.term.?.cols;
        client.feed_lock.unlock(testing.io);
        if (cols == 50) break;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    } else return error.Timeout;
    try testing.expectEqual(30, ts.mirror.term.?.rows);
    try waitSynced(client, b, &ts.mirror, "again\nagain");

    // The block's exit reaches its terminal.
    b.write("\x04");
    for (0..1000) |_| {
        if (ts.exit_code.load(.acquire) == 0) break;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    } else return error.Timeout;

    client.unbind(b);
    try testing.expectError(error.BindFailed, client.bind(b, "nope", ts.sink()));
}

test "rex client: RAP_AUTOSTART=0 never launches a server" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("RAP_AUTOSTART", "0");
    // Nothing listens here, and autostart is off.
    try testing.expectError(error.Unreachable, Client.connect(alloc, testing.io, "/tmp/rap-client-none.sock", .{
        .exe = "/nonexistent/rap",
        .env = &env,
    }));
}

test "rex client: binds an external-I/O surface" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const External = @import("../termio.zig").External;
    var h: Harness = undefined;
    try h.start();
    defer h.stop();
    const client = try Client.connect(alloc, testing.io, h.path, null);
    defer client.deinit();

    const block = block: {
        const r = try call(client, .{ .method = "session.create", .params = .{
            .cols = 80,
            .rows = 24,
            .command = [_][]const u8{ "/bin/sh", "-c", "read x; awk 'BEGIN{for(i=1;i<=1000;i++) printf \"%05d line\\n\", i}'; exec cat" },
        } });
        defer r.deinit();
        break :block try alloc.dupe(u8, result(r).object.get("block").?.string);
    };
    defer alloc.free(block);

    // The surface's input, size and focus go to the binding, and the
    // block's stream comes back into its termio.
    const b = try client.newBinding();
    var s: External.TestSurface = undefined;
    try s.initWith(.{
        .userdata = b,
        .write_cb = Client.Binding.onWrite,
        .resize_cb = Client.Binding.onResize,
        .focus_cb = Client.Binding.onFocus,
    });
    defer s.deinit();
    try client.bind(b, block, External.sink(&s.io));
    defer client.unbind(b);

    try s.write("go\n");
    for (0..1000) |_| {
        const r = try call(client, .{
            .method = "block.method",
            .params = .{ .block = block, .method = "format", .scope = "all" },
        });
        defer r.deinit();
        const want = result(r).object.get("text").?.string;
        const got = try s.plainAll();
        defer alloc.free(got);
        if (std.mem.indexOf(u8, want, "01000 line") != null and std.mem.eql(u8, want, got)) break;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    } else return error.Timeout;

    // A view resize is a size request; the terminal resizes when the
    // server's grid marker comes back.
    var bigger = External.TestSurface.size;
    bigger.screen.width = 1000;
    s.io.queueMessage(.{ .resize = bigger }, .unlocked);
    for (0..1000) |_| {
        s.mutex.lockUncancelable(testing.io);
        const cols = s.io.terminal.cols;
        s.mutex.unlock(testing.io);
        if (cols == 100) break;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    } else return error.Timeout;
}
