//! VP8 video encoding for captured frames, wrapping the vendored libvpx.
//!
//! Frames arrive as tightly packed top-down RGBA8 (what `rlReadScreenPixels`
//! produces) and are converted to the I420 that VP8 encodes. Encoded packets go
//! straight into `webm_muxer`, so memory stays bounded by one frame however
//! long the recording runs.
//!
//! libvpx itself is reached through the primitive-only shim in
//! `vendor/libvpx/shim/rocray_vp8.c`: the host is built freestanding and has no
//! C headers to `@cImport`.

const std = @import("std");
const builtin = @import("builtin");
const webm = @import("webm_muxer.zig");

/// Shape of the per-packet callback libvpx's shim invokes.
const PacketFn = *const fn (
    context: ?*anyopaque,
    data: [*]const u8,
    size: c_ulong,
    timecode_ms: c_longlong,
    keyframe: c_int,
) callconv(.c) void;

extern fn rocray_vp8_begin(width: c_int, height: c_int, fps: c_int, bitrate_kbps: c_int) c_int;
extern fn rocray_vp8_plane(plane: c_int) ?[*]u8;
extern fn rocray_vp8_plane_stride(plane: c_int) c_int;
extern fn rocray_vp8_encode(
    timecode_ms: c_longlong,
    duration_ms: c_int,
    force_keyframe: c_int,
    callback: PacketFn,
    context: ?*anyopaque,
) c_int;
extern fn rocray_vp8_flush(callback: PacketFn, context: ?*anyopaque) c_int;
extern fn rocray_vp8_end() void;
extern fn rocray_vp8_is_open() c_int;

/// Errors an encoder can report. Each maps onto a `capture.err_*` code.
pub const Error = error{
    /// The output file could not be created or written.
    WriteFailed,
    /// libvpx could not allocate its context or image.
    OutOfMemory,
    /// libvpx rejected a frame, or the muxer refused one.
    EncodeFailed,
    /// A previous encoder was never closed. libvpx's state here is a single
    /// static instance, so this is a host bug rather than anything an app did.
    AlreadyOpen,
};

/// Pick a target bitrate for a resolution and frame rate.
///
/// VP8 needs an explicit budget, and a fixed one looks either starved at 1080p
/// or wasteful at 320x180. This tracks pixel throughput at roughly 0.09 bits
/// per pixel per frame, which holds up for the flat colours and text that
/// screen recordings are mostly made of.
pub fn bitrateKbps(width: u32, height: u32, fps: i32) c_int {
    const rate: u64 = @intCast(@max(fps, 1));
    const pixels = @as(u64, width) *| @as(u64, height);
    const bits_per_second = pixels *| rate *| 9 / 100;
    const kbps = bits_per_second / 1000;
    const clamped = std.math.clamp(kbps, 256, 40_000);
    return @intCast(clamped);
}

/// Convert one BT.601 limited-range luma sample from RGB.
fn lumaFromRgb(r: i32, g: i32, b: i32) u8 {
    // Y = 16 + (65.481 R + 128.553 G + 24.966 B) / 255, in 16.8 fixed point.
    const y = (66 * r + 129 * g + 25 * b + 128) >> 8;
    return @intCast(std.math.clamp(y + 16, 0, 255));
}

fn blueChromaFromRgb(r: i32, g: i32, b: i32) u8 {
    const u = (-38 * r - 74 * g + 112 * b + 128) >> 8;
    return @intCast(std.math.clamp(u + 128, 0, 255));
}

fn redChromaFromRgb(r: i32, g: i32, b: i32) u8 {
    const v = (112 * r - 94 * g - 18 * b + 128) >> 8;
    return @intCast(std.math.clamp(v + 128, 0, 255));
}

