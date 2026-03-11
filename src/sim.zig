//! Simulation recording and replay for roc-ray.
//!
//! This module provides recording, replay, and headless testing capabilities.
//! Environment variables control the mode:
//!   - SIM_RECORD=path.rrsim  -> Record session to file
//!   - SIM_REPLAY=path.rrsim  -> Replay session (visual, no Roc)
//!   - SIM_TEST=path.rrsim -> Headless test (verify Roc outputs)
//!   - SIM_LOG=path.log   -> Write all mismatches to file (no limit)

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const ffi = @import("roc_ffi.zig");

pub const KEY_COUNT = ffi.KEY_COUNT;

/// Magic bytes for .rrsim file format
pub const MAGIC = [4]u8{ 'R', 'R', 'S', 'M' };

/// Current format version (v4: adds keyboard state - 349 bytes per frame)
pub const VERSION: u32 = 4;

/// Epsilon for floating-point comparisons.
pub const FLOAT_EPSILON: f32 = 0.001;

/// Compare two floats with epsilon tolerance for cross-platform compatibility
fn floatEq(a: f32, b: f32) bool {
    return @abs(a - b) < FLOAT_EPSILON;
}

// Input State Types (previously in types.zig)

/// Platform input state (safe version).
pub const InputState = struct {
    frame_count: u64,
    keys: [KEY_COUNT]u8,
    mouse_x: f32,
    mouse_y: f32,
    mouse_wheel: f32,
    mouse_left: bool,
    mouse_middle: bool,
    mouse_right: bool,

    pub fn init() InputState {
        return .{
            .frame_count = 0,
            .keys = [_]u8{0} ** KEY_COUNT,
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_wheel = 0,
            .mouse_left = false,
            .mouse_middle = false,
            .mouse_right = false,
        };
    }

    pub fn toSerialized(self: InputState) InputStateSerialized {
        return .{
            .frame_count = self.frame_count,
            .mouse_wheel = self.mouse_wheel,
            .mouse_x = self.mouse_x,
            .mouse_y = self.mouse_y,
            .mouse_left = if (self.mouse_left) 1 else 0,
            .mouse_middle = if (self.mouse_middle) 1 else 0,
            .mouse_right = if (self.mouse_right) 1 else 0,
            .keys = self.keys,
        };
    }
};

/// Serialization layout for .rrsim format.
pub const InputStateSerialized = extern struct {
    frame_count: u64,
    mouse_wheel: f32,
    mouse_x: f32,
    mouse_y: f32,
    mouse_left: u8,
    mouse_middle: u8,
    mouse_right: u8,
    _padding: u8 = 0,
    keys: [KEY_COUNT]u8,

    pub fn toInputState(self: InputStateSerialized) InputState {
        return .{
            .frame_count = self.frame_count,
            .keys = self.keys,
            .mouse_x = self.mouse_x,
            .mouse_y = self.mouse_y,
            .mouse_wheel = self.mouse_wheel,
            .mouse_left = self.mouse_left != 0,
            .mouse_middle = self.mouse_middle != 0,
            .mouse_right = self.mouse_right != 0,
        };
    }
};

/// Convert abi.Host state to InputState (for sim recording)
pub fn inputStateFromHost(host: abi.Host) InputState {
    var state = InputState.init();
    state.frame_count = host.frame_count;
    state.mouse_x = host.mouse.x;
    state.mouse_y = host.mouse.y;
    state.mouse_wheel = host.mouse.wheel;
    state.mouse_left = host.mouse.left;
    state.mouse_middle = host.mouse.middle;
    state.mouse_right = host.mouse.right;
    const items = host.keys.items();
    const len = @min(items.len, KEY_COUNT);
    @memcpy(state.keys[0..len], items[0..len]);
    return state;
}

/// Serialization-only layout for text in .rrsim format.
pub const TextSerialized = extern struct {
    pos_x: f32,
    pos_y: f32,
    size: i32,
    color: u8,
    text_offset: u32,
    text_len: u32,
};

/// Simulation mode
pub const SimMode = enum {
    Normal,
    Record,
    Replay,
    Test,
};

/// Draw command types (alphabetically ordered to match hosted function indices)
pub const DrawCommandTag = enum(u8) {
    BeginFrame = 0,
    Circle = 1,
    CircleGradient = 2,
    Clear = 3,
    EndFrame = 4,
    Line = 5,
    Rectangle = 6,
    RectangleGradientH = 7,
    RectangleGradientV = 8,
    Text = 9,
};

