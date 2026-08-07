//! Animated GIF encoding for captured frames, wrapping the vendored msf_gif.
//!
//! Uses msf_gif's incremental to-file API rather than its buffered one, so
//! memory stays bounded by a single frame no matter how long the recording is.
//! The frame count is then limited only by disk space and by the app's own
//! `max_frames`, instead of by how much of the encode we can hold in RAM.
//!
//! Frames arrive as tightly packed top-down RGBA8, which is exactly what
//! `rlReadScreenPixels` produces, so nothing here reorders or flips pixels.

const std = @import("std");
const capture = @import("capture.zig");

/// msf_gif's `fwrite`-shaped output callback.
const WriteFunc = *const fn (
    buffer: ?*const anyopaque,
    size: usize,
    count: usize,
    stream: ?*anyopaque,
) callconv(.c) usize;

// The C shim in `vendor/msf_gif/msf_gif_impl.c`. Declared by hand rather than
// via `@cImport` because the host module is built freestanding and so has no
// C headers available; the shim exposes only primitives and opaque pointers,
// so there is no struct layout to mirror.
extern fn rocray_gif_begin(width: c_int, height: c_int, write_func: WriteFunc, write_data: ?*anyopaque) c_int;
extern fn rocray_gif_frame(pixels: [*]u8, centiseconds_per_frame: c_int, quality: c_int, pitch_in_bytes: c_int) c_int;
extern fn rocray_gif_end() c_int;

/// Translate a `capture.quality_*` code into msf_gif's palette search depth.
///
/// msf_gif takes a depth from 1 (coarsest) to 16 (finest), setting how many
/// bits of each colour channel survive quantization: 16 is 5r/6g/5b, 12 is
/// 4r/4g/4b, and 6 is 2r/2g/2b. It cooks the whole frame at that depth, counts
/// the distinct colours, and if more than 255 survive it drops a level and
/// cooks again -- so a lower ceiling skips whole passes over colourful frames,
/// and costs nothing on frames that already fit a palette.
///
/// The three levels were picked by replaying a real 150-frame 490x320 UI
/// recording through the encoder and measuring against the source pixels:
///
///   depth  mean channel error  worst  file size  encode time
///      16                1.74      8   169,970      65.8 ms
///      12                3.38     16   156,865      60.1 ms
///       6               31.36     84   140,459      59.4 ms
///
/// 12 is the default because it is the last depth that keeps every channel at
/// four bits -- 11 drops blue to three, which triples the worst-case error for
/// a further 3% of file size. 6 is the highest depth that still bites on a
/// frame full of gradients, where it is worth roughly a fifth of the encode
/// time and half the file size. 16 is what msf_gif's own examples and raylib's
/// recorder use, so `Best` reproduces this host's previous output exactly.
pub fn paletteDepth(quality: u8) c_int {
    return switch (capture.normalizeQuality(quality)) {
        capture.quality_fast => 6,
        capture.quality_best => 16,
        // `normalizeQuality` has already folded anything unrecognized to here.
        else => 12,
    };
}

/// Errors an encoder can report. Each maps onto a `capture.err_*` code.
pub const Error = error{
    /// The output file could not be created or written.
    WriteFailed,
    /// msf_gif could not allocate its working buffers.
    OutOfMemory,
    /// msf_gif rejected a frame or failed to finalize the file.
    EncodeFailed,
};

/// An open GIF being written incrementally to disk.
pub const Encoder = struct {
    file: std.Io.File,
    io: std.Io,
    width: u32,
    height: u32,
    centiseconds_per_frame: c_int,
    /// msf_gif palette search depth, resolved once from the session's quality.
    palette_depth: c_int,
    bytes_written: u64,
    write_failed: bool,
    /// Whether the finalizer actually emitted anything.
    ///
    /// If msf_gif runs out of memory it frees its state and then hands the
    /// finalizer an empty result, which the callback accepts and msf_gif
    /// reports as success -- leaving a GIF with no trailer and missing frames.
    /// Tracking this is the only way to tell that apart from a real finish.
    wrote_something: bool,

    /// msf_gif hands writes back through an `fwrite`-shaped callback.
    ///
    /// Backing it with our own `std.Io` file rather than a libc `FILE*` keeps
    /// GIF output on the same I/O path as the rest of the host, and avoids
    /// depending on stdio from a `-nostdlib` build.
    fn writeCallback(
        buffer: ?*const anyopaque,
        size: usize,
        count: usize,
        stream: ?*anyopaque,
    ) callconv(.c) usize {
        const self: *Encoder = @ptrCast(@alignCast(stream orelse return 0));
        const total = size *| count;
        if (total == 0) return count;
        const bytes: [*]const u8 = @ptrCast(buffer orelse return 0);

        self.wrote_something = true;
        self.file.writeStreamingAll(self.io, bytes[0..total]) catch {
            // Returning short tells msf_gif the write failed. Latch it too, so
            // a failure part-way through a long recording is still reportable
            // after msf_gif has stopped calling us.
            self.write_failed = true;
            return 0;
        };
        self.bytes_written +|= total;
        return count;
    }

    /// Bytes written to the file so far.
    pub fn bytesWritten(self: *const Encoder) u64 {
        return self.bytes_written;
    }

    /// Encode one frame of tightly packed top-down RGBA8 pixels.
    pub fn addFrame(self: *Encoder, pixels: []const u8) Error!void {
        const expected = @as(usize, self.width) * @as(usize, self.height) * 4;
        if (pixels.len < expected) return Error.EncodeFailed;

        const pitch: c_int = @intCast(self.width * 4);
        // msf_gif does not modify the pixels, but its C signature is non-const.
        const mutable: [*]u8 = @constCast(pixels.ptr);
        const ok = rocray_gif_frame(mutable, self.centiseconds_per_frame, self.palette_depth, pitch);
        if (self.write_failed) return Error.WriteFailed;
        if (ok == 0) return Error.OutOfMemory;
    }

    /// Finish the file and release msf_gif's buffers.
    ///
    /// Safe to call after a failed frame: msf_gif no-ops once it has errored,
    /// and its buffers still need freeing.
    pub fn finish(self: *Encoder) Error!void {
        self.wrote_something = false;
        const ok = rocray_gif_end();
        self.file.close(self.io);
        if (self.write_failed) return Error.WriteFailed;
        if (ok == 0) return Error.EncodeFailed;
        // msf_gif returns success for an empty result, so an encoder that gave
        // up earlier would otherwise look like a clean finish.
        if (!self.wrote_something) return Error.EncodeFailed;
    }

    /// Abandon the recording, closing the file without finalizing it.
    pub fn abort(self: *Encoder) void {
        _ = rocray_gif_end();
        self.file.close(self.io);
    }
};