/// Pixels converted per vector step of `rgbaToI420`.
///
/// Sixteen RGBA pixels is exactly one 64-byte cache line in, and one 32-bit
/// lane per pixel keeps the fixed-point maths in range with no widening step.
/// That is four SSE2 registers on the baseline x86_64 the host targets are
/// built for, and four NEON registers on arm64; measured faster there than
/// either 8 or 32 lanes.
const vector_pixels = 16;
/// One chroma sample covers a 2x2 block, so a vector step of pixels is half as
/// many chroma samples -- which only works if the step is even.
const chroma_vector_pixels = blk: {
    std.debug.assert(vector_pixels % 2 == 0);
    break :blk vector_pixels / 2;
};

const PixelVec = @Vector(vector_pixels, u32);
const ShiftVec = @Vector(vector_pixels, u5);
const AverageVec = @Vector(chroma_vector_pixels, u32);
const SignedAverageVec = @Vector(chroma_vector_pixels, i32);
const ChromaShiftVec = @Vector(chroma_vector_pixels, u5);

/// Lanes holding the left and right pixel of each 2x2 block in a `PixelVec`.
const left_lanes: @Vector(chroma_vector_pixels, i32) = blk: {
    var lanes: [chroma_vector_pixels]i32 = undefined;
    for (&lanes, 0..) |*lane, i| lane.* = @intCast(i * 2);
    break :blk lanes;
};
const right_lanes: @Vector(chroma_vector_pixels, i32) = blk: {
    var lanes: [chroma_vector_pixels]i32 = undefined;
    for (&lanes, 0..) |*lane, i| lane.* = @intCast(i * 2 + 1);
    break :blk lanes;
};

/// Load `vector_pixels` packed pixels as one 32-bit lane each.
///
/// The bytes go through an array rather than a pointer cast so the load stays
/// alignment-agnostic: `rgba` is a `[]const u8` and nothing promises the
/// caller's buffer, or an offset into it, is 4-byte aligned.
inline fn loadPixels(rgba: []const u8, offset: usize) PixelVec {
    const bytes: [vector_pixels * 4]u8 = rgba[offset..][0 .. vector_pixels * 4].*;
    return @bitCast(bytes);
}

/// Luma for a whole vector of pixels.
///
/// `@intCast` rather than `@truncate` on the way back to bytes: 255 of each
/// channel sums to 56228, so the u32 lanes cannot overflow and the result is
/// always 16..235. The cast asserts that in safe builds instead of silently
/// wrapping if the arithmetic above is ever changed.
inline fn lumaVec(r: PixelVec, g: PixelVec, b: PixelVec) [vector_pixels]u8 {
    const scaled = @as(PixelVec, @splat(66)) * r +
        @as(PixelVec, @splat(129)) * g +
        @as(PixelVec, @splat(25)) * b +
        @as(PixelVec, @splat(128));
    const y = (scaled >> @as(ShiftVec, @splat(8))) + @as(PixelVec, @splat(16));
    return @as(@Vector(vector_pixels, u8), @intCast(y));
}

/// Average one channel over each 2x2 block of a vector-wide row pair.
///
/// Rounded, not truncated, exactly as the scalar path: truncation biases every
/// chroma sample down by up to three quarters of a level. The sum peaks at
/// 4 * 255 + 2, so the u32 lanes have room to spare.
inline fn blockAverage(top: PixelVec, bottom: PixelVec) AverageVec {
    const sum = @shuffle(u32, top, top, left_lanes) + @shuffle(u32, top, top, right_lanes) +
        @shuffle(u32, bottom, bottom, left_lanes) + @shuffle(u32, bottom, bottom, right_lanes);
    return (sum + @as(AverageVec, @splat(2))) >> @as(ChromaShiftVec, @splat(2));
}

