// <setjmp.h> for the Windows build of the vendored libvpx.
//
// libvpx is compiled against mingw headers but linked into an MSVC-target
// binary (see build.zig). mingw's <setjmp.h> maps `setjmp` to the compiler
// intrinsic `__intrinsic_setjmpex`, which only mingw's CRT defines, so the
// final link fails with an unresolved external. MSVCRT exports plain `_setjmp`
// and `longjmp`, so map onto those instead.
//
// Every use of jmp_buf is inside libvpx, and every libvpx translation unit sees
// this header, so the buffer's layout is self-consistent. It is deliberately
// oversized: MSVC's x64 jmp_buf is 256 bytes, and writing fewer would be the
// only way this could go wrong.
//
// This directory is on the include path for the Windows libvpx build only.

#ifndef ROCRAY_LIBVPX_SHIM_SETJMP_H
#define ROCRAY_LIBVPX_SHIM_SETJMP_H

typedef struct {
    __declspec(align(16)) unsigned char opaque[1024];
} rocray_jmp_buf_storage;

typedef rocray_jmp_buf_storage jmp_buf[1];

int _setjmp(jmp_buf env);
__declspec(noreturn) void longjmp(jmp_buf env, int value);

#define setjmp(env) _setjmp(env)

#endif