/// A recorded draw command using abi types from roc_platform_abi.zig
pub const DrawCommand = union(DrawCommandTag) {
    BeginFrame: void,
    Circle: abi.DrawCircleArgs,
    CircleGradient: abi.DrawCircle_gradientArgs,
    Clear: u8, // color discriminant
    EndFrame: void,
    Line: abi.DrawLineArgs,
    Rectangle: abi.DrawRectangleArgs,
    RectangleGradientH: abi.DrawRectangle_gradient_hArgs,
    RectangleGradientV: abi.DrawRectangle_gradient_vArgs,
    Text: TextSerialized,

    pub fn eql(self: DrawCommand, other: DrawCommand) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
        if (self_tag != other_tag) return false;

        return switch (self) {
            .BeginFrame, .EndFrame => true,
            .Clear => |c| c == other.Clear,
            .Circle => |c| floatEq(c.center.x, other.Circle.center.x) and
                floatEq(c.center.y, other.Circle.center.y) and
                floatEq(c.radius, other.Circle.radius) and
                c.color == other.Circle.color,
            .CircleGradient => |c| floatEq(c.center.x, other.CircleGradient.center.x) and
                floatEq(c.center.y, other.CircleGradient.center.y) and
                floatEq(c.radius, other.CircleGradient.radius) and
                c.color_inner == other.CircleGradient.color_inner and
                c.color_outer == other.CircleGradient.color_outer,
            .Line => |l| floatEq(l.start.x, other.Line.start.x) and
                floatEq(l.start.y, other.Line.start.y) and
                floatEq(l.end.x, other.Line.end.x) and
                floatEq(l.end.y, other.Line.end.y) and
                l.color == other.Line.color,
            .Rectangle => |r| floatEq(r.x, other.Rectangle.x) and
                floatEq(r.y, other.Rectangle.y) and
                floatEq(r.width, other.Rectangle.width) and
                floatEq(r.height, other.Rectangle.height) and
                r.color == other.Rectangle.color,
            .RectangleGradientV => |r| floatEq(r.x, other.RectangleGradientV.x) and
                floatEq(r.y, other.RectangleGradientV.y) and
                floatEq(r.width, other.RectangleGradientV.width) and
                floatEq(r.height, other.RectangleGradientV.height) and
                r.color_top == other.RectangleGradientV.color_top and
                r.color_bottom == other.RectangleGradientV.color_bottom,
            .RectangleGradientH => |r| floatEq(r.x, other.RectangleGradientH.x) and
                floatEq(r.y, other.RectangleGradientH.y) and
                floatEq(r.width, other.RectangleGradientH.width) and
                floatEq(r.height, other.RectangleGradientH.height) and
                r.color_left == other.RectangleGradientH.color_left and
                r.color_right == other.RectangleGradientH.color_right,
            .Text => |t| floatEq(t.pos_x, other.Text.pos_x) and
                floatEq(t.pos_y, other.Text.pos_y) and
                t.size == other.Text.size and
                t.color == other.Text.color and
                t.text_offset == other.Text.text_offset and
                t.text_len == other.Text.text_len,
        };
    }
};

/// One frame of recorded data
pub const FrameRecord = struct {
    inputs: InputStateSerialized,
    outputs: std.ArrayListUnmanaged(DrawCommand),

    pub fn init() FrameRecord {
        return .{
            .inputs = std.mem.zeroes(InputStateSerialized),
            .outputs = .{},
        };
    }

    pub fn deinit(self: *FrameRecord, allocator: std.mem.Allocator) void {
        self.outputs.deinit(allocator);
    }
};

