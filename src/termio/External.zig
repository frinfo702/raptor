//! A termio backend for a terminal whose program runs somewhere else,
//! such as in a rap server. It starts no process: the embedder feeds the
//! program's output to `Termio.processOutput` (or a snapshot to
//! `loadSnapshot`), and the backend hands the user's input, the view's
//! size, and focus changes to the embedder's callbacks.
//!
//! The remote side answers the program's queries, so the stream handler
//! drops this terminal's own replies, and the terminal only resizes when
//! the remote side says it did (`setGrid`). Whoever feeds it may be a
//! thread the app waits on, so it never waits for the app's mailbox:
//! messages that don't fit wait in `Pending` for the app's next tick.
//!
//! The callbacks run on the termio thread.
const External = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const restore = @import("../rex/restore.zig");
const Feed = @import("../rex/Feed.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const App = @import("../App.zig");
const apprt = @import("../apprt.zig");

const log = std.log.scoped(.io_external);

/// Bytes for the program: keys, text, mouse and focus reports.
pub const WriteFn = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void;

/// The view now fits this grid. The terminal keeps its size until
/// `setGrid`.
pub const ResizeFn = *const fn (?*anyopaque, u16, u16, u32, u32) callconv(.c) void;

/// The view gained (true) or lost focus.
pub const FocusFn = *const fn (?*anyopaque, bool) callconv(.c) void;

userdata: ?*anyopaque = null,
write_cb: ?WriteFn = null,
resize_cb: ?ResizeFn = null,
focus_cb: ?FocusFn = null,

pub fn deinit(self: *External) void {
    _ = self;
}

pub fn initTerminal(self: *External, t: *terminal.Terminal) void {
    _ = self;
    _ = t;
}

pub fn threadEnter(
    self: *External,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;
    td.backend = .{ .external = .{} };
}

pub fn threadExit(self: *External, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

pub fn focusGained(
    self: *External,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = td;
    if (self.focus_cb) |cb| cb(self.userdata, focused);
}

pub fn resize(
    self: *External,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    if (self.resize_cb) |cb| cb(
        self.userdata,
        grid_size.columns,
        grid_size.rows,
        screen_size.width,
        screen_size.height,
    );
}

// ponytail: linefeed mode (LNM) isn't applied; the remote side gets the
// bytes as typed.
pub fn queueWrite(
    self: *External,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    _ = td;
    _ = linefeed;
    if (self.write_cb) |cb| cb(self.userdata, data.ptr, data.len);
}

pub fn getProcessInfo(self: *External, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

/// Replace the terminal with one decoded from a snapshot, keeping this
/// surface's configured colors and image limits. Output that follows
/// the snapshot goes to `Termio.processOutput` as usual.
pub fn loadSnapshot(io: *termio.Termio, bytes: []const u8) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    var decoded = try restore.decode(io.alloc, global.io(), &reader);
    defer decoded.deinit(io.alloc);

    io.renderer_state.mutex.lockUncancelable(global.io());
    defer io.renderer_state.mutex.unlock(global.io());

    // The stream handler and the renderer point at the field, so the
    // new terminal goes in its place.
    var old = io.terminal;
    io.terminal = decoded.toOwned();
    old.deinit(io.alloc);

    const t = &io.terminal;
    t.colors.palette.changeDefault(io.alloc, io.config.palette) catch
        t.colors.palette.resetDefault(io.alloc);
    t.colors.background.default = io.config.background.toTerminalRGB();
    t.colors.foreground.default = io.config.foreground.toTerminalRGB();
    t.colors.cursor.default = cursor: {
        const color = io.config.cursor_color orelse break :cursor null;
        break :cursor color.toTerminalRGB() orelse break :cursor null;
    };
    t.setKittyGraphicsSizeLimit(io.alloc, io.config.image_storage_limit);
    t.setKittyGraphicsLoadingLimits(.allWithTempDir(global.tmpDirPath()));
    t.width_px = t.cols * io.size.cell.width;
    t.height_px = t.rows * io.size.cell.height;
    // Page serials restart in a new terminal, so the renderer can't tell
    // its rows apart from the old ones.
    t.flags.dirty.clear = true;
    t.flags.dirty.palette = true;

    // Resume parsing where the snapshot left off.
    const stream = &io.terminal_stream;
    stream.parser.deinit();
    stream.parser = .init();
    stream.parser.osc_parser.alloc = io.alloc;
    stream.utf8decoder = .{};
    switch (decoded.continuation) {
        .ground => {},
        .bytes => |b| stream.nextSlice(b),
    }
    try stream.handler.queueRender();
}

/// The remote terminal is now this size, at this point in its output.
pub fn setGrid(io: *termio.Termio, cols: u16, rows: u16) !void {
    {
        io.renderer_state.mutex.lockUncancelable(global.io());
        defer io.renderer_state.mutex.unlock(global.io());
        try io.terminal.resize(io.alloc, .{
            .cols = cols,
            .rows = rows,
            .cell_size_px = .{
                .width = io.size.cell.width,
                .height = io.size.cell.height,
            },
        });
    }
    try io.renderer_wakeup.notify();
}

/// Messages for the surface that the app's mailbox had no room for. They
/// wait here, in order, until the app's tick moves them (`flushPending`).
pub const Pending = struct {
    lock: std.Io.Mutex = .init,
    msgs: std.ArrayList(apprt.surface.Message) = .empty,

    pub fn deinit(self: *Pending, alloc: Allocator) void {
        for (self.msgs.items) |m| m.deinit();
        self.msgs.deinit(alloc);
    }

    /// Send `msg` after any messages still waiting, without waiting for
    /// the app.
    pub fn push(self: *Pending, alloc: Allocator, mailbox: apprt.surface.Mailbox, msg: apprt.surface.Message) void {
        self.lock.lockUncancelable(global.io());
        defer self.lock.unlock(global.io());
        if (self.msgs.items.len == 0 and mailbox.push(msg, .{ .instant = {} }) != 0) return;
        for (self.msgs.items, 0..) |m, i| if (supersedes(msg, m)) {
            self.msgs.orderedRemove(i).deinit();
            break;
        };
        // ponytail: past `cap` waiting messages the oldest go, which can
        // lose a clipboard request or a color; raise it if that matters.
        if (self.msgs.items.len >= cap) for (self.msgs.items, 0..) |m, i| if (m != .child_exited) {
            self.msgs.orderedRemove(i).deinit();
            break;
        };
        self.msgs.append(alloc, msg) catch {
            log.warn("out of memory, dropping surface message {t}", .{msg});
            return msg.deinit();
        };
        mailbox.app.rt_app.wakeup();
    }

    pub const cap = 256;

    /// Whether `new` makes `old` pointless to deliver: only the latest
    /// state of a kind (per color or clipboard) matters.
    fn supersedes(new: apprt.surface.Message, old: apprt.surface.Message) bool {
        return switch (new) {
            .set_title,
            .pwd_change,
            .ring_bell,
            .set_mouse_shape,
            .progress_report,
            .report_title,
            .resize_window,
            .clipboard_read,
            => std.meta.activeTag(old) == std.meta.activeTag(new),
            .start_command, .stop_command => old == .start_command or old == .stop_command,
            .color_change => |c| old == .color_change and std.meta.eql(old.color_change.target, c.target),
            .clipboard_write => |w| old == .clipboard_write and old.clipboard_write.clipboard_type == w.clipboard_type,
            .kitty_clipboard_read => |r| old == .kitty_clipboard_read and old.kitty_clipboard_read.location == r.location,
            .kitty_clipboard_write => |w| old == .kitty_clipboard_write and old.kitty_clipboard_write.location == w.location,
            else => false,
        };
    }

    /// Move waiting messages into the app's mailbox while it has room.
    fn flush(self: *Pending, mailbox: apprt.surface.Mailbox) void {
        self.lock.lockUncancelable(global.io());
        defer self.lock.unlock(global.io());
        var n: usize = 0;
        while (n < self.msgs.items.len and mailbox.push(self.msgs.items[n], .{ .instant = {} }) != 0) n += 1;
        self.msgs.replaceRangeAssumeCapacity(0, n, &.{});
    }
};

/// On the app's thread, each tick: move the surface's waiting messages
/// into the app's mailbox.
pub fn flushPending(io: *termio.Termio) void {
    const h = &io.terminal_stream.handler;
    if (h.surface_pending) |*p| p.flush(h.surface_mailbox);
}

/// The terminal as the target of a rap client's binding (rex/Client.zig),
/// which feeds it on its reader thread.
pub fn sink(io: *termio.Termio) Feed.Sink {
    return .{ .ctx = io, .vtable = &sink_vtable };
}

const sink_vtable: Feed.Sink.VTable = .{
    .load = struct {
        fn f(ctx: *anyopaque, bytes: []const u8) anyerror!void {
            return loadSnapshot(sinkTermio(ctx), bytes);
        }
    }.f,
    .output = struct {
        fn f(ctx: *anyopaque, bytes: []const u8) void {
            const io = sinkTermio(ctx);
            io.processOutput(bytes);
            io.renderer_state.yieldToDemand(global.io());
        }
    }.f,
    .grid = struct {
        fn f(ctx: *anyopaque, cols: u16, rows: u16) anyerror!void {
            return setGrid(sinkTermio(ctx), cols, rows);
        }
    }.f,
    .exited = struct {
        fn f(ctx: *anyopaque, code: u32) void {
            // As termio.Exec reports a local child's exit. The remote side
            // knows how long the program ran; never treat the exit as an
            // abnormal, too-quick one.
            const h = &sinkTermio(ctx).terminal_stream.handler;
            h.surface_pending.?.push(h.alloc, h.surface_mailbox, .{ .child_exited = .{
                .exit_code = code,
                .runtime_ms = std.math.maxInt(u64),
            } });
        }
    }.f,
};

fn sinkTermio(ctx: *anyopaque) *termio.Termio {
    return @ptrCast(@alignCast(ctx));
}

/// A Termio with this backend and its thread, set up the way CoreSurface
/// sets them up, without a renderer or an app. It records the callbacks.
pub const TestSurface = struct {
    const testing = std.testing;
    const configpkg = @import("../config.zig");
    const xev = global.xev;

    config: configpkg.Config,
    mutex: std.Io.Mutex = .init,
    renderer_state: renderer.State,
    renderer_wakeup: xev.Async,
    renderer_mailbox: *renderer.Thread.Mailbox,
    /// The app's mailbox, which nothing drains but the test.
    app_mailbox: *App.Mailbox.Queue,
    io: termio.Termio,
    thread: termio.Thread,
    thr: std.Thread,

    /// Guards the fields below, which the termio thread writes.
    lock: std.Io.Mutex = .init,
    written: std.ArrayList(u8) = .empty,
    resizes: std.ArrayList([2]u16) = .empty,

    pub const size: renderer.Size = .{
        .screen = .{ .width = 800, .height = 480 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{},
    };

    pub fn init(self: *TestSurface) !void {
        try self.initWith(.{
            .userdata = self,
            .write_cb = onWrite,
            .resize_cb = onResize,
        });
    }

    /// Init with other callbacks, which leaves `written` and `resizes`
    /// empty.
    pub fn initWith(self: *TestSurface, backend: External) !void {
        const alloc = testing.allocator;
        self.* = .{
            .config = try .default(alloc),
            .renderer_state = undefined,
            .renderer_wakeup = try .init(),
            .renderer_mailbox = try .create(alloc),
            .app_mailbox = try .create(alloc),
            .io = undefined,
            .thread = try .init(alloc),
            .thr = undefined,
        };
        self.renderer_state = .{ .mutex = &self.mutex, .terminal = &self.io.terminal };
        try termio.Termio.init(&self.io, alloc, .{
            .size = size,
            .full_config = &self.config,
            .config = try .init(alloc, &self.config),
            .backend = .{ .external = backend },
            .mailbox = try .initSPSC(alloc),
            .renderer_state = &self.renderer_state,
            .renderer_wakeup = self.renderer_wakeup,
            .renderer_mailbox = self.renderer_mailbox,
            // Only a runtime with no app loop to wake takes an undefined
            // app.
            .surface_mailbox = .{ .surface = undefined, .app = .{ .rt_app = undefined, .mailbox = self.app_mailbox } },
        });
        self.thr = try .spawn(.{}, termio.Thread.threadMain, .{ &self.thread, &self.io });
    }

    pub fn deinit(self: *TestSurface) void {
        const alloc = testing.allocator;
        self.thread.stop.notify() catch unreachable;
        self.thr.join();
        self.thread.deinit();
        self.io.deinit();
        self.renderer_mailbox.destroy(alloc);
        self.app_mailbox.destroy(alloc);
        self.renderer_wakeup.deinit();
        self.config.deinit();
        self.written.deinit(alloc);
        self.resizes.deinit(alloc);
    }

    fn onWrite(ud: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
        const self: *TestSurface = @ptrCast(@alignCast(ud.?));
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        self.written.appendSlice(testing.allocator, ptr[0..len]) catch unreachable;
    }

    fn onResize(ud: ?*anyopaque, cols: u16, rows: u16, _: u32, _: u32) callconv(.c) void {
        const self: *TestSurface = @ptrCast(@alignCast(ud.?));
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        self.resizes.append(testing.allocator, .{ cols, rows }) catch unreachable;
    }

    /// Send the user's input the way CoreSurface does.
    pub fn write(self: *TestSurface, data: []const u8) !void {
        self.io.queueMessage(try termio.Message.writeReq(testing.allocator, data), .unlocked);
    }

    /// Wait until the termio thread has written `n` bytes, then return
    /// them all.
    fn waitWritten(self: *TestSurface, n: usize) ![]const u8 {
        for (0..500) |_| {
            {
                self.lock.lockUncancelable(testing.io);
                defer self.lock.unlock(testing.io);
                if (self.written.items.len >= n) return self.written.items;
            }
            try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
        }
        return error.Timeout;
    }

    pub fn plainAll(self: *TestSurface) ![]const u8 {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        return self.io.terminal.screens.active.dumpStringAlloc(testing.allocator, .{ .screen = .{} });
    }
};

test "rex external surface: processOutput changes the plain text" {
    var s: TestSurface = undefined;
    try s.init();
    defer s.deinit();

    s.io.processOutput("hello\r\nworld");
    const text = try s.plainAll();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello\nworld", text);
}

test "rex external surface: a key event reaches write_cb encoded" {
    const input = @import("../input.zig");
    var s: TestSurface = undefined;
    try s.init();
    defer s.deinit();

    // The program turns on application cursor keys, which changes how
    // the arrow keys encode.
    s.io.processOutput("\x1b[?1h");
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    {
        s.mutex.lockUncancelable(std.testing.io);
        defer s.mutex.unlock(std.testing.io);
        try input.key_encode.encode(&w, .{ .key = .arrow_up }, .fromTerminal(&s.io.terminal));
    }
    try s.write(w.buffered());
    try std.testing.expectEqualStrings("\x1bOA", try s.waitWritten(3));
}

test "rex external surface: the program's queries get no reply" {
    var s: TestSurface = undefined;
    try s.init();
    defer s.deinit();

    // Device attributes, cursor position, and a size report.
    s.io.processOutput("\x1b[c\x1b[6n\x1b[18t");
    // The termio thread handles messages in order, so once it has
    // written this, it would have written any reply.
    try s.write("x");
    try std.testing.expectEqualStrings("x", try s.waitWritten(1));
}

test "rex external surface: load_snapshot reproduces a 10k-line terminal" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s: TestSurface = undefined;
    try s.init();
    defer s.deinit();

    // Small enough a limit that both the lines before the snapshot and
    // the lines after it prune scrollback.
    var src: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 2 * 1000 * 1000,
    });
    defer src.deinit(alloc);
    var src_vt = src.vtStream();
    defer src_vt.deinit();
    var buf: [32]u8 = undefined;
    for (0..10_000) |i| src_vt.nextSlice(try std.fmt.bufPrint(&buf, "line {d}\r\n", .{i}));

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try terminal.snapshot.encode(alloc, &encoded.writer, &src, .{ .continuation = .ground });
    try loadSnapshot(&s.io, encoded.written());
    {
        const want = try src.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(want);
        const got = try s.plainAll();
        defer alloc.free(got);
        try testing.expect(!std.mem.startsWith(u8, want, "line 0\n"));
        try testing.expectEqualStrings(want, got);
    }

    for (10_000..14_000) |i| {
        const line = try std.fmt.bufPrint(&buf, "line {d}\r\n", .{i});
        src_vt.nextSlice(line);
        s.io.processOutput(line);
    }
    const want = try src.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(want);
    const got = try s.plainAll();
    defer alloc.free(got);
    try testing.expectEqualStrings(want, got);
}

test "rex external surface: a view resize waits for set_grid" {
    const testing = std.testing;
    var s: TestSurface = undefined;
    try s.init();
    defer s.deinit();
    try testing.expectEqual(80, s.io.terminal.cols);

    var bigger = TestSurface.size;
    bigger.screen.width = 1000;
    s.io.queueMessage(.{ .resize = bigger }, .unlocked);
    for (0..500) |_| {
        {
            s.lock.lockUncancelable(testing.io);
            defer s.lock.unlock(testing.io);
            if (s.resizes.items.len > 0) break;
        }
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    } else return error.Timeout;
    try testing.expectEqualSlices([2]u16, &.{.{ 100, 24 }}, s.resizes.items);
    try testing.expectEqual(80, s.io.terminal.cols);

    try setGrid(&s.io, 100, 24);
    try testing.expectEqual(100, s.io.terminal.cols);
}
