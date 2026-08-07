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

/// Errors an encoder can report. Each maps onto a `capture.err_*` code.
pub const Error = error{
    /// The output file could not be created or written.
    WriteFailed,
    /// libvpx could not allocate its context or image.
    OutOfMemory,
    /// libvpx rejected a frame, or the muxer refused one.
    EncodeFailed,
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

/// Convert tightly packed top-down RGBA8 into the encoder's I420 planes.
///
/// Chroma is averaged over each 2x2 block, so an odd width or height reuses the
/// last row or column rather than reading past the frame.
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
            r = @divTrunc(r, 4);
            g = @divTrunc(g, 4);
            b = @divTrunc(b, 4);

            u_plane[@as(usize, chroma_row) * u_stride + @as(usize, chroma_col)] = blueChromaFromRgb(r, g, b);
            v_plane[@as(usize, chroma_row) * v_stride + @as(usize, chroma_col)] = redChromaFromRgb(r, g, b);
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

    /// Milliseconds a frame occupies at this recording's rate.
    fn frameDurationMs(self: *const Encoder) u64 {
        const rate: u64 = @intCast(@max(self.fps, 1));
        return @max(1000 / rate, 1);
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

        const duration = self.frameDurationMs();
        const timecode = self.frame_index * duration;
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

        const duration = self.frame_index * self.frameDurationMs();
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

    encoder.* = .{
        .muxer = undefined,
        .width = width,
        .height = height,
        .fps = fps,
        .frame_index = 0,
        .failed = false,
    };

    webm.open(io, &encoder.muxer, path, width, height) catch |err| return switch (err) {
        webm.Error.WriteFailed => Error.WriteFailed,
        webm.Error.NonMonotonicTimecode => Error.EncodeFailed,
    };

    if (rocray_vp8_begin(@intCast(width), @intCast(height), fps, bitrateKbps(width, height, fps)) == 0) {
        encoder.muxer.abort();
        return Error.OutOfMemory;
    }
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