/// Simulation state
pub const SimState = struct {
    mode: SimMode,
    allocator: std.mem.Allocator,
    frames: std.ArrayListUnmanaged(FrameRecord),
    string_buffer: std.ArrayListUnmanaged(u8),
    frame_idx: usize,
    output_idx: usize,
    mismatches: u32,
    mismatch_details: std.ArrayListUnmanaged(u8),
    log_file: ?std.fs.File,
    file_path: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) SimState {
        return .{
            .mode = .Normal,
            .allocator = allocator,
            .frames = .{},
            .string_buffer = .{},
            .frame_idx = 0,
            .output_idx = 0,
            .mismatches = 0,
            .mismatch_details = .{},
            .log_file = null,
            .file_path = null,
        };
    }

    pub fn deinit(self: *SimState) void {
        for (self.frames.items) |*frame| {
            frame.deinit(self.allocator);
        }
        self.frames.deinit(self.allocator);
        self.string_buffer.deinit(self.allocator);
        self.mismatch_details.deinit(self.allocator);

        if (self.log_file) |file| {
            file.close();
        }

        if (self.file_path) |path| {
            if (self.mode != .Normal) {
                self.allocator.free(path);
            }
        }
    }

    pub fn hasMoreFrames(self: *const SimState) bool {
        return self.frame_idx < self.frames.items.len;
    }

    pub fn currentFrame(self: *const SimState) ?*const FrameRecord {
        if (self.frame_idx < self.frames.items.len) {
            return &self.frames.items[self.frame_idx];
        }
        return null;
    }

    pub fn currentInputState(self: *const SimState) ?InputState {
        if (self.currentFrame()) |frame| {
            return frame.inputs.toInputState();
        }
        return null;
    }

    pub fn getText(self: *const SimState, offset: u32, len: u32) []const u8 {
        const start = @min(offset, @as(u32, @intCast(self.string_buffer.items.len)));
        const end = @min(offset + len, @as(u32, @intCast(self.string_buffer.items.len)));
        return self.string_buffer.items[start..end];
    }

    pub fn stepForward(self: *SimState) void {
        if (self.frame_idx + 1 < self.frames.items.len) {
            self.frame_idx += 1;
        }
    }

    pub fn stepBack(self: *SimState) void {
        if (self.frame_idx > 0) {
            self.frame_idx -= 1;
        }
    }

    pub fn jumpToStart(self: *SimState) void {
        self.frame_idx = 0;
    }

    pub fn jumpToEnd(self: *SimState) void {
        if (self.frames.items.len > 0) {
            self.frame_idx = self.frames.items.len - 1;
        }
    }

    pub fn getFrameIndex(self: *const SimState) usize {
        return self.frame_idx;
    }

    pub fn getTotalFrames(self: *const SimState) usize {
        return self.frames.items.len;
    }

    /// Start a new frame (recording mode)
    pub fn beginFrame(self: *SimState, inputs: InputState) !void {
        if (self.mode != .Record) return;

        var frame = FrameRecord.init();
        frame.inputs = inputs.toSerialized();
        try self.frames.append(self.allocator, frame);
    }

    const MAX_MISMATCH_DETAILS = 20;

    fn reportMismatch(self: *SimState, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;

        if (self.log_file) |file| {
            file.writeAll(msg) catch {};
        }

        if (self.mismatches <= MAX_MISMATCH_DETAILS) {
            self.mismatch_details.appendSlice(self.allocator, msg) catch {};
        }
    }

    fn findExistingText(self: *const SimState, text: []const u8) ?u32 {
        if (text.len == 0 or self.string_buffer.items.len < text.len) return null;

        const haystack = self.string_buffer.items;
        var i: usize = 0;
        while (i + text.len <= haystack.len) : (i += 1) {
            if (std.mem.eql(u8, haystack[i..][0..text.len], text)) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// Record a text output - handles text specially to avoid string_buffer issues in Test mode
    pub fn recordTextOutput(self: *SimState, text_slice: []const u8, pos_x: f32, pos_y: f32, size: i32, color: u8) !void {
        if (self.mode == .Normal) return;

        if (self.mode == .Record) {
            const text_offset: u32 = self.findExistingText(text_slice) orelse blk: {
                const offset: u32 = @intCast(self.string_buffer.items.len);
                try self.string_buffer.appendSlice(self.allocator, text_slice);
                break :blk offset;
            };
            const cmd = DrawCommand{ .Text = .{
                .pos_x = pos_x,
                .pos_y = pos_y,
                .size = size,
                .color = color,
                .text_offset = text_offset,
                .text_len = @intCast(text_slice.len),
            } };
            if (self.frames.items.len > 0) {
                try self.frames.items[self.frames.items.len - 1].outputs.append(self.allocator, cmd);
            }
        } else if (self.mode == .Test) {
            if (self.currentFrame()) |frame| {
                if (self.output_idx < frame.outputs.items.len) {
                    const expected = frame.outputs.items[self.output_idx];
                    var matches = false;
                    if (std.meta.activeTag(expected) == .Text) {
                        const e = expected.Text;
                        const expected_text = self.getText(e.text_offset, e.text_len);
                        matches = (floatEq(pos_x, e.pos_x) and floatEq(pos_y, e.pos_y) and
                            size == e.size and color == e.color and
                            std.mem.eql(u8, text_slice, expected_text));
                    }
                    if (!matches) {
                        self.mismatches += 1;
                        var exp_buf: [128]u8 = undefined;
                        var act_buf: [128]u8 = undefined;
                        self.reportMismatch("  [mismatch] frame={d} output={d}: expected {s}, got {s}\n", .{
                            self.frame_idx,
                            self.output_idx,
                            self.formatCommandWithText(expected, &exp_buf),
                            std.fmt.bufPrint(&act_buf, "Text(\"{s}\",x={d:.0},y={d:.0},sz={d})", .{ text_slice, pos_x, pos_y, size }) catch "Text(?)",
                        });
                    }
                } else {
                    self.mismatches += 1;
                    var act_buf: [128]u8 = undefined;
                    self.reportMismatch("  [mismatch] frame={d} output={d}: unexpected extra Text(\"{s}\")\n", .{
                        self.frame_idx,
                        self.output_idx,
                        std.fmt.bufPrint(&act_buf, "{s}", .{text_slice}) catch "?",
                    });
                }
                self.output_idx += 1;
            }
        }
    }

    pub fn recordOutput(self: *SimState, cmd: DrawCommand) !void {
        if (self.mode == .Normal) return;

        if (self.mode == .Record) {
            if (self.frames.items.len > 0) {
                try self.frames.items[self.frames.items.len - 1].outputs.append(self.allocator, cmd);
            }
        } else if (self.mode == .Test) {
            if (self.currentFrame()) |frame| {
                if (self.output_idx < frame.outputs.items.len) {
                    const expected = frame.outputs.items[self.output_idx];
                    if (!self.commandsEqual(cmd, expected)) {
                        self.mismatches += 1;
                        var exp_buf: [128]u8 = undefined;
                        var act_buf: [128]u8 = undefined;
                        self.reportMismatch("  [mismatch] frame={d} output={d}: expected {s}, got {s}\n", .{
                            self.frame_idx,
                            self.output_idx,
                            self.formatCommandWithText(expected, &exp_buf),
                            self.formatCommandWithText(cmd, &act_buf),
                        });
                    }
                } else {
                    self.mismatches += 1;
                    var act_buf: [128]u8 = undefined;
                    self.reportMismatch("  [mismatch] frame={d} output={d}: unexpected extra output {s}\n", .{
                        self.frame_idx,
                        self.output_idx,
                        self.formatCommandWithText(cmd, &act_buf),
                    });
                }
                self.output_idx += 1;
            } else {
                self.mismatches += 1;
                self.reportMismatch("  [mismatch] frame={d}: no expected frame data\n", .{self.frame_idx});
            }
        }
    }

    fn commandsEqual(self: *const SimState, actual: DrawCommand, expected: DrawCommand) bool {
        const actual_tag = std.meta.activeTag(actual);
        const expected_tag = std.meta.activeTag(expected);
        if (actual_tag != expected_tag) return false;

        return switch (actual) {
            .BeginFrame, .EndFrame => true,
            .Clear => |a| a == expected.Clear,
            .Circle => |a| {
                const e = expected.Circle;
                return floatEq(a.center.x, e.center.x) and floatEq(a.center.y, e.center.y) and
                    floatEq(a.radius, e.radius) and a.color == e.color;
            },
            .CircleGradient => |a| {
                const e = expected.CircleGradient;
                return floatEq(a.center.x, e.center.x) and floatEq(a.center.y, e.center.y) and
                    floatEq(a.radius, e.radius) and a.color_inner == e.color_inner and a.color_outer == e.color_outer;
            },
            .Line => |a| {
                const e = expected.Line;
                return floatEq(a.start.x, e.start.x) and floatEq(a.start.y, e.start.y) and
                    floatEq(a.end.x, e.end.x) and floatEq(a.end.y, e.end.y) and a.color == e.color;
            },
            .Rectangle => |a| {
                const e = expected.Rectangle;
                return floatEq(a.x, e.x) and floatEq(a.y, e.y) and floatEq(a.width, e.width) and
                    floatEq(a.height, e.height) and a.color == e.color;
            },
            .RectangleGradientV => |a| {
                const e = expected.RectangleGradientV;
                return floatEq(a.x, e.x) and floatEq(a.y, e.y) and floatEq(a.width, e.width) and
                    floatEq(a.height, e.height) and a.color_top == e.color_top and a.color_bottom == e.color_bottom;
            },
            .RectangleGradientH => |a| {
                const e = expected.RectangleGradientH;
                return floatEq(a.x, e.x) and floatEq(a.y, e.y) and floatEq(a.width, e.width) and
                    floatEq(a.height, e.height) and a.color_left == e.color_left and a.color_right == e.color_right;
            },
            .Text => |a| {
                const e = expected.Text;
                if (!floatEq(a.pos_x, e.pos_x) or !floatEq(a.pos_y, e.pos_y) or
                    a.size != e.size or a.color != e.color) return false;
                if (a.text_len != e.text_len) return false;
                const actual_text = self.getText(a.text_offset, a.text_len);
                const expected_text = self.getText(e.text_offset, e.text_len);
                return std.mem.eql(u8, actual_text, expected_text);
            },
        };
    }

    fn formatCommandWithText(self: *const SimState, cmd: DrawCommand, buf: []u8) []const u8 {
        return switch (cmd) {
            .BeginFrame => std.fmt.bufPrint(buf, "BeginFrame", .{}) catch "BeginFrame",
            .EndFrame => std.fmt.bufPrint(buf, "EndFrame", .{}) catch "EndFrame",
            .Clear => |c| std.fmt.bufPrint(buf, "Clear(color={d})", .{c}) catch "Clear(?)",
            .Circle => |c| std.fmt.bufPrint(buf, "Circle(x={d:.0},y={d:.0},r={d:.0})", .{ c.center.x, c.center.y, c.radius }) catch "Circle(?)",
            .CircleGradient => |c| std.fmt.bufPrint(buf, "CircleGrad(x={d:.0},y={d:.0},r={d:.0})", .{ c.center.x, c.center.y, c.radius }) catch "CircleGrad(?)",
            .Rectangle => |r| std.fmt.bufPrint(buf, "Rect(x={d:.0},y={d:.0},w={d:.0},h={d:.0})", .{ r.x, r.y, r.width, r.height }) catch "Rect(?)",
            .RectangleGradientV => |r| std.fmt.bufPrint(buf, "RectGradV(x={d:.0},y={d:.0},w={d:.0},h={d:.0})", .{ r.x, r.y, r.width, r.height }) catch "RectGradV(?)",
            .RectangleGradientH => |r| std.fmt.bufPrint(buf, "RectGradH(x={d:.0},y={d:.0},w={d:.0},h={d:.0})", .{ r.x, r.y, r.width, r.height }) catch "RectGradH(?)",
            .Line => |l| std.fmt.bufPrint(buf, "Line({d:.0},{d:.0})-({d:.0},{d:.0})", .{ l.start.x, l.start.y, l.end.x, l.end.y }) catch "Line(?)",
            .Text => |t| {
                const text_content = self.getText(t.text_offset, t.text_len);
                return std.fmt.bufPrint(buf, "Text(\"{s}\",x={d:.0},y={d:.0},sz={d})", .{ text_content, t.pos_x, t.pos_y, t.size }) catch "Text(?)";
            },
        };
    }

    pub fn endFrame(self: *SimState) void {
        if (self.mode == .Test) {
            if (self.currentFrame()) |frame| {
                if (self.output_idx < frame.outputs.items.len) {
                    self.mismatches += @intCast(frame.outputs.items.len - self.output_idx);
                }
            }
            self.output_idx = 0;
        }

        if (self.mode == .Replay or self.mode == .Test) {
            self.frame_idx += 1;
        }
    }

    pub fn writeTo(self: *const SimState, writer: anytype) !void {
        // Header
        try writer.writeAll(&MAGIC);
        try writer.writeInt(u32, VERSION, .little);
        try writer.writeInt(u32, @intCast(self.frames.items.len), .little);
        try writer.writeInt(u32, @intCast(self.string_buffer.items.len), .little);

        // String table
        try writer.writeAll(self.string_buffer.items);

        // Frames
        for (self.frames.items) |frame| {
            // Write inputs field by field for portability
            try writer.writeInt(u64, frame.inputs.frame_count, .little);
            try writer.writeAll(std.mem.asBytes(&frame.inputs.mouse_wheel));
            try writer.writeAll(std.mem.asBytes(&frame.inputs.mouse_x));
            try writer.writeAll(std.mem.asBytes(&frame.inputs.mouse_y));
            try writer.writeByte(frame.inputs.mouse_left);
            try writer.writeByte(frame.inputs.mouse_middle);
            try writer.writeByte(frame.inputs.mouse_right);
            try writer.writeAll(&frame.inputs.keys);

            // Write output count
            try writer.writeInt(u32, @intCast(frame.outputs.items.len), .little);

            // Write each output
            for (frame.outputs.items) |cmd| {
                try writer.writeByte(@intFromEnum(std.meta.activeTag(cmd)));
                switch (cmd) {
                    .BeginFrame, .EndFrame => {},
                    .Clear => |c| try writer.writeByte(c),
                    .Circle => |c| {
                        try writer.writeAll(std.mem.asBytes(&c.center.x));
                        try writer.writeAll(std.mem.asBytes(&c.center.y));
                        try writer.writeAll(std.mem.asBytes(&c.radius));
                        try writer.writeByte(@intFromEnum(c.color));
                    },
                    .CircleGradient => |c| {
                        try writer.writeAll(std.mem.asBytes(&c.center.x));
                        try writer.writeAll(std.mem.asBytes(&c.center.y));
                        try writer.writeAll(std.mem.asBytes(&c.radius));
                        try writer.writeByte(@intFromEnum(c.color_inner));
                        try writer.writeByte(@intFromEnum(c.color_outer));
                    },
                    .Line => |l| {
                        try writer.writeAll(std.mem.asBytes(&l.start.x));
                        try writer.writeAll(std.mem.asBytes(&l.start.y));
                        try writer.writeAll(std.mem.asBytes(&l.end.x));
                        try writer.writeAll(std.mem.asBytes(&l.end.y));
                        try writer.writeByte(@intFromEnum(l.color));
                    },
                    .Rectangle => |r| {
                        try writer.writeAll(std.mem.asBytes(&r.x));
                        try writer.writeAll(std.mem.asBytes(&r.y));
                        try writer.writeAll(std.mem.asBytes(&r.width));
                        try writer.writeAll(std.mem.asBytes(&r.height));
                        try writer.writeByte(@intFromEnum(r.color));
                    },
                    .RectangleGradientV => |r| {
                        try writer.writeAll(std.mem.asBytes(&r.x));
                        try writer.writeAll(std.mem.asBytes(&r.y));
                        try writer.writeAll(std.mem.asBytes(&r.width));
                        try writer.writeAll(std.mem.asBytes(&r.height));
                        try writer.writeByte(@intFromEnum(r.color_top));
                        try writer.writeByte(@intFromEnum(r.color_bottom));
                    },
                    .RectangleGradientH => |r| {
                        try writer.writeAll(std.mem.asBytes(&r.x));
                        try writer.writeAll(std.mem.asBytes(&r.y));
                        try writer.writeAll(std.mem.asBytes(&r.width));
                        try writer.writeAll(std.mem.asBytes(&r.height));
                        try writer.writeByte(@intFromEnum(r.color_left));
                        try writer.writeByte(@intFromEnum(r.color_right));
                    },
                    .Text => |t| {
                        try writer.writeAll(std.mem.asBytes(&t.pos_x));
                        try writer.writeAll(std.mem.asBytes(&t.pos_y));
                        try writer.writeAll(std.mem.asBytes(&t.size));
                        try writer.writeByte(t.color);
                        try writer.writeInt(u32, t.text_offset, .little);
                        try writer.writeInt(u32, t.text_len, .little);
                    },
                }
            }
        }
    }

    fn calcSerializedSize(self: *const SimState) usize {
        var size: usize = 16; // Header
        size += self.string_buffer.items.len; // String table
        for (self.frames.items) |frame| {
            size += 23 + KEY_COUNT; // InputState fields: u64 + 3*f32 + 3*u8 + keys
            size += 4; // output_count
            for (frame.outputs.items) |cmd| {
                size += 1; // command tag
                size += switch (cmd) {
                    .BeginFrame, .EndFrame => @as(usize, 0),
                    .Clear => 1,
                    .Circle => 13,
                    .CircleGradient => 14,
                    .Line => 17,
                    .Rectangle => 17,
                    .RectangleGradientV => 18,
                    .RectangleGradientH => 18,
                    .Text => 21,
                };
            }
        }
        return size;
    }

    pub fn toBytes(self: *const SimState, allocator: std.mem.Allocator) ![]u8 {
        const size = self.calcSerializedSize();
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        var fbs = std.io.fixedBufferStream(buffer);
        try self.writeTo(fbs.writer());

        return buffer;
    }

    pub fn readFromBytes(allocator: std.mem.Allocator, data: []const u8) !SimState {
        var state = SimState.init(allocator);
        errdefer state.deinit();

        var pos: usize = 0;

        const readBytes = struct {
            fn read(d: []const u8, p: *usize, comptime n: usize) ![n]u8 {
                if (p.* + n > d.len) return error.UnexpectedEof;
                const result = d[p.*..][0..n].*;
                p.* += n;
                return result;
            }
        }.read;

        const readByte = struct {
            fn read(d: []const u8, p: *usize) !u8 {
                if (p.* >= d.len) return error.UnexpectedEof;
                const result = d[p.*];
                p.* += 1;
                return result;
            }
        }.read;

        const readU32 = struct {
            fn read(d: []const u8, p: *usize) !u32 {
                if (p.* + 4 > d.len) return error.UnexpectedEof;
                const result = std.mem.readInt(u32, d[p.*..][0..4], .little);
                p.* += 4;
                return result;
            }
        }.read;

        const readU64 = struct {
            fn read(d: []const u8, p: *usize) !u64 {
                if (p.* + 8 > d.len) return error.UnexpectedEof;
                const result = std.mem.readInt(u64, d[p.*..][0..8], .little);
                p.* += 8;
                return result;
            }
        }.read;

        const readF32 = struct {
            fn read(d: []const u8, p: *usize) !f32 {
                if (p.* + 4 > d.len) return error.UnexpectedEof;
                const bits = std.mem.readInt(u32, d[p.*..][0..4], .little);
                p.* += 4;
                return @bitCast(bits);
            }
        }.read;

        const readI32 = struct {
            fn read(d: []const u8, p: *usize) !i32 {
                if (p.* + 4 > d.len) return error.UnexpectedEof;
                const result = std.mem.readInt(i32, d[p.*..][0..4], .little);
                p.* += 4;
                return result;
            }
        }.read;

        // Read and verify header
        const magic = try readBytes(data, &pos, 4);
        if (!std.mem.eql(u8, &magic, &MAGIC)) {
            return error.InvalidFormat;
        }

        const version = try readU32(data, &pos);
        if (version != VERSION) {
            return error.UnsupportedVersion;
        }

        const frame_count = try readU32(data, &pos);
        const string_size = try readU32(data, &pos);

        // Read string table
        if (pos + string_size > data.len) return error.UnexpectedEof;
        try state.string_buffer.resize(allocator, string_size);
        @memcpy(state.string_buffer.items, data[pos..][0..string_size]);
        pos += string_size;

        // Read frames
        try state.frames.ensureTotalCapacity(allocator, frame_count);
        for (0..frame_count) |_| {
            var frame = FrameRecord.init();
            errdefer frame.deinit(allocator);

            // Read inputs
            frame.inputs.frame_count = try readU64(data, &pos);
            frame.inputs.mouse_wheel = try readF32(data, &pos);
            frame.inputs.mouse_x = try readF32(data, &pos);
            frame.inputs.mouse_y = try readF32(data, &pos);
            frame.inputs.mouse_left = try readByte(data, &pos);
            frame.inputs.mouse_middle = try readByte(data, &pos);
            frame.inputs.mouse_right = try readByte(data, &pos);
            if (pos + KEY_COUNT > data.len) return error.UnexpectedEof;
            @memcpy(&frame.inputs.keys, data[pos..][0..KEY_COUNT]);
            pos += KEY_COUNT;

            // Read outputs
            const output_count = try readU32(data, &pos);
            try frame.outputs.ensureTotalCapacity(allocator, output_count);

            for (0..output_count) |_| {
                const cmd_type: DrawCommandTag = @enumFromInt(try readByte(data, &pos));
                const cmd: DrawCommand = switch (cmd_type) {
                    .BeginFrame => .{ .BeginFrame = {} },
                    .EndFrame => .{ .EndFrame = {} },
                    .Clear => .{ .Clear = try readByte(data, &pos) },
                    .Circle => blk: {
                        var d: abi.DrawCircleArgs = undefined;
                        d.center.x = try readF32(data, &pos);
                        d.center.y = try readF32(data, &pos);
                        d.radius = try readF32(data, &pos);
                        d.color = @enumFromInt(try readByte(data, &pos));
                        break :blk .{ .Circle = d };
                    },
                    .CircleGradient => blk: {
                        var d: abi.DrawCircle_gradientArgs = undefined;
                        d.center.x = try readF32(data, &pos);
                        d.center.y = try readF32(data, &pos);
                        d.radius = try readF32(data, &pos);
                        d.color_inner = @enumFromInt(try readByte(data, &pos));
                        d.color_outer = @enumFromInt(try readByte(data, &pos));
                        break :blk .{ .CircleGradient = d };
                    },
                    .Line => blk: {
                        var d: abi.DrawLineArgs = undefined;
                        d.start.x = try readF32(data, &pos);
                        d.start.y = try readF32(data, &pos);
                        d.end.x = try readF32(data, &pos);
                        d.end.y = try readF32(data, &pos);
                        d.color = @enumFromInt(try readByte(data, &pos));
                        break :blk .{ .Line = d };
                    },
                    .Rectangle => blk: {
                        var d: abi.DrawRectangleArgs = undefined;
                        d.x = try readF32(data, &pos);
                        d.y = try readF32(data, &pos);
                        d.width = try readF32(data, &pos);
                        d.height = try readF32(data, &pos);
                        d.color = @enumFromInt(try readByte(data, &pos));
                        break :blk .{ .Rectangle = d };
                    },
                    .RectangleGradientV => blk: {
                        var d: abi.DrawRectangle_gradient_vArgs = undefined;
                        d.x = try readF32(data, &pos);
                        d.y = try readF32(data, &pos);
                        d.width = try readF32(data, &pos);
                        d.height = try readF32(data, &pos);
                        d.color_top = @enumFromInt(try readByte(data, &pos));
                        d.color_bottom = @enumFromInt(try readByte(data, &pos));
                        break :blk .{ .RectangleGradientV = d };
                    },
                    .RectangleGradientH => blk: {
                        var d: abi.DrawRectangle_gradient_hArgs = undefined;
                        d.x = try readF32(data, &pos);
                        d.y = try readF32(data, &pos);
                        d.width = try readF32(data, &pos);
                        d.height = try readF32(data, &pos);
                        d.color_left = @enumFromInt(try readByte(data, &pos));
                        d.color_right = @enumFromInt(try readByte(data, &pos));
                        break :blk .{ .RectangleGradientH = d };
                    },
                    .Text => blk: {
                        var d: TextSerialized = undefined;
                        d.pos_x = try readF32(data, &pos);
                        d.pos_y = try readF32(data, &pos);
                        d.size = try readI32(data, &pos);
                        d.color = try readByte(data, &pos);
                        d.text_offset = try readU32(data, &pos);
                        d.text_len = try readU32(data, &pos);
                        break :blk .{ .Text = d };
                    },
                };
                try frame.outputs.append(allocator, cmd);
            }

            try state.frames.append(allocator, frame);
        }

        return state;
    }

    pub fn writeToFile(self: *const SimState, path: []const u8) !void {
        const data = try self.toBytes(self.allocator);
        defer self.allocator.free(data);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(data);
    }

    pub fn readFromFile(allocator: std.mem.Allocator, path: []const u8) !SimState {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const data = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
        defer allocator.free(data);
        return try readFromBytes(allocator, data);
    }

    pub fn finish(self: *SimState) !void {
        const stderr: std.fs.File = .stderr();
        var buf: [512]u8 = undefined;

        if (self.mode == .Record) {
            if (self.file_path) |path| {
                self.writeToFile(path) catch |err| {
                    const err_msg = std.fmt.bufPrint(&buf, "[SIM] writeToFile error: {}\n", .{err}) catch "[SIM] write error\n";
                    stderr.writeAll(err_msg) catch {};
                    return err;
                };
                const msg = std.fmt.bufPrint(&buf, "Recording saved: {s} ({d} frames)\n", .{ path, self.frames.items.len }) catch "Recording saved\n";
                stderr.writeAll(msg) catch {};
            } else {
                stderr.writeAll("[SIM] Record mode but file_path is null\n") catch {};
            }
        } else if (self.mode == .Test) {
            if (self.mismatches == 0) {
                if (self.file_path) |path| {
                    const msg = std.fmt.bufPrint(&buf, "[PASS] {s} ({d} frames)\n", .{ path, self.frames.items.len }) catch "[PASS]\n";
                    stderr.writeAll(msg) catch {};
                }
            } else {
                if (self.mismatch_details.items.len > 0) {
                    stderr.writeAll(self.mismatch_details.items) catch {};
                }
                if (self.file_path) |path| {
                    if (self.mismatches > MAX_MISMATCH_DETAILS) {
                        const truncated_msg = std.fmt.bufPrint(&buf, "  ... and {d} more mismatches", .{self.mismatches - MAX_MISMATCH_DETAILS}) catch "";
                        stderr.writeAll(truncated_msg) catch {};
                        if (self.log_file != null) {
                            stderr.writeAll(" (see SIM_LOG for full output)\n") catch {};
                        } else {
                            stderr.writeAll("\n") catch {};
                        }
                    }
                    const msg = std.fmt.bufPrint(&buf, "[FAIL] {s} - {d} total mismatches\n", .{ path, self.mismatches }) catch "[FAIL]\n";
                    stderr.writeAll(msg) catch {};
                }
                if (self.log_file) |file| {
                    const log_summary = std.fmt.bufPrint(&buf, "\n[SUMMARY] {d} total mismatches\n", .{self.mismatches}) catch "";
                    file.writeAll(log_summary) catch {};
                }
                return error.TestFailed;
            }
        }
    }
};

/// Helper to get environment variable (cross-platform)
fn getEnvVar(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => null,
    };
}

