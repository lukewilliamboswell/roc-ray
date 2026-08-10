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
            .x64win => .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc },
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

    /// Get the raylib library filename for this target
    fn raylibFilename(self: RocTarget) []const u8 {
        return switch (self) {
            .x64win => "raylib.lib",
            else => "libraylib.a",
        };
    }

    /// Get the GIF encoder archive filename for this target
    fn msfGifFilename(self: RocTarget) []const u8 {
        return switch (self) {
            .x64win => "msf_gif.lib",
            else => "libmsf_gif.a",
        };
    }

    /// Get the VP8 encoder archive filename for this target
    fn libvpxFilename(self: RocTarget) []const u8 {
        return switch (self) {
            .x64win => "vpx.lib",
            else => "libvpx.a",
        };
    }

    /// libvpx is configured per CPU architecture, not per OS: the generated
    /// headers only vary in which `VPX_ARCH_*`/`HAVE_<simd>` are set, and both
    /// macOS targets share theirs with the Linux/Windows target of the same
    /// architecture. See vendor/libvpx/config/README.md.
    fn libvpxConfigDir(self: RocTarget) []const u8 {
        return switch (self) {
            .x64mac, .x64win, .x64glibc => "vendor/libvpx/config/x86_64",
            .arm64mac => "vendor/libvpx/config/arm64",
        };
    }

    /// The SIMD sources matching that config.
    fn libvpxSimdSources(self: RocTarget) []const []const u8 {
        return switch (self) {
            .x64mac, .x64win, .x64glibc => &libvpx_x86_64_sources,
            .arm64mac => &libvpx_arm64_sources,
        };
    }
};