/// Convert a frame rate to msf_gif's per-frame delay in centiseconds.
///
/// GIF stores frame delays in hundredths of a second, so rates that do not
/// divide 100 are approximated. Never returns 0: many decoders treat a zero
/// delay as "as fast as possible" or silently substitute 10cs, which makes a
/// recording play back at the wrong speed.
pub fn centisecondsPerFrame(fps: i32) c_int {
    if (fps <= 0) return 4;
    const rounded = @divTrunc(100 + @divTrunc(fps, 2), fps);
    if (rounded < 1) return 1;
    return @intCast(rounded);
}

/// Create a GIF and write its header.
///
/// `path` must already be resolved and sandboxed by the caller.
pub fn open(
    io: std.Io,
    encoder: *Encoder,
    path: []const u8,
    width: u32,
    height: u32,
    fps: i32,
    quality: u8,
) Error!void {
    if (width == 0 or height == 0) return Error.EncodeFailed;

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return Error.WriteFailed;

    encoder.* = .{
        .file = file,
        .io = io,
        .width = width,
        .height = height,
        .centiseconds_per_frame = centisecondsPerFrame(fps),
        .palette_depth = paletteDepth(quality),
        .bytes_written = 0,
        .write_failed = false,
        .wrote_something = false,
    };

    const ok = rocray_gif_begin(
        @intCast(width),
        @intCast(height),
        Encoder.writeCallback,
        encoder,
    );
    if (encoder.write_failed) {
        file.close(io);
        return Error.WriteFailed;
    }
    if (ok == 0) {
        file.close(io);
        return Error.OutOfMemory;
    }
}

test "centisecondsPerFrame rounds to the nearest hundredth of a second" {
    try std.testing.expectEqual(@as(c_int, 4), centisecondsPerFrame(25));
    try std.testing.expectEqual(@as(c_int, 2), centisecondsPerFrame(50));
    try std.testing.expectEqual(@as(c_int, 10), centisecondsPerFrame(10));
    try std.testing.expectEqual(@as(c_int, 100), centisecondsPerFrame(1));
    // 60fps is 1.67cs; GIF cannot express it, so it rounds to 2cs (50fps).
    try std.testing.expectEqual(@as(c_int, 2), centisecondsPerFrame(60));
    try std.testing.expectEqual(@as(c_int, 3), centisecondsPerFrame(30));
}

test "centisecondsPerFrame never returns a zero delay" {
    // A zero delay makes many decoders substitute their own, so a very high
    // frame rate has to clamp to the fastest expressible one instead.
    try std.testing.expectEqual(@as(c_int, 1), centisecondsPerFrame(1000));
    try std.testing.expectEqual(@as(c_int, 1), centisecondsPerFrame(std.math.maxInt(i32)));
}

test "centisecondsPerFrame falls back for non-positive rates" {
    try std.testing.expectEqual(@as(c_int, 4), centisecondsPerFrame(0));
    try std.testing.expectEqual(@as(c_int, 4), centisecondsPerFrame(-30));
}

test "paletteDepth maps each quality onto a distinct msf_gif depth" {
    try std.testing.expectEqual(@as(c_int, 6), paletteDepth(capture.quality_fast));
    try std.testing.expectEqual(@as(c_int, 12), paletteDepth(capture.quality_balanced));
    try std.testing.expectEqual(@as(c_int, 16), paletteDepth(capture.quality_best));
}

test "paletteDepth stays inside the range msf_gif accepts" {
    // msf_gif clamps to 1..16 internally, so a depth outside it would silently
    // become a different level than the one this table claims.
    for ([_]u8{ capture.quality_fast, capture.quality_balanced, capture.quality_best }) |value| {
        const depth = paletteDepth(value);
        try std.testing.expect(depth >= 1 and depth <= 16);
    }
}

test "paletteDepth folds an unknown quality onto the default" {
    try std.testing.expectEqual(paletteDepth(capture.quality_balanced), paletteDepth(3));
    try std.testing.expectEqual(paletteDepth(capture.quality_balanced), paletteDepth(255));
}
