// Minimal <stdlib.h> for building the vendored msf_gif freestanding.
//
// See shim/string.h for why these shims exist. msf_gif itself only needs
// malloc/realloc/free; posix_memalign is declared because the compiler's
// <mm_malloc.h> (pulled in by <emmintrin.h> for msf_gif's SSE2 path) expects
// it. Nothing here is called by msf_gif, and the symbols resolve at final link.

#ifndef ROCRAY_MSF_GIF_SHIM_STDLIB_H
#define ROCRAY_MSF_GIF_SHIM_STDLIB_H

#include <stddef.h>

void *malloc(size_t size);
void *realloc(void *memory, size_t size);
void free(void *memory);
int posix_memalign(void **memory, size_t alignment, size_t size);

#endif
