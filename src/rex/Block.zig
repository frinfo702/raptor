//! A Block is one terminal pane hosted by the rex server: a child process
//! attached to a pty, and the ghostty-vt Terminal that parses its output.
//!
//! Blocks never own a thread. Every block is driven by the one libxev loop
//! that owns the server, and all blocks on a loop share one read buffer.
//! The terminal answers queries (DA, DSR, ...) itself by writing back to the
//! pty, so replies happen even when no client is attached. Everything else
//! the program does that a client might show (title, bell, clipboard, ...)
//! is reported through `Options.on_event`.
const Block = @This();

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const global = @import("../global.zig");
const xev = global.xev;
const Command = @import("../Command.zig");
const Pty = @import("../pty.zig").Pty;
const terminal = @import("../terminal/main.zig");

const log = std.log.scoped(.rex_block);

/// The buffer every block on a loop reads its pty into. One read is at most
/// this large, so a busy block yields to the others after each read.
///
/// Sharing it is safe on kqueue because libxev only reports readiness
/// there and the block reads in its callback, right before it processes
/// the bytes.
// ponytail: other backends read into it before the callback, and io_uring
// even concurrently, so a Linux server needs a buffer per block.
pub const ReadBuffer = [64 * 1024]u8;

/// libxev's kqueue backend reports readiness without reading when given
/// an empty buffer. Only then may blocks share a `ReadBuffer`.
pub const kqueue = if (xev.dynamic) false else xev.backend == .kqueue;

/// The default scrollback limit, sized to hold at least 10,000 lines of
/// history at 80 columns. One 400 KiB page holds about 600 rows there, and
/// only whole pages are pruned. Wider terminals keep fewer lines.
pub const default_max_scrollback_bytes = 8 * 1000 * 1000;

/// The longest unfinished escape sequence a snapshot can carry over. While
/// the program is in the middle of a longer one, `snapshot` fails.
pub const max_continuation_bytes = 64 * 1024;

/// The owner must not run the loop with `.no_wait` while any write may be
/// in flight, including replies the terminal sends on its own (DA, DSR,
/// ...): libxev's kqueue backend drops the removal of a write finished in
/// that mode, and its next readiness event uses the freed write.
pub const Options = struct {
    /// The command to run. args[0] is the program and must be a path.
    args: []const [:0]const u8,

    /// The exact environment of the child. Null inherits ours.
    env: ?*const EnvMap = null,

    /// The working directory of the child. Null inherits ours.
    cwd: ?[:0]const u8 = null,

    cols: terminal.size.CellCountInt = 80,
    rows: terminal.size.CellCountInt = 24,

    /// Uncompressed bytes of scrollback to keep. Zero disables scrollback.
    max_scrollback_bytes: usize = default_max_scrollback_bytes,

    /// Receives every event. It runs on the loop thread and must not
    /// destroy the block.
    on_event: *const fn (*Block, Event) void,

    /// Stored on the block for `on_event` to use.
    userdata: ?*anyopaque = null,
};

/// Everything a block reports. Slices are only valid during the callback.
pub const Event = union(enum) {
    /// Bytes read from the pty, after the terminal has processed them.
    output: []const u8,

    /// A reply the terminal sent to the program (e.g. to a DA query).
    /// The block has already queued it to the pty.
    write_pty: []const u8,

    /// The new title, empty if the program cleared it.
    title_changed: []const u8,

    /// The new working directory (OSC 7), empty if cleared.
    pwd_changed: []const u8,

    bell,
    desktop_notification: terminal.StreamAction.ShowDesktopNotification,
    progress_report: terminal.osc.Command.ProgressReport,
    clipboard_write: terminal.clipboard.Write,
    program_status: terminal.osc.Command.ProgramStatus.Report,

    /// The child exited with this status. All output the child wrote
    /// before exiting has been reported first.
    child_exited: ChildExited,

    pub const ChildExited = struct {
        // ponytail: libxev reaps the child itself and reports 0 for a
        // child killed by a signal; report the signal when a client needs it.
        exit_code: u32,
    };
};

alloc: Allocator,
loop: *xev.Loop,
read_buf: *ReadBuffer,
on_event: *const fn (*Block, Event) void,
userdata: ?*anyopaque,

