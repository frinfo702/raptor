//! Entrypoint for `rap`, the Raptor command line tool.
//!
//! This sits at the root of `src/` so that it can import shared modules
//! such as `pty.zig`, `Command.zig` and `ghostty-vt` as the tool grows.
const std = @import("std");
const vt = @import("ghostty-vt");
const options = @import("build_options");
const exit = @import("rap/exit.zig");

pub const ExitCode = exit.Code;

const usage =
    \\Usage: rap <command>
    \\
    \\Commands:
    \\  version   Print the build id
    \\  help      Print this help
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buf);

    const code = try run(
        if (args.len > 0) args[1..] else args,
        &stdout_writer.interface,
        &stderr_writer.interface,
    );
    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
    return @backingInt(code);
}

/// Run the command named by `args` (excluding argv[0]).
fn run(
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) std.Io.Writer.Error!ExitCode {
    if (args.len == 0) {
        try stderr.writeAll(usage);
        return .usage;
    }

    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "version")) {
        try stdout.print("rap {s}\n", .{options.app_version_string});
        return .ok;
    }
    if (std.mem.eql(u8, cmd, "help")) {
        try stdout.writeAll(usage);
        return .ok;
    }

    try stderr.print("rap: unknown command '{s}'\n\n" ++ usage, .{cmd});
    return .usage;
}

fn testRun(args: []const []const u8, expected: ExitCode, out: []const u8, err: []const u8) !void {
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    try std.testing.expectEqual(expected, try run(args, &stdout.writer, &stderr.writer));
    try std.testing.expectEqualStrings(out, stdout.written());
    try std.testing.expectEqualStrings(err, stderr.written());
}

test "rap version" {
    try testRun(&.{"version"}, .ok, "rap " ++ options.app_version_string ++ "\n", "");
}

test "rap help" {
    try testRun(&.{"help"}, .ok, usage, "");
}

test "rap without a command is a usage error" {
    try testRun(&.{}, .usage, "", usage);
}

test "rap unknown command is a usage error" {
    try testRun(&.{"nope"}, .usage, "", "rap: unknown command 'nope'\n\n" ++ usage);
}

test "rap unknown flag is a usage error" {
    try testRun(&.{"--version"}, .usage, "", "rap: unknown command '--version'\n\n" ++ usage);
}

test "rap imports ghostty-vt" {
    std.testing.refAllDecls(vt);
}

test "rap exit codes" {
    try std.testing.expectEqual(0, @backingInt(ExitCode.ok));
    try std.testing.expectEqual(1, @backingInt(ExitCode.fail));
    try std.testing.expectEqual(2, @backingInt(ExitCode.usage));
    try std.testing.expectEqual(3, @backingInt(ExitCode.target));
    try std.testing.expectEqual(4, @backingInt(ExitCode.unreachable_server));
    try std.testing.expectEqual(130, @backingInt(ExitCode.interrupted));
}
