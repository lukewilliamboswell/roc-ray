const std = @import("std");
const raylib = @import("raylib/build.zig");
const raygui = @import("raygui/build.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    // Create a static library
    const lib = b.addStaticLibrary(.{
        .name = "roc-ray",
        .root_source_file = .{ .path = "platform/host.zig" },
        .target = target,
        .optimize = mode,
        .link_libc = true,
    });

    lib.force_pic = true;
    lib.disable_stack_probing = true;

    raylib.addTo(b, lib, target, mode, .{});
    raygui.addTo(b, lib, target, mode);

    b.installArtifact(lib);

    // Create a binary
    // const bin = b.addExecutable(.{
    //     .name = "roc-raygui-bin",
    //     .root_source_file = .{ .path = "platform/host.zig" },
    //     .target = target,
    //     .optimize = mode,
    //     .link_libc = true,
    // });

    // raylib.addTo(b, bin, target, mode, .{});
    // raygui.addTo(b, bin, target, mode);

    // b.installArtifact(bin);
}