pty: Pty,
pty_stream: xev.Stream,
pid: posix.pid_t,
process: xev.Process,
term: terminal.Terminal,
vt: terminal.TerminalStream,
/// Bytes of output the terminal has processed. A client mirroring the
/// block counts the same bytes, so its terminal matches at equal seqs.
seq: u64 = 0,

/// Completions still registered with the loop. The block may be destroyed
/// only once this is zero.
pending: usize = 0,
exited: bool = false,
/// `kill()` was called before the child exited.
killed: bool = false,
/// The pty read is armed and counted in `pending`.
reading: bool = false,
/// `stopRead()` queued the cancel.
stop_requested: bool = false,

read_c: xev.Completion = .{},
cancel_c: xev.Completion = .{},
process_c: xev.Completion = .{},
write_queue: xev.WriteQueue = .{},

/// One queued pty write. libxev needs the request and the bytes to stay
/// put until the write completes, so each write gets its own allocation.
const Write = struct {
    block: *Block,
    req: xev.WriteRequest = undefined,
    data: []u8,
};

/// Start the command on a new pty and begin reading it on `loop`.
pub fn create(
    alloc: Allocator,
    loop: *xev.Loop,
    read_buf: *ReadBuffer,
    opts: Options,
) !*Block {
    const self = try alloc.create(Block);
    errdefer alloc.destroy(self);

    var term: terminal.Terminal = try .init(global.io(), alloc, .{
        .cols = opts.cols,
        .rows = opts.rows,
        .max_scrollback_bytes = opts.max_scrollback_bytes,
    });
    errdefer term.deinit(alloc);

    var pty = try Pty.open(.{ .ws_col = opts.cols, .ws_row = opts.rows });
    errdefer pty.deinit();
    // The child has its own copy of the slave. Ours must be closed so that
    // reads see the pty close once the child and its descendants exit.
    defer _ = posix.system.close(pty.slave);

    const slave: std.Io.File = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } };
    var cmd: Command = .{
        .path = opts.args[0],
        .args = opts.args,
        .env = opts.env,
        .cwd = opts.cwd,
        .stdin = slave,
        .stdout = slave,
        .stderr = slave,
        .os_pre_exec = childPreExec,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
        .data = &pty,
    };
    cmd.start(alloc) catch |err| {
        // We're the forked child and exec failed. Command already printed
        // why, and we must not return into the caller's copy of the server.
        if (err == error.ExecFailedInChild) posix.system.exit(1);
        return err;
    };

    // Blocks share one loop thread, so no pty syscall may block it.
    const fl = posix.system.fcntl(pty.master, posix.F.GETFL);
    _ = posix.system.fcntl(pty.master, posix.F.SETFL, fl | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));

    self.* = .{
        .alloc = alloc,
        .loop = loop,
        .read_buf = read_buf,
        .on_event = opts.on_event,
        .userdata = opts.userdata,
        .pty = pty,
        .pty_stream = .initFd(pty.master),
        .pid = cmd.pid.?,
        .process = undefined,
        .term = term,
        .vt = undefined,
    };

    // The handler points at the terminal, so it's built in place.
    var handler = self.term.vtHandler();
    handler.effects.write_pty = &writePty;
    handler.effects.bell = &bell;
    handler.effects.desktop_notification = &desktopNotification;
    handler.effects.device_attributes = &deviceAttributes;
    handler.effects.title_changed = &titleChanged;
    handler.effects.pwd_changed = &pwdChanged;
    handler.effects.progress_report = &progressReport;
    handler.effects.program_status = &programStatus;
    handler.effects.clipboard_write = &clipboardWrite;
    handler.effects.reset = &reset;
    self.vt = .init(.{
        .allocator = alloc,
        .handler = handler,
        .continuation_max_bytes = max_continuation_bytes,
    });
    errdefer self.vt.deinit();

    self.process = xev.Process.init(self.pid) catch |err| {
        posix.kill(-self.pid, .KILL) catch {};
        var status: if (builtin.link_libc) c_int else u32 = 0;
        _ = posix.system.waitpid(self.pid, &status, 0);
        return err;
    };
    self.process.wait(loop, &self.process_c, Block, self, onExit);
    const buf = if (comptime kqueue) read_buf[0..0] else read_buf;
    self.pty_stream.read(loop, &self.read_c, .{ .slice = buf }, Block, self, onRead);
    self.reading = true;
    self.pending = 2;

    return self;
}

