// Single translation unit for the vendored msf_gif single-header library,
// plus a narrow C shim over it.
//
// Upstream: https://github.com/notnullnotvoid/msf_gif (MIT or public domain).
//
// The shim exists so the Zig side never has to see `MsfGifState`. The host is
// built freestanding (no libc headers), while msf_gif needs <string.h> and
// friends, so this file is compiled into its own libc-linked static library
// and the host talks to it through the primitive-only functions below. That
// also means no hand-mirrored struct layout to drift out of sync.
//
// Only one recording is active at a time, so the encoder state is a single
// static instance rather than something the caller has to allocate and pass.
//
// This builds freestanding, like the rest of the host: no libc headers are
// available (the Windows cross-compile has no MSVC SDK). The handful msf_gif
// needs -- malloc/realloc/free and memcpy/memset -- are declared by the minimal
// shims in this directory's `shim/`, and the symbols resolve at final link, the
// same way raylib's uses of them already do.

#define MSF_GIF_IMPL
#include "msf_gif.h"

static MsfGifState rocray_gif_state;

int rocray_gif_begin(int width, int height, MsfGifFileWriteFunc write_func, void *write_data) {
    return msf_gif_begin_to_file(&rocray_gif_state, width, height, write_func, write_data);
}

int rocray_gif_frame(unsigned char *pixels, int centiseconds_per_frame, int quality, int pitch_in_bytes) {
    return msf_gif_frame_to_file(&rocray_gif_state, pixels, centiseconds_per_frame, quality, pitch_in_bytes);
}

int rocray_gif_end(void) {
    return msf_gif_end_to_file(&rocray_gif_state);
}
