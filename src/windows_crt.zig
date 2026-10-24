//! Process startup for the `x64win` host.
//!
//! `roc build` links exactly the inputs `platform/main.roc` lists for a target
//! and takes nothing from a Visual Studio or Windows SDK install, so the host
//! supplies what the MSVC C runtime's static half otherwise would: the entry
//! point the linker infers for a console program, the image's thread-local
//! storage directory, the stack probe, and (through `msvc_runtime_stubs.zig`)
//! the compiler support symbols the MSVC-built raylib references. Everything else the C
//! runtime provides is imported from the Universal CRT, `ucrtbase.dll`, which
//! is part of Windows.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

comptime {
    if (builtin.os.tag == .windows and builtin.abi == .msvc and !builtin.is_test) {
        _ = @import("msvc_runtime_stubs.zig");
        @export(&mainCRTStartup, .{ .name = "mainCRTStartup" });
        @export(&chkstk, .{ .name = "__chkstk" });
        @export(&fltused, .{ .name = "_fltused" });
        @export(&tls_index, .{ .name = "_tls_index" });
        @export(&tls_start, .{ .name = "_tls_start" });
        @export(&tls_end, .{ .name = "_tls_end" });
        @export(&xl_a, .{ .name = "__xl_a" });
        @export(&xl_z, .{ .name = "__xl_z" });
        @export(&tls_used, .{ .name = "_tls_used" });
    }
}

extern fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int;

extern fn _configure_narrow_argv(mode: c_int) callconv(.c) c_int;
extern fn __p___argc() callconv(.c) *c_int;
extern fn __p___argv() callconv(.c) *[*][*:0]u8;
extern fn exit(status: c_int) callconv(.c) noreturn;

/// `_crt_argv_unexpanded_arguments`: split the command line without expanding
/// wildcards.
const argv_unexpanded = 1;

const Initializer = ?*const fn () callconv(.c) void;

// Compilers place pointers to startup functions in `.CRT$XI*` (C) and
// `.CRT$XC*` (C++) sections. The linker sorts those sections by name, so
// these sentinels bracket every pointer a linked object contributed.
var xi_a: Initializer linksection(".CRT$XIA") = null;
var xi_z: Initializer linksection(".CRT$XIZ") = null;
var xc_a: Initializer linksection(".CRT$XCA") = null;
var xc_z: Initializer linksection(".CRT$XCZ") = null;

fn runInitializers(first: *Initializer, last: *Initializer) void {
    var entry: [*]Initializer = @ptrCast(first);
    const end: [*]Initializer = @ptrCast(last);
    while (@intFromPtr(entry) < @intFromPtr(end)) : (entry += 1) {
        if (entry[0]) |initializer| initializer();
    }
}

fn mainCRTStartup() callconv(.winapi) noreturn {
    if (_configure_narrow_argv(argv_unexpanded) != 0) exit(255);
    runInitializers(&xi_a, &xi_z);
    runInitializers(&xc_a, &xc_z);
    exit(main(__p___argc().*, __p___argv().*));
}

/// The linker requires this symbol of any image whose code uses floating
/// point.
var fltused: c_int = 1;

/// The stack probe the compiler calls before a frame larger than a page:
/// touch every page of the `rax` bytes about to be claimed, so the guard page
/// is hit in order. Preserves every register; the caller adjusts `rsp`.
/// Zig's compiler-rt has the same routine but omits it from a libc-linked
/// build, expecting the MSVC CRT to supply it.
fn chkstk() callconv(.naked) void {
    asm volatile (
        \\ push %rcx
        \\ push %rax
        \\ cmp $0x1000, %rax
        \\ lea 24(%rsp), %rcx
        \\ jb 1f
        \\2:
        \\ sub $0x1000, %rcx
        \\ test %rcx, (%rcx)
        \\ sub $0x1000, %rax
        \\ cmp $0x1000, %rax
        \\ ja 2b
        \\1:
        \\ sub %rax, %rcx
        \\ test %rcx, (%rcx)
        \\ pop %rax
        \\ pop %rcx
        \\ ret
    );
}

// The PE thread-local storage directory. Mirrors Zig's
// `std/os/windows/tls.zig`, which `std.start` provides only to executables Zig
// links itself; the host is a static library linked by `roc build`.
var tls_index: u32 = windows.TLS_OUT_OF_INDEXES;
var tls_start: ?*anyopaque linksection(".tls") = null;
var tls_end: ?*anyopaque linksection(".tls$ZZZ") = null;
var xl_a: windows.PIMAGE_TLS_CALLBACK linksection(".CRT$XLA") = null;
var xl_z: windows.PIMAGE_TLS_CALLBACK linksection(".CRT$XLZ") = null;

const ImageTlsDirectory = extern struct {
    start_address_of_raw_data: *?*anyopaque,
    end_address_of_raw_data: *?*anyopaque,
    address_of_index: *u32,
    address_of_callbacks: [*:null]windows.PIMAGE_TLS_CALLBACK,
    size_of_zero_fill: u32,
    characteristics: u32,
};

const tls_used linksection(".rdata$T") = ImageTlsDirectory{
    .start_address_of_raw_data = &tls_start,
    .end_address_of_raw_data = &tls_end,
    .address_of_index = &tls_index,
    // `xl_a` is a null sentinel; the callbacks sit between it and `xl_z`.
    .address_of_callbacks = @as([*:null]windows.PIMAGE_TLS_CALLBACK, @ptrCast(&xl_a)) + 1,
    .size_of_zero_fill = 0,
    .characteristics = 0,
};