/// Free the block. Nothing for it may be left on the loop, i.e. `isDone()`.
/// That happens once the child has exited and either every holder of the
/// pty slave has closed it or `kill()` stopped the read; call `kill()` and
/// run the loop to get there.
pub fn destroy(self: *Block) void {
    std.debug.assert(self.isDone());
    const alloc = self.alloc;
    self.process.deinit();
    self.vt.deinit();
    self.term.deinit(alloc);
    self.pty.deinit();
    alloc.destroy(self);
}

/// True once nothing for this block is left on the loop.
pub fn isDone(self: *const Block) bool {
    return self.pending == 0;
}

/// Close the pane: hang up the child's process group and stop reading the
/// pty, so a descendant that keeps the slave open can't keep the block
/// alive. The exit arrives later as `child_exited`.
pub fn kill(self: *Block) void {
    if (self.exited) return self.stopRead();
    // The child called setsid, so its process group id is its pid.
    posix.kill(-self.pid, .HUP) catch |err| log.warn("killing child failed err={}", .{err});
    // macOS doesn't finish a session leader's exit until its unread tty
    // output drains, so the read stops only once the exit arrives.
    self.killed = true;
}

/// Remove the read through the loop. The read is never disarmed from its
/// callback: libxev's kqueue backend can drop that removal under
/// `.no_wait`, leaving the pty registered.
fn stopRead(self: *Block) void {
    if (!self.reading or self.stop_requested) return;
    self.stop_requested = true;
    if (comptime xev.dynamic) switch (xev.backend) {
        inline else => |tag| {
            self.cancel_c.ensureTag(tag);
            self.cancelReadOn(
                (comptime xev.superset(tag)).Api(),
                &@field(self.loop.backend, @tagName(tag)),
                &@field(self.read_c.value, @tagName(tag)),
                &@field(self.cancel_c.value, @tagName(tag)),
            );
        },
    } else self.cancelReadOn(xev, self.loop, &self.read_c, &self.cancel_c);
    self.pending += 1;
}

/// libxev only offers cancellation on each backend's own types.
fn cancelReadOn(
    self: *Block,
    comptime api: type,
    loop: *api.Loop,
    read_c: *api.Completion,
    cancel_c: *api.Completion,
) void {
    cancel_c.* = .{
        .op = .{ .cancel = .{ .c = read_c } },
        .userdata = self,
        .callback = (struct {
            fn cb(ud: ?*anyopaque, _: *api.Loop, _: *api.Completion, _: api.Result) api.CallbackAction {
                const b: *Block = @ptrCast(@alignCast(ud.?));
                // io_uring always completes the canceled read itself, maybe
                // in a later batch. Elsewhere the read never calls onRead.
                if (xev.backend != .io_uring) b.endRead();
                b.pending -= 1;
                return .disarm;
            }
        }).cb,
    };
    loop.add(cancel_c);
}

/// Queue bytes to the program's input.
pub fn write(self: *Block, data: []const u8) Allocator.Error!void {
    if (data.len == 0) return;
    const w = try self.alloc.create(Write);
    errdefer self.alloc.destroy(w);
    w.* = .{ .block = self, .data = try self.alloc.dupe(u8, data) };
    self.pty_stream.queueWrite(
        self.loop,
        &self.write_queue,
        &w.req,
        .{ .slice = w.data },
        Write,
        w,
        onWrite,
    );
    self.pending += 1;
}

/// Run bytes through the terminal as if the program had written them.
pub fn processOutput(self: *Block, data: []const u8) void {
    self.vt.nextSlice(data);
    self.seq += data.len;
    self.emit(.{ .output = data });
}

/// Resize the terminal and tell the program. Zero cell sizes leave the
/// pixel size unknown.
pub fn resize(
    self: *Block,
    cols: terminal.size.CellCountInt,
    rows: terminal.size.CellCountInt,
    cell_w_px: u16,
    cell_h_px: u16,
) terminal.Terminal.ResizeError!void {
    try self.term.resize(self.alloc, .{
        .cols = cols,
        .rows = rows,
        .cell_size_px = if (cell_w_px > 0 and cell_h_px > 0)
            .{ .width = cell_w_px, .height = cell_h_px }
        else
            null,
    });
    self.pty.setSize(.{
        .ws_col = cols,
        .ws_row = rows,
        .ws_xpixel = cols *| cell_w_px,
        .ws_ypixel = rows *| cell_h_px,
    }) catch |err| log.warn("resizing pty failed err={}", .{err});
}