/// All cross-compilation targets for `zig build`
/// Only includes targets that have vendored raylib libraries available
const all_native_targets = [_]RocTarget{
    .x64mac,
    .arm64mac,
    .x64glibc,
    .x64win,
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const run_roc_tests = b.option(
        bool,
        "roc-tests",
        "Run Roc example tests as part of `zig build test`",
    ) orelse true;

    // Cleanup step: remove all generated build artifacts
    const cleanup_step = b.step("clean", "Remove all built library files");
    for (all_native_targets) |roc_target| {
        cleanup_step.dependOn(&CleanupStep.create(b, b.path(
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libFilename() }),
        )).step);
        cleanup_step.dependOn(&CleanupStep.create(b, b.path(
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.msfGifFilename() }),
        )).step);
        cleanup_step.dependOn(&CleanupStep.create(b, b.path(
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libvpxFilename() }),
        )).step);
    }
    // Clean legacy locations
    cleanup_step.dependOn(&CleanupStep.create(b, b.path("platform/libhost.a")).step);
    cleanup_step.dependOn(&CleanupStep.create(b, b.path("platform/host.lib")).step);

    // Generate X11 stubs step (needed for Linux cross-compilation)
    const x11_stubs_step = b.step("generate-x11-stubs", "Generate X11 stub libraries for Linux cross-compilation");
    const x11_stub_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu });
    const gen_stubs = generateX11Stubs(b, x11_stub_target);
    x11_stubs_step.dependOn(gen_stubs);

    // Create copy step for all targets
    const copy_all = b.addUpdateSourceFiles();
    copy_all.step.dependOn(cleanup_step);

    // Default step: build the host library for all native targets. Ensure the
    // cleanup completes before generated libraries are copied into the source
    // tree; sibling dependencies would be free to run in either order.
    const all_step = b.getInstallStep();
    all_step.dependOn(&copy_all.step);

    // Generate Windows import libraries (needed for Windows cross-compilation)
    generateWindowsImportLibs(b, copy_all);

    // Build for each native Roc target
    for (all_native_targets) |roc_target| {
        const target = b.resolveTargetQuery(roc_target.toZigTarget());
        const build_result = buildHostLib(b, target, optimize, roc_target);

        // For Linux targets, ensure X11 stubs are generated first
        if (target.result.os.tag == .linux) {
            build_result.host_lib.step.dependOn(gen_stubs);
        }

        // Copy libhost.a to platform/targets/{target}/
        copy_all.addCopyFileToSource(
            build_result.host_lib.getEmittedBin(),
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libFilename() }),
        );

        // Copy vendored raylib library to platform/targets/{target}/
        copy_all.addCopyFileToSource(
            build_result.raylib_archive,
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.raylibFilename() }),
        );

        // Copy the GIF encoder archive to platform/targets/{target}/
        copy_all.addCopyFileToSource(
            build_result.msf_gif_archive,
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.msfGifFilename() }),
        );

        // Copy the VP8 encoder archive to platform/targets/{target}/
        copy_all.addCopyFileToSource(
            build_result.libvpx_archive,
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libvpxFilename() }),
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

        // Copy libX11.so stub for Linux targets
        if (build_result.x11_stub) |x11_stub| {
            copy_all.addCopyFileToSource(
                x11_stub,
                b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), "libX11.so" }),
            );
        }
    }

    const test_step = b.step("test", "Run all tests");
    const lint_step = b.step("lint", "Run code quality lints");

    // Run lints as part of tests
    test_step.dependOn(lint_step);

    // Zig unit tests for host_native.zig
    const native_target = b.standardTargetOptions(.{});

    // Build and run tidy.zig (tidiness checks: CRLF, banned patterns, dead code, etc.)
    const tidy = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/tidy.zig"),
            .target = native_target,
            .optimize = .Debug,
        }),
    });
    const run_tidy = b.addRunArtifact(tidy);
    run_tidy.setCwd(b.path(".")); // Run from project root
    lint_step.dependOn(&run_tidy.step);

    // Build and run zig_lints.zig (style checks: doc comments, separator comments)
    const zig_lints = b.addExecutable(.{
        .name = "zig_lints",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/zig_lints.zig"),
            .target = native_target,
            .optimize = .Debug,
        }),
    });
    const run_lints = b.addRunArtifact(zig_lints);
    run_lints.setCwd(b.path(".")); // Run from project root
    lint_step.dependOn(&run_lints.step);

    const glue_helper_tests = b.addSystemCommand(&.{
        "python3",
        "scripts/test_roc_platform_abi.py",
    });
    glue_helper_tests.setCwd(b.path("."));
    test_step.dependOn(&glue_helper_tests.step);

    const app_transport_privacy_tests = b.addSystemCommand(&.{
        "python3",
        "scripts/test_app_transport_privacy.py",
    });
    app_transport_privacy_tests.setCwd(b.path("."));
    test_step.dependOn(&app_transport_privacy_tests.step);

    const asset_manifest_tests = b.addSystemCommand(&.{
        "python3",
        "scripts/test_asset_manifest.py",
    });
    asset_manifest_tests.setCwd(b.path("."));
    test_step.dependOn(&asset_manifest_tests.step);

    // The platform's re-export shims for `roc-ray-types` modules are generated,
    // so a hand-edit there would silently diverge from the package.
    const reexport_shims_check = b.addSystemCommand(&.{
        "python3",
        "scripts/generate_reexports.py",
        "--check",
    });
    reexport_shims_check.setCwd(b.path("."));
    test_step.dependOn(&reexport_shims_check.step);

    const native_roc_target = detectNativeRocTarget(native_target.result);

    if (native_roc_target) |roc_target| {
        const native_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/host_native.zig"),
                .target = native_target,
                .optimize = optimize,
            }),
        });
        native_tests.root_module.addIncludePath(b.path("vendor/raylib/include"));
        native_tests.root_module.link_libc = true;
        const run_native_tests = b.addRunArtifact(native_tests);
        test_step.dependOn(&run_native_tests.step);

        // SIMD/C parity for the vendored libvpx. This has to run *on* the
        // target -- it is the only check that a NEON or SSE2 kernel actually
        // computes what its C counterpart does, and an arm64 build swaps out
        // ~200 of them. Native target on purpose: cross-compiling it would
        // build the kernels without ever executing them.
        const parity_target_arch: RocTarget = switch (native_target.result.cpu.arch) {
            .aarch64 => .arm64mac,
            else => .x64glibc,
        };
        const parity_config_dir = parity_target_arch.libvpxConfigDir();

        const parity = b.addExecutable(.{
            .name = "libvpx-parity",
            .root_module = b.createModule(.{
                .target = native_target,
                .optimize = optimize,
                .sanitize_c = .off,
            }),
        });
        parity.root_module.addIncludePath(b.path("vendor/libvpx"));
        parity.root_module.addIncludePath(b.path(parity_config_dir));
        parity.root_module.addIncludePath(b.path("vendor/libvpx/test"));
        parity.root_module.addCSourceFiles(.{
            .root = b.path("vendor/libvpx"),
            .files = &.{"test/simd_parity.c"},
            .flags = &libvpx_flags,
        });
        parity.root_module.addCSourceFiles(.{
            .root = b.path(parity_config_dir),
            .files = &.{"simd_parity_table.c"},
            .flags = &libvpx_flags,
        });
        parity.root_module.linkLibrary(buildLibvpx(b, native_target, optimize, parity_target_arch));
        parity.root_module.link_libc = true;

        const run_parity = b.addRunArtifact(parity);
        const parity_step = b.step(
            "libvpx-parity",
            "Check the vendored libvpx SIMD kernels against their C references",
        );
        parity_step.dependOn(&run_parity.step);
        test_step.dependOn(&run_parity.step);

        // Pixel-level rendering checks need a real graphics context, so keep
        // them opt-in for local/CI runs with a display (for example xvfb-run).
        const raylib_lib_dir = b.pathJoin(&.{ "vendor", "raylib", roc_target.vendoredRaylibDir() });
        const graphical_smoke = b.addExecutable(.{
            .name = "graphical-smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/graphical_smoke.zig"),
                .target = native_target,
                .optimize = optimize,
            }),
        });
        graphical_smoke.root_module.addIncludePath(b.path("vendor/raylib/include"));
        graphical_smoke.root_module.addLibraryPath(b.path(raylib_lib_dir));
        graphical_smoke.root_module.linkSystemLibrary("raylib", .{});
        switch (native_target.result.os.tag) {
            .linux => graphical_smoke.root_module.linkSystemLibrary("X11", .{}),
            .macos => {
                graphical_smoke.root_module.linkFramework("Cocoa", .{});
                graphical_smoke.root_module.linkFramework("IOKit", .{});
                graphical_smoke.root_module.linkFramework("CoreVideo", .{});
                graphical_smoke.root_module.linkFramework("OpenGL", .{});
            },
            .windows => {
                inline for (windows_import_libs) |lib_name| {
                    graphical_smoke.root_module.linkSystemLibrary(lib_name, .{});
                }
            },
            else => {},
        }
        graphical_smoke.root_module.link_libc = true;
        const run_graphical_smoke = b.addRunArtifact(graphical_smoke);
        const graphical_smoke_step = b.step("graphical-smoke", "Run pixel-level rendering smoke tests (requires a display)");
        graphical_smoke_step.dependOn(&run_graphical_smoke.step);
    }

    if (run_roc_tests) {
        // Run Roc tests (check, fmt, test, build)
        const roc_tests = b.addSystemCommand(&.{
            "python3",
            "scripts/all_tests.py",
            "--skip-platform-build",
        });
        roc_tests.setCwd(b.path(".")); // Run from project root
        roc_tests.step.dependOn(&copy_all.step);
        test_step.dependOn(&roc_tests.step);
    }
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
        const io = step.owner.graph.io;
        const path = self.path.getPath2(step.owner, null);
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};

