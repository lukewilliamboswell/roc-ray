//! Serialization for the message stream, so a session can be recorded and
//! replayed exactly.
//!
//! Every value an app cannot predict -- input, the clock, and the result of any
//! command -- reaches it as a message. That makes the message stream a complete
//! account of a run: write it down and feeding it back reproduces the run.
//! Visual-regression testing, bug reproduction, and demo scripting stop being
//! three mechanisms and become one.
//!
//! Deliberately free of raylib and of any GPU dependency, so `zig test`
//! exercises the whole format on a machine with no display, in the same spirit
//! as `capture.zig`.
//!
//! A tape is valid for one binary on one machine. Records are fixed-layout
//! structs written raw, and the header carries a shape hash so a tape made by a
//! different build fails loudly instead of decoding into nonsense.

const std = @import("std");
const ffi = @import("roc_ffi.zig");

/// Identifies a tape, so a stray file fails fast rather than decoding.
pub const magic = "ROCRAYMSG";
/// Incremented on any incompatible change to the tape structure.
pub const format_version: u32 = 1;

/// Bumped whenever the record layout changes. A stale tape must be rejected,
/// not misread, so this is checked before a single record is decoded.
pub const shape_hash: u64 = 0x726f637261796d31;

/// Written once at the start of a tape and checked before any record.
pub const Header = extern struct {
    magic: [9]u8,
    version: u32,
    shape: u64,
    /// Recorded so a replay into a different-sized window is refused: the same
    /// messages drawn at another resolution produce different pixels.
    screen_width: i32,
    screen_height: i32,
    /// The seed the run used, so randomness reproduces.
    random_seed: u32,

    pub fn init(screen_width: i32, screen_height: i32, random_seed: u32) Header {
        return .{
            .magic = magic.*,
            .version = format_version,
            .shape = shape_hash,
            .screen_width = screen_width,
            .screen_height = screen_height,
            .random_seed = random_seed,
        };
    }

    pub const Mismatch = error{
        NotATape,
        VersionMismatch,
        ShapeMismatch,
        ScreenMismatch,
    };

    /// Refuse a tape this binary cannot faithfully replay.
    pub fn verify(self: Header, screen_width: i32, screen_height: i32) Mismatch!void {
        if (!std.mem.eql(u8, &self.magic, magic)) return error.NotATape;
        if (self.version != format_version) return error.VersionMismatch;
        if (self.shape != shape_hash) return error.ShapeMismatch;
        if (self.screen_width != screen_width or self.screen_height != screen_height) return error.ScreenMismatch;
    }
};

/// The per-frame input a `Frame` message carries.
///
/// These are the post-edge-detection state bytes the host already computed, so
/// replaying them verbatim bypasses the edge detector entirely and cannot drift
/// from the recording because of an edge-detection subtlety.
pub const Snapshot = extern struct {
    keys: [ffi.KEY_COUNT]u8,
    mouse_buttons: [ffi.MOUSE_BUTTON_COUNT]u8,
    gamepad_available: [ffi.GAMEPAD_COUNT]u8,
    gamepad_buttons: [ffi.GAMEPAD_COUNT * ffi.GAMEPAD_BUTTON_COUNT]u8,
    gamepad_axes: [ffi.GAMEPAD_COUNT * ffi.GAMEPAD_AXIS_COUNT]f32,
    text_input: [32]u32,
    text_len: u32,
    screen_width: i32,
    screen_height: i32,
    mouse_x: f32,
    mouse_y: f32,
    mouse_delta_x: f32,
    mouse_delta_y: f32,
    mouse_wheel_x: f32,
    mouse_wheel_y: f32,
};

/// One message, as written to the tape.
///
/// `str_len` bytes of payload follow the record when a command returned a
/// string; nothing follows otherwise.
pub const Record = extern struct {
    kind: u8,
    value_kind: u8,
    err: u8,
    padding: u8 = 0,
    str_len: u32,
    frame_count: u64,
    timestamp_nanos: u64,
    id: u64,
    frame_time: f32,
    reserved: u32 = 0,
    snapshot: Snapshot,
};

