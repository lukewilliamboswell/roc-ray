const std = @import("std");
const builtin = @import("builtin");

/// Roc target definitions for native platforms
/// Maps to vendored raylib library directories
const RocTarget = enum {
    // x64 (x86_64) targets
    x64mac,
    x64win,
    x64glibc,

    // arm64 (aarch64) targets
    arm64mac,

    fn toZigTarget(self: RocTarget) std.Target.Query {
        return switch (self) {
            .x64mac => .{ .cpu_arch = .x86_64, .os_tag = .macos },
            .x64win => .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
            .x64glibc => .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
            .arm64mac => .{ .cpu_arch = .aarch64, .os_tag = .macos },
        };
    }

    fn targetDir(self: RocTarget) []const u8 {
        return switch (self) {
            .x64mac => "x64mac",
            .x64win => "x64win",
            .x64glibc => "x64glibc",
            .arm64mac => "arm64mac",
        };
    }

    fn libFilename(self: RocTarget) []const u8 {
        return switch (self) {
            .x64win => "host.lib",
            else => "libhost.a",
        };
    }

    /// Get the vendored raylib library directory for this target
    fn vendoredRaylibDir(self: RocTarget) []const u8 {
        return switch (self) {
            .x64mac, .arm64mac => "macos",
            .x64glibc => "linux-x64",
            .x64win => "windows-x64",
        };
    }
};

/// All cross-compilation targets for `zig build`
/// Only includes targets that have vendored raylib libraries available
const all_native_targets = [_]RocTarget{
    .x64mac,
    .arm64mac,
    .x64glibc,
    // Note: arm64glibc, arm64win, x64win excluded - missing raylib libraries
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Get the roc dependency and its builtins module
    const roc_dep = b.dependency("roc", .{});
    const builtins_module = roc_dep.module("builtins");

    // Cleanup step: remove all generated build artifacts
    const cleanup_step = b.step("clean", "Remove all built library files");
    for (all_native_targets) |roc_target| {
        cleanup_step.dependOn(&CleanupStep.create(b, b.path(
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libFilename() }),
        )).step);
    }
    // Clean wasm32 target (including old raylib/libc artifacts)
    cleanup_step.dependOn(&CleanupStep.create(b, b.path("platform/targets/wasm32/libhost.a")).step);
    cleanup_step.dependOn(&CleanupStep.create(b, b.path("platform/targets/wasm32/libraylib.a")).step);
    cleanup_step.dependOn(&CleanupStep.create(b, b.path("platform/targets/wasm32/libwasm_libc.a")).step);
    // Clean legacy locations
    cleanup_step.dependOn(&CleanupStep.create(b, b.path("platform/libhost.a")).step);
    cleanup_step.dependOn(&CleanupStep.create(b, b.path("platform/host.lib")).step);

    // Default step: build for all targets (native + wasm32)
    const all_step = b.getInstallStep();
    all_step.dependOn(cleanup_step);

    // Generate X11 stubs step (needed for Linux cross-compilation)
    const x11_stubs_step = b.step("generate-x11-stubs", "Generate X11 stub libraries for Linux cross-compilation");
    const x11_stub_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu });
    const gen_stubs = generateX11Stubs(b, x11_stub_target);
    x11_stubs_step.dependOn(gen_stubs);

    // Create copy step for all targets
    const copy_all = b.addUpdateSourceFiles();
    all_step.dependOn(&copy_all.step);

    // Build for each native Roc target
    for (all_native_targets) |roc_target| {
        const target = b.resolveTargetQuery(roc_target.toZigTarget());
        const build_result = buildHostLib(b, target, optimize, builtins_module, roc_target);

        // For Linux targets, ensure X11 stubs are generated first
        if (target.result.os.tag == .linux) {
            build_result.host_lib.step.dependOn(gen_stubs);
        }

        // Copy libhost.a to platform/targets/{target}/
        copy_all.addCopyFileToSource(
            build_result.host_lib.getEmittedBin(),
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libFilename() }),
        );

        // Copy vendored libraylib.a to platform/targets/{target}/
        copy_all.addCopyFileToSource(
            build_result.raylib_archive,
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), "libraylib.a" }),
        );

        // Copy libc.so stub for Linux targets
        if (build_result.libc_stub) |libc_stub| {
            copy_all.addCopyFileToSource(
                libc_stub,
                b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), "libc.so" }),
            );
        }

        // Copy libm.so stub for Linux targets
        if (build_result.libm_stub) |libm_stub| {
            copy_all.addCopyFileToSource(
                libm_stub,
                b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), "libm.so" }),
            );
        }
    }

    // ========================================================================
    // WASM32 target: command-buffer based rendering (no raylib/emscripten)
    // ========================================================================
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_host = b.addLibrary(.{
        .name = "host",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("platform/host_web.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .strip = false, // Preserve debug info for better error messages
            .imports = &.{
                .{ .name = "builtins", .module = builtins_module },
            },
        }),
    });

    // Copy libhost.a to platform/targets/wasm32/
    copy_all.addCopyFileToSource(
        wasm_host.getEmittedBin(),
        "platform/targets/wasm32/libhost.a",
    );

    // Copy JS runtime and HTML to platform/web/
    copy_all.addCopyFileToSource(b.path("platform/web/host.js"), "platform/web/host.js");
    copy_all.addCopyFileToSource(b.path("platform/web/index.html"), "platform/web/index.html");

    // ========================================================================
    // Test step: Zig unit tests + WASM integration tests
    // ========================================================================
    const test_step = b.step("test", "Run all tests");

    // Zig unit tests for host_native.zig
    const native_target = b.standardTargetOptions(.{});
    const native_roc_target = detectNativeRocTarget(native_target.result);

    if (native_roc_target) |roc_target| {
        const raylib_lib_dir = b.pathJoin(&.{ "vendor", "raylib", roc_target.vendoredRaylibDir() });

        const native_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("platform/host_native.zig"),
                .target = native_target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "builtins", .module = builtins_module },
                },
            }),
        });
        native_tests.root_module.addIncludePath(b.path("vendor/raylib/include"));
        native_tests.root_module.addLibraryPath(b.path(raylib_lib_dir));
        native_tests.linkSystemLibrary("raylib");
        native_tests.linkLibC();
        const run_native_tests = b.addRunArtifact(native_tests);
        test_step.dependOn(&run_native_tests.step);
    }

    // Zig unit tests for host_web.zig (runs natively, tests pure command buffer logic)
    const web_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("platform/host_web.zig"),
            .target = native_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "builtins", .module = builtins_module },
            },
        }),
    });
    const run_web_tests = b.addRunArtifact(web_tests);
    test_step.dependOn(&run_web_tests.step);

    // Build standalone test WASM module (exports test functions, no Roc app)
    const wasm_test_exe = b.addExecutable(.{
        .name = "host_web",
        .root_module = b.createModule(.{
            .root_source_file = b.path("platform/host_web.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .strip = false,
            .imports = &.{
                .{ .name = "builtins", .module = builtins_module },
            },
        }),
    });
    wasm_test_exe.entry = .disabled;
    wasm_test_exe.rdynamic = true;

    const install_test_wasm = b.addInstallFile(wasm_test_exe.getEmittedBin(), "web-test/host_web.wasm");

    // Run Node.js integration tests
    const node_test = b.addSystemCommand(&.{ "node", "ci/wasm-test.mjs" });
    node_test.step.dependOn(&install_test_wasm.step);
    test_step.dependOn(&node_test.step);
}