pub const SnapshotError = terminal.snapshot.EncodeError || error{
    /// The program is in the middle of an escape sequence longer than
    /// `max_continuation_bytes`. Try again after more output.
    ContinuationUnavailable,
};

/// Encode a snapshot of the terminal as of `seq`.
pub fn snapshot(self: *const Block, alloc: Allocator, w: *std.Io.Writer) SnapshotError!void {
    var cont: std.Io.Writer.Allocating = .init(alloc);
    defer cont.deinit();
    self.vt.writeContinuation(&cont.writer) catch |err| return switch (err) {
        error.ContinuationUnavailable => error.ContinuationUnavailable,
        error.ContinuationDisabled => unreachable,
        error.WriteFailed => error.OutOfMemory,
    };
    try terminal.snapshot.encode(alloc, w, &self.term, .{ .continuation = .{ .bytes = cont.written() } });
}

fn emit(self: *Block, event: Event) void {
    self.on_event(self, event);
}

/// Runs in the forked child, before exec.
fn childPreExec(cmd: *Command) ?u8 {
    const pty = cmd.getData(Pty).?;
    pty.childPreExec() catch |err| log.err("error initializing child: {}", .{err});
    return null;
}

fn onRead(
    self_: ?*Block,
    _: *xev.Loop,
    c: *xev.Completion,
    _: xev.Stream,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    const self = self_.?;
    const n = r catch |err| switch (err) {
        error.Canceled => {
            self.endRead();
            return .disarm;
        },
        else => {
            // A spurious wakeup: libxev's kqueue reports EAGAIN this way.
            if (comptime kqueue) if (err == error.MissingKevent) return rearm(c);
            return self.readEnded(c, err);
        },
    };
    const data = if (comptime kqueue) data: {
        const len = posix.read(self.pty.master, self.read_buf) catch |err| switch (err) {
            error.WouldBlock => return rearm(c),
            else => return self.readEnded(c, err),
        };
        if (len == 0) return self.readEnded(c, error.EOF);
        break :data self.read_buf[0..len];
    } else buf.slice[0..n];
    self.processOutput(data);
    // The cancel raced this read, so io_uring's cancel can't end it.
    if (self.stop_requested and xev.backend == .io_uring) {
        self.endRead();
        return .disarm;
    }
    return rearm(c);
}

/// EOF, or EIO: every holder of the slave has closed it.
fn readEnded(self: *Block, c: *xev.Completion, err: anyerror) xev.CallbackAction {
    if (err != error.EOF) log.debug("pty read ended err={}", .{err});
    if (comptime kqueue) {
        self.stopRead();
        return rearm(c);
    }
    // epoll's cancel removes the fd, so it must still be registered then.
    if (self.stop_requested and xev.backend == .epoll) return rearm(c);
    // Elsewhere no cancel is queued here: on io_uring it would be submitted
    // before the rearmed read, miss it, and free the block under the read.
    self.endRead();
    return .disarm;
}

/// Rearm a read or readiness completion from its callback.
pub fn rearm(c: *xev.Completion) xev.CallbackAction {
    // kqueue leaves a read it performed at submit time marked dead and
    // holding its result when it is rearmed, though it stays registered,
    // and a cancel ignores it in either state.
    if (comptime kqueue) {
        c.flags.state = .active;
        c.result = null;
    }
    return .rearm;
}

fn endRead(self: *Block) void {
    if (!self.reading) return;
    self.reading = false;
    self.pending -= 1;
}

fn onExit(
    self_: ?*Block,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Process.WaitError!u32,
) xev.CallbackAction {
    const self = self_.?;
    self.pending -= 1;
    self.exited = true;
    const exit_code = r catch |err| code: {
        // kqueue can't watch a child that exited before the loop
        // registered the watch, so reap it here instead.
        var status: if (builtin.link_libc) c_int else u32 = 0;
        if (posix.system.waitpid(self.pid, &status, 0) == self.pid) {
            switch (Command.Exit.init(@bitCast(status))) {
                .Exited => |v| break :code v,
                else => break :code 0,
            }
        }
        log.warn("waiting for child failed err={}", .{err});
        break :code 1;
    };

    // The exit can be seen before the output the child wrote just before
    // it. Read what is already in the pty so the exit is reported last. A
    // pty buffers far less than one read, so one read gets all of it.
    var pfd = [_]posix.pollfd{.{ .fd = self.pty.master, .events = posix.POLL.IN, .revents = 0 }};
    if ((posix.poll(&pfd, 0) catch 0) > 0 and pfd[0].revents & posix.POLL.IN != 0) {
        if (posix.read(self.pty.master, self.read_buf)) |n| {
            self.processOutput(self.read_buf[0..n]);
        } else |_| {}
    }

    self.emit(.{ .child_exited = .{ .exit_code = exit_code } });
    if (self.killed) self.stopRead();
    return .disarm;
}

