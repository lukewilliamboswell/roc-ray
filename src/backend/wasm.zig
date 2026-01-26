//! WASM command buffer backend.
//!
//! This module provides a command buffer-based rendering backend for WASM targets.
//! Draw commands are buffered and later read by JavaScript for rendering to Canvas 2D.
//!
//! The command buffer uses Structure-of-Arrays (SoA) layout for cache efficiency
//! and zero runtime allocations.

const types = @import("../types.zig");

/// Maximum total commands per frame (all types combined).
pub const MAX_COMMANDS = 2048;
/// Maximum rectangles per frame.
pub const MAX_RECTS = 1024;
/// Maximum circles per frame.
pub const MAX_CIRCLES = 512;
/// Maximum lines per frame.
pub const MAX_LINES = 512;
/// Maximum text items per frame.
pub const MAX_TEXTS = 256;
/// Maximum total string bytes for text content.
pub const MAX_STRING_BYTES = 8192;
/// Command type code for rectangle.
pub const CMD_RECT: u4 = 1;
/// Command type code for circle.
pub const CMD_CIRCLE: u4 = 2;
/// Command type code for line.
pub const CMD_LINE: u4 = 3;
/// Command type code for text.
pub const CMD_TEXT: u4 = 4;

/// Command buffer using Structure-of-Arrays layout for cache efficiency.
/// This struct is read directly by JavaScript via memory access.
pub const CommandBuffer = struct {
    // Frame state
    has_clear: bool = false,
    clear_color: u8 = 0,

    // Command stream - draw order as (type, index) pairs
    // High 4 bits = type, low 12 bits = index into type-specific arrays
    cmd_stream: [MAX_COMMANDS]u16 = undefined,
    cmd_count: u32 = 0,

    // Rectangles (SoA)
    rect_count: u32 = 0,
    rect_x: [MAX_RECTS]f32 = undefined,
    rect_y: [MAX_RECTS]f32 = undefined,
    rect_w: [MAX_RECTS]f32 = undefined,
    rect_h: [MAX_RECTS]f32 = undefined,
    rect_color: [MAX_RECTS]u8 = undefined,

    // Circles (SoA)
    circle_count: u32 = 0,
    circle_x: [MAX_CIRCLES]f32 = undefined,
    circle_y: [MAX_CIRCLES]f32 = undefined,
    circle_radius: [MAX_CIRCLES]f32 = undefined,
    circle_color: [MAX_CIRCLES]u8 = undefined,

    // Lines (SoA)
    line_count: u32 = 0,
    line_x1: [MAX_LINES]f32 = undefined,
    line_y1: [MAX_LINES]f32 = undefined,
    line_x2: [MAX_LINES]f32 = undefined,
    line_y2: [MAX_LINES]f32 = undefined,
    line_color: [MAX_LINES]u8 = undefined,

    // Text (SoA)
    text_count: u32 = 0,
    text_x: [MAX_TEXTS]f32 = undefined,
    text_y: [MAX_TEXTS]f32 = undefined,
    text_size: [MAX_TEXTS]i32 = undefined,
    text_color: [MAX_TEXTS]u8 = undefined,
    text_str_offset: [MAX_TEXTS]u16 = undefined,
    text_str_len: [MAX_TEXTS]u16 = undefined,

    // String buffer (append-only)
    string_buffer: [MAX_STRING_BYTES]u8 = undefined,
    string_buffer_len: u32 = 0,

    pub fn reset(self: *CommandBuffer) void {
        self.has_clear = false;
        self.cmd_count = 0;
        self.rect_count = 0;
        self.circle_count = 0;
        self.line_count = 0;
        self.text_count = 0;
        self.string_buffer_len = 0;
    }
};

// Global command buffer (static allocation - no runtime alloc)
var cmd_buffer: CommandBuffer = .{};

fn pushCmd(cmd_type: u4, index: u12) void {
    if (cmd_buffer.cmd_count >= MAX_COMMANDS) return;
    cmd_buffer.cmd_stream[cmd_buffer.cmd_count] = (@as(u16, cmd_type) << 12) | index;
    cmd_buffer.cmd_count += 1;
}