/// Initialize simulation state from environment variables
pub fn initFromEnv(allocator: std.mem.Allocator) !SimState {
    var state = SimState.init(allocator);
    errdefer state.deinit();

    if (getEnvVar(allocator, "SIM_TEST")) |path| {
        state.mode = .Test;
        state.file_path = path;
        const loaded = try SimState.readFromFile(allocator, path);
        state.frames = loaded.frames;
        state.string_buffer = loaded.string_buffer;
    } else if (getEnvVar(allocator, "SIM_REPLAY")) |path| {
        state.mode = .Replay;
        state.file_path = path;
        const loaded = try SimState.readFromFile(allocator, path);
        state.frames = loaded.frames;
        state.string_buffer = loaded.string_buffer;
    } else if (getEnvVar(allocator, "SIM_RECORD")) |path| {
        state.mode = .Record;
        state.file_path = path;
    }

    if (getEnvVar(allocator, "SIM_LOG")) |log_path| {
        defer allocator.free(log_path);
        state.log_file = std.fs.cwd().createFile(log_path, .{}) catch null;
    }

    return state;
}

// Unit Tests

test "rrsim format round-trip" {
    const allocator = std.testing.allocator;

    var state = SimState.init(allocator);
    defer state.deinit();

    try state.string_buffer.appendSlice(allocator, "Hello World");

    var frame = FrameRecord.init();
    frame.inputs = .{
        .frame_count = 42,
        .mouse_x = 100.5,
        .mouse_y = 200.25,
        .mouse_wheel = 1.0,
        .mouse_left = 1,
        .mouse_middle = 0,
        .mouse_right = 1,
        .keys = [_]u8{0} ** KEY_COUNT,
    };
    try frame.outputs.append(allocator, .{ .BeginFrame = {} });
    try frame.outputs.append(allocator, .{ .Clear = 5 });
    try frame.outputs.append(allocator, .{ .Rectangle = .{ .height = 50, .width = 100, .x = 10, .y = 20, .color = .red } });
    try frame.outputs.append(allocator, .{ .Circle = .{ .center = .{ .x = 50, .y = 50 }, .radius = 25, .color = .green } });
    try frame.outputs.append(allocator, .{ .Line = .{ .end = .{ .x = 100, .y = 100 }, .start = .{ .x = 0, .y = 0 }, .color = .blue } });
    try frame.outputs.append(allocator, .{ .Text = .{ .pos_x = 10, .pos_y = 10, .size = 20, .color = 11, .text_offset = 0, .text_len = 11 } });
    try frame.outputs.append(allocator, .{ .EndFrame = {} });
    try state.frames.append(allocator, frame);

    var buffer: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try state.writeTo(fbs.writer());

    const written = fbs.getWritten();
    var loaded = try SimState.readFromBytes(allocator, written);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 1), loaded.frames.items.len);
    try std.testing.expectEqual(@as(u64, 42), loaded.frames.items[0].inputs.frame_count);
    try std.testing.expectEqual(@as(f32, 100.5), loaded.frames.items[0].inputs.mouse_x);
    try std.testing.expectEqual(@as(usize, 7), loaded.frames.items[0].outputs.items.len);
    try std.testing.expectEqual(@as(usize, 11), loaded.string_buffer.items.len);
    try std.testing.expectEqualStrings("Hello World", loaded.string_buffer.items);
}