const BuildResult = struct {
    host_lib: *std.Build.Step.Compile,
    raylib_archive: std.Build.LazyPath,
    msf_gif_archive: std.Build.LazyPath,
    libvpx_archive: std.Build.LazyPath,
    libc_stub: ?std.Build.LazyPath,
    libm_stub: ?std.Build.LazyPath,
    x11_stub: ?std.Build.LazyPath,
};

/// Compiler flags for the vendored libvpx.
///
/// gnu99, not c99: vpx_ports/vpx_timer.h uses clock_gettime and struct
/// timespec, which strict-ANSI mode hides behind __STRICT_ANSI__.
///
/// The stack protector and stack probes are disabled because the Windows
/// archive is compiled against mingw headers but linked into an MSVC-target
/// binary: those options emit calls to libgcc-only helpers (__stack_chk_fail,
/// __stack_chk_guard, ___chkstk_ms) that no MSVC CRT provides, and the link
/// fails. They cost nothing here -- this is a self-contained encoder fed
/// fixed-size frames, not a parser handling untrusted input.
const libvpx_flags = [_][]const u8{
    "-std=gnu99",
    "-Wno-unused-function",
    "-fno-stack-protector",
    "-mno-stack-arg-probe",
};

/// Architecture-independent VP8 encoder sources from the vendored libvpx.
///
/// This is the set libvpx's own configure selects for a
/// `--target=generic-gnu --disable-runtime-cpu-detect` VP8-encoder build, which
/// is every C source it compiles that is not under an architecture directory;
/// see vendor/libvpx/config/README.md. Each target adds the SIMD list for its
/// architecture on top, and `vpx_config.c` comes from its config directory.
const libvpx_sources = [_][]const u8{
    "vp8/common/alloccommon.c",
    "vp8/common/blockd.c",
    "vp8/common/dequantize.c",
    "vp8/common/entropy.c",
    "vp8/common/entropymode.c",
    "vp8/common/entropymv.c",
    "vp8/common/extend.c",
    "vp8/common/filter.c",
    "vp8/common/findnearmv.c",
    "vp8/common/generic/systemdependent.c",
    "vp8/common/idct_blk.c",
    "vp8/common/idctllm.c",
    "vp8/common/loopfilter_filters.c",
    "vp8/common/mbpitch.c",
    "vp8/common/modecont.c",
    "vp8/common/quant_common.c",
    "vp8/common/reconinter.c",
    "vp8/common/reconintra.c",
    "vp8/common/reconintra4x4.c",
    "vp8/common/rtcd.c",
    "vp8/common/setupintrarecon.c",
    "vp8/common/swapyv12buffer.c",
    "vp8/common/treecoder.c",
    "vp8/common/vp8_loopfilter.c",
    "vp8/common/vp8_skin_detection.c",
    "vp8/encoder/bitstream.c",
    "vp8/encoder/boolhuff.c",
    "vp8/encoder/copy_c.c",
    "vp8/encoder/dct.c",
    "vp8/encoder/denoising.c",
    "vp8/encoder/encodeframe.c",
    "vp8/encoder/encodeintra.c",
    "vp8/encoder/encodemb.c",
    "vp8/encoder/encodemv.c",
    "vp8/encoder/firstpass.c",
    "vp8/encoder/lookahead.c",
    "vp8/encoder/mcomp.c",
    "vp8/encoder/modecosts.c",
    "vp8/encoder/onyx_if.c",
    "vp8/encoder/pickinter.c",
    "vp8/encoder/picklpf.c",
    "vp8/encoder/ratectrl.c",
    "vp8/encoder/rdopt.c",
    "vp8/encoder/segmentation.c",
    "vp8/encoder/temporal_filter.c",
    "vp8/encoder/tokenize.c",
    "vp8/encoder/treewriter.c",
    "vp8/encoder/vp8_quantize.c",
    "vp8/vp8_cx_iface.c",
    "vpx/src/vpx_codec.c",
    "vpx/src/vpx_decoder.c",
    "vpx/src/vpx_encoder.c",
    "vpx/src/vpx_image.c",
    "vpx_dsp/bitwriter.c",
    "vpx_dsp/bitwriter_buffer.c",
    "vpx_dsp/intrapred.c",
    "vpx_dsp/prob.c",
    "vpx_dsp/psnr.c",
    "vpx_dsp/sad.c",
    "vpx_dsp/skin_detection.c",
    "vpx_dsp/sse.c",
    "vpx_dsp/subtract.c",
    "vpx_dsp/sum_squares.c",
    "vpx_dsp/variance.c",
    "vpx_dsp/vpx_dsp_rtcd.c",
    "vpx_mem/vpx_mem.c",
    "vpx_scale/generic/gen_scalers.c",
    "vpx_scale/generic/vpx_scale.c",
    "vpx_scale/generic/yv12config.c",
    "vpx_scale/generic/yv12extend.c",
    "vpx_scale/vpx_scale_rtcd.c",
    "vpx_util/vpx_thread.c",
    "vpx_util/vpx_write_yuv_frame.c",
};