/// One chroma plane for a vector of averaged blocks.
///
/// Coefficients are passed in so U and V share the code. Both land in 16..240
/// for any byte-valued input, so as in `lumaVec` the `@intCast` back to bytes
/// is a checked assertion rather than a clamp.
inline fn chromaVec(
    r: SignedAverageVec,
    g: SignedAverageVec,
    b: SignedAverageVec,
    comptime r_coeff: i32,
    comptime g_coeff: i32,
    comptime b_coeff: i32,
) [chroma_vector_pixels]u8 {
    const scaled = @as(SignedAverageVec, @splat(r_coeff)) * r +
        @as(SignedAverageVec, @splat(g_coeff)) * g +
        @as(SignedAverageVec, @splat(b_coeff)) * b +
        @as(SignedAverageVec, @splat(128));
    // Signed, so this is an arithmetic shift, matching `blueChromaFromRgb`.
    const out = (scaled >> @as(ChromaShiftVec, @splat(8))) + @as(SignedAverageVec, @splat(128));
    return @as(@Vector(chroma_vector_pixels, u8), @intCast(out));
}

/// Convert tightly packed top-down RGBA8 into the encoder's I420 planes.
///
/// The frame is walked once, in 2x2 blocks: each block's four pixels are loaded
/// together, produce four luma samples, and are averaged for the one U and V
/// sample that covers them. Luma and chroma used to be two separate passes,
/// which read the whole 8MB of a 1080p frame twice and left the second pass
/// gathering four strided pixels per output sample. Fusing them halves the read
/// traffic and, more importantly, puts the four pixels in registers for both
/// uses, which is what lets the hot rows run as `vector_pixels`-wide SIMD.
///
/// Measured on a 1920x1080 frame against the two-pass version it replaced:
/// 2.41ms -> 0.87ms for baseline x86_64 at ReleaseFast, which is what releases
/// ship. A `Debug` build is the one case that gets slower, 46ms -> 60ms, because
/// unoptimized vector code lowers lane by lane. That is the right way round:
/// `zig test` runs in Debug, so the path releases actually use is the one the
/// tests cover, and capture at Debug speeds was never real-time anyway.
///
/// Chroma is averaged over each 2x2 block, so an odd width or height reuses the
/// last row or column rather than reading past the frame.
///
/// The three destination planes must not overlap each other or `rgba`. That was
/// true of the two-pass version by accident and is true here by requirement:
/// stores from one block are now visible to the next block's loads. libvpx
/// allocates the planes separately from the frame buffer, so this holds.
pub fn rgbaToI420(
    rgba: []const u8,
    width: u32,
    height: u32,
    y_plane: []u8,
    y_stride: usize,
    u_plane: []u8,
    u_stride: usize,
    v_plane: []u8,
    v_stride: usize,
) void {
    const w: usize = width;
    const h: usize = height;
    const row_bytes = w * 4;

    var top: usize = 0;
    var chroma_row: usize = 0;
    while (top < h) : ({
        top += 2;
        chroma_row += 1;
    }) {
        // An odd height leaves the last block without a second row. Reusing the
        // first keeps the average over four samples, and keeps the read inside
        // the frame.
        const has_bottom = top + 1 < h;
        const top_src = top * row_bytes;
        const bottom_src = if (has_bottom) top_src + row_bytes else top_src;
        const top_dst = top * y_stride;
        const bottom_dst = top_dst + y_stride;
        const u_row = chroma_row * u_stride;
        const v_row = chroma_row * v_stride;

        var x: usize = 0;
        var chroma_col: usize = 0;

        // The lane layout below reads a pixel as R | G<<8 | B<<16, which is what
        // packed RGBA bytes bitcast to on a little-endian target. Every host
        // target is little-endian; anything else falls through to the scalar
        // loop below with the same result.
        if (comptime builtin.cpu.arch.endian() == .little) {
            while (x + vector_pixels <= w) : ({
                x += vector_pixels;
                chroma_col += chroma_vector_pixels;
            }) {
                const top_px = loadPixels(rgba, top_src + x * 4);
                const bottom_px = loadPixels(rgba, bottom_src + x * 4);

                const byte: PixelVec = @splat(0xFF);
                const top_r = top_px & byte;
                const top_g = (top_px >> @as(ShiftVec, @splat(8))) & byte;
                const top_b = (top_px >> @as(ShiftVec, @splat(16))) & byte;
                const bottom_r = bottom_px & byte;
                const bottom_g = (bottom_px >> @as(ShiftVec, @splat(8))) & byte;
                const bottom_b = (bottom_px >> @as(ShiftVec, @splat(16))) & byte;

                y_plane[top_dst + x ..][0..vector_pixels].* = lumaVec(top_r, top_g, top_b);
                if (has_bottom) {
                    y_plane[bottom_dst + x ..][0..vector_pixels].* = lumaVec(bottom_r, bottom_g, bottom_b);
                }

                const avg_r: SignedAverageVec = @intCast(blockAverage(top_r, bottom_r));
                const avg_g: SignedAverageVec = @intCast(blockAverage(top_g, bottom_g));
                const avg_b: SignedAverageVec = @intCast(blockAverage(top_b, bottom_b));
                u_plane[u_row + chroma_col ..][0..chroma_vector_pixels].* =
                    chromaVec(avg_r, avg_g, avg_b, -38, -74, 112);
                v_plane[v_row + chroma_col ..][0..chroma_vector_pixels].* =
                    chromaVec(avg_r, avg_g, avg_b, 112, -94, -18);
            }
        }

        // Whatever the vector step could not cover: fewer than `vector_pixels`
        // columns left, and an odd width's final lone column.
        while (x < w) : ({
            x += 2;
            chroma_col += 1;
        }) {
            // As with `has_bottom`, an odd width reuses the last column. Both
            // luma stores then land on the same byte with the same value, which
            // is cheaper than branching for the once-per-row case.
            const right = if (x + 1 < w) x + 1 else x;
            const top_left = top_src + x * 4;
            const top_right = top_src + right * 4;
            const bottom_left = bottom_src + x * 4;
            const bottom_right = bottom_src + right * 4;

            const r0: i32 = rgba[top_left];
            const g0: i32 = rgba[top_left + 1];
            const b0: i32 = rgba[top_left + 2];
            const r1: i32 = rgba[top_right];
            const g1: i32 = rgba[top_right + 1];
            const b1: i32 = rgba[top_right + 2];
            const r2: i32 = rgba[bottom_left];
            const g2: i32 = rgba[bottom_left + 1];
            const b2: i32 = rgba[bottom_left + 2];
            const r3: i32 = rgba[bottom_right];
            const g3: i32 = rgba[bottom_right + 1];
            const b3: i32 = rgba[bottom_right + 2];

            y_plane[top_dst + x] = lumaFromRgb(r0, g0, b0);
            y_plane[top_dst + right] = lumaFromRgb(r1, g1, b1);
            if (has_bottom) {
                y_plane[bottom_dst + x] = lumaFromRgb(r2, g2, b2);
                y_plane[bottom_dst + right] = lumaFromRgb(r3, g3, b3);
            }

            // Rounded, not truncated: truncation biases every chroma sample
            // down by up to three quarters of a level.
            const r = @divTrunc(r0 + r1 + r2 + r3 + 2, 4);
            const g = @divTrunc(g0 + g1 + g2 + g3 + 2, 4);
            const b = @divTrunc(b0 + b1 + b2 + b3 + 2, 4);

            u_plane[u_row + chroma_col] = blueChromaFromRgb(r, g, b);
            v_plane[v_row + chroma_col] = redChromaFromRgb(r, g, b);
        }
    }
}

