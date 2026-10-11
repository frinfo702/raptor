//! The `rap` commands that talk to the server.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const Writer = std.Io.Writer;
const protocol = @import("../rex/protocol.zig");
const ExitCode = @import("exit.zig").Code;

pub const usage =
    \\Usage: rap [flags] <command> [args] [-- command...]
    \\
    \\Sessions and blocks:
    \\  ls                     List sessions
    \\  new [name] [-- cmd]    Create a session
    \\  run [--wait] -- cmd    Run a command in a new window
    \\  split [--down] [-- cmd]
    \\                         Split a block (right unless --down)
    \\  send <text>...         Type text into a block (\n, \t, \e, \xHH escapes)
    \\  send-key <key>...      Press keys (Enter, Tab, Escape, Up, C-c, M-x, ...)
    \\  capture [--all]        Print a block's screen (--all adds scrollback)
    \\  kill [name]            Kill a session and everything in it
    \\  close                  Close a block, or a window with -w
    \\  zoom                   Toggle a block's zoom
    \\  focus                  Focus a block, or a window with -w
    \\  events                 Print events as JSON lines
    \\  wait                   Wait for a block's program; exit with its status
    \\  session inspect [name] Describe a session
    \\  block inspect [block]  Describe a block
    \\
    \\Server:
    \\  server run [--idle-timeout secs]    Run the server in the foreground
    \\  server start [--idle-timeout secs]  Start the server in the background
    \\  server stop | server status
    \\
    \\Other:
    \\  version                Print the build id
    \\  help                   Print this help
    \\
    \\Flags:
    \\  -s <session>  -w <window>  -b <block>   Targets: id, label, position, or id suffix
    \\  -S <socket>   Server socket (default: $RAP_SERVER, else per user)
    \\  --json        Print results as JSON
    \\
    \\Inside a rap block, RAP_SESSION and RAP_BLOCK are the default targets.
    \\Set RAP_AUTOSTART=0 to never start a server on demand.
    \\
;

/// A parsed command line.
pub const Args = struct {
    session: ?[]const u8 = null,
    window: ?[]const u8 = null,
    block: ?[]const u8 = null,
    server: ?[]const u8 = null,
    json: bool = false,
    wait: bool = false,
    all: bool = false,
    down: bool = false,
    idle_timeout: ?[]const u8 = null,
    /// The command name and its operands.
    words: []const []const u8 = &.{},
    /// Everything after `--`.
    command: ?[]const []const u8 = null,
};

const value_flags = std.StaticStringMap(enum { session, window, block, server, idle_timeout }).initComptime(.{
    .{ "-s", .session },
    .{ "-w", .window },
    .{ "-b", .block },
    .{ "-S", .server },
    .{ "--idle-timeout", .idle_timeout },
});

const bool_flags = std.StaticStringMap(enum { json, wait, all, down }).initComptime(.{
    .{ "--json", .json },
    .{ "--wait", .wait },
    .{ "--all", .all },
    .{ "--down", .down },
});

pub const ParseError = error{ MissingValue, UnknownFlag } || Allocator.Error;

pub fn parse(alloc: Allocator, argv: []const []const u8, bad: *[]const u8) ParseError!Args {
    var args: Args = .{};
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--")) {
            args.command = argv[i + 1 ..];
            break;
        }
        if (a.len < 2 or a[0] != '-') {
            try words.append(alloc, a);
            continue;
        }
        bad.* = a;
        if (value_flags.get(a)) |field| {
            i += 1;
            if (i == argv.len) return error.MissingValue;
            switch (field) {
                inline else => |f| @field(args, @tagName(f)) = argv[i],
            }
        } else if (bool_flags.get(a)) |field| switch (field) {
            inline else => |f| @field(args, @tagName(f)) = true,
        } else return error.UnknownFlag;
    }
    args.words = words.items;
    return args;
}