/// SSE2 sources for the three x86-64 targets.
///
/// Short, because most of libvpx's x86 SIMD is NASM-syntax `.asm` that Zig
/// cannot assemble; these are the encoder kernels it happens to write as
/// compiler intrinsics. SSE2 is guaranteed by the x86-64 baseline, so no
/// runtime CPU detection is needed. Everything above SSE2 -- including the AVX2
/// files, which are also intrinsics -- is left out because nothing here checks
/// what the CPU supports. `vendor/libvpx/config/prune_rtcd.py` points the
/// dispatch entries these do *not* cover back at the C versions, so this list
/// and `config/x86_64/` have to be regenerated together.
const libvpx_x86_64_sources = [_][]const u8{
    "vp8/common/x86/bilinear_filter_sse2.c",
    "vp8/encoder/x86/vp8_quantize_sse2.c",
    "vpx_dsp/x86/variance_sse2.c",
};

/// NEON sources for the arm64 target.
///
/// Long, because on AArch64 libvpx writes all of it as intrinsics: the `.asm`
/// beside these files is 32-bit ARM only and `HAVE_NEON_ASM` is 0 for us. This
/// is the complete set configure selects for an arm64 VP8-encoder build, so
/// nothing is pruned out of `config/arm64/` and NEON covers the hot path.
const libvpx_arm64_sources = [_][]const u8{
    // The generated arm64 rtcd setup calls arm_cpu_caps(), so its definition
    // has to be compiled in. A static archive does not complain about an
    // unresolved reference, so leaving this out builds cleanly and then fails
    // at the final link of every arm64 app.
    "vpx_ports/aarch64_cpudetect.c",
    "vp8/common/arm/loopfilter_arm.c",
    "vp8/common/arm/neon/bilinearpredict_neon.c",
    "vp8/common/arm/neon/copymem_neon.c",
    "vp8/common/arm/neon/dc_only_idct_add_neon.c",
    "vp8/common/arm/neon/dequant_idct_neon.c",
    "vp8/common/arm/neon/dequantizeb_neon.c",
    "vp8/common/arm/neon/idct_blk_neon.c",
    "vp8/common/arm/neon/iwalsh_neon.c",
    "vp8/common/arm/neon/loopfiltersimplehorizontaledge_neon.c",
    "vp8/common/arm/neon/loopfiltersimpleverticaledge_neon.c",
    "vp8/common/arm/neon/mbloopfilter_neon.c",
    "vp8/common/arm/neon/shortidct4x4llm_neon.c",
    "vp8/common/arm/neon/sixtappredict_neon.c",
    "vp8/common/arm/neon/vp8_loopfilter_neon.c",
    "vp8/encoder/arm/neon/denoising_neon.c",
    "vp8/encoder/arm/neon/fastquantizeb_neon.c",
    "vp8/encoder/arm/neon/shortfdct_neon.c",
    "vp8/encoder/arm/neon/vp8_shortwalsh4x4_neon.c",
    "vpx_dsp/arm/avg_pred_neon.c",
    "vpx_dsp/arm/intrapred_neon.c",
    "vpx_dsp/arm/sad4d_neon.c",
    "vpx_dsp/arm/sad_neon.c",
    "vpx_dsp/arm/sse_neon.c",
    "vpx_dsp/arm/subpel_variance_neon.c",
    "vpx_dsp/arm/subtract_neon.c",
    "vpx_dsp/arm/sum_squares_neon.c",
    "vpx_dsp/arm/variance_neon.c",
};

