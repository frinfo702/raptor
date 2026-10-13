//! Ghostty's shell integration for the shells the server starts. A
//! surface sets it up in termio's Exec; blocks are started by the server
//! instead, so it does the same here from the user's Ghostty config.
const std = @import("std");
const EnvMap = std.process.Environ.Map;
const configpkg = @import("../config.zig");
const global = @import("../global.zig");
const shell_integration = @import("../termio/shell_integration.zig");

const log = std.log.scoped(.rap_shell);

/// The config keys that shape the integration, and where its scripts are.
pub const Integration = struct {
    mode: configpkg.Config.ShellIntegration = .detect,
    features: configpkg.ShellIntegrationFeatures = .{},
    cursor_blink: bool = true,
    /// Ghostty's resources directory. Without it nothing is injected.
    resources_dir: ?[]const u8 = null,

    /// Read the user's Ghostty config, falling back to its defaults.
    /// Command-line arguments are the server's own and not config.
    pub fn load(alloc: std.mem.Allocator) Integration {
        var self: Integration = .{ .resources_dir = resourcesDir(alloc) };
        var cfg = configpkg.Config.default(alloc) catch return self;
        defer cfg.deinit();
        cfg.loadDefaultFiles(alloc) catch |err| log.warn("loading Ghostty config failed: {t}", .{err});
        cfg.loadRecursiveFiles(alloc) catch |err| log.warn("loading Ghostty config failed: {t}", .{err});
        cfg.finalize() catch |err| log.warn("finalizing Ghostty config failed: {t}", .{err});
        self.mode = cfg.@"shell-integration";
        self.features = cfg.@"shell-integration-features";
        self.cursor_blink = cfg.@"cursor-style-blink" orelse true;
        return self;
    }

    /// Set up `env` for running `args` and return the command to run
    /// instead, as Exec does: GHOSTTY_SHELL_FEATURES always, the shell's
    /// startup files unless the mode is `none` or the shell is unknown.
    pub fn apply(
        self: Integration,
        arena: std.mem.Allocator,
        args: []const [:0]const u8,
        env: *EnvMap,
    ) ![]const [:0]const u8 {
        try shell_integration.setupFeatures(env, self.features, self.cursor_blink);
        const dir = self.resources_dir orelse return args;
        try env.put("GHOSTTY_RESOURCES_DIR", dir);
        if (self.mode == .none) return args;

        // The other modes are named after the shell they force.
        const force = std.meta.stringToEnum(shell_integration.Shell, @tagName(self.mode));
        const result = try shell_integration.setup(arena, dir, .{ .direct = args }, env, force) orelse
            return args;
        return switch (result.command) {
            .direct => |v| v,
            // Exec runs these through /bin/sh too; exec keeps the shell
            // the block's own child.
            .shell => |v| try arena.dupe([:0]const u8, &.{
                "/bin/sh", "-c", try arena.printSentinel("exec {s}", .{v}, 0),
            }),
        };
    }
};

/// Ghostty's resources directory. A `zig build rap` installs only the
/// shell integration beside rap, which the usual search does not find.
fn resourcesDir(alloc: std.mem.Allocator) ?[]const u8 {
    if (global.resourcesDir().app()) |dir| return dir;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = buf[0 .. std.process.executablePath(global.io(), &buf) catch return null];
    const bin = std.fs.path.dirname(exe) orelse return null;
    const dir = std.fs.path.resolve(alloc, &.{ bin, "..", "share", "ghostty" }) catch return null;
    const integ = std.fs.path.join(alloc, &.{ dir, "shell-integration" }) catch return null;
    std.Io.Dir.accessAbsolute(global.io(), integ, .{}) catch return null;
    return dir;
}

const testing = std.testing;

/// A resources directory with the zsh and bash integration in it.
fn tmpResources(tmp: *testing.TmpDir, alloc: std.mem.Allocator) ![]const u8 {
    try tmp.dir.createDirPath(testing.io, "shell-integration/zsh");
    try tmp.dir.createDirPath(testing.io, "shell-integration/bash");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shell-integration/bash/ghostty.bash", .data = "" });
    return tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
}

test "rex shell: integration decision" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const res = try tmpResources(&tmp, alloc);
    const zdotdir = try std.fs.path.join(alloc, &.{ res, "shell-integration/zsh" });

    const Case = struct {
        integ: Integration,
        args: []const [:0]const u8,
        /// The command expected to run, or null for `args` unchanged.
        want: ?[]const [:0]const u8 = null,
        zdotdir: bool = false,
    };
    const cases = [_]Case{
        // Detected from the program's name, as Ghostty does.
        .{ .integ = .{ .resources_dir = res }, .args = &.{"/usr/local/bin/zsh"}, .zdotdir = true },
        .{ .integ = .{ .resources_dir = res }, .args = &.{ "bash", "-l" }, .want = &.{ "/bin/sh", "-c", "exec bash --posix -l" } },
        .{ .integ = .{ .resources_dir = res }, .args = &.{"/bin/sh"} },
        // Bash running a command is never interactive.
        .{ .integ = .{ .resources_dir = res }, .args = &.{ "bash", "-c", "true" } },
        // `none` turns it off; a named shell forces it.
        .{ .integ = .{ .resources_dir = res, .mode = .none }, .args = &.{"zsh"} },
        .{ .integ = .{ .resources_dir = res, .mode = .zsh }, .args = &.{"/opt/my-shell"}, .zdotdir = true },
        // Without the scripts there is nothing to inject.
        .{ .integ = .{}, .args = &.{"zsh"} },
    };
    for (cases) |c| {
        var env: EnvMap = .init(alloc);
        const got = try c.integ.apply(alloc, c.args, &env);
        const want = c.want orelse c.args;
        try testing.expectEqual(want.len, got.len);
        for (want, got) |w, g| try testing.expectEqualStrings(w, g);
        if (c.zdotdir) {
            try testing.expectEqualStrings(zdotdir, env.get("ZDOTDIR").?);
        } else {
            try testing.expect(env.get("ZDOTDIR") == null);
        }
        try testing.expectEqualStrings("cursor:blink,path,title", env.get("GHOSTTY_SHELL_FEATURES") orelse "");
        try testing.expectEqual(c.integ.resources_dir != null, env.get("GHOSTTY_RESOURCES_DIR") != null);
    }
}