fn onWrite(
    w_: ?*Write,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const w = w_.?;
    const self = w.block;
    _ = r catch |err| log.warn("pty write failed err={}", .{err});
    self.pending -= 1;
    self.alloc.free(w.data);
    self.alloc.destroy(w);
    return .disarm;
}

fn fromHandler(handler: *terminal.TerminalStream.Handler) *Block {
    const vt: *terminal.TerminalStream = @fieldParentPtr("handler", handler);
    return @fieldParentPtr("vt", vt);
}

fn writePty(handler: *terminal.TerminalStream.Handler, data: []const u8) void {
    const self = fromHandler(handler);
    self.write(data) catch |err| {
        log.warn("dropping pty reply err={}", .{err});
        return;
    };
    self.emit(.{ .write_pty = data });
}

fn bell(handler: *terminal.TerminalStream.Handler) void {
    fromHandler(handler).emit(.bell);
}

fn desktopNotification(
    handler: *terminal.TerminalStream.Handler,
    n: terminal.StreamAction.ShowDesktopNotification,
) void {
    fromHandler(handler).emit(.{ .desktop_notification = n });
}

fn deviceAttributes(_: *terminal.TerminalStream.Handler) terminal.device_attributes.Attributes {
    return .{};
}

fn titleChanged(handler: *terminal.TerminalStream.Handler) void {
    const self = fromHandler(handler);
    self.emit(.{ .title_changed = self.term.getTitle() orelse "" });
}

fn pwdChanged(handler: *terminal.TerminalStream.Handler) void {
    const self = fromHandler(handler);
    self.emit(.{ .pwd_changed = self.term.getPwd() orelse "" });
}

fn reset(handler: *terminal.TerminalStream.Handler) void {
    const self = fromHandler(handler);
    self.emit(.{ .title_changed = "" });
    self.emit(.{ .pwd_changed = "" });
}

fn progressReport(
    handler: *terminal.TerminalStream.Handler,
    report: terminal.osc.Command.ProgressReport,
) void {
    fromHandler(handler).emit(.{ .progress_report = report });
}

fn programStatus(
    handler: *terminal.TerminalStream.Handler,
    report: terminal.osc.Command.ProgramStatus.Report,
) void {
    fromHandler(handler).emit(.{ .program_status = report });
}

fn clipboardWrite(
    handler: *terminal.TerminalStream.Handler,
    w: terminal.clipboard.Write,
) void {
    fromHandler(handler).emit(.{ .clipboard_write = w });
}

test "rex Block: title, output, DA reply, and exit" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    const Recorder = struct {
        title: ?[]u8 = null,
        output: std.ArrayList(u8) = .empty,
        exit_code: ?u32 = null,

        fn onEvent(block: *Block, event: Event) void {
            const r: *@This() = @ptrCast(@alignCast(block.userdata.?));
            switch (event) {
                .title_changed => |t| {
                    if (r.title) |old| alloc.free(old);
                    r.title = alloc.dupe(u8, t) catch @panic("OOM");
                },
                .output => |b| r.output.appendSlice(alloc, b) catch @panic("OOM"),
                .child_exited => |e| r.exit_code = e.exit_code,
                else => {},
            }
        }
    };
    var rec: Recorder = .{};
    defer {
        if (rec.title) |t| alloc.free(t);
        rec.output.deinit(alloc);
    }

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var read_buf: ReadBuffer = undefined;

    const block = try Block.create(alloc, &loop, &read_buf, .{
        .args = &.{ "/bin/sh", "-c", "printf '\\033]0;hello\\007'; echo hi; read -r x; echo \"got:$x\"" },
        .on_event = &Recorder.onEvent,
        .userdata = &rec,
    });
    defer block.destroy();

    // The DA query makes the terminal reply to the child, which reads the
    // reply as its line once the newline follows.
    block.processOutput("\x1b[c");
    try block.write("\n");

    // Hang up the child rather than hang the test if it never finishes.
    var timer = try xev.Timer.init();
    defer timer.deinit();
    var timer_c: xev.Completion = .{};
    var cancel_c: xev.Completion = .{};
    timer.run(&loop, &timer_c, 10_000, Block, block, (struct {
        fn cb(b: ?*Block, _: *xev.Loop, _: *xev.Completion, r: xev.Timer.RunError!void) xev.CallbackAction {
            _ = r catch return .disarm;
            b.?.kill();
            return .disarm;
        }
    }).cb);
    while (!block.isDone()) try loop.run(.once);
    timer.cancel(&loop, &timer_c, &cancel_c, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.Timer.CancelError!void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);
    try loop.run(.until_done);

    try testing.expectEqualStrings("hello", rec.title.?);
    try testing.expectEqual(@as(?u32, 0), rec.exit_code);
    try testing.expect(std.mem.indexOf(u8, rec.output.items, "got:\x1b[?") != null);

    const plain = try block.term.plainString(alloc);
    defer alloc.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "hi") != null);
}

