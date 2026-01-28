//! Replay UI overlay module.
//!
//! This module handles the visual overlay displayed during replay mode,
//! including the PAUSED indicator, frame counter, speed display, and
//! input state visualization.

const std = @import("std");
const types = @import("types.zig");
const raylib = @import("backend_raylib.zig");

/// Speed presets for playback control.
pub const speed_presets = [_]f32{ 0.1, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0 };

/// Default speed index (1.0x).
pub const default_speed_index: usize = 4;

/// Overlay state for replay UI.
pub const OverlayState = struct {
    blink_timer: f32 = 0,
    paused: bool = true,
    speed_index: usize = default_speed_index,
    frame_accumulator: f32 = 0,

    /// Get the current playback speed.
    pub fn currentSpeed(self: *const OverlayState) f32 {
        return speed_presets[self.speed_index];
    }

    /// Toggle pause state.
    pub fn togglePause(self: *OverlayState) void {
        self.paused = !self.paused;
        self.frame_accumulator = 0;
    }

    /// Increase playback speed.
    pub fn increaseSpeed(self: *OverlayState) void {
        if (self.speed_index + 1 < speed_presets.len) {
            self.speed_index += 1;
        }
    }

    /// Decrease playback speed.
    pub fn decreaseSpeed(self: *OverlayState) void {
        if (self.speed_index > 0) {
            self.speed_index -= 1;
        }
    }

    /// Update the blink timer.
    pub fn update(self: *OverlayState, delta: f32) void {
        self.blink_timer += delta;
    }

    /// Get the current blink color (alternates between light and dark).
    pub fn getBlinkColor(self: *const OverlayState) types.Color {
        if (@mod(self.blink_timer, 1.0) < 0.5) {
            return .white;
        } else {
            return .dark_gray;
        }
    }
};

/// Draw the paused overlay with frame and speed info.
pub fn drawPausedOverlay(
    state: *const OverlayState,
    frame_idx: usize,
    total_frames: usize,
    screen_width: c_int,
    screen_height: c_int,
) void {
    const color = state.getBlinkColor();
    const info_font: c_int = 30;

    // "PAUSED" text centered
    const paused_text = "PAUSED";
    const paused_font: c_int = 80;
    const paused_width = raylib.measureText(paused_text, paused_font);
    const paused_x = @divTrunc(screen_width - paused_width, 2);
    const paused_y = @divTrunc(screen_height, 2) - 60;
    raylib.drawTextZ(paused_text, paused_x, paused_y, paused_font, color);

    // Frame/Speed status centered below PAUSED
    var status_buf: [128:0]u8 = undefined;
    const status_slice = std.fmt.bufPrint(&status_buf, "Frame: {d}/{d}  Speed: {d:.2}x", .{
        frame_idx + 1,
        total_frames,
        state.currentSpeed(),
    }) catch "Frame: ?/?";
    status_buf[status_slice.len] = 0;
    const status_width = raylib.measureText(status_buf[0..status_slice.len :0], info_font);
    const status_x = @divTrunc(screen_width - status_width, 2);
    const status_y = paused_y + paused_font + 10;
    raylib.drawTextZ(status_buf[0..status_slice.len :0], status_x, status_y, info_font, color);

    // Hint to press F
    const hint_text = "PRESS F FOR INPUTS";
    const hint_font: c_int = 20;
    const hint_width = raylib.measureText(hint_text, hint_font);
    const hint_x = @divTrunc(screen_width - hint_width, 2);
    const hint_y = status_y + info_font + 20;
    raylib.drawTextZ(hint_text, hint_x, hint_y, hint_font, color);
}

