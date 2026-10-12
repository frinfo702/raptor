//! A client's copy of one block's terminal, kept in sync from its data
//! stream: a snapshot replaces it, `out` bytes feed it, and a `grid`
//! marker resizes it at the same point in the output as the server did.
//!
//! The mirror never answers the program's queries; the server does.
//! It must not move once it has loaded a snapshot.
const Mirror = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const restore = @import("restore.zig");
const protocol = @import("protocol.zig");

alloc: Allocator,
io: std.Io,
/// Null until the first snapshot has loaded.
term: ?terminal.Terminal = null,
vt: terminal.TerminalStream = undefined,
/// How much of the block's output this mirror has applied.
seq: u64 = 0,
/// A snapshot whose last chunk hasn't arrived.
snap: std.ArrayList(u8) = .empty,
/// Snapshots loaded so far.
snapshots: usize = 0,

pub const Error = error{
    /// A frame doesn't continue from `seq`, or came before any snapshot.
    OutOfSync,
    BadFrame,
} || terminal.snapshot.DecodeError || terminal.Terminal.ResizeError || Allocator.Error;

pub fn init(alloc: Allocator, io: std.Io) Mirror {
    return .{ .alloc = alloc, .io = io };
}

pub fn deinit(self: *Mirror) void {
    self.unload();
    self.snap.deinit(self.alloc);
}

fn unload(self: *Mirror) void {
    if (self.term) |*t| {
        self.vt.deinit();
        t.deinit(self.alloc);
        self.term = null;
    }
}

/// Apply a `snap`, `out` or `grid` frame of the mirror's stream.
pub fn apply(self: *Mirror, t: protocol.FrameType, payload: []const u8) Error!void {
    switch (t) {
        .snap => {
            const f, const bytes = protocol.decodeData(protocol.Snap, payload) orelse return error.BadFrame;
            if (f.flags.first) self.snap.clearRetainingCapacity();
            try self.snap.appendSlice(self.alloc, bytes);
            if (f.flags.last) try self.load(f.base_seq);
        },
        .out => {
            const f, const bytes = protocol.decodeData(protocol.Out, payload) orelse return error.BadFrame;
            if (self.term == null or f.seq != self.seq + bytes.len) return error.OutOfSync;
            self.vt.nextSlice(bytes);
            self.seq = f.seq;
        },
        .grid => {
            const f, _ = protocol.decodeData(protocol.Grid, payload) orelse return error.BadFrame;
            if (self.term == null or f.seq != self.seq) return error.OutOfSync;
            try self.term.?.resize(self.alloc, .{ .cols = f.cols, .rows = f.rows });
        },
        else => return error.BadFrame,
    }
}

fn load(self: *Mirror, base_seq: u64) Error!void {
    var reader: std.Io.Reader = .fixed(self.snap.items);
    var decoded = try restore.decode(self.alloc, self.io, &reader);
    defer decoded.deinit(self.alloc);
    self.unload();
    self.term = decoded.toOwned();
    self.vt = .init(.{ .allocator = self.alloc, .handler = self.term.?.vtHandler() });
    switch (decoded.continuation) {
        .ground => {},
        .bytes => |b| self.vt.nextSlice(b),
    }
    self.seq = base_seq;
    self.snapshots += 1;
    self.snap.clearRetainingCapacity();
}

/// The screen and its scrollback as plain text, like the server's
/// `format` method with `"scope":"all"`. The caller owns the result.
pub fn plainAll(self: *const Mirror, alloc: Allocator) ![]const u8 {
    return self.term.?.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
}