/// X11 libraries that raylib depends on (need stubs for cross-compilation)
const x11_libs = [_][]const u8{
    "GLX", "X11", "Xcursor", "Xext", "Xfixes", "Xi", "Xinerama", "Xrandr", "Xrender",
};

/// Xlib functions that raylib 6.0's `GetClipboardImage()` (rcore.c) calls
/// directly, instead of going through GLFW's dlopen-loaded X11 like every other
/// X11 use. roc-ray never calls `GetClipboardImage`, but `rcore.o` is pulled
/// into the final executable link, so these symbols must resolve. We ship a
/// `libX11.so` stub (SONAME `libX11.so.6`) that declares them; at runtime the
/// real libX11 (already loaded by GLFW) provides the implementations. See
/// `generateX11SoStub` and the `x64glibc` link list in `platform/main.roc`.
const x11_clipboard_syms = [_][]const u8{
    "XConvertSelection", "XNextEvent",          "XGetWindowProperty", "XFree",
    "XDestroyWindow",    "XCreateSimpleWindow", "XInternAtom",
};

/// Windows system libraries that raylib depends on (need import libs for cross-compilation)
/// These are generated from MinGW DEF files (ZPL licensed) bundled with Zig
const windows_import_libs = [_][]const u8{
    "gdi32", "user32", "winmm", "opengl32", "shell32",
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
        stub_lib.root_module.addCSourceFile(.{ .file = stub_file });

        copy_stubs.addCopyFileToSource(
            stub_lib.getEmittedBin(),
            std.fmt.allocPrint(b.allocator, "platform/targets/linux-x11-stubs/lib{s}.a", .{lib_name}) catch @panic("OOM"),
        );
    }

    return &copy_stubs.step;
}