/// Draw the input state overlay (when F is held).
pub fn drawInputsOverlay(
    state: *const OverlayState,
    inputs: types.InputState,
    screen_width: c_int,
    screen_height: c_int,
) void {
    const color = state.getBlinkColor();
    const info_font: c_int = 30;
    const base_y = @divTrunc(screen_height, 2) - 80;

    // Title
    const title = "INPUTS";
    const title_font: c_int = 60;
    const title_width = raylib.measureText(title, title_font);
    raylib.drawTextZ(title, @divTrunc(screen_width - title_width, 2), base_y, title_font, color);

    // Mouse position
    var line1_buf: [64:0]u8 = undefined;
    const line1 = std.fmt.bufPrint(&line1_buf, "Mouse: ({d:.1}, {d:.1})", .{ inputs.mouse_x, inputs.mouse_y }) catch "Mouse: ?";
    line1_buf[line1.len] = 0;
    const line1_width = raylib.measureText(line1_buf[0..line1.len :0], info_font);
    raylib.drawTextZ(line1_buf[0..line1.len :0], @divTrunc(screen_width - line1_width, 2), base_y + title_font + 15, info_font, color);

    // Mouse buttons
    var line2_buf: [64:0]u8 = undefined;
    const left_str: []const u8 = if (inputs.mouse_left) "LEFT" else "left";
    const mid_str: []const u8 = if (inputs.mouse_middle) "MID" else "mid";
    const right_str: []const u8 = if (inputs.mouse_right) "RIGHT" else "right";
    const line2 = std.fmt.bufPrint(&line2_buf, "Buttons: [{s}] [{s}] [{s}]", .{ left_str, mid_str, right_str }) catch "Buttons: ?";
    line2_buf[line2.len] = 0;
    const line2_width = raylib.measureText(line2_buf[0..line2.len :0], info_font);
    raylib.drawTextZ(line2_buf[0..line2.len :0], @divTrunc(screen_width - line2_width, 2), base_y + title_font + 50, info_font, color);

    // Mouse wheel
    var line3_buf: [64:0]u8 = undefined;
    const line3 = std.fmt.bufPrint(&line3_buf, "Wheel: {d:.2}", .{inputs.mouse_wheel}) catch "Wheel: ?";
    line3_buf[line3.len] = 0;
    const line3_width = raylib.measureText(line3_buf[0..line3.len :0], info_font);
    raylib.drawTextZ(line3_buf[0..line3.len :0], @divTrunc(screen_width - line3_width, 2), base_y + title_font + 85, info_font, color);
}

/// Actions requested by input handling.
pub const InputAction = struct {
    quit: bool = false,
    step_back: bool = false,
    step_forward: bool = false,
    jump_to_start: bool = false,
    jump_to_end: bool = false,
};

/// Handle replay control input. Returns requested actions.
pub fn handleInput(state: *OverlayState) InputAction {
    var action = InputAction{};

    // Q to quit
    if (raylib.isKeyPressed(.q)) {
        action.quit = true;
        return action;
    }

    // Space to toggle pause
    if (raylib.isKeyPressed(.space)) {
        state.togglePause();
    }

    // Arrow keys for stepping (only when paused)
    if (state.paused) {
        if (raylib.isKeyPressed(.left)) action.step_back = true;
        if (raylib.isKeyPressed(.right)) action.step_forward = true;
    }

    // Home/End to jump
    if (raylib.isKeyPressed(.home)) action.jump_to_start = true;
    if (raylib.isKeyPressed(.end)) action.jump_to_end = true;

    // Up/Down for speed control
    if (raylib.isKeyPressed(.up)) state.increaseSpeed();
    if (raylib.isKeyPressed(.down)) state.decreaseSpeed();

    return action;
}

/// Check if F key is held (for showing inputs overlay).
pub fn isShowingInputs() bool {
    return raylib.isKeyDown(.f);
}

// Tests

test "OverlayState default values" {
    const state = OverlayState{};
    try std.testing.expectEqual(@as(f32, 0), state.blink_timer);
    try std.testing.expect(state.paused);
    try std.testing.expectEqual(@as(usize, 4), state.speed_index);
    try std.testing.expectEqual(@as(f32, 1.0), state.currentSpeed());
}

test "OverlayState toggle pause" {
    var state = OverlayState{};
    try std.testing.expect(state.paused);

    state.togglePause();
    try std.testing.expect(!state.paused);

    state.togglePause();
    try std.testing.expect(state.paused);
}

test "OverlayState speed control" {
    var state = OverlayState{};

    // Start at 1.0x (index 4)
    try std.testing.expectEqual(@as(f32, 1.0), state.currentSpeed());

    // Increase to 1.25x
    state.increaseSpeed();
    try std.testing.expectEqual(@as(f32, 1.25), state.currentSpeed());

    // Decrease back to 1.0x
    state.decreaseSpeed();
    try std.testing.expectEqual(@as(f32, 1.0), state.currentSpeed());

    // Decrease to 0.75x
    state.decreaseSpeed();
    try std.testing.expectEqual(@as(f32, 0.75), state.currentSpeed());
}

test "OverlayState speed bounds" {
    var state = OverlayState{};

    // Go to minimum
    state.speed_index = 0;
    state.decreaseSpeed();
    try std.testing.expectEqual(@as(usize, 0), state.speed_index);

    // Go to maximum
    state.speed_index = speed_presets.len - 1;
    state.increaseSpeed();
    try std.testing.expectEqual(speed_presets.len - 1, state.speed_index);
}

test "OverlayState update blink timer" {
    var state = OverlayState{};
    try std.testing.expectEqual(@as(f32, 0), state.blink_timer);

    state.update(0.5);
    try std.testing.expectEqual(@as(f32, 0.5), state.blink_timer);

    state.update(0.3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), state.blink_timer, 0.001);
}