/// An open WebM file with a VP8 encoder feeding it.
pub const Encoder = struct {
    muxer: webm.Muxer,
    width: u32,
    height: u32,
    fps: i32,
    frame_index: u64,
    /// Latched so a muxer failure inside the C callback survives back to Zig.
    failed: bool,

    /// libvpx hands each encoded packet back through this.
    fn onPacket(
        context: ?*anyopaque,
        data: [*]const u8,
        size: c_ulong,
        timecode_ms: c_longlong,
        keyframe: c_int,
    ) callconv(.c) void {
        const self: *Encoder = @ptrCast(@alignCast(context orelse return));
        if (self.failed) return;
        const payload = data[0..@intCast(size)];
        const timecode: u64 = if (timecode_ms < 0) 0 else @intCast(timecode_ms);
        self.muxer.addFrame(payload, timecode, keyframe != 0) catch {
            self.failed = true;
        };
    }

    /// Presentation time of a frame index, in whole milliseconds.
    ///
    /// Computed as an exact rational rather than accumulating a per-frame
    /// duration: `1000 / 60` truncates to 16ms, which would play a 60fps
    /// recording back 4% fast and drift further the longer it runs.
    fn timecodeMs(self: *const Encoder, index: u64) u64 {
        const rate: u64 = @intCast(@max(self.fps, 1));
        return index *| 1000 / rate;
    }

    /// Milliseconds between a frame and the next one.
    fn frameDurationMs(self: *const Encoder, index: u64) u64 {
        return @max(self.timecodeMs(index + 1) -| self.timecodeMs(index), 1);
    }

    /// Bytes written to the file so far.
    pub fn bytesWritten(self: *const Encoder) u64 {
        return self.muxer.bytesWritten();
    }

    /// Encode one frame of tightly packed top-down RGBA8 pixels.
    pub fn addFrame(self: *Encoder, pixels: []const u8) Error!void {
        const expected = @as(usize, self.width) * @as(usize, self.height) * 4;
        if (pixels.len < expected) return Error.EncodeFailed;

        const y_stride: usize = @intCast(rocray_vp8_plane_stride(0));
        const u_stride: usize = @intCast(rocray_vp8_plane_stride(1));
        const v_stride: usize = @intCast(rocray_vp8_plane_stride(2));
        const y_ptr = rocray_vp8_plane(0) orelse return Error.EncodeFailed;
        const u_ptr = rocray_vp8_plane(1) orelse return Error.EncodeFailed;
        const v_ptr = rocray_vp8_plane(2) orelse return Error.EncodeFailed;

        const chroma_height = (self.height + 1) / 2;
        rgbaToI420(
            pixels,
            self.width,
            self.height,
            y_ptr[0 .. y_stride * self.height],
            y_stride,
            u_ptr[0 .. u_stride * chroma_height],
            u_stride,
            v_ptr[0 .. v_stride * chroma_height],
            v_stride,
        );

        const timecode = self.timecodeMs(self.frame_index);
        const duration = self.frameDurationMs(self.frame_index);
        self.frame_index += 1;

        const ok = rocray_vp8_encode(
            @intCast(timecode),
            @intCast(duration),
            // Force a keyframe on the first frame so the file opens cleanly.
            if (self.frame_index == 1) 1 else 0,
            Encoder.onPacket,
            self,
        );
        if (self.failed) return Error.WriteFailed;
        if (ok == 0) return Error.EncodeFailed;
    }

    /// Drain the encoder and finish the container.
    pub fn finish(self: *Encoder) Error!void {
        const ok = rocray_vp8_flush(Encoder.onPacket, self);
        rocray_vp8_end();

        // A muxer that already failed cannot be finished cleanly; close it and
        // report, rather than writing more into a broken file.
        if (self.failed) {
            self.muxer.abort();
            return Error.WriteFailed;
        }

        const duration = self.timecodeMs(self.frame_index);
        self.muxer.finish(duration) catch {
            return Error.WriteFailed;
        };
        if (self.failed) return Error.WriteFailed;
        if (ok == 0) return Error.EncodeFailed;
    }

    /// Abandon the recording without finishing the container.
    pub fn abort(self: *Encoder) void {
        rocray_vp8_end();
        self.muxer.abort();
    }
};

