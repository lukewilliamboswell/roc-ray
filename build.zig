const std = @import("std");

pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const roc_src = b.option([]const u8, "app", "the roc application to build");

    const build_roc = b.addExecutable(.{
        .name = "build_roc",
        .root_source_file = b.path("build_roc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_build_roc = b.addRunArtifact(build_roc);
    // By setting this to true, we ensure zig always rebuilds the roc app since it can't tell if any transitive dependencies have changed.
    run_build_roc.stdio = .inherit;
    run_build_roc.has_side_effects = true;

    if (roc_src) |val| {
        run_build_roc.addFileArg(b.path(val));
    } else {
        run_build_roc.addFileArg(b.path("examples/basic-shapes.roc"));
    }

    switch (optimize) {
        .ReleaseFast, .ReleaseSafe => {
            run_build_roc.addArg("--optimize");
        },
        .ReleaseSmall => {
            run_build_roc.addArg("--opt-size");
        },
        else => {},
    }

    const raylib_dep = b.dependency("raylib-zig", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "rocray",
        .root_source_file = b.path("host/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const raylib = raylib_dep.module("raylib"); // main raylib module
    const raygui = raylib_dep.module("raygui"); // raygui module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library

    exe.step.dependOn(&run_build_roc.step);

    exe.addObjectFile(b.path("app.o"));
    exe.linkLibrary(raylib_artifact);

    exe.root_module.addImport("raylib", raylib);
    exe.root_module.addImport("raygui", raygui);

    b.installArtifact(exe);
}