test "rex Block: exit status of a child that exits before the loop runs" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;

    const Recorder = struct {
        fn onEvent(block: *Block, event: Event) void {
            if (event == .child_exited) {
                const code: *?u32 = @ptrCast(@alignCast(block.userdata.?));
                code.* = event.child_exited.exit_code;
            }
        }
    };
    var exit_code: ?u32 = null;

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var read_buf: ReadBuffer = undefined;

    const block = try Block.create(testing.allocator, &loop, &read_buf, .{
        .args = &.{ "/bin/sh", "-c", "exit 3" },
        .on_event = &Recorder.onEvent,
        .userdata = &exit_code,
    });
    defer block.destroy();

    try std.Io.sleep(testing.io, .fromMilliseconds(200), .awake);
    try loop.run(.until_done);
    try testing.expectEqual(@as(?u32, 3), exit_code);
}

test "rex Block: default scrollback keeps 10,000 lines at 80 columns" {
    const testing = std.testing;
    var pages: terminal.PageList = try .init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = default_max_scrollback_bytes,
    });
    defer pages.deinit();

    for (0..12_000) |_| _ = try pages.grow();
    try testing.expect(pages.total_rows >= 10_000 + pages.rows);
}

test "rex Block: kill frees a block whose descendant keeps the pty open" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;

    const Recorder = struct {
        fn onEvent(block: *Block, event: Event) void {
            if (event == .output) {
                const outputs: *usize = @ptrCast(@alignCast(block.userdata.?));
                outputs.* += 1;
            }
        }
    };
    var outputs: usize = 0;

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var read_buf: ReadBuffer = undefined;

    const block = try Block.create(testing.allocator, &loop, &read_buf, .{
        .args = &.{ "/bin/sh", "-c", "echo started; (trap '' HUP; while :; do sleep 0.05; echo x; done) & sleep 30" },
        .on_event = &Recorder.onEvent,
        .userdata = &outputs,
    });
    defer block.destroy();
    // The survivor ignores the hangup but shares the child's process group.
    defer posix.kill(-block.pid, .KILL) catch {};

    // Output already waiting when the loop first runs is read at once,
    // and the survivor is running before the pane is closed.
    try std.Io.sleep(testing.io, .fromMilliseconds(200), .awake);
    try loop.run(.no_wait);
    block.kill();
    var tries: usize = 0;
    while (!block.isDone()) : (tries += 1) {
        if (tries == 500) return error.TestUnexpectedResult;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
        try loop.run(.no_wait);
    }

    // Nothing reads the pty anymore, though the survivor keeps writing.
    outputs = 0;
    for (0..20) |_| {
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
        try loop.run(.no_wait);
    }
    try testing.expectEqual(@as(usize, 0), outputs);
}