/// Create a WebM file and start a VP8 encoder for it.
pub fn open(
    io: std.Io,
    encoder: *Encoder,
    path: []const u8,
    width: u32,
    height: u32,
    fps: i32,
) Error!void {
    if (width == 0 or height == 0) return Error.EncodeFailed;

    // Checked before anything is written, and before `encoder` is overwritten:
    // libvpx's context here is a single static instance, so starting a second
    // encoder while one is live would strand the first one's file handle and
    // leave every later recording failing for the rest of the process.
    if (rocray_vp8_is_open() != 0) return Error.AlreadyOpen;

    var muxer: webm.Muxer = undefined;
    webm.open(io, &muxer, path, width, height) catch |err| return switch (err) {
        webm.Error.WriteFailed => Error.WriteFailed,
        webm.Error.NonMonotonicTimecode => Error.EncodeFailed,
    };

    if (rocray_vp8_begin(@intCast(width), @intCast(height), fps, bitrateKbps(width, height, fps)) == 0) {
        muxer.abort();
        return Error.OutOfMemory;
    }

    encoder.* = .{
        .muxer = muxer,
        .width = width,
        .height = height,
        .fps = fps,
        .frame_index = 0,
        .failed = false,
    };
}

test "bitrateKbps scales with pixel throughput and stays in range" {
    // 640x360 at 25fps is a typical README clip.
    const modest = bitrateKbps(640, 360, 25);
    try std.testing.expect(modest > 256 and modest < 2000);

    // More pixels and more frames both cost more.
    try std.testing.expect(bitrateKbps(1920, 1080, 25) > modest);
    try std.testing.expect(bitrateKbps(640, 360, 50) > modest);

    // A tiny capture still gets a usable floor rather than a starved stream.
    try std.testing.expectEqual(@as(c_int, 256), bitrateKbps(16, 16, 1));
    // And an enormous one is capped rather than asking for a silly budget.
    try std.testing.expectEqual(@as(c_int, 40_000), bitrateKbps(7680, 4320, 60));
}

