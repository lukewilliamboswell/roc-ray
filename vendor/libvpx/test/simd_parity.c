// SIMD/C parity comparators. See simd_parity.h for why this exists.

#include "simd_parity.h"

#include <stdio.h>
#include <string.h>

// Buffers are generously oversized: the widest kernel here works on 16x16 with
// a stride, and the sub-pixel ones read one extra row and column.
#define STRIDE 64
#define PLANE (STRIDE * 32)
#define ITERATIONS 200

// A fixed-seed xorshift, so a failure reproduces exactly and CI does not go
// intermittent. Not meant to be a good PRNG, just a repeatable one.
static uint32_t parity_state = 0x9E3779B9u;

static void parity_reseed(void) { parity_state = 0x9E3779B9u; }

static uint32_t parity_next(void) {
    parity_state ^= parity_state << 13;
    parity_state ^= parity_state >> 17;
    parity_state ^= parity_state << 5;
    return parity_state;
}

// Content is deliberately mixed: pure noise exercises the arithmetic, but flat
// and saturated runs are what expose saturation and rounding differences.
static void parity_fill(uint8_t *buffer, size_t length, int iteration) {
    switch (iteration % 4) {
        case 0:
            for (size_t i = 0; i < length; ++i) buffer[i] = (uint8_t)parity_next();
            break;
        case 1:
            memset(buffer, (int)(parity_next() & 0xFF), length);
            break;
        case 2:
            for (size_t i = 0; i < length; ++i) buffer[i] = (parity_next() & 1) ? 255 : 0;
            break;
        default:
            for (size_t i = 0; i < length; ++i) {
                uint32_t r = parity_next();
                buffer[i] = (uint8_t)((r & 0x7) + ((r & 8) ? 248 : 0));
            }
            break;
    }
}

static int parity_report(const char *what, unsigned long long a, unsigned long long b) {
    if (a == b) return 0;
    printf("      %s: C=%llu SIMD=%llu\n", what, a, b);
    return 1;
}

typedef void (*IntraPredFn)(uint8_t *, ptrdiff_t, const uint8_t *, const uint8_t *);
typedef unsigned int (*SadFn)(const uint8_t *, int, const uint8_t *, int);
typedef void (*SadX4Fn)(const uint8_t *, int, const uint8_t *const[4], int, uint32_t[4]);
typedef unsigned int (*VarianceFn)(const uint8_t *, int, const uint8_t *, int, unsigned int *);
typedef unsigned int (*SadAvgFn)(const uint8_t *, int, const uint8_t *, int, const uint8_t *);
typedef uint32_t (*SubpelVarFn)(const uint8_t *, int, int, int, const uint8_t *, int, uint32_t *);
typedef uint32_t (*SubpelVarAvgFn)(const uint8_t *, int, int, int, const uint8_t *, int,
                                   uint32_t *, const uint8_t *);

int rocray_parity_run_intra_pred(const void *reference, const void *candidate) {
    IntraPredFn c_impl = (IntraPredFn)reference;
    IntraPredFn simd_impl = (IntraPredFn)candidate;
    static uint8_t above[STRIDE], left[STRIDE], out_c[PLANE], out_simd[PLANE];
    int failures = 0;

    parity_reseed();
    for (int i = 0; i < ITERATIONS; ++i) {
        parity_fill(above, sizeof(above), i);
        parity_fill(left, sizeof(left), i + 1);
        // Predictors write only their own block, so a distinct filler makes an
        // out-of-block write visible rather than blending into the comparison.
        memset(out_c, 0xAA, sizeof(out_c));
        memset(out_simd, 0xAA, sizeof(out_simd));

        c_impl(out_c, STRIDE, above, left);
        simd_impl(out_simd, STRIDE, above, left);
        if (memcmp(out_c, out_simd, sizeof(out_c)) != 0) {
            printf("      iteration %d: predicted block differs\n", i);
            if (++failures > 2) break;
        }
    }
    return failures;
}

int rocray_parity_run_sad(const void *reference, const void *candidate) {
    SadFn c_impl = (SadFn)reference;
    SadFn simd_impl = (SadFn)candidate;
    static uint8_t a[PLANE], b[PLANE];
    int failures = 0;

    parity_reseed();
    for (int i = 0; i < ITERATIONS; ++i) {
        parity_fill(a, sizeof(a), i);
        parity_fill(b, sizeof(b), i + 1);
        failures += parity_report("sad", c_impl(a, STRIDE, b, STRIDE),
                                  simd_impl(a, STRIDE, b, STRIDE));
        if (failures > 2) break;
    }
    return failures;
}

int rocray_parity_run_sad_x4(const void *reference, const void *candidate) {
    SadX4Fn c_impl = (SadX4Fn)reference;
    SadX4Fn simd_impl = (SadX4Fn)candidate;
    static uint8_t src[PLANE], refs[4][PLANE];
    const uint8_t *ref_array[4] = { refs[0], refs[1], refs[2], refs[3] };
    uint32_t out_c[4], out_simd[4];
    int failures = 0;

    parity_reseed();
    for (int i = 0; i < ITERATIONS; ++i) {
        parity_fill(src, sizeof(src), i);
        for (int r = 0; r < 4; ++r) parity_fill(refs[r], sizeof(refs[r]), i + r + 1);
        memset(out_c, 0, sizeof(out_c));
        memset(out_simd, 0, sizeof(out_simd));

        c_impl(src, STRIDE, ref_array, STRIDE, out_c);
        simd_impl(src, STRIDE, ref_array, STRIDE, out_simd);
        for (int r = 0; r < 4; ++r) failures += parity_report("sad[n]", out_c[r], out_simd[r]);
        if (failures > 2) break;
    }
    return failures;
}