/// Run a command that talks to the server. `argv` excludes argv[0].
pub fn run(
    alloc: Allocator,
    io: std.Io,
    env: *const EnvMap,
    argv: []const []const u8,
    out: *Writer,
    err: *Writer,
) Writer.Error!ExitCode {
    var bad: []const u8 = "";
    const args = parse(alloc, argv, &bad) catch |e| {
        try err.print("rap: {s} '{s}'\n", .{ switch (e) {
            error.MissingValue => "missing value for",
            error.UnknownFlag => "unknown flag",
            error.OutOfMemory => "out of memory parsing",
        }, bad });
        return .usage;
    };
    var ctx: Ctx = .{ .alloc = alloc, .io = io, .env = env, .args = args, .out = out, .err = err };
    return ctx.dispatch() catch |e| switch (e) {
        error.WriteFailed => error.WriteFailed,
        else => {
            try err.print("rap: {t}\n", .{e});
            return .fail;
        },
    };
}

/// Make a relative socket path absolute, since the server and the
/// programs in its blocks run elsewhere.
pub fn resolveSocketPath(alloc: Allocator, io: std.Io, env: *const EnvMap, flag: ?[]const u8) ![:0]u8 {
    const path = try protocol.socketPath(alloc, env, flag);
    if (std.fs.path.isAbsolute(path)) return path;
    const cwd = try std.process.currentPathAlloc(io, alloc);
    const abs = try std.fs.path.resolve(alloc, &.{ cwd, path });
    return alloc.dupeSentinel(u8, abs, 0);
}

