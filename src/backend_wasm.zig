//! WASM command buffer backend.
//!
//! This module provides a command buffer-based rendering backend for WASM targets.
//! Draw commands are buffered and later read by JavaScript for rendering to Canvas 2D.
//!
//! The command buffer uses Structure-of-Arrays (SoA) layout for cache efficiency
//! and zero runtime allocations.

const abi = @import("roc_platform_abi.zig");
const ffi = @import("roc_ffi.zig");

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
/// Command type code for circle gradient.
pub const CMD_CIRCLE_GRADIENT: u4 = 5;
/// Command type code for rectangle gradient vertical.
pub const CMD_RECT_GRADIENT_V: u4 = 6;
/// Command type code for rectangle gradient horizontal.
pub const CMD_RECT_GRADIENT_H: u4 = 7;

/// Maximum circle gradients per frame.
pub const MAX_CIRCLE_GRADIENTS = 256;
/// Maximum rectangle gradients per frame.
pub const MAX_RECT_GRADIENTS = 256;

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

    // Circle gradients (SoA)
    circle_gradient_count: u32 = 0,
    circle_gradient_x: [MAX_CIRCLE_GRADIENTS]f32 = undefined,
    circle_gradient_y: [MAX_CIRCLE_GRADIENTS]f32 = undefined,
    circle_gradient_radius: [MAX_CIRCLE_GRADIENTS]f32 = undefined,
    circle_gradient_inner: [MAX_CIRCLE_GRADIENTS]u8 = undefined,
    circle_gradient_outer: [MAX_CIRCLE_GRADIENTS]u8 = undefined,

    // Rectangle gradients V (SoA)
    rect_gradient_v_count: u32 = 0,
    rect_gradient_v_x: [MAX_RECT_GRADIENTS]f32 = undefined,
    rect_gradient_v_y: [MAX_RECT_GRADIENTS]f32 = undefined,
    rect_gradient_v_w: [MAX_RECT_GRADIENTS]f32 = undefined,
    rect_gradient_v_h: [MAX_RECT_GRADIENTS]f32 = undefined,
    rect_gradient_v_top: [MAX_RECT_GRADIENTS]u8 = undefined,
    rect_gradient_v_bottom: [MAX_RECT_GRADIENTS]u8 = undefined,

    // Rectangle gradients H (SoA)
    rect_gradient_h_count: u32 = 0,
    rect_gradient_h_x: [MAX_RECT_GRADIENTS]f32 = undefined,
    rect_gradient_h_y: [MAX_RECT_GRADIENTS]f32 = undefined,
    rect_gradient_h_w: [MAX_RECT_GRADIENTS]f32 = undefined,
    rect_gradient_h_h: [MAX_RECT_GRADIENTS]f32 = undefined,
    rect_gradient_h_left: [MAX_RECT_GRADIENTS]u8 = undefined,
    rect_gradient_h_right: [MAX_RECT_GRADIENTS]u8 = undefined,

    pub fn reset(self: *CommandBuffer) void {
        self.has_clear = false;
        self.cmd_count = 0;
        self.rect_count = 0;
        self.circle_count = 0;
        self.line_count = 0;
        self.text_count = 0;
        self.string_buffer_len = 0;
        self.circle_gradient_count = 0;
        self.rect_gradient_v_count = 0;
        self.rect_gradient_h_count = 0;
    }
};

// Global command buffer (static allocation - no runtime alloc)
var cmd_buffer: CommandBuffer = .{};

fn pushCmd(cmd_type: u4, index: u12) void {
    if (cmd_buffer.cmd_count >= MAX_COMMANDS) return;
    cmd_buffer.cmd_stream[cmd_buffer.cmd_count] = (@as(u16, cmd_type) << 12) | index;
    cmd_buffer.cmd_count += 1;
}

/// Draw a circle from abi args.
pub fn drawCircle(args: abi.DrawCircleArgs) void {
    const i = cmd_buffer.circle_count;
    if (i >= MAX_CIRCLES) return;

    cmd_buffer.circle_x[i] = args.center.x;
    cmd_buffer.circle_y[i] = args.center.y;
    cmd_buffer.circle_radius[i] = args.radius;
    cmd_buffer.circle_color[i] = ffi.colorToU8(args.color);
    cmd_buffer.circle_count += 1;

    pushCmd(CMD_CIRCLE, @intCast(i));
}

/// Draw a rectangle from abi args.
pub fn drawRectangle(args: abi.DrawRectangleArgs) void {
    const i = cmd_buffer.rect_count;
    if (i >= MAX_RECTS) return;

    cmd_buffer.rect_x[i] = args.x;
    cmd_buffer.rect_y[i] = args.y;
    cmd_buffer.rect_w[i] = args.width;
    cmd_buffer.rect_h[i] = args.height;
    cmd_buffer.rect_color[i] = ffi.colorToU8(args.color);
    cmd_buffer.rect_count += 1;

    pushCmd(CMD_RECT, @intCast(i));
}

/// Draw a line from abi args.
pub fn drawLine(args: abi.DrawLineArgs) void {
    const i = cmd_buffer.line_count;
    if (i >= MAX_LINES) return;

    cmd_buffer.line_x1[i] = args.start.x;
    cmd_buffer.line_y1[i] = args.start.y;
    cmd_buffer.line_x2[i] = args.end.x;
    cmd_buffer.line_y2[i] = args.end.y;
    cmd_buffer.line_color[i] = ffi.colorToU8(args.color);
    cmd_buffer.line_count += 1;

    pushCmd(CMD_LINE, @intCast(i));
}