test "luma conversion matches BT.601 limited range at the extremes" {
    // Limited range puts black at 16 and white at 235.
    try std.testing.expectEqual(@as(u8, 16), lumaFromRgb(0, 0, 0));
    try std.testing.expectEqual(@as(u8, 235), lumaFromRgb(255, 255, 255));
    // Green dominates luma, blue contributes least.
    try std.testing.expect(lumaFromRgb(0, 255, 0) > lumaFromRgb(255, 0, 0));
    try std.testing.expect(lumaFromRgb(255, 0, 0) > lumaFromRgb(0, 0, 255));
}

test "chroma conversion centres on neutral for greys" {
    // A grey has no colour difference, so both chroma planes sit at 128.
    try std.testing.expectEqual(@as(u8, 128), blueChromaFromRgb(128, 128, 128));
    try std.testing.expectEqual(@as(u8, 128), redChromaFromRgb(128, 128, 128));
    // Blue pushes U up and V down; red does the opposite.
    try std.testing.expect(blueChromaFromRgb(0, 0, 255) > 128);
    try std.testing.expect(redChromaFromRgb(0, 0, 255) < 128);
    try std.testing.expect(redChromaFromRgb(255, 0, 0) > 128);
    try std.testing.expect(blueChromaFromRgb(255, 0, 0) < 128);
}

test "rgbaToI420 converts a solid frame to flat planes" {
    const width = 4;
    const height = 4;
    var rgba: [width * height * 4]u8 = undefined;
    for (0..width * height) |i| {
        rgba[i * 4 + 0] = 255;
        rgba[i * 4 + 1] = 0;
        rgba[i * 4 + 2] = 0;
        rgba[i * 4 + 3] = 255;
    }

    var y_plane: [width * height]u8 = @splat(0);
    var u_plane: [(width / 2) * (height / 2)]u8 = @splat(0);
    var v_plane: [(width / 2) * (height / 2)]u8 = @splat(0);

    rgbaToI420(&rgba, width, height, &y_plane, width, &u_plane, width / 2, &v_plane, width / 2);

    const expected_y = lumaFromRgb(255, 0, 0);
    for (y_plane) |sample| try std.testing.expectEqual(expected_y, sample);
    for (u_plane) |sample| try std.testing.expectEqual(blueChromaFromRgb(255, 0, 0), sample);
    for (v_plane) |sample| try std.testing.expectEqual(redChromaFromRgb(255, 0, 0), sample);
}