const Ctx = struct {
    alloc: Allocator,
    io: std.Io,
    env: *const EnvMap,
    args: Args,
    out: *Writer,
    err: *Writer,
    fd: posix.fd_t = -1,
    next_id: i64 = 1,

    const Error = anyerror;

    fn dispatch(self: *Ctx) Error!ExitCode {
        const words = self.args.words;
        if (words.len == 0) {
            try self.err.writeAll(usage);
            return .usage;
        }
        const cmd = words[0];
        const Cmd = enum {
            ls,
            new,
            run,
            split,
            send,
            @"send-key",
            capture,
            kill,
            close,
            zoom,
            focus,
            events,
            wait,
            session,
            block,
            server,
        };
        const which = std.meta.stringToEnum(Cmd, cmd) orelse {
            try self.err.print("rap: unknown command '{s}'\n\n" ++ usage, .{cmd});
            return .usage;
        };
        return switch (which) {
            .ls => self.ls(),
            .new => self.new(),
            .run => self.runCmd(),
            .split => self.split(),
            .send => self.send(),
            .@"send-key" => self.sendKey(),
            .capture => self.capture(),
            .kill => self.kill(),
            .close => self.close(),
            .zoom => self.simple("session.zoom_block"),
            .focus => self.simple("session.focus"),
            .events => self.events(),
            .wait => self.wait(),
            .session => self.inspect("session"),
            .block => self.inspect("block"),
            .server => self.server(),
        };
    }

    fn usageError(self: *Ctx, comptime fmt: []const u8, a: anytype) Error!ExitCode {
        try self.err.print("rap: " ++ fmt ++ "\n", a);
        return .usage;
    }

    // Connection

    fn socketPath(self: *Ctx) Error![:0]u8 {
        return resolveSocketPath(self.alloc, self.io, self.env, self.args.server);
    }

    /// Connect, starting a server first if `autostart` and none is running.
    /// Null means the server is unreachable and that was reported.
    fn connect(self: *Ctx, autostart: bool) Error!?void {
        const path = try self.socketPath();
        self.fd = protocol.connect(path) catch |e| fd: {
            if (e != error.Unreachable) return e;
            const allowed = if (self.env.get("RAP_AUTOSTART")) |v| !std.mem.eql(u8, v, "0") else true;
            if (!autostart or !allowed) {
                try self.err.print("rap: no server running on {s}\n", .{path});
                return null;
            }
            try startServer(self.alloc, self.io, self.env, path, self.args.idle_timeout);
            break :fd protocol.connect(path) catch {
                try self.err.print("rap: no server running on {s}\n", .{path});
                return null;
            };
        };
    }

    const Response = union(enum) {
        result: std.json.Value,
        failed: ExitCode,
    };

    /// Send a request and wait for its response. A failure is printed.
    fn call(self: *Ctx, method: []const u8, params: anytype) Error!Response {
        const id = self.next_id;
        self.next_id += 1;
        var buf: std.Io.Writer.Allocating = .init(self.alloc);
        try std.json.Stringify.value(.{
            .id = id,
            .method = method,
            .params = params,
        }, .{ .emit_null_optional_fields = false }, &buf.writer);
        try protocol.writeFrame(self.fd, .json, buf.written());

        while (true) {
            const frame = try protocol.readFrame(self.alloc, self.fd);
            const msg = try std.json.parseFromSliceLeaky(std.json.Value, self.alloc, frame.payload, .{});
            if (msg != .object) return error.BadResponse;
            const got = msg.object.get("id") orelse continue;
            if (got != .integer or got.integer != id) continue;
            if (msg.object.get("error")) |e| {
                const code = std.meta.stringToEnum(protocol.ErrorCode, e.object.get("code").?.string) orelse .fail;
                try self.err.print("rap: {s}\n", .{e.object.get("message").?.string});
                return .{ .failed = switch (code) {
                    .usage => .usage,
                    .target => .target,
                    .fail => .fail,
                } };
            }
            return .{ .result = msg.object.get("result") orelse .null };
        }
    }

    fn printJson(self: *Ctx, v: std.json.Value) Error!void {
        try std.json.Stringify.value(v, .{}, self.out);
        try self.out.writeByte('\n');
    }

    const Target = struct {
        session: ?[]const u8 = null,
        window: ?[]const u8 = null,
        block: ?[]const u8 = null,
    };

    /// The target flags, defaulting to the session and block this runs in.
    /// A block id or label is looked up in every session.
    fn target(self: *Ctx) Target {
        const a = self.args;
        const none = a.session == null and a.window == null and a.block == null;
        const by_name = if (a.block) |b| std.meta.isError(std.fmt.parseInt(usize, b, 10)) else false;
        return .{
            .session = a.session orelse if (by_name) null else self.env.get("RAP_SESSION"),
            .window = a.window,
            .block = if (none) self.env.get("RAP_BLOCK") else a.block,
        };
    }

    fn str(v: std.json.Value, key: []const u8) []const u8 {
        const f = v.object.get(key) orelse return "";
        return if (f == .string) f.string else "";
    }

    fn int(v: std.json.Value, key: []const u8) i64 {
        const f = v.object.get(key) orelse return 0;
        return if (f == .integer) f.integer else 0;
    }

    /// The variables the client hands to new sessions.
    fn sessionEnv(self: *Ctx) Error!std.json.Value {
        var obj = try std.json.ObjectMap.init(self.alloc, &.{}, &.{});
        for (protocol.session_env) |k| if (self.env.get(k)) |v| try obj.put(self.alloc, k, .{ .string = v });
        return .{ .object = obj };
    }

    fn cwd(self: *Ctx) ?[]const u8 {
        return std.process.currentPathAlloc(self.io, self.alloc) catch null;
    }

    // Commands

    fn ls(self: *Ctx) Error!ExitCode {
        if (try self.connect(false) == null) return .unreachable_server;
        const r = switch (try self.call("session.list", .{})) {
            .result => |v| v,
            .failed => |code| return code,
        };
        if (self.args.json) {
            try self.printJson(r);
            return .ok;
        }
        const sessions = r.object.get("sessions").?.array.items;
        var width: usize = "NAME".len;
        for (sessions) |s| width = @max(width, str(s, "label").len);
        try self.out.print("{s}", .{"NAME"});
        try self.out.splatByteAll(' ', width - 4 + 2);
        try self.out.writeAll("WINDOWS  BLOCKS  ID\n");
        for (sessions) |s| {
            const label = str(s, "label");
            try self.out.writeAll(label);
            try self.out.splatByteAll(' ', width - label.len + 2);
            try self.out.print("{d: <7}  {d: <6}  {s}\n", .{ int(s, "windows"), int(s, "blocks"), str(s, "id") });
        }
        return .ok;
    }

    fn new(self: *Ctx) Error!ExitCode {
        if (self.args.words.len > 2) return self.usageError("usage: rap new [name] [-- command...]", .{});
        if (try self.connect(true) == null) return .unreachable_server;
        const r = switch (try self.call("session.create", .{
            .label = if (self.args.words.len == 2) self.args.words[1] else null,
            .command = self.args.command,
            .cwd = self.cwd(),
            .env = try self.sessionEnv(),
        })) {
            .result => |v| v,
            .failed => |code| return code,
        };
        if (self.args.json) try self.printJson(r) else try self.out.print("{s}\n", .{str(r, "label")});
        return .ok;
    }

    fn runCmd(self: *Ctx) Error!ExitCode {
        const command = self.args.command orelse return self.usageError("usage: rap run [--wait] -- command...", .{});
        if (command.len == 0) return self.usageError("usage: rap run [--wait] -- command...", .{});
        if (try self.connect(true) == null) return .unreachable_server;
        const t = self.target();
        const params = .{
            .session = t.session,
            .command = command,
            .cwd = self.cwd(),
            .wait = self.args.wait,
        };
        var resp = try self.call("session.list", .{});
        const none = resp == .result and resp.result.object.get("sessions").?.array.items.len == 0;
        resp = if (none and t.session == null)
            try self.call("session.create", .{
                .command = command,
                .cwd = params.cwd,
                .env = try self.sessionEnv(),
                .wait = self.args.wait,
            })
        else
            try self.call("session.new_window", params);
        const r = switch (resp) {
            .result => |v| v,
            .failed => |code| return code,
        };
        if (self.args.wait) return exitStatus(int(r, "exit_code"));
        if (self.args.json) try self.printJson(r) else try self.out.print("{s}\n", .{str(r, "block")});
        return .ok;
    }

    fn split(self: *Ctx) Error!ExitCode {
        if (try self.connect(false) == null) return .unreachable_server;
        const t = self.target();
        const r = switch (try self.call("session.new_split", .{
            .session = t.session,
            .window = t.window,
            .block = t.block,
            .direction = if (self.args.down) "down" else "right",
            .command = self.args.command,
            .cwd = self.cwd(),
        })) {
            .result => |v| v,
            .failed => |code| return code,
        };
        if (self.args.json) try self.printJson(r) else try self.out.print("{s}\n", .{str(r, "block")});
        return .ok;
    }

    fn writeBlock(self: *Ctx, data: []const u8) Error!ExitCode {
        if (try self.connect(false) == null) return .unreachable_server;
        const t = self.target();
        return switch (try self.call("block.method", .{
            .session = t.session,
            .window = t.window,
            .block = t.block,
            .method = "write",
            .data = data,
        })) {
            .result => .ok,
            .failed => |code| code,
        };
    }

    fn send(self: *Ctx) Error!ExitCode {
        if (self.args.words.len < 2) return self.usageError("usage: rap send <text>...", .{});
        var data: std.ArrayList(u8) = .empty;
        for (self.args.words[1..], 0..) |word, i| {
            if (i > 0) try data.append(self.alloc, ' ');
            try unescape(self.alloc, &data, word);
        }
        return self.writeBlock(data.items);
    }

    fn sendKey(self: *Ctx) Error!ExitCode {
        if (self.args.words.len < 2) return self.usageError("usage: rap send-key <key>...", .{});
        var data: std.ArrayList(u8) = .empty;
        for (self.args.words[1..]) |key| encodeKey(self.alloc, &data, key) catch |e| switch (e) {
            error.UnknownKey => return self.usageError("unknown key '{s}'", .{key}),
            else => return e,
        };
        return self.writeBlock(data.items);
    }

    fn capture(self: *Ctx) Error!ExitCode {
        if (try self.connect(false) == null) return .unreachable_server;
        const t = self.target();
        const r = switch (try self.call("block.method", .{
            .session = t.session,
            .window = t.window,
            .block = t.block,
            .method = "format",
            .scope = if (self.args.all) "all" else "screen",
        })) {
            .result => |v| v,
            .failed => |code| return code,
        };
        if (self.args.json) {
            try self.printJson(r);
            return .ok;
        }
        const text = str(r, "text");
        try self.out.writeAll(text);
        if (text.len > 0 and text[text.len - 1] != '\n') try self.out.writeByte('\n');
        return .ok;
    }

    fn kill(self: *Ctx) Error!ExitCode {
        if (self.args.words.len > 2) return self.usageError("usage: rap kill [session]", .{});
        if (try self.connect(false) == null) return .unreachable_server;
        const session = if (self.args.words.len == 2) self.args.words[1] else self.target().session;
        return switch (try self.call("session.kill", .{ .session = session })) {
            .result => .ok,
            .failed => |code| code,
        };
    }

    fn close(self: *Ctx) Error!ExitCode {
        if (try self.connect(false) == null) return .unreachable_server;
        const t = self.target();
        const method = if (t.window != null and t.block == null) "session.close_window" else "block.close";
        return switch (try self.call(method, t)) {
            .result => .ok,
            .failed => |code| code,
        };
    }

    fn simple(self: *Ctx, method: []const u8) Error!ExitCode {
        if (try self.connect(false) == null) return .unreachable_server;
        const r = switch (try self.call(method, self.target())) {
            .result => |v| v,
            .failed => |code| return code,
        };
        if (self.args.json) try self.printJson(r);
        return .ok;
    }

    fn events(self: *Ctx) Error!ExitCode {
        if (try self.connect(false) == null) return .unreachable_server;
        switch (try self.call("session.subscribe", .{ .session = self.args.session })) {
            .result => {},
            .failed => |code| return code,
        }
        try self.out.flush();
        while (true) {
            const frame = protocol.readFrame(self.alloc, self.fd) catch |e| switch (e) {
                error.EndOfStream => return .ok,
                else => return e,
            };
            defer self.alloc.free(frame.payload);
            try self.out.writeAll(frame.payload);
            try self.out.writeByte('\n');
            try self.out.flush();
        }
    }

    fn wait(self: *Ctx) Error!ExitCode {
        if (try self.connect(false) == null) return .unreachable_server;
        const t = self.target();
        const r = switch (try self.call("block.wait", t)) {
            .result => |v| v,
            .failed => |code| return code,
        };
        return exitStatus(int(r, "exit_code"));
    }

    fn inspect(self: *Ctx, comptime kind: []const u8) Error!ExitCode {
        const words = self.args.words;
        if (words.len < 2 or !std.mem.eql(u8, words[1], "inspect") or words.len > 3)
            return self.usageError("usage: rap " ++ kind ++ " inspect [" ++ kind ++ "]", .{});
        if (try self.connect(false) == null) return .unreachable_server;
        if (words.len == 3) @field(self.args, kind) = words[2];
        const t = self.target();
        const method = if (comptime std.mem.eql(u8, kind, "session")) "session.view" else "session.describe_block";
        const r = switch (try self.call(method, t)) {
            .result => |v| v,
            .failed => |code| return code,
        };
        if (self.args.json) {
            try self.printJson(r);
            return .ok;
        }
        if (comptime std.mem.eql(u8, kind, "session")) try self.printSession(r) else try self.printBlock(r);
        return .ok;
    }

    fn printSession(self: *Ctx, r: std.json.Value) Error!void {
        const o = self.out;
        const windows = r.object.get("windows").?.array.items;
        try o.print("session: {s}\nlabel: {s}\nrevision: {d}\nwindows: {d}\n", .{
            str(r, "id"), str(r, "label"), int(r, "revision"), windows.len,
        });
        var width: usize = "LABEL".len;
        for (windows) |w| width = @max(width, str(w, "label").len);
        try o.writeAll("WINDOW                                         LABEL");
        try o.splatByteAll(' ', width - 5 + 2);
        try o.writeAll("ACTIVE  FOCUSED BLOCK                                 BLOCKS\n");
        for (windows) |w| {
            const label = str(w, "label");
            const active = w.object.get("active").?.bool;
            try o.print("{s: <45}  {s}", .{ str(w, "id"), label });
            try o.splatByteAll(' ', width - label.len + 2);
            try o.print("{s: <6}  {s: <44}  {d}\n", .{
                if (active) "yes" else "", str(w, "focused_block"), w.object.get("blocks").?.array.items.len,
            });
        }
        const clients = r.object.get("clients").?.array.items;
        try o.print("clients: {d}\n", .{clients.len});
        for (clients) |cl| {
            const p = cl.object.get("principal").?;
            try o.print("  {s} uid {d} pid {d} over unix\n", .{ str(cl, "id"), int(p, "uid"), int(p, "pid") });
        }
    }

    fn printBlock(self: *Ctx, r: std.json.Value) Error!void {
        const b = r.object.get("block").?;
        const exit_code = b.object.get("exit_code").?;
        try self.out.print(
            \\block: {s}
            \\label: {s}
            \\session: {s}
            \\window: {s}
            \\flavor: {s}
            \\pid: {d}
            \\title: {s}
            \\pwd: {s}
            \\size: {d}x{d}
            \\
        , .{
            str(b, "id"),     str(b, "label"), str(r, "session"), str(r, "window"),
            str(b, "flavor"), int(b, "pid"),   str(b, "title"),   str(b, "pwd"),
            int(b, "cols"),   int(b, "rows"),
        });
        if (exit_code == .integer) try self.out.print("exited: {d}\n", .{exit_code.integer});
        const methods = r.object.get("methods").?.array.items;
        try self.out.print("methods: {d}\n", .{methods.len});
        for (methods) |m| try self.out.print("  {s}\n", .{m.string});
        const evs = r.object.get("events").?.array.items;
        try self.out.print("events: {d}\n", .{evs.len});
        for (evs) |e| try self.out.print("  {s}\n", .{e.string});
    }

    fn server(self: *Ctx) Error!ExitCode {
        const words = self.args.words;
        const sub = if (words.len == 2) words[1] else "";
        if (std.mem.eql(u8, sub, "start")) {
            const path = try self.socketPath();
            if (protocol.connect(path)) |fd| {
                _ = c.close(fd);
                try self.out.print("server already running on {s}\n", .{path});
                return .ok;
            } else |_| {}
            try startServer(self.alloc, self.io, self.env, path, self.args.idle_timeout);
            return .ok;
        }
        if (std.mem.eql(u8, sub, "stop")) {
            if (try self.connect(false) == null) return .unreachable_server;
            return switch (try self.call("server.stop", .{})) {
                .result => .ok,
                .failed => |code| code,
            };
        }
        if (std.mem.eql(u8, sub, "status")) {
            if (try self.connect(false) == null) return .unreachable_server;
            const r = switch (try self.call("server.status", .{})) {
                .result => |v| v,
                .failed => |code| return code,
            };
            if (self.args.json) {
                try self.printJson(r);
                return .ok;
            }
            try self.out.print("running pid {d} on {s}\nversion: {s}\nsessions: {d}\nclients: {d}\n", .{
                int(r, "pid"), str(r, "socket"), str(r, "version"), int(r, "sessions"), int(r, "clients"),
            });
            return .ok;
        }
        return self.usageError("usage: rap server run|start|stop|status", .{});
    }
};

