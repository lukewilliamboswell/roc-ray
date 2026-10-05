// <setjmp.h> for the Windows build of the vendored libvpx.
//
// libvpx is compiled against mingw headers but linked into an MSVC-target
// binary (see build.zig). mingw's <setjmp.h> maps `setjmp` to the compiler
// intrinsic `__intrinsic_setjmpex`, which only mingw's CRT defines, so the
// final link fails with an unresolved external. The Universal CRT
// (`ucrtbase.dll`, the only C runtime an `x64win` link lists) exports
// `__intrinsic_setjmp` and `longjmp`, so map onto those instead. The frame
// argument is null: `longjmp` then restores the saved registers without
// unwinding, which is what libvpx's plain-C error path expects.
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

__attribute__((returns_twice)) int __intrinsic_setjmp(jmp_buf env, void *frame);
__declspec(noreturn) void longjmp(jmp_buf env, int value);

#define setjmp(env) __intrinsic_setjmp((env), 0)

#endif
