//! Minimal WebM (Matroska) muxer for a single VP8 video track.
//!
//! Hand-rolled rather than using libwebm, which is C++ and would drag a C++
//! toolchain into a build that is otherwise C and Zig. A video-only, one-track
//! WebM needs very little of Matroska: an EBML header, a Segment holding Info
//! and Tracks, then Clusters of SimpleBlocks.
//!
//! Frames are written as they arrive, so memory stays bounded by one frame no
//! matter how long the recording runs. The two fields that cannot be known
//! until the end -- the Segment size and the Duration -- are written as
//! fixed-width placeholders and patched by seeking back on finish, which keeps
//! the file fully sized rather than relying on the unknown-size encoding that
//! some players handle poorly.

const std = @import("std");

/// Matroska element IDs, stored with their length marker already applied.
const id_ebml: u32 = 0x1A45DFA3;
const id_ebml_version: u32 = 0x4286;
const id_ebml_read_version: u32 = 0x42F7;
const id_ebml_max_id_length: u32 = 0x42F2;
const id_ebml_max_size_length: u32 = 0x42F3;
const id_doc_type: u32 = 0x4282;
const id_doc_type_version: u32 = 0x4287;
const id_doc_type_read_version: u32 = 0x4285;
const id_segment: u32 = 0x18538067;
const id_info: u32 = 0x1549A966;
const id_timecode_scale: u32 = 0x2AD7B1;
const id_duration: u32 = 0x4489;
const id_muxing_app: u32 = 0x4D80;
const id_writing_app: u32 = 0x5741;
const id_tracks: u32 = 0x1654AE6B;
const id_track_entry: u32 = 0xAE;
const id_track_number: u32 = 0xD7;
const id_track_uid: u32 = 0x73C5;
const id_track_type: u32 = 0x83;
const id_codec_id: u32 = 0x86;
const id_video: u32 = 0xE0;
const id_pixel_width: u32 = 0xB0;
const id_pixel_height: u32 = 0xBA;
const id_cluster: u32 = 0x1F43B675;
const id_timecode: u32 = 0xE7;
const id_simple_block: u32 = 0xA3;

/// One millisecond per timecode unit, in nanoseconds.
///
/// Matroska timecodes are integers scaled by this. A millisecond is the
/// conventional choice and is finer than any frame rate we record at.
pub const timecode_scale_ns: u64 = 1_000_000;

/// The only track in the file.
const track_number: u8 = 1;

/// SimpleBlock stores its timecode relative to the cluster as a signed 16-bit
/// value, so a cluster cannot span more than this many milliseconds.
const max_cluster_span_ms: u64 = 30_000;