/// Generate Windows import libraries from MinGW DEF files for cross-compilation.
/// The DEF files are vendored from MinGW-w64 (Zope Public License) in
/// platform/targets/windows-def/ and are used to generate import libraries.
fn generateWindowsImportLibs(b: *std.Build, copy_step: *std.Build.Step.UpdateSourceFiles) void {
    for (windows_import_libs) |lib_name| {
        // DEF file path in our vendored directory
        const def_filename = std.fmt.allocPrint(b.allocator, "{s}.def", .{lib_name}) catch @panic("OOM");
        const def_path = b.path(b.pathJoin(&.{ "platform", "targets", "windows-def", def_filename }));

        // Output library name
        const lib_filename = std.fmt.allocPrint(b.allocator, "{s}.lib", .{lib_name}) catch @panic("OOM");

        // Use zig dlltool to generate import library from DEF file
        // dlltool creates a minimal import library that references the Windows DLL
        const gen_lib = b.addSystemCommand(&.{"zig"});
        gen_lib.addArg("dlltool");
        gen_lib.addArg("-m");
        gen_lib.addArg("i386:x86-64");
        gen_lib.addArg("-d");
        gen_lib.addFileArg(def_path);
        gen_lib.addArg("-l");
        const output_lib = gen_lib.addOutputFileArg(lib_filename);

        copy_step.addCopyFileToSource(
            output_lib,
            b.pathJoin(&.{ "platform", "targets", "x64win", lib_filename }),
        );
    }
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
    stub_lib.root_module.addAssemblyFile(b.path(stub_path));
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
    stub_lib.root_module.addAssemblyFile(b.path(stub_path));
    return stub_lib;
}

