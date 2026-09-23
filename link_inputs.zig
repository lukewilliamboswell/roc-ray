//! Recipes for RocRay's platform linker inputs.
//!
//! These produce every file a platform `targets` block names except the host
//! archive (`libhost.a`/`host.lib`) and the Roc app: raylib, the vendored C
//! encoders and SQLite, the Linux CRT objects and link stubs, and the Windows
//! import libraries. They change far less often than the host, so they are
//! released independently under `link-inputs.lock.json` and an ordinary build
//! consumes that release instead of running these recipes. See
//! `dependencies/link-inputs/README.md`.
//!
//! Everything that can change the bytes these recipes emit lives in this file
//! or in a path listed in `scripts/link_input_release.py`, because those paths
//! are the producer-input fingerprint the lock is checked against. Keep host
//! build logic in `build.zig`: editing it must not make the lock stale.

const std = @import("std");

/// Linker inputs are always built at one fixed optimization mode, whatever the
/// host is built with, so a release has exactly one identity per profile.
pub const release_optimize: std.builtin.OptimizeMode = .ReleaseFast;

/// Roc target definitions for native platforms
/// Maps to vendored raylib library directories
pub const RocTarget = enum {
    // x64 (x86_64) targets
    x64mac,
    x64win,
    x64glibc,

    // arm64 (aarch64) targets
    arm64mac,

    pub fn toZigTarget(self: RocTarget) std.Target.Query {
        return switch (self) {
            .x64mac => .{ .cpu_arch = .x86_64, .os_tag = .macos },
            .x64win => .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc },
            .x64glibc => .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
            .arm64mac => .{ .cpu_arch = .aarch64, .os_tag = .macos },
        };
    }

    pub fn targetDir(self: RocTarget) []const u8 {
        return switch (self) {
            .x64mac => "x64mac",
            .x64win => "x64win",
            .x64glibc => "x64glibc",
            .arm64mac => "arm64mac",
        };
    }

    pub fn libFilename(self: RocTarget) []const u8 {
        return switch (self) {
            .x64win => "host.lib",
            else => "libhost.a",
        };
    }

    /// Get the vendored raylib library directory for this target
    pub fn vendoredRaylibDir(self: RocTarget) []const u8 {
        return switch (self) {
            .x64mac, .arm64mac => "macos",
            .x64glibc => "linux-x64",
            .x64win => "windows-x64",
        };
    }

    /// Get the raylib library filename for this target
    pub fn raylibFilename(self: RocTarget) []const u8 {
        return switch (self) {
            .x64win => "raylib.lib",
            else => "libraylib.a",
        };
    }

    /// Get the GIF encoder archive filename for this target
    pub fn msfGifFilename(self: RocTarget) []const u8 {
        return switch (self) {
            .x64win => "msf_gif.lib",
            else => "libmsf_gif.a",
        };
    }

    /// Get the VP8 encoder archive filename for this target
    pub fn libvpxFilename(self: RocTarget) []const u8 {
        return switch (self) {
            .x64win => "vpx.lib",
            else => "libvpx.a",
        };
    }

    /// Get the SQLite archive filename for this target
    pub fn sqlite3Filename(self: RocTarget) []const u8 {
        return switch (self) {
            .x64win => "sqlite3.lib",
            else => "libsqlite3.a",
        };
    }

    /// libvpx is configured per CPU architecture, not per OS: the generated
    /// headers only vary in which `VPX_ARCH_*`/`HAVE_<simd>` are set, and both
    /// macOS targets share theirs with the Linux/Windows target of the same
    /// architecture. See vendor/libvpx/config/README.md.
    pub fn libvpxConfigDir(self: RocTarget) []const u8 {
        return switch (self) {
            .x64mac, .x64win, .x64glibc => "vendor/libvpx/config/x86_64",
            .arm64mac => "vendor/libvpx/config/arm64",
        };
    }

    /// The SIMD sources matching that config.
    pub fn libvpxSimdSources(self: RocTarget) []const []const u8 {
        return switch (self) {
            .x64mac, .x64win, .x64glibc => &libvpx_x86_64_sources,
            .arm64mac => &libvpx_arm64_sources,
        };
    }
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
pub const libvpx_flags = [_][]const u8{
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
pub const windows_import_libs = [_][]const u8{
    "gdi32", "user32", "winmm", "opengl32", "shell32", "ws2_32", "crypt32", "shlwapi", "bcryptprimitives",
};

/// Generate one Windows import library from its MinGW DEF file.
///
/// The DEF files are vendored from MinGW-w64 (Zope Public License) in
/// platform/targets/windows-def/. `zig dlltool` turns each into a minimal
/// import library that references the Windows DLL.
pub fn windowsImportLib(b: *std.Build, lib_name: []const u8) std.Build.LazyPath {
    const def_filename = b.fmt("{s}.def", .{lib_name});
    const gen_lib = b.addSystemCommand(&.{ b.graph.zig_exe, "dlltool", "-m", "i386:x86-64", "-d" });
    gen_lib.addFileArg(b.path(b.pathJoin(&.{ "platform", "targets", "windows-def", def_filename })));
    gen_lib.addArg("-l");
    return gen_lib.addOutputFileArg(b.fmt("{s}.lib", .{lib_name}));
}

/// Generate libc stub shared library with SONAME libc.so.6
pub fn generateLibcStub(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
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
pub fn generateLibmStub(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
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
pub fn generateX11SoStub(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
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
pub fn buildLibvpx(
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

/// Compiler flags for the vendored SQLite.
///
/// The stack protector and stack probes are off for the same reason libvpx
/// turns them off: the Windows archive is compiled against mingw headers and
/// linked into an MSVC-target binary, and those options emit calls to
/// libgcc-only helpers no MSVC CRT provides.
///
/// The `SQLITE_*` defines are the recommended build options from
/// <https://sqlite.org/compile.html>, less the ones that would change
/// behaviour an app can see. `vendor/sqlite/README.md` explains each choice.
const sqlite3_flags = [_][]const u8{
    "-std=c99",
    "-fno-stack-protector",
    "-mno-stack-arg-probe",
    "-Wno-unused-function",
    // Serialized. The host holds its own per-connection mutex, so mode 2 would
    // be enough for correctness, but shutdown calls sqlite3_interrupt from the
    // frame thread while a query runs on a blocking-pool thread, and serialized
    // mode is what makes that safe without further argument.
    "-DSQLITE_THREADSAFE=1",
    // A database file can never cause native code to be loaded.
    "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_SHARED_CACHE",
    // A double-quoted string is an identifier, never a string literal, so a
    // mistyped column name is an error instead of quietly becoming text.
    "-DSQLITE_DQS=0",
    "-DSQLITE_DEFAULT_MEMSTATUS=0",
    "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
    "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
    "-DSQLITE_MAX_EXPR_DEPTH=0",
    "-DSQLITE_USE_ALLOCA",
    // Kept, unlike most of the extension set: these two are what make a
    // visualization query worth running in the database rather than in Roc.
    "-DSQLITE_ENABLE_MATH_FUNCTIONS",
};

/// Build the vendored SQLite for one target.
///
/// Same shape as buildLibvpx: its own static library so the real libc headers
/// sqlite needs stay off the freestanding host module, and its own C shim so
/// the Zig side never sees a sqlite type.
pub fn buildSqlite3(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    roc_target: RocTarget,
) *std.Build.Step.Compile {
    // As with libvpx: MSVC has no libc headers available when cross-compiling
    // from Linux, and the amalgamation needs a dozen of them. Plain C with no
    // CRT-specific types in its interface, so build it against mingw's headers
    // instead; both produce COFF objects with the same C ABI.
    const sqlite_target = if (roc_target == .x64win)
        b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu })
    else
        target;

    const sqlite3 = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = sqlite_target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .pic = true,
            // As with the other vendored C: Roc's final link has no UBSan runtime.
            .sanitize_c = .off,
            .link_libc = true,
        }),
    });
    sqlite3.root_module.addIncludePath(b.path("vendor/sqlite"));
    sqlite3.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &sqlite3_flags,
    });
    // The narrow C shim the host actually calls; see src/sqlite_effect.zig.
    sqlite3.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/shim/rocray_sqlite.c"),
        .flags = &sqlite3_flags,
    });

    return sqlite3;
}

