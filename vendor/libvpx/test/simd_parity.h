// SIMD/C parity harness for the vendored libvpx.
//
// Every SIMD kernel libvpx dispatches has a plain-C counterpart with the same
// signature. Running both over identical random input and comparing the results
// is the only thing that catches a miscompiled or mis-selected kernel, and it
// is the only check that can run on a machine which cannot execute the target's
// SIMD -- it runs *on* the target, in CI.
//
// This matters most for aarch64: libvpx implements all of VP8 in NEON
// intrinsics, so an arm64 build swaps out ~200 kernels, and nothing else in the
// test suite would notice if one of them were wrong. Whole-encode output is not
// comparable between builds, because `vp8_auto_select_speed` feeds wall-clock
// timing back into mode decisions -- so parity has to be checked per kernel.
//
// The kernel table is generated; see config/generate_simd_parity.py.

#ifndef ROCRAY_LIBVPX_SIMD_PARITY_H
#define ROCRAY_LIBVPX_SIMD_PARITY_H

#include <stddef.h>
#include <stdint.h>

#include "./vpx_config.h"
#include "./vp8_rtcd.h"
#include "./vpx_dsp_rtcd.h"
#include "./vpx_scale_rtcd.h"

// One kernel pair, type-erased behind a comparator that knows its shape.
typedef struct {
    const char *name;
    int (*run)(const void *reference, const void *candidate);
    const void *reference;
    const void *candidate;
} RocRayParityKernel;

// Each shape gets a comparator and a macro that binds the pair to it.
int rocray_parity_run_intra_pred(const void *reference, const void *candidate);
int rocray_parity_run_sad(const void *reference, const void *candidate);
int rocray_parity_run_sad_x4(const void *reference, const void *candidate);
int rocray_parity_run_variance(const void *reference, const void *candidate);
int rocray_parity_run_sad_avg(const void *reference, const void *candidate);
int rocray_parity_run_subpel_var(const void *reference, const void *candidate);
int rocray_parity_run_subpel_var_avg(const void *reference, const void *candidate);

#define ROCRAY_PARITY_BIND(shape, c_impl, simd_impl) \
    rocray_parity_run_##shape, (const void *)(c_impl), (const void *)(simd_impl)

#define ROCRAY_PARITY_INTRA_PRED(c_impl, simd_impl) ROCRAY_PARITY_BIND(intra_pred, c_impl, simd_impl)
#define ROCRAY_PARITY_SAD(c_impl, simd_impl) ROCRAY_PARITY_BIND(sad, c_impl, simd_impl)
#define ROCRAY_PARITY_SAD_X4(c_impl, simd_impl) ROCRAY_PARITY_BIND(sad_x4, c_impl, simd_impl)
#define ROCRAY_PARITY_VARIANCE(c_impl, simd_impl) ROCRAY_PARITY_BIND(variance, c_impl, simd_impl)
#define ROCRAY_PARITY_SAD_AVG(c_impl, simd_impl) ROCRAY_PARITY_BIND(sad_avg, c_impl, simd_impl)
#define ROCRAY_PARITY_SUBPEL_VAR(c_impl, simd_impl) ROCRAY_PARITY_BIND(subpel_var, c_impl, simd_impl)
#define ROCRAY_PARITY_SUBPEL_VAR_AVG(c_impl, simd_impl) \
    ROCRAY_PARITY_BIND(subpel_var_avg, c_impl, simd_impl)

extern const RocRayParityKernel rocray_parity_kernels[];
extern const int rocray_parity_kernel_count;

#endif