/// Generate libX11 stub shared library with SONAME libX11.so.6.
/// Declares the Xlib symbols raylib 6.0's `GetClipboardImage()` references
/// directly (see `x11_clipboard_syms`); the real libX11 loaded at runtime by
/// GLFW provides the implementations. Needed in the `x64glibc` link list so the
/// `rcore.o` references resolve even though roc-ray never calls clipboard image.
fn generateX11SoStub(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const stub_lib = b.addLibrary(.{
        .name = "X11",
        .linkage = .dynamic,
        .version = .{ .major = 6, .minor = 0, .patch = 0 },
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });

    var src: []const u8 = "";
    for (x11_clipboard_syms) |sym| {
        src = std.fmt.allocPrint(b.allocator,
            \\{s}int {s}(void) {{ return 0; }}
            \\
        , .{ src, sym }) catch @panic("OOM");
    }
    const write_files = b.addWriteFiles();
    const stub_file = write_files.add("x11_stub.c", src);
    stub_lib.root_module.addCSourceFile(.{ .file = stub_file });
    return stub_lib;
}

/// Build the vendored libvpx for one target.
///
/// Factored out so the SIMD/C parity test can build the same library for the
/// native target: a parity check that ran against a differently-configured
/// libvpx than the host links would prove nothing.
fn buildLibvpx(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    roc_target: RocTarget,
) *std.Build.Step.Compile {
    // Vendored libvpx, built from source for every target rather than shipped
    // as a prebuilt archive: it is C all the way down -- portable C plus the
    // SIMD libvpx writes as compiler intrinsics, never its assembly -- so
    // `zig build` compiles it directly and there is no configure step and no
    // per-OS CI runner in the loop. Produces WebM video via src/capture_vp8.zig.
    // MSVC has no libc headers available when cross-compiling from Linux, and
    // libvpx needs a dozen of them. It is plain C with no CRT-specific types,
    // so build this one library against mingw's headers instead; both produce
    // COFF objects with the same C ABI.
    const libvpx_target = if (roc_target == .x64win)
        b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu })
    else
        target;

    const libvpx = b.addLibrary(.{
        .name = "vpx",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = libvpx_target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .pic = true,
            // As with msf_gif: Roc's final link has no UBSan runtime.
            .sanitize_c = .off,
            // Unlike msf_gif, libvpx needs real libc headers (stdlib, string,
            // assert, inttypes, math). Isolating it in its own library keeps
            // that off the freestanding host module.
            .link_libc = true,
        }),
    });
    libvpx.root_module.addIncludePath(b.path("vendor/libvpx"));
    // Exactly one config directory is on the include path, so a source can only
    // ever see the generated headers for the architecture it is being built
    // for.
    const libvpx_config_dir = roc_target.libvpxConfigDir();
    libvpx.root_module.addIncludePath(b.path(libvpx_config_dir));
    if (roc_target == .x64win) {
        // Replaces mingw's <setjmp.h>, whose x64 mapping needs a helper only
        // mingw's CRT defines. Windows-only: every other target links a real
        // libc and must use its own header.
        libvpx.root_module.addIncludePath(b.path("vendor/libvpx/shim/win"));
    }
    // The narrow C shim the host actually calls; see src/capture_vp8.zig.
    libvpx.root_module.addCSourceFile(.{
        .file = b.path("vendor/libvpx/shim/rocray_vp8.c"),
        .flags = &libvpx_flags,
    });
    libvpx.root_module.addCSourceFile(.{
        .file = b.path(b.pathJoin(&.{ libvpx_config_dir, "vpx_config.c" })),
        .flags = &libvpx_flags,
    });
    libvpx.root_module.addCSourceFiles(.{
        .root = b.path("vendor/libvpx"),
        // gnu99, not c99: vpx_ports/vpx_timer.h uses clock_gettime and
        // struct timespec, which strict-ANSI mode hides behind __STRICT_ANSI__.
        .files = &libvpx_sources,
        .flags = &libvpx_flags,
    });
    libvpx.root_module.addCSourceFiles(.{
        .root = b.path("vendor/libvpx"),
        .files = roc_target.libvpxSimdSources(),
        .flags = &libvpx_flags,
    });

    return libvpx;
}

