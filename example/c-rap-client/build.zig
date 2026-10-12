const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run the app");

    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{"main.c"},
    });

    // Exe
    const exe = b.addExecutable(.{
        .name = "c_rap_client",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    // You'll want to use a lazy dependency here so that ghostty is only
    // downloaded if you actually need it.
    if (b.lazyDependency("ghostty", .{
        // The full libghostty, which has the rap client, rather than
        // only libghostty-vt.
        .@"emit-lib-vt" = false,
        .@"app-runtime" = .none,
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
    })) |dep| {
        exe_mod.addIncludePath(dep.path("include"));
        const lib = dep.namedLazyPath("ghostty");
        exe_mod.addObjectFile(lib);
        exe_mod.addRPath(lib.dirname());

        // The example runs a test server with this rap.
        run_cmd.addArtifactArg(dep.artifact("rap"));
    }
}