/// Detect which RocTarget matches the native platform
fn detectNativeRocTarget(target: std.Target) ?RocTarget {
    return switch (target.os.tag) {
        .macos => switch (target.cpu.arch) {
            .x86_64 => .x64mac,
            .aarch64 => .arm64mac,
            else => null,
        },
        .linux => switch (target.cpu.arch) {
            .x86_64 => .x64glibc,
            else => null,
        },
        .windows => switch (target.cpu.arch) {
            .x86_64 => .x64win,
            else => null,
        },
        else => null,
    };
}

/// Custom step to remove a single file if it exists
const CleanupStep = struct {
    step: std.Build.Step,
    path: std.Build.LazyPath,

    fn create(b: *std.Build, path: std.Build.LazyPath) *CleanupStep {
        const self = b.allocator.create(CleanupStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "cleanup",
                .owner = b,
                .makeFn = make,
            }),
            .path = path,
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *CleanupStep = @fieldParentPtr("step", step);
        const path = self.path.getPath2(step.owner, null);
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};

const BuildResult = struct {
    host_lib: *std.Build.Step.Compile,
    raylib_archive: std.Build.LazyPath,
    libc_stub: ?std.Build.LazyPath,
    libm_stub: ?std.Build.LazyPath,
};

/// X11 libraries that raylib depends on (need stubs for cross-compilation)
const x11_libs = [_][]const u8{
    "GLX", "X11", "Xcursor", "Xext", "Xfixes", "Xi", "Xinerama", "Xrandr", "Xrender",
};

