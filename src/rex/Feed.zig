//! The client side of one block stream: it reassembles snapshot chunks,
//! checks that every frame continues from the last, and hands the result
//! to a target terminal. The target is any value with these methods:
//!
//! - `load(bytes) !void`: replace the terminal with a snapshot;
//! - `output(bytes) void`: the program's output;
//! - `grid(cols, rows) !void`: the server resized the terminal here.
const Feed = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");

/// How much of the block's output the target has applied.
seq: u64 = 0,
/// Whether a snapshot has loaded, so that output can apply.
loaded: bool = false,
/// A snapshot whose last chunk hasn't arrived.
snap: std.ArrayList(u8) = .empty,
/// Snapshots loaded so far.
snapshots: usize = 0,

/// A target behind a vtable, for a client that binds terminals of
/// different kinds.
pub const Sink = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (*anyopaque, []const u8) anyerror!void,
        output: *const fn (*anyopaque, []const u8) void,
        grid: *const fn (*anyopaque, u16, u16) anyerror!void,
        /// The block's program exited with this code.
        exited: *const fn (*anyopaque, u32) void,
    };

    pub fn load(self: Sink, bytes: []const u8) anyerror!void {
        return self.vtable.load(self.ctx, bytes);
    }

    pub fn output(self: Sink, bytes: []const u8) void {
        self.vtable.output(self.ctx, bytes);
    }

    pub fn grid(self: Sink, cols: u16, rows: u16) anyerror!void {
        return self.vtable.grid(self.ctx, cols, rows);
    }

    pub fn exited(self: Sink, code: u32) void {
        self.vtable.exited(self.ctx, code);
    }
};

pub const Error = error{
    /// A frame doesn't continue from `seq`, or came before any snapshot.
    OutOfSync,
    BadFrame,
} || Allocator.Error;

pub fn deinit(self: *Feed, alloc: Allocator) void {
    self.snap.deinit(alloc);
}

/// Apply a `snap`, `out` or `grid` frame of the stream to `target`.
pub fn apply(
    self: *Feed,
    alloc: Allocator,
    t: protocol.FrameType,
    payload: []const u8,
    target: anytype,
) !void {
    switch (t) {
        .snap => {
            const f, const bytes = protocol.decodeData(protocol.Snap, payload) orelse return error.BadFrame;
            if (f.flags.first) self.snap.clearRetainingCapacity();
            try self.snap.appendSlice(alloc, bytes);
            if (!f.flags.last) return;
            defer self.snap.clearRetainingCapacity();
            try target.load(self.snap.items);
            self.seq = f.base_seq;
            self.loaded = true;
            self.snapshots += 1;
        },
        .out => {
            const f, const bytes = protocol.decodeData(protocol.Out, payload) orelse return error.BadFrame;
            if (!self.loaded or f.seq != self.seq + bytes.len) return error.OutOfSync;
            target.output(bytes);
            self.seq = f.seq;
        },
        .grid => {
            const f, _ = protocol.decodeData(protocol.Grid, payload) orelse return error.BadFrame;
            if (!self.loaded or f.seq != self.seq) return error.OutOfSync;
            try target.grid(f.cols, f.rows);
        },
        else => return error.BadFrame,
    }
}
