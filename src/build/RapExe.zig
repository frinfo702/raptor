//! The `rap` executable: the Raptor command line tool. Unlike the main
//! Ghostty executable this is built regardless of the app runtime so that
//! it is available on macOS, where the app is built by Xcode.
const RapExe = @This();

const std = @import("std");
const Config = @import("Config.zig");
const GhosttyZig = @import("GhosttyZig.zig");

/// The rap executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

/// Runs the rap unit tests.
test_run: *std.Build.Step.Run,

pub fn init(
    b: *std.Build,
    cfg: *const Config,
    mod: *const GhosttyZig,
    test_filters: []const []const u8,
) RapExe {
    const options = mod.vt.import_table.get("build_options").?;

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
    });
    exe.root_module.addImport("build_options", options);
    exe.root_module.addImport("ghostty-vt", mod.vt);
    if (cfg.pie) exe.pie = true;

    const test_exe = b.addTest(.{
        .name = "rap-test",
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_rap.zig"),
            .target = cfg.baselineTarget(b.graph.io),
            .optimize = .debug,
        }),
    });
    test_exe.root_module.addImport("build_options", options);
    test_exe.root_module.addImport("ghostty-vt", mod.vt);

    return .{
        .exe = exe,
        .install_step = b.addInstallArtifact(exe, .{}),
        .test_run = b.addRunArtifact(test_exe),
    };
}

/// Add the rap exe to the install target.
pub fn install(self: *const RapExe) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}
