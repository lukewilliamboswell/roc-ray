// Narrow C shim over libvpx's VP8 encoder.
//
// The host module is built freestanding and has no C headers, so it cannot
// @cImport vpx_encoder.h. This shim lives inside the libvpx library (which does
// have libc) and exposes only primitives and opaque pointers, so the Zig side
// needs no vpx types and there is no struct layout to mirror.
//
// Only one recording is active at a time, so the codec context and its input
// image are single static instances rather than something the caller allocates.
//
// The caller fills the Y/U/V planes in place through rocray_vp8_plane(), which
// avoids copying a frame just to hand it across the boundary.

#include <string.h>

#include "vpx/vpx_encoder.h"
#include "vpx/vp8cx.h"

typedef void (*RocRayVp8PacketFn)(void *context, const unsigned char *data,
                                  unsigned long size, long long timecode_ms,
                                  int keyframe);

static vpx_codec_ctx_t rocray_vp8_codec;
static vpx_image_t rocray_vp8_image;
static int rocray_vp8_open = 0;

int rocray_vp8_begin(int width, int height, int fps, int bitrate_kbps) {
    vpx_codec_enc_cfg_t cfg;

    if (rocray_vp8_open) return 0;
    if (width <= 0 || height <= 0) return 0;

    if (vpx_codec_enc_config_default(vpx_codec_vp8_cx(), &cfg, 0) != VPX_CODEC_OK) return 0;

    cfg.g_w = (unsigned int)width;
    cfg.g_h = (unsigned int)height;
    // Timebase in milliseconds, matching the muxer's timecode scale, so a
    // frame's presentation time is the same number in both.
    cfg.g_timebase.num = 1;
    cfg.g_timebase.den = 1000;
    cfg.rc_target_bitrate = (unsigned int)(bitrate_kbps > 0 ? bitrate_kbps : 1024);
    cfg.g_threads = 1;
    cfg.g_lag_in_frames = 0;
    cfg.g_error_resilient = 0;
    cfg.rc_end_usage = VPX_VBR;
    // One keyframe every two seconds keeps seeking usable without bloating a
    // short clip.
    cfg.kf_mode = VPX_KF_AUTO;
    cfg.kf_max_dist = (unsigned int)(fps > 0 ? fps * 2 : 50);

    if (vpx_codec_enc_init(&rocray_vp8_codec, vpx_codec_vp8_cx(), &cfg, 0) != VPX_CODEC_OK) {
        return 0;
    }

    if (!vpx_img_alloc(&rocray_vp8_image, VPX_IMG_FMT_I420,
                       (unsigned int)width, (unsigned int)height, 32)) {
        vpx_codec_destroy(&rocray_vp8_codec);
        return 0;
    }

    // Realtime is the fastest deadline; the readback already dominates.
    vpx_codec_control_(&rocray_vp8_codec, VP8E_SET_CPUUSED, 4);

    rocray_vp8_open = 1;
    return 1;
}

unsigned char *rocray_vp8_plane(int plane) {
    if (!rocray_vp8_open || plane < 0 || plane > 2) return 0;
    return rocray_vp8_image.planes[plane];
}

int rocray_vp8_plane_stride(int plane) {
    if (!rocray_vp8_open || plane < 0 || plane > 2) return 0;
    return rocray_vp8_image.stride[plane];
}

static int rocray_vp8_drain(RocRayVp8PacketFn callback, void *context) {
    vpx_codec_iter_t iter = 0;
    const vpx_codec_cx_pkt_t *pkt;

    while ((pkt = vpx_codec_get_cx_data(&rocray_vp8_codec, &iter)) != 0) {
        if (pkt->kind != VPX_CODEC_CX_FRAME_PKT) continue;
        callback(context, (const unsigned char *)pkt->data.frame.buf,
                 (unsigned long)pkt->data.frame.sz,
                 (long long)pkt->data.frame.pts,
                 (pkt->data.frame.flags & VPX_FRAME_IS_KEY) != 0);
    }
    return 1;
}

int rocray_vp8_encode(long long timecode_ms, int duration_ms, int force_keyframe,
                      RocRayVp8PacketFn callback, void *context) {
    vpx_enc_frame_flags_t flags = force_keyframe ? VPX_EFLAG_FORCE_KF : 0;

    if (!rocray_vp8_open) return 0;
    if (vpx_codec_encode(&rocray_vp8_codec, &rocray_vp8_image, (vpx_codec_pts_t)timecode_ms,
                         (unsigned long)(duration_ms > 0 ? duration_ms : 1),
                         flags, VPX_DL_REALTIME) != VPX_CODEC_OK) {
        return 0;
    }
    return rocray_vp8_drain(callback, context);
}

int rocray_vp8_flush(RocRayVp8PacketFn callback, void *context) {
    if (!rocray_vp8_open) return 0;
    // A null image tells libvpx there are no more frames, so it emits whatever
    // it is still holding.
    if (vpx_codec_encode(&rocray_vp8_codec, 0, 0, 1, 0, VPX_DL_REALTIME) != VPX_CODEC_OK) {
        return 0;
    }
    return rocray_vp8_drain(callback, context);
}

void rocray_vp8_end(void) {
    if (!rocray_vp8_open) return;
    vpx_img_free(&rocray_vp8_image);
    vpx_codec_destroy(&rocray_vp8_codec);
    rocray_vp8_open = 0;
}