test "rgbaToI420 honours a plane stride wider than the frame" {
    const width = 2;
    const height = 2;
    const stride = 8;
    var rgba: [width * height * 4]u8 = @splat(0);
    for (0..width * height) |i| rgba[i * 4 + 3] = 255;

    var y_plane: [stride * height]u8 = @splat(0xAA);
    var u_plane: [stride]u8 = @splat(0xAA);
    var v_plane: [stride]u8 = @splat(0xAA);

    rgbaToI420(&rgba, width, height, &y_plane, stride, &u_plane, stride, &v_plane, stride);

    // Black converts to luma 16 inside the frame, and the padding past each
    // row's width must be left alone rather than overwritten.
    try std.testing.expectEqual(@as(u8, 16), y_plane[0]);
    try std.testing.expectEqual(@as(u8, 16), y_plane[1]);
    try std.testing.expectEqual(@as(u8, 0xAA), y_plane[2]);
    try std.testing.expectEqual(@as(u8, 16), y_plane[stride]);
    try std.testing.expectEqual(@as(u8, 0xAA), y_plane[stride + 2]);
}

/// The two-pass conversion `rgbaToI420` replaced, kept as a test oracle.
///
/// Deliberately the naive shape: one pass for luma, a second gathering four
/// strided pixels per chroma sample. Obviously correct and independent of the
/// fused vector code, so a byte-for-byte match against it is real evidence that
/// the rewrite changed only the speed.
fn rgbaToI420TwoPass(
    rgba: []const u8,
    width: u32,
    height: u32,
    y_plane: []u8,
    y_stride: usize,
    u_plane: []u8,
    u_stride: usize,
    v_plane: []u8,
    v_stride: usize,
) void {
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const src = (@as(usize, row) * @as(usize, width) + @as(usize, col)) * 4;
            const r: i32 = rgba[src];
            const g: i32 = rgba[src + 1];
            const b: i32 = rgba[src + 2];
            y_plane[@as(usize, row) * y_stride + @as(usize, col)] = lumaFromRgb(r, g, b);
        }
    }

    var chroma_row: u32 = 0;
    while (chroma_row * 2 < height) : (chroma_row += 1) {
        var chroma_col: u32 = 0;
        while (chroma_col * 2 < width) : (chroma_col += 1) {
            const x0 = chroma_col * 2;
            const y0 = chroma_row * 2;
            const x1 = if (x0 + 1 < width) x0 + 1 else x0;
            const y1 = if (y0 + 1 < height) y0 + 1 else y0;

            var r: i32 = 0;
            var g: i32 = 0;
            var b: i32 = 0;
            for ([_]u32{ y0, y1 }) |sy| {
                for ([_]u32{ x0, x1 }) |sx| {
                    const src = (@as(usize, sy) * @as(usize, width) + @as(usize, sx)) * 4;
                    r += rgba[src];
                    g += rgba[src + 1];
                    b += rgba[src + 2];
                }
            }
            r = @divTrunc(r + 2, 4);
            g = @divTrunc(g + 2, 4);
            b = @divTrunc(b + 2, 4);

            u_plane[@as(usize, chroma_row) * u_stride + @as(usize, chroma_col)] = blueChromaFromRgb(r, g, b);
            v_plane[@as(usize, chroma_row) * v_stride + @as(usize, chroma_col)] = redChromaFromRgb(r, g, b);
        }
    }
}

