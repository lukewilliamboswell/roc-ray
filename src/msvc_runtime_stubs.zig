//! MSVC runtime symbols referenced by the vendored `raylib.lib`.
//!
//! The Windows raylib archive is built by MSVC with `/GS` stack checks, so its
//! objects reference the security-cookie machinery, `__isa_available`, and
//! `_fltused`, which the static half of the MSVC CRT defines. Nothing links
//! that CRT: `roc build` takes no input from a Visual Studio install (see
//! `windows_crt.zig`), and the graphical smoke executable is built for
//! `x86_64-windows-gnu` against Zig's mingw CRT. The references resolve here
//! instead. The definitions are the conventional ones: a fixed cookie, a check
//! that accepts it, and a handler that declines to handle anything.

const builtin = @import("builtin");

comptime {
    if (builtin.os.tag == .windows) {
        @export(&security_cookie, .{ .name = "__security_cookie" });
        @export(&securityCheckCookie, .{ .name = "__security_check_cookie" });
        @export(&gsHandlerCheck, .{ .name = "__GSHandlerCheck" });
        @export(&reportRangeCheckFailure, .{ .name = "__report_rangecheckfailure" });
        switch (builtin.abi) {
            // mingw's CRT defines `__isa_available` but not `_fltused`.
            .gnu => @export(&fltused, .{ .name = "_fltused" }),
            // `windows_crt.zig` defines `_fltused` for the host; the
            // instruction-set level is the x86-64 baseline.
            else => @export(&isa_available, .{ .name = "__isa_available" }),
        }
    }
}

var isa_available: c_int = 0;
var security_cookie: usize = 0x2B992DDFA232;
var fltused: c_int = 1;

fn securityCheckCookie(_: usize) callconv(.c) void {}

/// Returns `ExceptionContinueSearch`.
fn gsHandlerCheck(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    return 1;
}

fn reportRangeCheckFailure() callconv(.c) noreturn {
    @trap();
}