fn exitStatus(code: i64) ExitCode {
    return @fromBackingInt(@intCast(std.math.cast(u8, code) orelse 1));
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
/// output going to the log, and wait for it to listen.
pub fn startServer(
    alloc: Allocator,
    io: std.Io,
    env: *const EnvMap,
    socket_path: [:0]const u8,
    idle_timeout: ?[]const u8,
) !void {
    const exe = try std.process.executablePathAlloc(io, alloc);

    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ exe, "server", "run", "-S", socket_path });
    if (idle_timeout) |t| try argv.appendSlice(alloc, &.{ "--idle-timeout", try alloc.dupeSentinel(u8, t, 0) });
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

/// Append `text` with C-style escapes decoded.
pub fn unescape(alloc: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\' or i + 1 == text.len) {
            try out.append(alloc, text[i]);
            continue;
        }
        i += 1;
        const ch: u8 = switch (text[i]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'e' => 0x1b,
            'a' => 0x07,
            'b' => 0x08,
            '0' => 0,
            '\\' => '\\',
            'x' => hex: {
                if (i + 2 < text.len) {
                    if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |v| {
                        i += 2;
                        break :hex v;
                    } else |_| {}
                }
                try out.append(alloc, '\\');
                break :hex 'x';
            },
            else => |other| esc: {
                try out.append(alloc, '\\');
                break :esc other;
            },
        };
        try out.append(alloc, ch);
    }
}