/// Draw a circle using safe types.
pub fn drawCircle(circle: types.Circle) void {
    const i = cmd_buffer.circle_count;
    if (i >= MAX_CIRCLES) return;

    cmd_buffer.circle_x[i] = circle.center.x;
    cmd_buffer.circle_y[i] = circle.center.y;
    cmd_buffer.circle_radius[i] = circle.radius;
    cmd_buffer.circle_color[i] = circle.color.toU8();
    cmd_buffer.circle_count += 1;

    pushCmd(CMD_CIRCLE, @intCast(i));
}

/// Draw a rectangle using safe types.
pub fn drawRectangle(rect: types.Rectangle) void {
    const i = cmd_buffer.rect_count;
    if (i >= MAX_RECTS) return;

    cmd_buffer.rect_x[i] = rect.x;
    cmd_buffer.rect_y[i] = rect.y;
    cmd_buffer.rect_w[i] = rect.width;
    cmd_buffer.rect_h[i] = rect.height;
    cmd_buffer.rect_color[i] = rect.color.toU8();
    cmd_buffer.rect_count += 1;

    pushCmd(CMD_RECT, @intCast(i));
}

/// Draw a line using safe types.
pub fn drawLine(line: types.Line) void {
    const i = cmd_buffer.line_count;
    if (i >= MAX_LINES) return;

    cmd_buffer.line_x1[i] = line.start.x;
    cmd_buffer.line_y1[i] = line.start.y;
    cmd_buffer.line_x2[i] = line.end.x;
    cmd_buffer.line_y2[i] = line.end.y;
    cmd_buffer.line_color[i] = line.color.toU8();
    cmd_buffer.line_count += 1;

    pushCmd(CMD_LINE, @intCast(i));
}

/// Draw text using safe types.
/// Note: The buf parameter is for API compatibility with raylib backend but unused here.
pub fn drawText(text: types.Text, buf: *[256:0]u8) void {
    _ = buf;
    const i = cmd_buffer.text_count;
    if (i >= MAX_TEXTS) return;

    const str = text.content;
    const available = MAX_STRING_BYTES - cmd_buffer.string_buffer_len;
    const str_len: u32 = @intCast(@min(str.len, available));
    if (str_len == 0) return;

    const offset = cmd_buffer.string_buffer_len;
    @memcpy(cmd_buffer.string_buffer[offset..][0..str_len], str[0..str_len]);
    cmd_buffer.string_buffer_len += str_len;

    cmd_buffer.text_x[i] = text.pos.x;
    cmd_buffer.text_y[i] = text.pos.y;
    cmd_buffer.text_size[i] = text.size;
    cmd_buffer.text_color[i] = text.color.toU8();
    cmd_buffer.text_str_offset[i] = @intCast(offset);
    cmd_buffer.text_str_len[i] = @intCast(str_len);
    cmd_buffer.text_count += 1;

    pushCmd(CMD_TEXT, @intCast(i));
}

/// Begin drawing frame - resets the command buffer.
pub fn beginDrawing() void {
    cmd_buffer.reset();
}

/// End drawing frame - no-op for WASM (JS reads buffer after _frame() returns).
pub fn endDrawing() void {
    // No-op - JS reads the buffer after the frame function returns
}

/// Clear the background with a safe color.
pub fn clearBackground(color: types.Color) void {
    cmd_buffer.has_clear = true;
    cmd_buffer.clear_color = color.toU8();
}

/// Get pointer to the command buffer for JS to read.
pub fn getBuffer() *CommandBuffer {
    return &cmd_buffer;
}

// Unit Tests

const testing = @import("std").testing;

test "CommandBuffer.reset clears all counts" {
    var buf = CommandBuffer{};
    buf.rect_count = 5;
    buf.circle_count = 3;
    buf.cmd_count = 8;
    buf.string_buffer_len = 100;
    buf.has_clear = true;

    buf.reset();

    try testing.expectEqual(@as(u32, 0), buf.rect_count);
    try testing.expectEqual(@as(u32, 0), buf.circle_count);
    try testing.expectEqual(@as(u32, 0), buf.cmd_count);
    try testing.expectEqual(@as(u32, 0), buf.string_buffer_len);
    try testing.expect(!buf.has_clear);
}