/// A tape is a header followed by records, so the reader is a cursor over bytes.
pub const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn readHeader(self: *Reader) ?Header {
        const value = self.take(Header) orelse return null;
        return value;
    }

    /// Return the next record and its string payload, or null at end of tape.
    pub fn next(self: *Reader) ?struct { record: Record, payload: []const u8 } {
        const record = self.take(Record) orelse return null;
        const len = record.str_len;
        if (self.offset + len > self.bytes.len) return null;
        const payload = self.bytes[self.offset .. self.offset + len];
        self.offset += len;
        return .{ .record = record, .payload = payload };
    }

    fn take(self: *Reader, comptime T: type) ?T {
        if (self.offset + @sizeOf(T) > self.bytes.len) return null;
        var value: T = undefined;
        @memcpy(std.mem.asBytes(&value), self.bytes[self.offset .. self.offset + @sizeOf(T)]);
        self.offset += @sizeOf(T);
        return value;
    }
};

/// Append one record and its payload to `out`.
pub fn append(out: *std.ArrayList(u8), allocator: std.mem.Allocator, record: Record, payload: []const u8) !void {
    var stamped = record;
    stamped.str_len = @intCast(payload.len);
    try out.appendSlice(allocator, std.mem.asBytes(&stamped));
    try out.appendSlice(allocator, payload);
}

/// Write the tape header. Must precede any record.
pub fn appendHeader(out: *std.ArrayList(u8), allocator: std.mem.Allocator, header: Header) !void {
    try out.appendSlice(allocator, std.mem.asBytes(&header));
}

test "a header round-trips and accepts the run it describes" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    try appendHeader(&buffer, std.testing.allocator, Header.init(800, 600, 42));

    var reader = Reader.init(buffer.items);
    const header = reader.readHeader().?;
    try header.verify(800, 600);
    try std.testing.expectEqual(@as(u32, 42), header.random_seed);
}

test "a tape recorded at another size is refused rather than replayed wrong" {
    // The same messages drawn into a different window produce different pixels,
    // so a size mismatch has to fail loudly or the comparison is meaningless.
    const header = Header.init(800, 600, 0);
    try std.testing.expectError(error.ScreenMismatch, header.verify(1024, 600));
}

test "a tape from a different record layout is refused rather than misread" {
    var header = Header.init(800, 600, 0);
    header.shape = shape_hash ^ 1;
    try std.testing.expectError(error.ShapeMismatch, header.verify(800, 600));

    var not_a_tape = Header.init(800, 600, 0);
    not_a_tape.magic = "NOTATAPE!".*;
    try std.testing.expectError(error.NotATape, not_a_tape.verify(800, 600));
}

test "records round-trip in order, with and without a payload" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    var tick = std.mem.zeroes(Record);
    tick.kind = 0;
    tick.frame_count = 7;
    tick.frame_time = 0.25;
    try append(&buffer, std.testing.allocator, tick, "");

    var result = std.mem.zeroes(Record);
    result.kind = 2;
    result.id = 99;
    try append(&buffer, std.testing.allocator, result, "file contents");

    var reader = Reader.init(buffer.items);
    const first = reader.next().?;
    try std.testing.expectEqual(@as(u64, 7), first.record.frame_count);
    try std.testing.expectEqual(@as(f32, 0.25), first.record.frame_time);
    try std.testing.expectEqual(@as(usize, 0), first.payload.len);

    const second = reader.next().?;
    try std.testing.expectEqual(@as(u64, 99), second.record.id);
    try std.testing.expectEqualStrings("file contents", second.payload);

    try std.testing.expectEqual(@as(?@TypeOf(second), null), reader.next());
}

test "a truncated tape ends the replay instead of reading past the buffer" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    var record = std.mem.zeroes(Record);
    record.kind = 1;
    try append(&buffer, std.testing.allocator, record, "payload");

    // Chop the payload: the record header still parses but its bytes are gone.
    var reader = Reader.init(buffer.items[0 .. buffer.items.len - 3]);
    try std.testing.expectEqual(@as(?@TypeOf(reader.next().?), null), reader.next());
}

test "input snapshots survive the round trip byte for byte" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    var record = std.mem.zeroes(Record);
    record.kind = 1;
    record.snapshot.keys[32] = 0b111;
    record.snapshot.mouse_x = 401.5;
    record.snapshot.text_len = 2;
    record.snapshot.text_input[0] = 'h';
    record.snapshot.text_input[1] = 'i';
    try append(&buffer, std.testing.allocator, record, "");

    var reader = Reader.init(buffer.items);
    const decoded = reader.next().?.record;
    try std.testing.expectEqual(@as(u8, 0b111), decoded.snapshot.keys[32]);
    try std.testing.expectEqual(@as(f32, 401.5), decoded.snapshot.mouse_x);
    try std.testing.expectEqual(@as(u32, 2), decoded.snapshot.text_len);
    try std.testing.expectEqual(@as(u32, 'i'), decoded.snapshot.text_input[1]);
}