const named_keys = std.StaticStringMap([]const u8).initComptime(.{
    .{ "enter", "\r" },       .{ "tab", "\t" },         .{ "escape", "\x1b" },
    .{ "esc", "\x1b" },       .{ "space", " " },        .{ "bspace", "\x7f" },
    .{ "backspace", "\x7f" }, .{ "up", "\x1b[A" },      .{ "down", "\x1b[B" },
    .{ "right", "\x1b[C" },   .{ "left", "\x1b[D" },    .{ "home", "\x1b[H" },
    .{ "end", "\x1b[F" },     .{ "pageup", "\x1b[5~" }, .{ "pagedown", "\x1b[6~" },
    .{ "ppage", "\x1b[5~" },  .{ "npage", "\x1b[6~" },  .{ "insert", "\x1b[2~" },
    .{ "delete", "\x1b[3~" }, .{ "dc", "\x1b[3~" },     .{ "f1", "\x1bOP" },
    .{ "f2", "\x1bOQ" },      .{ "f3", "\x1bOR" },      .{ "f4", "\x1bOS" },
    .{ "f5", "\x1b[15~" },    .{ "f6", "\x1b[17~" },    .{ "f7", "\x1b[18~" },
    .{ "f8", "\x1b[19~" },    .{ "f9", "\x1b[20~" },    .{ "f10", "\x1b[21~" },
    .{ "f11", "\x1b[23~" },   .{ "f12", "\x1b[24~" },
});

