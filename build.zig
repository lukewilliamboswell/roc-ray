const std = @import("std");
const builtin = @import("builtin");

/// Records the compiler a host build was made for, which the Observatory
/// reports. The platform names no compiler, so a release build passes the
/// nightly it resolved with `-Droc-compiler=<tag>`.
fn addBuildMetadata(b: *std.Build, module: *std.Build.Module, roc_compiler: []const u8) void {
    const options = b.addOptions();
    options.addOption([]const u8, "roc_compiler_built_with", roc_compiler);
    module.addOptions("build_metadata", options);
}

const link_inputs = @import("link_inputs.zig");
const RocTarget = link_inputs.RocTarget;
const buildLibvpx = link_inputs.buildLibvpx;
const libvpx_flags = link_inputs.libvpx_flags;
const windows_import_libs = link_inputs.windows_import_libs;

/// All cross-compilation targets for `zig build`
/// Only includes targets that have vendored raylib libraries available
const all_native_targets = [_]RocTarget{
    .x64mac,
    .arm64mac,
    .x64v1glibc,
    .x64win,
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const configured_macos_interfaces_path = b.option(
        []const u8,
        "macos-interfaces-path",
        "Path to a generated macOS interface tree (defaults to the locked release)",
    );
    const macos_interfaces_path = configured_macos_interfaces_path orelse "platform/targets/macos-sysroot";
    const roc_compiler = b.option(
        []const u8,
        "roc-compiler",
        "The Roc nightly tag this host is built for, recorded in Observatory metadata",
    ) orelse "unavailable";
    const prepare_macos_interfaces = if (configured_macos_interfaces_path == null) b.addSystemCommand(&.{
        "python3",
        "scripts/prepare_dependencies.py",
    }) else null;
    if (prepare_macos_interfaces) |prepare| prepare.setCwd(b.path("."));
    const run_roc_tests = b.option(
        bool,
        "roc-tests",
        "Run Roc example tests as part of `zig build test`",
    ) orelse true;

    // Cleanup step: remove the host archives this build writes.
    const cleanup_step = b.step("clean", "Remove the built host libraries");
    const remove_files = b.addRunArtifact(b.addExecutable(.{
        .name = "remove_files",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/remove_files.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    }));
    remove_files.setCwd(b.path("."));
    remove_files.has_side_effects = true;
    for (all_native_targets) |roc_target| {
        remove_files.addArg(b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libFilename() }));
    }
    cleanup_step.dependOn(&remove_files.step);

    // Producer-only: ordinary builds never run the linker-input recipes.
    _ = link_inputs.addProducerStep(b);

    // Every other linker input comes from the release selected by
    // link-inputs.lock.json. The installer rehashes cached archives against
    // the lock on every run, downloads only on a cache miss, and fails -- it
    // never rebuilds -- when an input is missing, stale, or not the locked
    // bytes. See dependencies/link-inputs/README.md.
    const install_link_inputs = b.addSystemCommand(&.{
        "python3",
        "scripts/link_inputs.py",
        "install",
        "--destination",
        "platform",
        "--targets-only",
    });
    install_link_inputs.setCwd(b.path("."));
    install_link_inputs.has_side_effects = true;
    const link_inputs_step = b.step("link-inputs-install", "Install the locked linker inputs into platform/targets");
    link_inputs_step.dependOn(&install_link_inputs.step);

    // Build the host library for all native targets from this checkout.
    // Cleanup has to finish before the new archives are copied into the
    // source tree.
    const copy_all = b.addUpdateSourceFiles();
    copy_all.step.dependOn(cleanup_step);

    // Hosts alone, without the lock. The linker-input producer validates an
    // unpublished candidate this way: a candidate exists precisely because the
    // lock is missing or stale, so its validation cannot depend on it.
    const hosts_step = b.step("hosts", "Build only the host libraries, without installing locked linker inputs");
    hosts_step.dependOn(&copy_all.step);

    // Default step: the hosts next to the locked inputs.
    const all_step = b.getInstallStep();
    all_step.dependOn(&copy_all.step);
    all_step.dependOn(&install_link_inputs.step);

    for (all_native_targets) |roc_target| {
        const target = b.resolveTargetQuery(roc_target.toZigTarget());
        const host_lib = buildHostLib(b, target, optimize, macos_interfaces_path, roc_compiler);
        if (prepare_macos_interfaces) |prepare| {
            if (target.result.os.tag == .macos) host_lib.step.dependOn(&prepare.step);
        }
        copy_all.addCopyFileToSource(
            host_lib.getEmittedBin(),
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libFilename() }),
        );
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
            .optimize = .debug,
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
            .optimize = .debug,
        }),
    });
    const run_lints = b.addRunArtifact(zig_lints);
    run_lints.setCwd(b.path(".")); // Run from project root
    lint_step.dependOn(&run_lints.step);

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

    const release_helper_tests = b.addSystemCommand(&.{
        "python3",
        "scripts/test_release_helpers.py",
    });
    release_helper_tests.setCwd(b.path("."));
    test_step.dependOn(&release_helper_tests.step);

    const dependency_input_tests = b.addSystemCommand(&.{
        "python3",
        "-m",
        "unittest",
        "scripts/test_dependency_artifacts.py",
        "scripts/test_macos_archive_audit.py",
        "scripts/test_macos_interfaces.py",
        "scripts/test_prepare_dependencies.py",
        "scripts/test_link_inputs.py",
    });
    dependency_input_tests.setCwd(b.path("."));
    test_step.dependOn(&dependency_input_tests.step);

    const observatory_analysis_tests = b.addSystemCommand(&.{
        "python3",
        "scripts/test_analyze_observatory.py",
    });
    observatory_analysis_tests.setCwd(b.path("."));
    test_step.dependOn(&observatory_analysis_tests.step);

    const observatory_benchmark_tests = b.addSystemCommand(&.{
        "python3",
        "scripts/test_benchmark_observatory.py",
    });
    observatory_benchmark_tests.setCwd(b.path("."));
    test_step.dependOn(&observatory_benchmark_tests.step);

    // Timing is deliberately an opt-in report, never a universal CI gate.
    // The build dependency supplies a ReleaseFast native host; the script
    // builds its deterministic Roc fixture once and randomizes the four modes.
    const observatory_benchmark = b.addSystemCommand(&.{
        "python3",
        "scripts/benchmark_observatory.py",
        "--skip-platform-build",
        "--json-out",
        "zig-out/observatory-benchmark.json",
        "--markdown-out",
        "zig-out/observatory-benchmark.md",
    });
    observatory_benchmark.setCwd(b.path("."));
    observatory_benchmark.step.dependOn(all_step);
    const observatory_benchmark_step = b.step(
        "observatory-bench",
        "Report disabled/summary/standard/full Observatory overhead",
    );
    observatory_benchmark_step.dependOn(&observatory_benchmark.step);

    const observatory_query_tests = b.addSystemCommand(&.{
        "python3",
        "scripts/test_observatory_queries.py",
    });
    observatory_query_tests.setCwd(b.path("."));
    test_step.dependOn(&observatory_query_tests.step);

    const effect_scope_audit_tests = b.addSystemCommand(&.{
        "python3",
        "scripts/test_effect_scope_audit.py",
    });
    effect_scope_audit_tests.setCwd(b.path("."));
    test_step.dependOn(&effect_scope_audit_tests.step);

    const native_roc_target = detectNativeRocTarget(native_target.result);

    if (native_roc_target) |roc_target| {
        const native_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/host_native.zig"),
                .target = native_target,
                .optimize = optimize,
            }),
        });
        native_tests.root_module.addImport("raylib_c", raylibCModule(b, native_target, optimize));
        addBuildMetadata(b, native_tests.root_module, roc_compiler);
        native_tests.root_module.link_libc = true;
        native_tests.root_module.addImport("zio", zioModule(b, native_target, optimize));
        // The sqlite tests in src/sqlite_effect.zig run against a real
        // in-memory database rather than a stand-in: a heap test built on
        // zeroed memory makes every incref and decref a no-op and so cannot
        // fail when a refcount is wrong.
        // Linked against the exact locked archive the platform ships.
        const locked_sqlite3 = b.path(b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.sqlite3Filename() }));
        native_tests.root_module.addObjectFile(locked_sqlite3);
        native_tests.step.dependOn(&install_link_inputs.step);
        const run_native_tests = b.addRunArtifact(native_tests);
        test_step.dependOn(&run_native_tests.step);

        // Observatory owns a separate SQLite connection on its writer thread,
        // and its focused tests exercise a real finalized `.rrstats` file.
        const observatory_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/observatory.zig"),
                .target = native_target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        observatory_tests.root_module.addObjectFile(locked_sqlite3);
        observatory_tests.step.dependOn(&install_link_inputs.step);
        const run_observatory_tests = b.addRunArtifact(observatory_tests);
        test_step.dependOn(&run_observatory_tests.step);

        // SIMD/C parity for the vendored libvpx. This has to run *on* the
        // target -- it is the only check that a NEON or SSE2 kernel actually
        // computes what its C counterpart does, and an arm64 build swaps out
        // ~200 of them. Native target on purpose: cross-compiling it would
        // build the kernels without ever executing them.
        const parity_target_arch: RocTarget = switch (native_target.result.cpu.arch) {
            .aarch64 => .arm64mac,
            else => .x64v1glibc,
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
        // A producer check: it builds libvpx from source, so it runs in the
        // linker-input producer workflow rather than as part of `zig build test`.
        parity_step.dependOn(&run_parity.step);

        // Pixel-level rendering checks need a real graphics context, so keep
        // them opt-in for local/CI runs with a display (for example xvfb-run).
        const raylib_lib_dir = b.pathJoin(&.{ "vendor", "raylib", roc_target.vendoredRaylibDir() });
        // As with libvpx and sqlite: a native Windows build links `-lc`, and
        // the MSVC ABI has no CRT for Zig to supply (CI has no MSVC libraries
        // either). Build against mingw's CRT instead; the vendored raylib.lib
        // is plain C with the same COFF ABI, so it links either way.
        const graphical_smoke_target = if (native_target.result.os.tag == .windows)
            b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu })
        else
            native_target;
        const graphical_smoke = b.addExecutable(.{
            .name = "graphical-smoke",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/graphical_smoke.zig"),
                .target = graphical_smoke_target,
                .optimize = optimize,
            }),
        });
        graphical_smoke.root_module.addImport("raylib_c", raylibCModule(b, graphical_smoke_target, optimize));
        graphical_smoke.root_module.addLibraryPath(b.path(raylib_lib_dir));
        graphical_smoke.root_module.linkSystemLibrary("raylib", .{ .use_pkg_config = .no });
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
                // The MSVC-built raylib.lib carries `/DEFAULTLIB` directives
                // for the MSVC CRT, which lld honours even on the gnu target.
                // mingw's CRT already provides everything they would, so
                // satisfy the names with empty archives. The runtime symbols
                // MSVC's `/GS` codegen needs come from src/msvc_runtime_stubs.zig.
                const empty_source = b.addWriteFiles().add("empty.c", "\n");
                const placeholders = b.addWriteFiles();
                inline for (.{ "MSVCRT", "OLDNAMES", "uuid" }) |lib_name| {
                    const empty = b.addLibrary(.{
                        .name = lib_name,
                        .linkage = .static,
                        .root_module = b.createModule(.{
                            .target = graphical_smoke_target,
                            .optimize = optimize,
                        }),
                    });
                    empty.root_module.addCSourceFile(.{ .file = empty_source, .flags = &.{} });
                    _ = placeholders.addCopyFile(empty.getEmittedBin(), "lib" ++ lib_name ++ ".a");
                }
                graphical_smoke.root_module.addLibraryPath(placeholders.getDirectory());
            },
            else => {},
        }
        graphical_smoke.root_module.link_libc = true;
        const run_graphical_smoke = b.addRunArtifact(graphical_smoke);
        const graphical_smoke_step = b.step("graphical-smoke", "Run pixel-level rendering smoke tests (requires a display)");
        graphical_smoke_step.dependOn(&run_graphical_smoke.step);

        // Windows CI has no GL 3.3 driver, so it substitutes Mesa's llvmpipe
        // `opengl32.dll`. Windows only picks a DLL up from the executable's own
        // directory, and the run step above runs straight out of the build
        // cache, so installing the executable gives CI a stable directory to
        // drop the replacement next to.
        const install_graphical_smoke = b.addInstallArtifact(graphical_smoke, .{});
        const install_graphical_smoke_step = b.step(
            "graphical-smoke-exe",
            "Build the graphical smoke test into zig-out/bin without running it",
        );
        install_graphical_smoke_step.dependOn(&install_graphical_smoke.step);
    }

    if (run_roc_tests) {
        // Run Roc tests (check, fmt, test, build)
        const roc_tests = b.addSystemCommand(&.{
            "python3",
            "scripts/all_tests.py",
            "--skip-platform-build",
        });
        roc_tests.setCwd(b.path(".")); // Run from project root
        roc_tests.step.dependOn(all_step);
        test_step.dependOn(&roc_tests.step);
    }
}