int rocray_parity_run_variance(const void *reference, const void *candidate) {
    VarianceFn c_impl = (VarianceFn)reference;
    VarianceFn simd_impl = (VarianceFn)candidate;
    static uint8_t a[PLANE], b[PLANE];
    int failures = 0;

    parity_reseed();
    for (int i = 0; i < ITERATIONS; ++i) {
        parity_fill(a, sizeof(a), i);
        parity_fill(b, sizeof(b), i + 1);
        unsigned int sse_c = 0, sse_simd = 0;
        failures += parity_report("variance", c_impl(a, STRIDE, b, STRIDE, &sse_c),
                                  simd_impl(a, STRIDE, b, STRIDE, &sse_simd));
        failures += parity_report("sse", sse_c, sse_simd);
        if (failures > 2) break;
    }
    return failures;
}

int rocray_parity_run_sad_avg(const void *reference, const void *candidate) {
    SadAvgFn c_impl = (SadAvgFn)reference;
    SadAvgFn simd_impl = (SadAvgFn)candidate;
    static uint8_t a[PLANE], b[PLANE], pred[PLANE];
    int failures = 0;

    parity_reseed();
    for (int i = 0; i < ITERATIONS; ++i) {
        parity_fill(a, sizeof(a), i);
        parity_fill(b, sizeof(b), i + 1);
        parity_fill(pred, sizeof(pred), i + 2);
        failures += parity_report("sad_avg", c_impl(a, STRIDE, b, STRIDE, pred),
                                  simd_impl(a, STRIDE, b, STRIDE, pred));
        if (failures > 2) break;
    }
    return failures;
}

int rocray_parity_run_subpel_var(const void *reference, const void *candidate) {
    SubpelVarFn c_impl = (SubpelVarFn)reference;
    SubpelVarFn simd_impl = (SubpelVarFn)candidate;
    static uint8_t src[PLANE], ref[PLANE];
    int failures = 0;

    parity_reseed();
    // Every eighth-pel offset: filter selection is exactly where these differ.
    for (int xoffset = 0; xoffset < 8 && failures <= 2; ++xoffset) {
        for (int yoffset = 0; yoffset < 8 && failures <= 2; ++yoffset) {
            parity_fill(src, sizeof(src), xoffset);
            parity_fill(ref, sizeof(ref), yoffset + 1);
            uint32_t sse_c = 0, sse_simd = 0;
            failures += parity_report(
                "subpel_var", c_impl(src, STRIDE, xoffset, yoffset, ref, STRIDE, &sse_c),
                simd_impl(src, STRIDE, xoffset, yoffset, ref, STRIDE, &sse_simd));
            failures += parity_report("sse", sse_c, sse_simd);
        }
    }
    return failures;
}

int rocray_parity_run_subpel_var_avg(const void *reference, const void *candidate) {
    SubpelVarAvgFn c_impl = (SubpelVarAvgFn)reference;
    SubpelVarAvgFn simd_impl = (SubpelVarAvgFn)candidate;
    static uint8_t src[PLANE], ref[PLANE], second[PLANE];
    int failures = 0;

    parity_reseed();
    for (int xoffset = 0; xoffset < 8 && failures <= 2; ++xoffset) {
        for (int yoffset = 0; yoffset < 8 && failures <= 2; ++yoffset) {
            parity_fill(src, sizeof(src), xoffset);
            parity_fill(ref, sizeof(ref), yoffset + 1);
            parity_fill(second, sizeof(second), xoffset + yoffset + 2);
            uint32_t sse_c = 0, sse_simd = 0;
            failures += parity_report(
                "subpel_var_avg",
                c_impl(src, STRIDE, xoffset, yoffset, ref, STRIDE, &sse_c, second),
                simd_impl(src, STRIDE, xoffset, yoffset, ref, STRIDE, &sse_simd, second));
            failures += parity_report("sse", sse_c, sse_simd);
        }
    }
    return failures;
}

int main(void) {
    int failed_kernels = 0;

    printf("libvpx SIMD/C parity: %d kernels\n", rocray_parity_kernel_count);
    if (rocray_parity_kernel_count == 0) {
        // A table of zero kernels would report success while checking nothing,
        // which is exactly the failure this test exists to prevent.
        printf("FAIL: no kernels in the table; the generator found no dispatch\n");
        return 1;
    }

    for (int i = 0; i < rocray_parity_kernel_count; ++i) {
        const RocRayParityKernel *kernel = &rocray_parity_kernels[i];
        if (kernel->run(kernel->reference, kernel->candidate) != 0) {
            printf("  FAIL %s\n", kernel->name);
            ++failed_kernels;
        }
    }

    if (failed_kernels != 0) {
        printf("FAIL: %d of %d kernels disagree with their C reference\n", failed_kernels,
               rocray_parity_kernel_count);
        return 1;
    }
    printf("OK: all %d kernels match their C reference\n", rocray_parity_kernel_count);
    return 0;
}