/// Draw text from individual fields (text content as a slice, not RocStr).
pub fn drawText(x: f32, y: f32, content: []const u8, size: i32, color: abi.Color) void {
    const i = cmd_buffer.text_count;
    if (i >= MAX_TEXTS) return;

    const available = MAX_STRING_BYTES - cmd_buffer.string_buffer_len;
    const str_len: u32 = @intCast(@min(content.len, available));
    if (str_len == 0) return;

    const offset = cmd_buffer.string_buffer_len;
    @memcpy(cmd_buffer.string_buffer[offset..][0..str_len], content[0..str_len]);
    cmd_buffer.string_buffer_len += str_len;

    cmd_buffer.text_x[i] = x;
    cmd_buffer.text_y[i] = y;
    cmd_buffer.text_size[i] = size;
    cmd_buffer.text_color[i] = ffi.colorToU8(color);
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

/// Clear the background with a color.
pub fn clearBackground(color: abi.Color) void {
    cmd_buffer.has_clear = true;
    cmd_buffer.clear_color = ffi.colorToU8(color);
}

/// Draw a circle gradient from abi args.
pub fn drawCircleGradient(args: abi.DrawCircle_gradientArgs) void {
    const i = cmd_buffer.circle_gradient_count;
    if (i >= MAX_CIRCLE_GRADIENTS) return;

    cmd_buffer.circle_gradient_x[i] = args.center.x;
    cmd_buffer.circle_gradient_y[i] = args.center.y;
    cmd_buffer.circle_gradient_radius[i] = args.radius;
    cmd_buffer.circle_gradient_inner[i] = ffi.colorToU8(args.color_inner);
    cmd_buffer.circle_gradient_outer[i] = ffi.colorToU8(args.color_outer);
    cmd_buffer.circle_gradient_count += 1;

    pushCmd(CMD_CIRCLE_GRADIENT, @intCast(i));
}

/// Draw a rectangle with vertical gradient from abi args.
pub fn drawRectangleGradientV(args: abi.DrawRectangle_gradient_vArgs) void {
    const i = cmd_buffer.rect_gradient_v_count;
    if (i >= MAX_RECT_GRADIENTS) return;

    cmd_buffer.rect_gradient_v_x[i] = args.x;
    cmd_buffer.rect_gradient_v_y[i] = args.y;
    cmd_buffer.rect_gradient_v_w[i] = args.width;
    cmd_buffer.rect_gradient_v_h[i] = args.height;
    cmd_buffer.rect_gradient_v_top[i] = ffi.colorToU8(args.color_top);
    cmd_buffer.rect_gradient_v_bottom[i] = ffi.colorToU8(args.color_bottom);
    cmd_buffer.rect_gradient_v_count += 1;

    pushCmd(CMD_RECT_GRADIENT_V, @intCast(i));
}

/// Draw a rectangle with horizontal gradient from abi args.
pub fn drawRectangleGradientH(args: abi.DrawRectangle_gradient_hArgs) void {
    const i = cmd_buffer.rect_gradient_h_count;
    if (i >= MAX_RECT_GRADIENTS) return;

    cmd_buffer.rect_gradient_h_x[i] = args.x;
    cmd_buffer.rect_gradient_h_y[i] = args.y;
    cmd_buffer.rect_gradient_h_w[i] = args.width;
    cmd_buffer.rect_gradient_h_h[i] = args.height;
    cmd_buffer.rect_gradient_h_left[i] = ffi.colorToU8(args.color_left);
    cmd_buffer.rect_gradient_h_right[i] = ffi.colorToU8(args.color_right);
    cmd_buffer.rect_gradient_h_count += 1;

    pushCmd(CMD_RECT_GRADIENT_H, @intCast(i));
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

    drawRectangle(.{ .x = 10.0, .y = 20.0, .width = 100.0, .height = 50.0, .color = .red });

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

    drawCircle(.{ .center = .{ .x = 50, .y = 50 }, .radius = 25, .color = .green });

    try testing.expectEqual(@as(u32, 1), cmd_buffer.circle_count);
    try testing.expectEqual(@as(f32, 50.0), cmd_buffer.circle_x[0]);
    try testing.expectEqual(@as(f32, 50.0), cmd_buffer.circle_y[0]);
    try testing.expectEqual(@as(f32, 25.0), cmd_buffer.circle_radius[0]);
    try testing.expectEqual(@as(u8, 4), cmd_buffer.circle_color[0]); // .green = 4
}

test "drawLine stores data correctly" {
    cmd_buffer.reset();

    drawLine(.{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 100, .y = 100 }, .color = .blue });

    try testing.expectEqual(@as(u32, 1), cmd_buffer.line_count);
    try testing.expectEqual(@as(f32, 0.0), cmd_buffer.line_x1[0]);
    try testing.expectEqual(@as(f32, 0.0), cmd_buffer.line_y1[0]);
    try testing.expectEqual(@as(f32, 100.0), cmd_buffer.line_x2[0]);
    try testing.expectEqual(@as(f32, 100.0), cmd_buffer.line_y2[0]);
    try testing.expectEqual(@as(u8, 1), cmd_buffer.line_color[0]); // .blue = 1
}

test "drawText stores data correctly" {
    cmd_buffer.reset();

    drawText(10, 200, "Hello", 20, .white);

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
    drawCircle(.{ .center = .{ .x = 50, .y = 50 }, .radius = 25, .color = .blue });
    drawRectangle(.{ .x = 100, .y = 0, .width = 10, .height = 10, .color = .red });
    drawLine(.{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 100, .y = 100 }, .color = .green });

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
