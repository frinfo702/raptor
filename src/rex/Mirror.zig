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
const Feed = @import("Feed.zig");

alloc: Allocator,
io: std.Io,
/// Null until the first snapshot has loaded.
term: ?terminal.Terminal = null,
vt: terminal.TerminalStream = undefined,
/// The stream's position, for frames applied with `apply`.
feed: Feed = .{},

pub const Error = Feed.Error || terminal.snapshot.DecodeError || terminal.Terminal.ResizeError;

pub fn init(alloc: Allocator, io: std.Io) Mirror {
    return .{ .alloc = alloc, .io = io };
}

pub fn deinit(self: *Mirror) void {
    self.unload();
    self.feed.deinit(self.alloc);
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
    return self.feed.apply(self.alloc, t, payload, self);
}

/// Replace the terminal with a snapshot's.
pub fn load(self: *Mirror, bytes: []const u8) Error!void {
    var reader: std.Io.Reader = .fixed(bytes);
    var decoded = try restore.decode(self.alloc, self.io, &reader);
    defer decoded.deinit(self.alloc);
    self.unload();
    self.term = decoded.toOwned();
    self.vt = .init(.{ .allocator = self.alloc, .handler = self.term.?.vtHandler() });
    switch (decoded.continuation) {
        .ground => {},
        .bytes => |b| self.vt.nextSlice(b),
    }
}

/// The program's output, after a snapshot has loaded.
pub fn output(self: *Mirror, bytes: []const u8) void {
    self.vt.nextSlice(bytes);
}

/// The server resized the terminal, after a snapshot has loaded.
pub fn grid(self: *Mirror, cols: u16, rows: u16) Error!void {
    try self.term.?.resize(self.alloc, .{ .cols = cols, .rows = rows });
}

/// The mirror as a client's binding target.
pub fn sink(self: *Mirror) Feed.Sink {
    return .{ .ctx = self, .vtable = &sink_vtable };
}

const sink_vtable: Feed.Sink.VTable = .{
    .load = struct {
        fn f(ctx: *anyopaque, bytes: []const u8) anyerror!void {
            return fromCtx(ctx).load(bytes);
        }
    }.f,
    .output = struct {
        fn f(ctx: *anyopaque, bytes: []const u8) void {
            fromCtx(ctx).output(bytes);
        }
    }.f,
    .grid = struct {
        fn f(ctx: *anyopaque, cols: u16, rows: u16) anyerror!void {
            return fromCtx(ctx).grid(cols, rows);
        }
    }.f,
    .exited = struct {
        fn f(_: *anyopaque, _: u32) void {}
    }.f,
};

fn fromCtx(ctx: *anyopaque) *Mirror {
    return @ptrCast(@alignCast(ctx));
}

/// The screen and its scrollback as plain text, like the server's
/// `format` method with `"scope":"all"`. The caller owns the result.
pub fn plainAll(self: *const Mirror, alloc: Allocator) ![]const u8 {
    return self.term.?.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
}