test "rex Block: a full reset clears the title" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;

    const Recorder = struct {
        fn onEvent(block: *Block, event: Event) void {
            if (event == .title_changed) {
                const title: *[16]u8 = @ptrCast(block.userdata.?);
                @memset(title, 0);
                @memcpy(title[0..event.title_changed.len], event.title_changed);
            }
        }
    };
    var title: [16]u8 = @splat(0);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var read_buf: ReadBuffer = undefined;

    const block = try Block.create(testing.allocator, &loop, &read_buf, .{
        .args = &.{ "/bin/sh", "-c", "exit 0" },
        .on_event = &Recorder.onEvent,
        .userdata = &title,
    });
    defer block.destroy();

    block.processOutput("\x1b]0;hello\x07");
    try testing.expectEqualStrings("hello", std.mem.sliceTo(&title, 0));
    block.processOutput("\x1bc");
    try testing.expectEqualStrings("", std.mem.sliceTo(&title, 0));

    try loop.run(.until_done);
}

test "rex Block: busy blocks sharing a read buffer get only their own output" {
    if (comptime !kqueue) return error.SkipZigTest;
    const testing = std.testing;

    const Recorder = struct {
        own: u8,
        bytes: usize = 0,
        foreign: usize = 0,

        fn onEvent(block: *Block, event: Event) void {
            const r: *@This() = @ptrCast(@alignCast(block.userdata.?));
            if (event != .output) return;
            for (event.output) |ch| switch (ch) {
                '\r', '\n' => {},
                else => if (ch == r.own) {
                    r.bytes += 1;
                } else {
                    r.foreign += 1;
                },
            };
        }
    };
    var rec_a: Recorder = .{ .own = 'a' };
    var rec_b: Recorder = .{ .own = 'b' };

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var read_buf: ReadBuffer = undefined;

    const a = try Block.create(testing.allocator, &loop, &read_buf, .{
        .args = &.{ "/bin/sh", "-c", "yes aaaaaaaaaaaaaaa | head -n 20000" },
        .on_event = &Recorder.onEvent,
        .userdata = &rec_a,
    });
    defer a.destroy();
    const b = try Block.create(testing.allocator, &loop, &read_buf, .{
        .args = &.{ "/bin/sh", "-c", "yes b | head -n 20000" },
        .on_event = &Recorder.onEvent,
        .userdata = &rec_b,
    });
    defer b.destroy();

    // Both ptys hold output before the loop first registers their reads.
    try std.Io.sleep(testing.io, .fromMilliseconds(200), .awake);
    while (!a.isDone() or !b.isDone()) try loop.run(.once);

    try testing.expectEqual(@as(usize, 0), rec_a.foreign);
    try testing.expectEqual(@as(usize, 0), rec_b.foreign);
    try testing.expectEqual(@as(usize, 15 * 20000), rec_a.bytes);
    try testing.expectEqual(@as(usize, 20000), rec_b.bytes);
}

test "rex Block: effects from a real child become events" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;

    const Recorder = struct {
        seen: std.EnumSet(std.meta.Tag(Event)) = .empty,
        pwd: [32]u8 = @splat(0),
        exit_code: ?u32 = null,

        fn onEvent(block: *Block, event: Event) void {
            const r: *@This() = @ptrCast(@alignCast(block.userdata.?));
            r.seen.insert(std.meta.activeTag(event));
            switch (event) {
                .pwd_changed => |p| @memcpy(r.pwd[0..p.len], p),
                .child_exited => |e| r.exit_code = e.exit_code,
                else => {},
            }
        }
    };
    var rec: Recorder = .{};

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var read_buf: ReadBuffer = undefined;

    // OSC 7 pwd, BEL, OSC 9 notification, OSC 9;4 progress, OSC 52
    // clipboard, OSC 7501 program status.
    const block = try Block.create(testing.allocator, &loop, &read_buf, .{
        .args = &.{ "/bin/sh", "-c", "printf '\\033]7;file://localhost/tmp\\007\\007\\033]9;hi there\\007\\033]9;4;1;50\\007\\033]52;c;aGVsbG8=\\007\\033]7501;state=working:app=probe\\033\\\\'; sleep 0.3; exit 7" },
        .on_event = &Recorder.onEvent,
        .userdata = &rec,
    });
    defer block.destroy();
    while (!block.isDone()) try loop.run(.once);

    for ([_]std.meta.Tag(Event){ .bell, .desktop_notification, .progress_report, .clipboard_write, .program_status }) |t|
        try testing.expect(rec.seen.contains(t));
    try testing.expectEqualStrings("file://localhost/tmp", std.mem.sliceTo(&rec.pwd, 0));
    try testing.expectEqual(@as(?u32, 7), rec.exit_code);
}