test "rrsim header validation - bad magic" {
    const allocator = std.testing.allocator;
    const bad_data = "XXXX" ++ [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidFormat, SimState.readFromBytes(allocator, bad_data));
}

test "rrsim header validation - unsupported version" {
    const allocator = std.testing.allocator;
    const bad_data = "RRSM" ++ [_]u8{ 99, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.UnsupportedVersion, SimState.readFromBytes(allocator, bad_data));
}

test "draw command equality" {
    const cmd1 = DrawCommand{ .Clear = 5 };
    const cmd2 = DrawCommand{ .Clear = 5 };
    const cmd3 = DrawCommand{ .Clear = 6 };
    const cmd4 = DrawCommand{ .BeginFrame = {} };

    try std.testing.expect(cmd1.eql(cmd2));
    try std.testing.expect(!cmd1.eql(cmd3));
    try std.testing.expect(!cmd1.eql(cmd4));
}

test "draw command with abi types" {
    const cmd = DrawCommand{ .Circle = .{ .center = .{ .x = 100, .y = 200 }, .radius = 50, .color = .red } };
    try std.testing.expectEqual(@as(f32, 100), cmd.Circle.center.x);
    try std.testing.expectEqual(@as(f32, 200), cmd.Circle.center.y);
    try std.testing.expectEqual(@as(f32, 50), cmd.Circle.radius);
    try std.testing.expectEqual(abi.Color.red, cmd.Circle.color);
}