/// An eight-byte EBML vint holding the reserved "unknown size" pattern.
const unknown_size_vint = [_]u8{ 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

/// Errors the muxer can report.
pub const Error = error{
    /// The output file could not be written.
    WriteFailed,
    /// A frame arrived with a timecode before the current cluster.
    NonMonotonicTimecode,
};

/// Encode an EBML variable-length integer into `buffer`.
///
/// The value is prefixed by a length marker: a leading zero bit count that says
/// how many bytes follow. Returns the bytes used.
pub fn writeVint(buffer: []u8, value: u64) usize {
    var length: usize = 1;
    while (length <= 8) : (length += 1) {
        // Each length can hold 7 bits per byte, minus the marker bit, and the
        // all-ones pattern is reserved for "unknown size".
        const capacity = (@as(u64, 1) << @intCast(7 * length)) - 1;
        if (value < capacity) break;
    }
    if (length > 8) length = 8;

    var i: usize = 0;
    while (i < length) : (i += 1) {
        const shift: u6 = @intCast(8 * (length - 1 - i));
        buffer[i] = @truncate(value >> shift);
    }
    buffer[0] |= @as(u8, 0x80) >> @intCast(length - 1);
    return length;
}

/// Encode an EBML vint into an exact width, for a placeholder to patch later.
pub fn writeVintFixed(buffer: []u8, value: u64, length: usize) void {
    var i: usize = 0;
    while (i < length) : (i += 1) {
        const shift: u6 = @intCast(8 * (length - 1 - i));
        buffer[i] = @truncate(value >> shift);
    }
    buffer[0] |= @as(u8, 0x80) >> @intCast(length - 1);
}

/// Serialize an element ID, which already carries its own length marker.
fn writeId(buffer: []u8, id: u32) usize {
    if (id <= 0xFF) {
        buffer[0] = @truncate(id);
        return 1;
    }
    if (id <= 0xFFFF) {
        std.mem.writeInt(u16, buffer[0..2], @truncate(id), .big);
        return 2;
    }
    if (id <= 0xFFFFFF) {
        buffer[0] = @truncate(id >> 16);
        buffer[1] = @truncate(id >> 8);
        buffer[2] = @truncate(id);
        return 3;
    }
    std.mem.writeInt(u32, buffer[0..4], id, .big);
    return 4;
}

/// Smallest big-endian encoding of an unsigned value, minimum one byte.
fn writeUnsigned(buffer: []u8, value: u64) usize {
    var length: usize = 1;
    while (length < 8 and (value >> @intCast(8 * length)) != 0) : (length += 1) {}
    var i: usize = 0;
    while (i < length) : (i += 1) {
        const shift: u6 = @intCast(8 * (length - 1 - i));
        buffer[i] = @truncate(value >> shift);
    }
    return length;
}

/// A growable in-memory element being assembled before it is written out.
///
/// Headers are small and their sizes must be known before they can be framed,
/// so they are built here rather than streamed.
const Builder = struct {
    bytes: [512]u8 = undefined,
    len: usize = 0,

    fn raw(self: *Builder, data: []const u8) void {
        // Only fixed, small headers go through a Builder -- frame payloads are
        // written straight out -- but assert it rather than leaving a silent
        // stack smash if that ever stops being true.
        std.debug.assert(self.len + data.len <= self.bytes.len);
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn id(self: *Builder, element: u32) void {
        self.len += writeId(self.bytes[self.len..], element);
    }

    fn size(self: *Builder, value: u64) void {
        self.len += writeVint(self.bytes[self.len..], value);
    }

    fn unsigned(self: *Builder, element: u32, value: u64) void {
        var payload: [8]u8 = undefined;
        const payload_len = writeUnsigned(&payload, value);
        self.id(element);
        self.size(payload_len);
        self.raw(payload[0..payload_len]);
    }

    fn string(self: *Builder, element: u32, value: []const u8) void {
        self.id(element);
        self.size(value.len);
        self.raw(value);
    }

    fn slice(self: *const Builder) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A WebM file being written incrementally.
pub const Muxer = struct {
    file: std.Io.File,
    io: std.Io,
    width: u32,
    height: u32,
    bytes_written: u64,
    /// File offset of the Segment's fixed-width size placeholder.
    segment_size_offset: u64,
    /// Payload bytes in the Segment, which becomes its size on finish.
    segment_payload: u64,
    /// File offset of the Duration placeholder.
    duration_offset: u64,
    /// Timecode of the open cluster, and its size placeholder offset.
    cluster_open: bool,
    cluster_base_ms: u64,
    cluster_size_offset: u64,
    cluster_payload: u64,
    last_timecode_ms: u64,

    fn write(self: *Muxer, data: []const u8) Error!void {
        self.file.writeStreamingAll(self.io, data) catch return Error.WriteFailed;
        self.bytes_written += data.len;
    }

    /// Bytes written to the file so far.
    pub fn bytesWritten(self: *const Muxer) u64 {
        return self.bytes_written;
    }

    fn openCluster(self: *Muxer, timecode_ms: u64) Error!void {
        var header = Builder{};
        header.id(id_cluster);
        self.segment_payload += header.len;

        // Reserve eight bytes, holding EBML's "unknown size" pattern until the
        // real size is patched in on close. A known size of zero would make a
        // recording that never finished -- a crash, a kill -- decode as an
        // empty cluster; unknown size makes a parser scan it instead.
        const size_placeholder = unknown_size_vint;
        try self.write(header.slice());
        self.cluster_size_offset = self.bytes_written;
        try self.write(&size_placeholder);
        self.segment_payload += size_placeholder.len;

        var timecode = Builder{};
        timecode.unsigned(id_timecode, timecode_ms);
        try self.write(timecode.slice());

        self.cluster_open = true;
        self.cluster_base_ms = timecode_ms;
        self.cluster_payload = timecode.len;
    }

    fn closeCluster(self: *Muxer) Error!void {
        if (!self.cluster_open) return;
        var patch: [8]u8 = undefined;
        writeVintFixed(&patch, self.cluster_payload, 8);
        self.patchAt(self.cluster_size_offset, &patch) catch return Error.WriteFailed;
        self.segment_payload += self.cluster_payload;
        self.cluster_open = false;
    }

    /// Overwrite a placeholder in place.
    ///
    /// Positional rather than seek-and-write, so the streaming append position
    /// used by every other write is untouched.
    fn patchAt(self: *Muxer, offset: u64, data: []const u8) !void {
        try self.file.writePositionalAll(self.io, data, offset);
    }

    /// Append one encoded VP8 frame.
    ///
    /// `timecode_ms` must not go backwards. A new cluster is started whenever
    /// the span would overflow SimpleBlock's signed 16-bit relative timecode.
    pub fn addFrame(self: *Muxer, payload: []const u8, timecode_ms: u64, keyframe: bool) Error!void {
        if (timecode_ms < self.last_timecode_ms) return Error.NonMonotonicTimecode;
        self.last_timecode_ms = timecode_ms;

        // A cluster must also start on a keyframe so seeking lands on one.
        const span = timecode_ms - self.cluster_base_ms;
        if (!self.cluster_open or (keyframe and span > 0) or span > max_cluster_span_ms) {
            try self.closeCluster();
            try self.openCluster(timecode_ms);
        }

        const relative: i16 = @intCast(@as(i64, @intCast(timecode_ms)) - @as(i64, @intCast(self.cluster_base_ms)));

        var block_header: [16]u8 = undefined;
        var header_len: usize = 0;
        header_len += writeVint(block_header[header_len..], track_number);
        std.mem.writeInt(i16, block_header[header_len..][0..2], relative, .big);
        header_len += 2;
        // Flags: bit 7 marks a keyframe, the rest are lacing/invisible.
        block_header[header_len] = if (keyframe) 0x80 else 0x00;
        header_len += 1;

        var frame = Builder{};
        frame.id(id_simple_block);
        frame.size(header_len + payload.len);

        try self.write(frame.slice());
        try self.write(block_header[0..header_len]);
        try self.write(payload);
        self.cluster_payload += frame.len + header_len + payload.len;
    }

    /// Close the final cluster and patch the sizes that needed the whole file.
    pub fn finish(self: *Muxer, duration_ms: u64) Error!void {
        // The descriptor is released whichever way this goes; leaking it on an
        // error path would exhaust the table for an app that retries.
        defer self.file.close(self.io);

        var failure: ?Error = null;
        self.closeCluster() catch |err| {
            failure = err;
        };

        var segment_patch: [8]u8 = undefined;
        writeVintFixed(&segment_patch, self.segment_payload, 8);
        self.patchAt(self.segment_size_offset, &segment_patch) catch {
            if (failure == null) failure = Error.WriteFailed;
        };

        // Attempted even if the segment patch failed: a file with a duration
        // and no segment size is no worse off, and the reverse may still play.
        // Duration is a float in timecode units, here milliseconds.
        const duration: f64 = @floatFromInt(duration_ms);
        var duration_patch: [8]u8 = undefined;
        std.mem.writeInt(u64, &duration_patch, @bitCast(duration), .big);
        self.patchAt(self.duration_offset, &duration_patch) catch {
            if (failure == null) failure = Error.WriteFailed;
        };

        if (failure) |err| return err;
    }

    /// Abandon the file without patching its sizes.
    pub fn abort(self: *Muxer) void {
        self.file.close(self.io);
    }
};

/// Create a WebM file and write everything up to the first cluster.
pub fn open(
    io: std.Io,
    muxer: *Muxer,
    path: []const u8,
    width: u32,
    height: u32,
) Error!void {
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return Error.WriteFailed;
    // Every write below can fail (a full disk fails all of them), and the
    // caller has no handle to close if it does. Release it here on the way out
    // and let success cancel the cleanup.
    var opened = false;
    errdefer if (!opened) file.close(io);

    muxer.* = .{
        .file = file,
        .io = io,
        .width = width,
        .height = height,
        .bytes_written = 0,
        .segment_size_offset = 0,
        .segment_payload = 0,
        .duration_offset = 0,
        .cluster_open = false,
        .cluster_base_ms = 0,
        .cluster_size_offset = 0,
        .cluster_payload = 0,
        .last_timecode_ms = 0,
    };

    var ebml = Builder{};
    var body = Builder{};
    body.unsigned(id_ebml_version, 1);
    body.unsigned(id_ebml_read_version, 1);
    body.unsigned(id_ebml_max_id_length, 4);
    body.unsigned(id_ebml_max_size_length, 8);
    body.string(id_doc_type, "webm");
    body.unsigned(id_doc_type_version, 2);
    body.unsigned(id_doc_type_read_version, 2);
    ebml.id(id_ebml);
    ebml.size(body.len);
    ebml.raw(body.slice());
    try muxer.write(ebml.slice());

    var segment = Builder{};
    segment.id(id_segment);
    try muxer.write(segment.slice());
    muxer.segment_size_offset = muxer.bytes_written;
    try muxer.write(&unknown_size_vint);

    // Info, with Duration left as a patchable 8-byte float.
    var info_body = Builder{};
    info_body.unsigned(id_timecode_scale, timecode_scale_ns);
    info_body.string(id_muxing_app, "roc-ray");
    info_body.string(id_writing_app, "roc-ray");
    var duration_prefix = Builder{};
    duration_prefix.id(id_duration);
    duration_prefix.size(8);
    info_body.raw(duration_prefix.slice());
    // The placeholder goes in right after its own ID and size, so the current
    // length is its offset within Info's body.
    const duration_offset_in_info = info_body.len;
    info_body.raw(&[_]u8{0} ** 8);

    var info = Builder{};
    info.id(id_info);
    info.size(info_body.len);
    const info_header_len = info.len;
    info.raw(info_body.slice());
    muxer.duration_offset = muxer.bytes_written + info_header_len + duration_offset_in_info;
    try muxer.write(info.slice());
    muxer.segment_payload += info.len;

    var video = Builder{};
    video.unsigned(id_pixel_width, width);
    video.unsigned(id_pixel_height, height);

    var entry = Builder{};
    entry.unsigned(id_track_number, track_number);
    entry.unsigned(id_track_uid, track_number);
    entry.unsigned(id_track_type, 1);
    entry.string(id_codec_id, "V_VP8");
    entry.id(id_video);
    entry.size(video.len);
    entry.raw(video.slice());

    var track_entry = Builder{};
    track_entry.id(id_track_entry);
    track_entry.size(entry.len);
    track_entry.raw(entry.slice());

    var tracks = Builder{};
    tracks.id(id_tracks);
    tracks.size(track_entry.len);
    tracks.raw(track_entry.slice());
    try muxer.write(tracks.slice());
    muxer.segment_payload += tracks.len;

    opened = true;
}

test "writeVint encodes the documented single-byte range" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), writeVint(&buffer, 0));
    try std.testing.expectEqual(@as(u8, 0x80), buffer[0]);

    try std.testing.expectEqual(@as(usize, 1), writeVint(&buffer, 1));
    try std.testing.expectEqual(@as(u8, 0x81), buffer[0]);

    try std.testing.expectEqual(@as(usize, 1), writeVint(&buffer, 126));
    try std.testing.expectEqual(@as(u8, 0xFE), buffer[0]);
}