test "pushCmd encodes type and index correctly" {
    cmd_buffer.reset();

    pushCmd(CMD_RECT, 0);
    try testing.expectEqual(@as(u16, 0x1000), cmd_buffer.cmd_stream[0]);

    pushCmd(CMD_CIRCLE, 5);
    try testing.expectEqual(@as(u16, 0x2005), cmd_buffer.cmd_stream[1]);

    pushCmd(CMD_LINE, 100);
    try testing.expectEqual(@as(u16, 0x3064), cmd_buffer.cmd_stream[2]);

    pushCmd(CMD_TEXT, 255);
    try testing.expectEqual(@as(u16, 0x40FF), cmd_buffer.cmd_stream[3]);

    try testing.expectEqual(@as(u32, 4), cmd_buffer.cmd_count);
}

test "drawRectangle stores data correctly" {
    cmd_buffer.reset();

    const rect = types.Rectangle{
        .x = 10.0,
        .y = 20.0,
        .width = 100.0,
        .height = 50.0,
        .color = .red,
    };
    drawRectangle(rect);

    try testing.expectEqual(@as(u32, 1), cmd_buffer.rect_count);
    try testing.expectEqual(@as(u32, 1), cmd_buffer.cmd_count);
    try testing.expectEqual(@as(f32, 10.0), cmd_buffer.rect_x[0]);
    try testing.expectEqual(@as(f32, 20.0), cmd_buffer.rect_y[0]);
    try testing.expectEqual(@as(f32, 100.0), cmd_buffer.rect_w[0]);
    try testing.expectEqual(@as(f32, 50.0), cmd_buffer.rect_h[0]);
    try testing.expectEqual(@as(u8, 10), cmd_buffer.rect_color[0]); // .red = 10

    // Check command stream
    const cmd = cmd_buffer.cmd_stream[0];
    try testing.expectEqual(CMD_RECT, @as(u4, @truncate(cmd >> 12)));
    try testing.expectEqual(@as(u12, 0), @as(u12, @truncate(cmd)));
}

test "drawCircle stores data correctly" {
    cmd_buffer.reset();

    const circle = types.Circle{
        .center = types.Vector2.init(50, 50),
        .radius = 25,
        .color = .green,
    };
    drawCircle(circle);

    try testing.expectEqual(@as(u32, 1), cmd_buffer.circle_count);
    try testing.expectEqual(@as(f32, 50.0), cmd_buffer.circle_x[0]);
    try testing.expectEqual(@as(f32, 50.0), cmd_buffer.circle_y[0]);
    try testing.expectEqual(@as(f32, 25.0), cmd_buffer.circle_radius[0]);
    try testing.expectEqual(@as(u8, 4), cmd_buffer.circle_color[0]); // .green = 4
}

test "drawLine stores data correctly" {
    cmd_buffer.reset();

    const line = types.Line{
        .start = types.Vector2.init(0, 0),
        .end = types.Vector2.init(100, 100),
        .color = .blue,
    };
    drawLine(line);

    try testing.expectEqual(@as(u32, 1), cmd_buffer.line_count);
    try testing.expectEqual(@as(f32, 0.0), cmd_buffer.line_x1[0]);
    try testing.expectEqual(@as(f32, 0.0), cmd_buffer.line_y1[0]);
    try testing.expectEqual(@as(f32, 100.0), cmd_buffer.line_x2[0]);
    try testing.expectEqual(@as(f32, 100.0), cmd_buffer.line_y2[0]);
    try testing.expectEqual(@as(u8, 1), cmd_buffer.line_color[0]); // .blue = 1
}

