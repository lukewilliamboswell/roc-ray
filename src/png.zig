//! Encode 8-bit RGBA pixels as a PNG.
//!
//! Exists so that turning a captured framebuffer into a file is work the effect
//! worker can do. raylib's `ExportImage` would encode the same bytes, but it is
//! reached through the graphics backend, and the worker thread is not allowed
//! anywhere near that. Being raylib-free also means `zig test` exercises this
//! with no display attached, the same reason `capture.zig` is written that way.
//!
//! Only the one colour type the capture path produces is supported -- 8-bit
//! RGBA, no interlacing, no palette -- because that is what the framebuffer
//! readback hands over and a general encoder would be untested surface.

const std = @import("std");

/// PNG's fixed opening bytes: a high byte to survive 7-bit transports, "PNG",
/// and a CRLF/EOF pair that makes naive text-mode copies corrupt the file
/// visibly rather than silently.
const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

const bytes_per_pixel = 4;

/// Why an image could not be encoded. All three are the caller's mistake or the
/// machine's; nothing about a well-formed RGBA buffer can fail to encode.
pub const Error = error{
    /// The pixel buffer does not match the dimensions given.
    PixelCountMismatch,
    /// A zero dimension, or one PNG cannot represent.
    InvalidDimensions,
    OutOfMemory,
};

/// Encode `pixels` -- tightly packed, top-down, 8-bit RGBA -- as a PNG.
///
/// The caller owns the returned slice.
pub fn encodeRgba(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
) Error![]u8 {
    if (width == 0 or height == 0) return Error.InvalidDimensions;
    if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return Error.InvalidDimensions;

    const stride = @as(usize, width) * bytes_per_pixel;
    const expected = std.math.mul(usize, stride, height) catch return Error.InvalidDimensions;
    if (pixels.len != expected) return Error.PixelCountMismatch;

    const image_data = try deflateScanlines(allocator, pixels, stride, height);
    defer allocator.free(image_data);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    writer.writeAll(&signature) catch return Error.OutOfMemory;

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8] = 8; // bit depth
    header[9] = 6; // colour type: truecolour with alpha
    header[10] = 0; // compression: deflate, the only one defined
    header[11] = 0; // filter method: the adaptive set, the only one defined
    header[12] = 0; // interlace: none
    writeChunk(writer, "IHDR", &header) catch return Error.OutOfMemory;
    writeChunk(writer, "IDAT", image_data) catch return Error.OutOfMemory;
    writeChunk(writer, "IEND", "") catch return Error.OutOfMemory;

    return out.toOwnedSlice() catch Error.OutOfMemory;
}

/// Compress the scanlines, each prefixed with its filter byte.
///
/// Every row uses filter 0 (store). Filtering exists to make the deflate stage
/// more effective on photographic data, and choosing per row well costs a pass
/// over the image per candidate filter. A screenshot is written once and read
/// by a human, so the trade lands on encoding quickly.
fn deflateScanlines(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    stride: usize,
    height: u32,
) Error![]u8 {
    // The compressor writes through this buffer rather than around it, and
    // asserts there is one, so it is sized up front instead of grown from zero.
    var out: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 64 * 1024) catch
        return Error.OutOfMemory;
    errdefer out.deinit();

    const window = allocator.alloc(u8, std.compress.flate.max_window_len) catch return Error.OutOfMemory;
    defer allocator.free(window);

    // zlib rather than raw deflate: PNG's IDAT is a zlib stream, so the
    // two-byte header and the Adler-32 footer are part of the format.
    var compress = std.compress.flate.Compress.init(
        &out.writer,
        window,
        .zlib,
        .level_6,
    ) catch return Error.OutOfMemory;

    var row: u32 = 0;
    while (row < height) : (row += 1) {
        const start = @as(usize, row) * stride;
        compress.writer.writeByte(0) catch return Error.OutOfMemory;
        compress.writer.writeAll(pixels[start .. start + stride]) catch return Error.OutOfMemory;
    }
    compress.finish() catch return Error.OutOfMemory;

    return out.toOwnedSlice() catch Error.OutOfMemory;
}

/// Write one PNG chunk: length, type, payload, and the CRC over both the type
/// and the payload -- the length is deliberately outside the checksum.
fn writeChunk(writer: *std.Io.Writer, chunk_type: []const u8, payload: []const u8) !void {
    std.debug.assert(chunk_type.len == 4);
    if (payload.len > std.math.maxInt(u32)) return error.WriteFailed;

    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(payload.len), .big);
    try writer.writeAll(&length);
    try writer.writeAll(chunk_type);
    try writer.writeAll(payload);

    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    crc.update(payload);
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, crc.final(), .big);
    try writer.writeAll(&checksum);
}

test "a solid image round-trips through the chunk structure" {
    const width = 3;
    const height = 2;
    var pixels: [width * height * bytes_per_pixel]u8 = @splat(0);
    for (0..width * height) |index| {
        pixels[index * 4 + 0] = 0x11;
        pixels[index * 4 + 1] = 0x22;
        pixels[index * 4 + 2] = 0x33;
        pixels[index * 4 + 3] = 0xff;
    }

    const encoded = try encodeRgba(std.testing.allocator, &pixels, width, height);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, &signature, encoded[0..8]);
    // IHDR is required to come first, and carries the dimensions back.
    try std.testing.expectEqualStrings("IHDR", encoded[12..16]);
    try std.testing.expectEqual(@as(u32, width), std.mem.readInt(u32, encoded[16..20], .big));
    try std.testing.expectEqual(@as(u32, height), std.mem.readInt(u32, encoded[20..24], .big));
    try std.testing.expectEqual(@as(u8, 6), encoded[25]);
    // IEND is required to come last, and is always empty.
    try std.testing.expectEqualStrings("IEND", encoded[encoded.len - 8 .. encoded.len - 4]);
}

test "the pixels survive the deflate stream" {
    const width = 4;
    const height = 3;
    var pixels: [width * height * bytes_per_pixel]u8 = undefined;
    for (&pixels, 0..) |*byte, index| byte.* = @truncate(index *% 37);

    const encoded = try encodeRgba(std.testing.allocator, &pixels, width, height);
    defer std.testing.allocator.free(encoded);

    // Find IDAT and inflate it, then strip the per-row filter byte back off.
    const idat_at = std.mem.indexOf(u8, encoded, "IDAT").?;
    const idat_len = std.mem.readInt(u32, encoded[idat_at - 4 ..][0..4], .big);
    const idat = encoded[idat_at + 4 ..][0..idat_len];

    var reader: std.Io.Reader = .fixed(idat);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&reader, .zlib, &window);
    var inflated: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer inflated.deinit();
    _ = try decompress.reader.streamRemaining(&inflated.writer);

    const raw = inflated.written();
    const stride = width * bytes_per_pixel;
    try std.testing.expectEqual(@as(usize, height * (stride + 1)), raw.len);
    for (0..height) |row| {
        const at = row * (stride + 1);
        try std.testing.expectEqual(@as(u8, 0), raw[at]);
        try std.testing.expectEqualSlices(u8, pixels[row * stride ..][0..stride], raw[at + 1 ..][0..stride]);
    }
}

test "dimensions that do not describe the buffer are refused" {
    var pixels: [16]u8 = @splat(0);
    try std.testing.expectError(Error.PixelCountMismatch, encodeRgba(std.testing.allocator, &pixels, 3, 1));
    try std.testing.expectError(Error.InvalidDimensions, encodeRgba(std.testing.allocator, &pixels, 0, 1));
}