/// Generate X11 stub libraries for Linux cross-compilation
fn generateX11Stubs(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const copy_stubs = b.addUpdateSourceFiles();

    for (x11_libs) |lib_name| {
        const stub_content = std.fmt.allocPrint(b.allocator,
            \\__attribute__((weak)) void __stub_{s}(void) {{}}
            \\
        , .{lib_name}) catch @panic("OOM");

        const write_files = b.addWriteFiles();
        const stub_filename = std.fmt.allocPrint(b.allocator, "stub_{s}.c", .{lib_name}) catch @panic("OOM");
        const stub_file = write_files.add(stub_filename, stub_content);

        const stub_lib = b.addLibrary(.{
            .name = lib_name,
            .linkage = .static,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = .ReleaseSmall,
            }),
        });
        stub_lib.addCSourceFile(.{ .file = stub_file });

        copy_stubs.addCopyFileToSource(
            stub_lib.getEmittedBin(),
            std.fmt.allocPrint(b.allocator, "platform/targets/linux-x11-stubs/lib{s}.a", .{lib_name}) catch @panic("OOM"),
        );
    }

    return &copy_stubs.step;
}

/// Generate libc stub shared library with SONAME libc.so.6
fn generateLibcStub(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const stub_lib = b.addLibrary(.{
        .name = "c",
        .linkage = .dynamic,
        .version = .{ .major = 6, .minor = 0, .patch = 0 },
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });

    const stub_path = switch (target.result.cpu.arch) {
        .x86_64 => "platform/targets/x64glibc/libc_stub.s",
        .aarch64 => "platform/targets/arm64glibc/libc_stub.s",
        else => @panic("Unsupported architecture for libc stub"),
    };
    stub_lib.addAssemblyFile(b.path(stub_path));
    return stub_lib;
}

/// Generate libm stub shared library with SONAME libm.so.6
fn generateLibmStub(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const stub_lib = b.addLibrary(.{
        .name = "m",
        .linkage = .dynamic,
        .version = .{ .major = 6, .minor = 0, .patch = 0 },
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });

    const stub_path = switch (target.result.cpu.arch) {
        .x86_64 => "platform/targets/x64glibc/libm_stub.s",
        .aarch64 => "platform/targets/arm64glibc/libm_stub.s",
        else => @panic("Unsupported architecture for libm stub"),
    };
    stub_lib.addAssemblyFile(b.path(stub_path));
    return stub_lib;
}

fn buildHostLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    builtins_module: *std.Build.Module,
    roc_target: RocTarget,
) BuildResult {
    const raylib_include_path = b.path("vendor/raylib/include");
    const raylib_lib_dir = b.pathJoin(&.{ "vendor", "raylib", roc_target.vendoredRaylibDir() });
    const raylib_lib_path = b.path(raylib_lib_dir);

    const host_lib = b.addLibrary(.{
        .name = "host",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("platform/host_native.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .pic = true,
            .imports = &.{
                .{ .name = "builtins", .module = builtins_module },
            },
        }),
    });

    host_lib.root_module.addIncludePath(raylib_include_path);
    host_lib.root_module.addLibraryPath(raylib_lib_path);

    if (target.result.os.tag == .macos) {
        const sysroot_frameworks = b.path("platform/targets/macos-sysroot/System/Library/Frameworks");
        const sysroot_lib = b.path("platform/targets/macos-sysroot/usr/lib");
        host_lib.root_module.addSystemFrameworkPath(sysroot_frameworks);
        host_lib.root_module.addLibraryPath(sysroot_lib);
    }

    if (target.result.os.tag == .linux) {
        const stubs_path = b.path("platform/targets/linux-x11-stubs");
        host_lib.root_module.addLibraryPath(stubs_path);
        host_lib.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    }

    host_lib.bundle_compiler_rt = true;

    const raylib_archive = b.path(b.pathJoin(&.{ raylib_lib_dir, "libraylib.a" }));

    const libc_stub: ?std.Build.LazyPath = if (target.result.os.tag == .linux) blk: {
        const stub = generateLibcStub(b, target);
        break :blk stub.getEmittedBin();
    } else null;

    const libm_stub: ?std.Build.LazyPath = if (target.result.os.tag == .linux) blk: {
        const stub = generateLibmStub(b, target);
        break :blk stub.getEmittedBin();
    } else null;

    return .{
        .host_lib = host_lib,
        .raylib_archive = raylib_archive,
        .libc_stub = libc_stub,
        .libm_stub = libm_stub,
    };
}