/// Build the vendored single-header GIF encoder (MIT or public domain).
///
/// It is its own archive rather than C added to the host module: a Zig module
/// that compiles C reaches for the system libc headers, which a freestanding
/// host does not have, while a standalone C library builds cleanly for all
/// four targets. It builds freestanding like the host -- malloc and memcpy
/// resolve at final link, as raylib's already do -- and the minimal libc
/// headers msf_gif includes come from vendor/msf_gif/shim. The host calls it
/// through the primitive-only shim in msf_gif_impl.c, so no C headers reach
/// the Zig side.
pub fn buildMsfGif(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const msf_gif = b.addLibrary(.{
        .name = "msf_gif",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = mode,
            .strip = mode != .Debug,
            .pic = true,
            // Debug builds otherwise emit UBSan calls into the vendored C, and
            // Roc's final link has no UBSan runtime to resolve them against.
            .sanitize_c = .off,
        }),
    });
    msf_gif.root_module.addIncludePath(b.path("vendor/msf_gif"));
    msf_gif.root_module.addIncludePath(b.path("vendor/msf_gif/shim"));
    msf_gif.root_module.addCSourceFile(.{
        .file = b.path("vendor/msf_gif/msf_gif_impl.c"),
        // An MSVC-ABI COFF object otherwise records the build time in its
        // header, which would give every build of the archive a new digest.
        .flags = if (target.result.os.tag == .windows)
            &.{ "-std=c99", "-mno-incremental-linker-compatible" }
        else
            &.{"-std=c99"},
    });
    return msf_gif;
}