/// The zio module for one target.
///
/// Scheduling is `single_executor`: the one executor is the frame thread, and
/// no task can move off it. Work stealing would be a way for Roc code to run on
/// another thread, and nothing in the host is safe for that. The host root
/// module declares the same `zio_options`, which is what a library build reads;
/// this build option is the default the test runner root falls back to.
fn zioModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Module {
    const dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
        .scheduling = .single_executor,
    });
    return dep.module("zio");
}

/// The raylib C API for one target, translated from src/raylib_c.h.
///
/// Only src/backend_raylib.zig imports this module (ci/tidy.zig enforces it):
/// that file is the host's sole C-import boundary into raylib.
fn raylibCModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/raylib_c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(b.path("vendor/raylib/include"));
    return translate.createModule();
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
            .x86_64 => .x64v1glibc,
            else => null,
        },
        .windows => switch (target.cpu.arch) {
            .x86_64 => .x64win,
            else => null,
        },
        else => null,
    };
}

fn buildHostLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    macos_interfaces_path: []const u8,
    roc_compiler: []const u8,
) *std.Build.Step.Compile {
    const host_lib = b.addLibrary(.{
        .name = "host",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host_native.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .debug,
            .pic = true,
            // On MSVC targets LLVM implements the stack protector with its own
            // `__security_cookie` global, which collides with the definition in
            // src/msvc_runtime_stubs.zig and crashes LLVM in Debug builds. The
            // protector would check nothing there anyway: those stubs accept
            // every cookie, and they exist only for the MSVC-built raylib.lib.
            .stack_protector = if (target.result.abi == .msvc) false else null,
            // Selects Zig's pthread path for std.Thread. The native path
            // depends on TLS that Zig's start code sets up, and the start code
            // never runs here: this is a static library that `roc build` links
            // into an executable of its own. Without this, spawning the effect
            // worker panics inside std.Thread rather than returning an error.
            .link_libc = true,
        }),
    });

    host_lib.root_module.addImport("raylib_c", raylibCModule(b, target, optimize));
    addBuildMetadata(b, host_lib.root_module, roc_compiler);

    // Coroutine runtime for app tasks. Configured to a single executor on the
    // frame thread; zio is built single-executor so the scheduler cannot move
    // a Roc call onto another thread.
    host_lib.root_module.addImport("zio", zioModule(b, target, optimize));

    if (target.result.os.tag == .macos) {
        const framework_path = b.pathJoin(&.{ macos_interfaces_path, "System/Library/Frameworks" });
        const library_path = b.pathJoin(&.{ macos_interfaces_path, "usr/lib" });
        const sysroot_frameworks: std.Build.LazyPath = if (std.fs.path.isAbsolute(framework_path))
            .{ .cwd_relative = framework_path }
        else
            b.path(framework_path);
        const sysroot_lib: std.Build.LazyPath = if (std.fs.path.isAbsolute(library_path))
            .{ .cwd_relative = library_path }
        else
            b.path(library_path);
        host_lib.root_module.addSystemFrameworkPath(sysroot_frameworks);
        host_lib.root_module.addLibraryPath(sysroot_lib);
    }

    // The glibc 2.38 C23 aliases the prebuilt Linux raylib references, resolved
    // inside the app so it runs on older glibc; see src/isoc23_shims.s.
    if (target.result.os.tag == .linux and target.result.abi.isGnu() and target.result.cpu.arch == .x86_64) {
        host_lib.root_module.addAssemblyFile(b.path("src/isoc23_shims.s"));
    }

    // Roc links the static host library directly, so include Zig compiler-rt
    // helpers such as __divti3 in the archive for every target.
    host_lib.bundle_compiler_rt = true;

    return host_lib;
}
