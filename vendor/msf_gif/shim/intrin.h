// Minimal <intrin.h> for building the vendored msf_gif freestanding on Windows.
//
// See shim/string.h for why these shims exist. When targeting msvc, msf_gif
// takes its `_MSC_VER` branch and includes <intrin.h> solely for
// `_BitScanReverse`. The real header pulls in <setjmp.h> and much more, none of
// which is available freestanding, so this supplies just that one intrinsic --
// implemented with the same compiler builtin msf_gif's gcc/clang branch uses.

#ifndef ROCRAY_MSF_GIF_SHIM_INTRIN_H
#define ROCRAY_MSF_GIF_SHIM_INTRIN_H

static inline unsigned char _BitScanReverse(unsigned long *index, unsigned long mask) {
    if (mask == 0) return 0;
    *index = (unsigned long)(31 - __builtin_clz(mask));
    return 1;
}

#endif