fn buildHostLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    roc_target: RocTarget,
) BuildResult {
    const raylib_include_path = b.path("vendor/raylib/include");
    const raylib_lib_dir = b.pathJoin(&.{ "vendor", "raylib", roc_target.vendoredRaylibDir() });
    const raylib_lib_path = b.path(raylib_lib_dir);

    const host_lib = b.addLibrary(.{
        .name = "host",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host_native.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .pic = true,
            // Selects Zig's pthread path for std.Thread. The native path
            // depends on TLS that Zig's start code sets up, and the start code
            // never runs here: this is a static library that `roc build` links
            // into an executable of its own. Without this, spawning the effect
            // worker panics inside std.Thread rather than returning an error.
            .link_libc = true,
        }),
    });

    host_lib.root_module.addIncludePath(raylib_include_path);
    host_lib.root_module.addLibraryPath(raylib_lib_path);

    // Vendored single-header GIF encoder (MIT or public domain), so recordings
    // need no external encoder. It is its own archive rather than C added to
    // the host module: a Zig module that compiles C reaches for the system libc
    // headers, which a freestanding host does not have, while a standalone C
    // library builds cleanly for all four targets.
    //
    // It builds freestanding like the host -- malloc and memcpy resolve at final
    // link, as raylib's already do -- and the minimal libc headers msf_gif
    // includes come from vendor/msf_gif/shim. The host calls it through the
    // primitive-only shim in msf_gif_impl.c, so no C headers reach the Zig side.
    //
    // Roc links from an explicit input list, so the archive is copied next to
    // libraylib.a below and named in the `targets:` block of platform/main.roc.
    const msf_gif = b.addLibrary(.{
        .name = "msf_gif",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .pic = true,
            // Debug builds otherwise emit UBSan calls into the vendored C, and
            // Roc's final link has no UBSan runtime to resolve them against.
            .sanitize_c = .off,
        }),
    });
    const libvpx = buildLibvpx(b, target, optimize, roc_target);

    msf_gif.root_module.addIncludePath(b.path("vendor/msf_gif"));
    msf_gif.root_module.addIncludePath(b.path("vendor/msf_gif/shim"));
    msf_gif.root_module.addCSourceFile(.{
        .file = b.path("vendor/msf_gif/msf_gif_impl.c"),
        .flags = &.{"-std=c99"},
    });

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

    // Roc links the static host library directly, so include Zig compiler-rt
    // helpers such as __divti3 in the archive for every target.
    host_lib.bundle_compiler_rt = true;

    const raylib_archive = b.path(b.pathJoin(&.{ raylib_lib_dir, roc_target.raylibFilename() }));

    const libc_stub: ?std.Build.LazyPath = if (target.result.os.tag == .linux) blk: {
        const stub = generateLibcStub(b, target);
        break :blk stub.getEmittedBin();
    } else null;

    const libm_stub: ?std.Build.LazyPath = if (target.result.os.tag == .linux) blk: {
        const stub = generateLibmStub(b, target);
        break :blk stub.getEmittedBin();
    } else null;

    const x11_stub: ?std.Build.LazyPath = if (target.result.os.tag == .linux) blk: {
        const stub = generateX11SoStub(b, target);
        break :blk stub.getEmittedBin();
    } else null;

    return .{
        .host_lib = host_lib,
        .raylib_archive = raylib_archive,
        .msf_gif_archive = msf_gif.getEmittedBin(),
        .libvpx_archive = libvpx.getEmittedBin(),
        .libc_stub = libc_stub,
        .libm_stub = libm_stub,
        .x11_stub = x11_stub,
    };
}