test "drawText stores data correctly" {
    cmd_buffer.reset();

    const text = types.Text{
        .pos = types.Vector2.init(10, 200),
        .content = "Hello",
        .size = 20,
        .color = .white,
    };
    var buf: [256:0]u8 = undefined;
    drawText(text, &buf);

    try testing.expectEqual(@as(u32, 1), cmd_buffer.text_count);
    try testing.expectEqual(@as(f32, 10.0), cmd_buffer.text_x[0]);
    try testing.expectEqual(@as(f32, 200.0), cmd_buffer.text_y[0]);
    try testing.expectEqual(@as(i32, 20), cmd_buffer.text_size[0]);
    try testing.expectEqual(@as(u8, 11), cmd_buffer.text_color[0]); // .white = 11
    try testing.expectEqual(@as(u16, 0), cmd_buffer.text_str_offset[0]);
    try testing.expectEqual(@as(u16, 5), cmd_buffer.text_str_len[0]);
    try testing.expectEqualStrings("Hello", cmd_buffer.string_buffer[0..5]);
}

test "command stream preserves order" {
    cmd_buffer.reset();

    // Push: rect, circle, rect, line
    drawRectangle(.{ .x = 0, .y = 0, .width = 10, .height = 10, .color = .black });
    drawCircle(.{ .center = types.Vector2.init(50, 50), .radius = 25, .color = .blue });
    drawRectangle(.{ .x = 100, .y = 0, .width = 10, .height = 10, .color = .red });
    drawLine(.{ .start = types.Vector2.zero(), .end = types.Vector2.init(100, 100), .color = .green });

    try testing.expectEqual(@as(u32, 4), cmd_buffer.cmd_count);
    try testing.expectEqual(@as(u32, 2), cmd_buffer.rect_count);
    try testing.expectEqual(@as(u32, 1), cmd_buffer.circle_count);
    try testing.expectEqual(@as(u32, 1), cmd_buffer.line_count);

    // Verify order: rect[0], circle[0], rect[1], line[0]
    try testing.expectEqual(CMD_RECT, @as(u4, @truncate(cmd_buffer.cmd_stream[0] >> 12)));
    try testing.expectEqual(@as(u12, 0), @as(u12, @truncate(cmd_buffer.cmd_stream[0])));

    try testing.expectEqual(CMD_CIRCLE, @as(u4, @truncate(cmd_buffer.cmd_stream[1] >> 12)));
    try testing.expectEqual(@as(u12, 0), @as(u12, @truncate(cmd_buffer.cmd_stream[1])));

    try testing.expectEqual(CMD_RECT, @as(u4, @truncate(cmd_buffer.cmd_stream[2] >> 12)));
    try testing.expectEqual(@as(u12, 1), @as(u12, @truncate(cmd_buffer.cmd_stream[2])));

    try testing.expectEqual(CMD_LINE, @as(u4, @truncate(cmd_buffer.cmd_stream[3] >> 12)));
    try testing.expectEqual(@as(u12, 0), @as(u12, @truncate(cmd_buffer.cmd_stream[3])));
}

test "capacity limits are respected" {
    cmd_buffer.reset();

    // Fill rectangles to capacity
    var i: u32 = 0;
    while (i < MAX_RECTS) : (i += 1) {
        drawRectangle(.{ .x = 0, .y = 0, .width = 1, .height = 1, .color = .black });
    }

    try testing.expectEqual(@as(u32, MAX_RECTS), cmd_buffer.rect_count);

    // One more should be ignored
    drawRectangle(.{ .x = 999, .y = 999, .width = 1, .height = 1, .color = .red });
    try testing.expectEqual(@as(u32, MAX_RECTS), cmd_buffer.rect_count);
}

test "clearBackground sets clear state" {
    cmd_buffer.reset();

    clearBackground(.blue);

    try testing.expect(cmd_buffer.has_clear);
    try testing.expectEqual(@as(u8, 1), cmd_buffer.clear_color); // .blue = 1
}

test "beginDrawing resets buffer" {
    // Fill some data
    drawRectangle(.{ .x = 0, .y = 0, .width = 10, .height = 10, .color = .black });
    clearBackground(.red);

    try testing.expectEqual(@as(u32, 1), cmd_buffer.rect_count);
    try testing.expect(cmd_buffer.has_clear);

    // Begin new frame
    beginDrawing();

    try testing.expectEqual(@as(u32, 0), cmd_buffer.rect_count);
    try testing.expect(!cmd_buffer.has_clear);
}
