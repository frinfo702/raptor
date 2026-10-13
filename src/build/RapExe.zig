//! The `rap` executable: the Raptor command line tool and server. Unlike
//! the main Ghostty executable this is built regardless of the app runtime
//! so that it is available on macOS, where the app is built by Xcode.
const RapExe = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

/// The rap executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

/// Runs the rap unit tests.
test_run: *std.Build.Step.Run,

pub fn init(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    test_filters: []const []const u8,
) !RapExe {
    const exe = b.addExecutable(.{
        .name = "rap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_rap.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
            .omit_frame_pointer = cfg.omitFramePointer(),
            .unwind_tables = if (cfg.strip) .none else .sync,
        }),
        // Crashes on x86_64 self-hosted on 0.15.1
        .use_llvm = true,
    });
    // The server hosts the same terminal core as the app, so it needs the
    // app's modules rather than only ghostty-vt.
    _ = try deps.add(exe);
    if (cfg.pie) exe.pie = true;

    const test_exe = b.addTest(.{
        .name = "rap-test",
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_rap.zig"),
            .target = cfg.baselineTarget(b.graph.io),
            .optimize = .debug,
        }),
        // Crash on x86_64 without this
        .use_llvm = true,
    });
    _ = try deps.add(test_exe);

    const install_step = b.addInstallArtifact(exe, .{});
    // The server injects Ghostty's shell integration into its shells.
    install_step.step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("src/shell-integration"),
        .install_dir = .{ .custom = "share" },
        .install_subdir = b.pathJoin(&.{ "ghostty", "shell-integration" }),
        .exclude_extensions = &.{".md"},
    }).step);
    cfg.addPatchElf(exe, &install_step.step);

    const test_run = b.addRunArtifact(test_exe);
    cfg.addPatchElf(test_exe, &test_run.step);

    return .{
        .exe = exe,
        .install_step = install_step,
        .test_run = test_run,
    };
}

/// Add the rap exe to the install target.
pub fn install(self: *const RapExe) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}