/// Append the bytes a terminal sends for `key`: a name such as `Enter`,
/// `C-c` for control, `M-x` for meta, or a single character.
pub fn encodeKey(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8) !void {
    if (key.len > 2 and (key[0] == 'M' or key[0] == 'm') and key[1] == '-') {
        try out.append(alloc, 0x1b);
        return encodeKey(alloc, out, key[2..]);
    }
    if (key.len == 3 and (key[0] == 'C' or key[0] == 'c') and key[1] == '-') {
        const ch = std.ascii.toLower(key[2]);
        return out.append(alloc, switch (ch) {
            'a'...'z' => ch & 0x1f,
            '@', ' ' => 0,
            '[' => 0x1b,
            '\\' => 0x1c,
            ']' => 0x1d,
            '^' => 0x1e,
            '_' => 0x1f,
            '?' => 0x7f,
            else => return error.UnknownKey,
        });
    }
    if (key.len == 1) return out.append(alloc, key[0]);
    var lower: [16]u8 = undefined;
    if (key.len > lower.len) return error.UnknownKey;
    const seq = named_keys.get(std.ascii.lowerString(&lower, key)) orelse return error.UnknownKey;
    try out.appendSlice(alloc, seq);
}

test "rap cli: flags anywhere, command after --" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var bad: []const u8 = "";
    const a = try parse(arena.allocator(), &.{ "-S", "/tmp/s", "new", "demo", "--json", "--", "/bin/sh", "-c", "x" }, &bad);
    try std.testing.expectEqualStrings("/tmp/s", a.server.?);
    try std.testing.expect(a.json);
    try std.testing.expectEqual(2, a.words.len);
    try std.testing.expectEqualStrings("demo", a.words[1]);
    try std.testing.expectEqual(3, a.command.?.len);
    try std.testing.expectError(error.UnknownFlag, parse(arena.allocator(), &.{ "ls", "--nope" }, &bad));
    try std.testing.expectEqualStrings("--nope", bad);
    try std.testing.expectError(error.MissingValue, parse(arena.allocator(), &.{ "ls", "-s" }, &bad));
}

test "rap cli: send escapes" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try unescape(alloc, &out, "echo hi\\n\\t\\e\\x41\\\\\\q\\");
    try std.testing.expectEqualStrings("echo hi\n\t\x1bA\\\\q\\", out.items);
}

test "rap cli: key names" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for ([_][]const u8{ "Enter", "C-c", "M-x", "Up", "a", "F5" }) |k| try encodeKey(alloc, &out, k);
    try std.testing.expectEqualStrings("\r\x03\x1bx\x1b[Aa\x1b[15~", out.items);
    try std.testing.expectError(error.UnknownKey, encodeKey(alloc, &out, "Nope"));
}
