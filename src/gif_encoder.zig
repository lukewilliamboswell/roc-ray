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

/// Palette search depth handed to msf_gif, 0 (coarsest) to 16 (finest).
///
/// msf_gif's own examples and raylib's recorder both use 16. Anything lower
/// trades visible banding for encode time, and the readback already dominates
/// the frame cost, so there is nothing to win by lowering it.
pub const quality: c_int = 16;

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
    bytes_written: u64,
    write_failed: bool,

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
        const ok = rocray_gif_frame(mutable, self.centiseconds_per_frame, quality, pitch);
        if (self.write_failed) return Error.WriteFailed;
        if (ok == 0) return Error.OutOfMemory;
    }

    /// Finish the file and release msf_gif's buffers.
    ///
    /// Safe to call after a failed frame: msf_gif no-ops once it has errored,
    /// and its buffers still need freeing.
    pub fn finish(self: *Encoder) Error!void {
        const ok = rocray_gif_end();
        self.file.close(self.io);
        if (self.write_failed) return Error.WriteFailed;
        if (ok == 0) return Error.EncodeFailed;
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
) Error!void {
    if (width == 0 or height == 0) return Error.EncodeFailed;

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return Error.WriteFailed;

    encoder.* = .{
        .file = file,
        .io = io,
        .width = width,
        .height = height,
        .centiseconds_per_frame = centisecondsPerFrame(fps),
        .bytes_written = 0,
        .write_failed = false,
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