/// One independently released set of linker inputs.
///
/// A profile is not a Roc target: X11 and Wayland share Roc's `x64glibc`
/// target and install into the same `targets/x64glibc/` directory, but link
/// different raylib builds and different stubs. Each profile therefore has its
/// own archive and identity, and the archive manifest names the profile so one
/// can never be accepted in place of the other.
pub const Profile = enum {
    x64mac,
    arm64mac,
    @"x64glibc-x11",
    @"x64glibc-wayland",
    x64win,

    pub fn rocTarget(self: Profile) RocTarget {
        return switch (self) {
            .x64mac => .x64mac,
            .arm64mac => .arm64mac,
            .@"x64glibc-x11", .@"x64glibc-wayland" => .x64glibc,
            .x64win => .x64win,
        };
    }

    /// The prebuilt raylib archive this profile links.
    fn raylibArchive(self: Profile) []const u8 {
        return switch (self) {
            .x64mac, .arm64mac => "vendor/raylib/macos/libraylib.a",
            .@"x64glibc-x11" => "vendor/raylib/linux-x64/libraylib.a",
            .@"x64glibc-wayland" => "vendor/raylib/linux-x64-wayland/libraylib.a",
            .x64win => "vendor/raylib/windows-x64/raylib.lib",
        };
    }
};

/// Licence texts that must travel with the compiled libvpx objects.
const libvpx_notices = [_][]const u8{ "LICENSE", "PATENTS", "AUTHORS" };

/// `zig build link-inputs`: build every profile into
/// `zig-out/link-inputs/<profile>/`, laid out as the platform bundle expects
/// (`targets/<roc target>/<file>` and `licenses/<file>`).
///
/// This is the producer. Ordinary builds never run it; they consume the
/// release selected by `link-inputs.lock.json`.
pub fn addProducerStep(b: *std.Build) *std.Build.Step {
    const step = b.step("link-inputs", "Build every linker-input profile into zig-out/link-inputs (producer only)");
    for (std.enums.values(Profile)) |profile| {
        const roc_target = profile.rocTarget();
        const target = b.resolveTargetQuery(roc_target.toZigTarget());
        const prefix = b.fmt("link-inputs/{s}", .{@tagName(profile)});
        const dir = b.fmt("{s}/targets/{s}", .{ prefix, roc_target.targetDir() });

        const install = struct {
            fn file(builder: *std.Build, parent: *std.Build.Step, source: std.Build.LazyPath, dest: []const u8) void {
                parent.dependOn(&builder.addInstallFile(source, dest).step);
            }
        }.file;

        install(b, step, b.path(profile.raylibArchive()), b.fmt("{s}/{s}", .{ dir, roc_target.raylibFilename() }));
        install(b, step, buildMsfGif(b, target, release_optimize).getEmittedBin(), b.fmt("{s}/{s}", .{ dir, roc_target.msfGifFilename() }));
        install(b, step, buildLibvpx(b, target, release_optimize, roc_target).getEmittedBin(), b.fmt("{s}/{s}", .{ dir, roc_target.libvpxFilename() }));
        install(b, step, buildSqlite3(b, target, release_optimize, roc_target).getEmittedBin(), b.fmt("{s}/{s}", .{ dir, roc_target.sqlite3Filename() }));
        for (libvpx_notices) |notice| {
            install(b, step, b.path(b.fmt("vendor/libvpx/{s}", .{notice})), b.fmt("{s}/licenses/{s}.libvpx", .{ prefix, notice }));
        }

        switch (roc_target) {
            .x64glibc => {
                for ([_][]const u8{ "Scrt1.o", "crti.o", "crtn.o" }) |crt| {
                    install(b, step, b.path(b.fmt("platform/targets/x64glibc/{s}", .{crt})), b.fmt("{s}/{s}", .{ dir, crt }));
                }
                install(b, step, generateLibcStub(b, target).getEmittedBin(), b.fmt("{s}/libc.so", .{dir}));
                install(b, step, generateLibmStub(b, target).getEmittedBin(), b.fmt("{s}/libm.so", .{dir}));
                // Only the X11 raylib references Xlib directly (see
                // `x11_clipboard_syms`); platform/main-wayland.roc names no
                // libX11 input.
                if (profile == .@"x64glibc-x11") {
                    install(b, step, generateX11SoStub(b, target).getEmittedBin(), b.fmt("{s}/libX11.so", .{dir}));
                }
            },
            .x64win => for (windows_import_libs) |lib_name| {
                install(b, step, windowsImportLib(b, lib_name), b.fmt("{s}/{s}.lib", .{ dir, lib_name }));
            },
            .x64mac, .arm64mac => {},
        }
    }
    return step;
}
