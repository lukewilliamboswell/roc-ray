// Minimal <malloc.h> for building the vendored msf_gif freestanding on Windows.
//
// The compiler's <mm_malloc.h> includes this instead of declaring
// posix_memalign when targeting _WIN32. msf_gif never calls the aligned
// allocators, so the declarations only have to exist.

#ifndef ROCRAY_MSF_GIF_SHIM_MALLOC_H
#define ROCRAY_MSF_GIF_SHIM_MALLOC_H

#include <stddef.h>

void *_aligned_malloc(size_t size, size_t alignment);
void _aligned_free(void *memory);

#endif