test "rgbaToI420 matches the two-pass reference on a noisy gradient" {
    const alloc = std.testing.allocator;

    // Sizes chosen to cover every path: a frame narrower than one vector step,
    // one exactly a whole number of steps, one whose remainder falls in the
    // scalar tail, and odd widths and heights in both.
    const sizes = [_][2]u32{
        .{ 1, 1 },   .{ 2, 1 },   .{ 1, 2 },   .{ 3, 3 },
        .{ 15, 7 },  .{ 16, 16 }, .{ 17, 9 },  .{ 32, 4 },
        .{ 33, 33 }, .{ 47, 11 }, .{ 64, 48 }, .{ 37, 23 },
    };

    for (sizes) |size| {
        const w = size[0];
        const h = size[1];
        // Strides deliberately wider than the frame, and not a multiple of the
        // vector step, so a lane-wide store cannot accidentally land right.
        const y_stride: usize = w + 7;
        const chroma_stride: usize = (w + 1) / 2 + 5;
        const chroma_height = (h + 1) / 2;

        const rgba = try alloc.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
        defer alloc.free(rgba);

        // A gradient with noise on top: neighbouring pixels differ, so a block
        // read from the wrong column or row shows up immediately, unlike the
        // flat frames the other tests use.
        var prng = std.Random.DefaultPrng.init(@as(u64, w) * 1013 + h);
        const rand = prng.random();
        for (0..h) |py| {
            for (0..w) |px| {
                const i = (py * w + px) * 4;
                rgba[i + 0] = @truncate(px *% 7 +% rand.int(u8) / 4);
                rgba[i + 1] = @truncate(py *% 11 +% rand.int(u8) / 4);
                rgba[i + 2] = @truncate((px ^ py) *% 3 +% rand.int(u8) / 4);
                rgba[i + 3] = 255;
            }
        }

        const y_len = y_stride * h;
        const chroma_len = chroma_stride * chroma_height;
        const planes = try alloc.alloc(u8, (y_len + chroma_len * 2) * 2);
        defer alloc.free(planes);
        // 0xAA everywhere, so stride padding either side must come back
        // untouched as well as the samples matching.
        @memset(planes, 0xAA);

        const want_y = planes[0..y_len];
        const want_u = planes[y_len..][0..chroma_len];
        const want_v = planes[y_len + chroma_len ..][0..chroma_len];
        const rest = planes[y_len + chroma_len * 2 ..];
        const got_y = rest[0..y_len];
        const got_u = rest[y_len..][0..chroma_len];
        const got_v = rest[y_len + chroma_len ..][0..chroma_len];

        rgbaToI420TwoPass(rgba, w, h, want_y, y_stride, want_u, chroma_stride, want_v, chroma_stride);
        rgbaToI420(rgba, w, h, got_y, y_stride, got_u, chroma_stride, got_v, chroma_stride);

        try std.testing.expectEqualSlices(u8, want_y, got_y);
        try std.testing.expectEqualSlices(u8, want_u, got_u);
        try std.testing.expectEqualSlices(u8, want_v, got_v);
    }
}

test "rgbaToI420 handles odd dimensions without reading past the frame" {
    const width = 3;
    const height = 3;
    var rgba: [width * height * 4]u8 = @splat(0);
    for (0..width * height) |i| {
        rgba[i * 4 + 1] = 200;
        rgba[i * 4 + 3] = 255;
    }

    var y_plane: [width * height]u8 = @splat(0);
    var u_plane: [4]u8 = @splat(0);
    var v_plane: [4]u8 = @splat(0);

    rgbaToI420(&rgba, width, height, &y_plane, width, &u_plane, 2, &v_plane, 2);

    const expected_y = lumaFromRgb(0, 200, 0);
    for (y_plane) |sample| try std.testing.expectEqual(expected_y, sample);
    // The 3x3 frame rounds up to a 2x2 chroma plane; every cell is written.
    for (u_plane) |sample| try std.testing.expectEqual(blueChromaFromRgb(0, 200, 0), sample);
}
