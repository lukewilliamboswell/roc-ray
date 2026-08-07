// Minimal <string.h> for building the vendored msf_gif freestanding.
//
// The host links -nostdlib and cross-compiles to x86_64-windows-msvc, where no
// MSVC libc headers are available. msf_gif includes <string.h> unconditionally
// but only needs these two declarations; the symbols themselves are resolved at
// final link, the same way raylib's uses of them already are.
//
// This directory is on the include path only for msf_gif's translation unit,
// so it cannot shadow <string.h> for anything else.

#ifndef ROCRAY_MSF_GIF_SHIM_STRING_H
#define ROCRAY_MSF_GIF_SHIM_STRING_H

#include <stddef.h>

void *memcpy(void *destination, const void *source, size_t count);
void *memset(void *destination, int value, size_t count);

#endif
