//! The buffers behind the server's data plane: each block's replay ring
//! and each client's outbound frame queue.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A block's latest output, so that a client that resubscribes soon after
/// losing its stream catches up without a snapshot. A block has one ring
/// shared by all its subscribers, and only while it has any.
pub const Ring = struct {
    pub const capacity = 16 * 1024;

    /// The byte at seq `s` is at `buf[s % capacity]`.
    buf: [capacity]u8 = undefined,
    /// The seq just past the newest byte.
    end: u64,
    /// How many of the newest bytes are kept.
    len: usize = 0,

    pub fn push(self: *Ring, data: []const u8) void {
        self.end += data.len;
        self.len = @min(capacity, self.len + data.len);
        const keep = data[data.len -| capacity..];
        const pos: usize = @intCast((self.end - keep.len) % capacity);
        const first = @min(keep.len, capacity - pos);
        @memcpy(self.buf[pos..][0..first], keep[0..first]);
        @memcpy(self.buf[0 .. keep.len - first], keep[first..]);
    }

    /// The output after `seq` through `end`, in two parts, or null if
    /// some of it is no longer kept.
    pub fn since(self: *const Ring, seq: u64) ?[2][]const u8 {
        if (seq > self.end or self.end - seq > self.len) return null;
        const n: usize = @intCast(self.end - seq);
        const start: usize = @intCast(seq % capacity);
        const first = @min(n, capacity - start);
        return .{ self.buf[start..][0..first], self.buf[0 .. n - first] };
    }
};

/// A client's outgoing frames, oldest first. Data frames count against
/// `cap`; the server stops queueing a stream's output when it would go
/// over and resends the stream as a snapshot instead. Snapshots don't
/// count, so that one larger than the cap still gets through.
pub const Outbox = struct {
    pub const cap = 1024 * 1024;

    frames: std.ArrayList(Frame) = .empty,
    head: usize = 0,
    /// Bytes of the oldest frame already written.
    sent: usize = 0,
    /// Queued bytes of every frame but snapshots.
    counted: usize = 0,

    pub const Kind = enum { control, data, snap };

    pub const Frame = struct {
        bytes: []u8,
        kind: Kind,
        /// The stream of a data or snap frame.
        stream: u32 = 0,
    };

    pub fn deinit(self: *Outbox, alloc: Allocator) void {
        for (self.frames.items[self.head..]) |f| alloc.free(f.bytes);
        self.frames.deinit(alloc);
    }

    pub fn isEmpty(self: *const Outbox) bool {
        return self.head == self.frames.items.len;
    }

    /// Queue a frame, taking ownership of its bytes even on failure.
    pub fn push(self: *Outbox, alloc: Allocator, f: Frame) Allocator.Error!void {
        errdefer alloc.free(f.bytes);
        try self.frames.append(alloc, f);
        if (f.kind != .snap) self.counted += f.bytes.len;
    }

    /// Whether `len` more data bytes fit under the cap.
    pub fn fits(self: *const Outbox, len: usize) bool {
        return self.counted + len <= cap;
    }

    /// The unwritten rest of the oldest frame.
    pub fn pending(self: *const Outbox) ?[]const u8 {
        if (self.isEmpty()) return null;
        return self.frames.items[self.head].bytes[self.sent..];
    }

    /// `n` bytes of `pending()` were written.
    pub fn consume(self: *Outbox, alloc: Allocator, n: usize) void {
        self.sent += n;
        const f = self.frames.items[self.head];
        if (self.sent < f.bytes.len) return;
        if (f.kind != .snap) self.counted -= f.bytes.len;
        alloc.free(f.bytes);
        self.sent = 0;
        self.head += 1;
        if (self.head == self.frames.items.len) {
            self.frames.clearRetainingCapacity();
            self.head = 0;
        } else if (self.head >= 32 and self.head * 2 >= self.frames.items.len) {
            self.frames.replaceRangeAssumeCapacity(0, self.head, &.{});
            self.head = 0;
        }
    }

    /// Drop the stream's queued data and snapshot frames. The oldest frame
    /// is kept whatever it is, since it may be partly written.
    pub fn dropStream(self: *Outbox, alloc: Allocator, stream: u32) void {
        if (self.isEmpty()) return;
        var w = self.head + 1;
        for (self.frames.items[self.head + 1 ..]) |f| {
            if (f.kind == .control or f.stream != stream) {
                self.frames.items[w] = f;
                w += 1;
                continue;
            }
            if (f.kind != .snap) self.counted -= f.bytes.len;
            alloc.free(f.bytes);
        }
        self.frames.items.len = w;
    }
};

test "rex dataplane: ring replays only what it still holds" {
    const testing = std.testing;
    var ring: Ring = .{ .end = 100 };
    try testing.expectEqualStrings("", ring.since(100).?[0]);
    try testing.expect(ring.since(99) == null);
    try testing.expect(ring.since(101) == null);

    ring.push("hello");
    const parts = ring.since(101).?;
    try testing.expectEqualStrings("ello", parts[0]);
    try testing.expectEqualStrings("", parts[1]);

    // Wrap around: the oldest bytes fall out.
    var big: [Ring.capacity]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast(i % 251);
    ring.push(&big);
    try testing.expect(ring.since(104) == null);
    const wrapped = ring.since(ring.end - Ring.capacity).?;
    try testing.expectEqual(Ring.capacity, wrapped[0].len + wrapped[1].len);
    try testing.expectEqual(big[0], wrapped[0][0]);
    try testing.expectEqual(big[big.len - 1], wrapped[1][wrapped[1].len - 1]);
}

test "rex dataplane: outbox drops a stream but keeps the frame being written" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var box: Outbox = .{};
    defer box.deinit(alloc);

    try box.push(alloc, .{ .bytes = try alloc.dupe(u8, "out1"), .kind = .data, .stream = 1 });
    try box.push(alloc, .{ .bytes = try alloc.dupe(u8, "json"), .kind = .control });
    try box.push(alloc, .{ .bytes = try alloc.dupe(u8, "out2"), .kind = .data, .stream = 1 });
    try box.push(alloc, .{ .bytes = try alloc.dupe(u8, "snap"), .kind = .snap, .stream = 1 });
    try box.push(alloc, .{ .bytes = try alloc.dupe(u8, "other"), .kind = .data, .stream = 2 });
    try testing.expectEqual(17, box.counted);

    box.consume(alloc, 2);
    box.dropStream(alloc, 1);
    try testing.expectEqual(13, box.counted);
    try testing.expectEqualStrings("t1", box.pending().?);
    box.consume(alloc, 2);
    try testing.expectEqualStrings("json", box.pending().?);
    box.consume(alloc, 4);
    try testing.expectEqualStrings("other", box.pending().?);
    box.consume(alloc, 5);
    try testing.expect(box.isEmpty());
    try testing.expectEqual(0, box.counted);
}