test "test mode mismatch detection" {
    const allocator = std.testing.allocator;

    var state = SimState.init(allocator);
    defer state.deinit();

    var frame = FrameRecord.init();
    try frame.outputs.append(allocator, .{ .Clear = 5 });
    try frame.outputs.append(allocator, .{ .Rectangle = .{ .height = 50, .width = 100, .x = 10, .y = 20, .color = .red } });
    try state.frames.append(allocator, frame);

    state.mode = .Test;
    state.frame_idx = 0;
    state.output_idx = 0;

    // Record matching output
    try state.recordOutput(.{ .Clear = 5 });
    try std.testing.expectEqual(@as(u32, 0), state.mismatches);

    // Record mismatching output (wrong color)
    try state.recordOutput(.{ .Rectangle = .{ .height = 50, .width = 100, .x = 10, .y = 20, .color = .white } });
    try std.testing.expectEqual(@as(u32, 1), state.mismatches);
}

test "empty recording round-trip" {
    const allocator = std.testing.allocator;

    var state = SimState.init(allocator);
    defer state.deinit();

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try state.writeTo(fbs.writer());

    const written = fbs.getWritten();
    var loaded = try SimState.readFromBytes(allocator, written);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 0), loaded.frames.items.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.string_buffer.items.len);
}
