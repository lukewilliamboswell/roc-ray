//! MSVC runtime symbols referenced by the vendored `raylib.lib`.
//!
//! The Windows raylib archive is built by MSVC with `/GS` stack checks, so its
//! objects reference the security-cookie machinery and `_fltused`, which only
//! the MSVC CRT defines. Zig supplies mingw's CRT on the `x86_64-windows-gnu`
//! target that the graphical smoke executable is built for in CI (the MSVC
//! ABI has no CRT for Zig to ship), so the references resolve here instead.
//! The definitions are the conventional ones: a fixed cookie, a check that
//! accepts it, and a handler that declines to handle anything.

const builtin = @import("builtin");

comptime {
    if (builtin.os.tag == .windows and builtin.abi == .gnu) {
        @export(&security_cookie, .{ .name = "__security_cookie" });
        @export(&securityCheckCookie, .{ .name = "__security_check_cookie" });
        @export(&gsHandlerCheck, .{ .name = "__GSHandlerCheck" });
        @export(&reportRangeCheckFailure, .{ .name = "__report_rangecheckfailure" });
        @export(&fltused, .{ .name = "_fltused" });
    }
}

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