test "writeVint widens rather than emitting the reserved all-ones pattern" {
    var buffer: [8]u8 = undefined;
    // 127 is 0xFF in one byte, which Matroska reserves for "unknown size", so
    // it has to spill into two bytes instead.
    try std.testing.expectEqual(@as(usize, 2), writeVint(&buffer, 127));
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 0x7F }, buffer[0..2]);

    try std.testing.expectEqual(@as(usize, 2), writeVint(&buffer, 128));
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 0x80 }, buffer[0..2]);

    try std.testing.expectEqual(@as(usize, 3), writeVint(&buffer, 16383));
    try std.testing.expectEqualSlices(u8, &.{ 0x20, 0x3F, 0xFF }, buffer[0..3]);
}

test "writeVintFixed fills an exact width for later patching" {
    var buffer: [8]u8 = undefined;
    writeVintFixed(&buffer, 1, 8);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0, 0, 0, 0, 0, 0, 1 }, &buffer);

    writeVintFixed(&buffer, 0x1234, 8);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0, 0, 0, 0, 0, 0x12, 0x34 }, &buffer);
}

test "writeId preserves each element ID width" {
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), writeId(&buffer, id_simple_block));
    try std.testing.expectEqual(@as(u8, 0xA3), buffer[0]);

    try std.testing.expectEqual(@as(usize, 2), writeId(&buffer, id_doc_type));
    try std.testing.expectEqualSlices(u8, &.{ 0x42, 0x82 }, buffer[0..2]);

    try std.testing.expectEqual(@as(usize, 3), writeId(&buffer, id_timecode_scale));
    try std.testing.expectEqualSlices(u8, &.{ 0x2A, 0xD7, 0xB1 }, buffer[0..3]);

    try std.testing.expectEqual(@as(usize, 4), writeId(&buffer, id_ebml));
    try std.testing.expectEqualSlices(u8, &.{ 0x1A, 0x45, 0xDF, 0xA3 }, buffer[0..4]);
}

test "writeUnsigned uses the fewest bytes that fit" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), writeUnsigned(&buffer, 0));
    try std.testing.expectEqual(@as(u8, 0), buffer[0]);

    try std.testing.expectEqual(@as(usize, 1), writeUnsigned(&buffer, 255));
    try std.testing.expectEqual(@as(u8, 255), buffer[0]);

    try std.testing.expectEqual(@as(usize, 2), writeUnsigned(&buffer, 256));
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00 }, buffer[0..2]);

    try std.testing.expectEqual(@as(usize, 3), writeUnsigned(&buffer, timecode_scale_ns));
    try std.testing.expectEqualSlices(u8, &.{ 0x0F, 0x42, 0x40 }, buffer[0..3]);
}

test "a builder frames a nested element with its own size" {
    var video = Builder{};
    video.unsigned(id_pixel_width, 640);
    video.unsigned(id_pixel_height, 360);
    // PixelWidth: id B0, size 81, value 02 80; PixelHeight: BA, 81, 01 68.
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xB0, 0x82, 0x02, 0x80, 0xBA, 0x82, 0x01, 0x68 },
        video.slice(),
    );
}
