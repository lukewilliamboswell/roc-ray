//! Raylib backend wrapper.
//!
//! This module provides a clean interface to raylib, accepting safe Zig types
//! from types.zig and converting them to raylib's C types. All C interop
//! is isolated here.

const types = @import("../types.zig");

/// Raw raylib C bindings.
pub const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("rlgl.h");
});

/// Raylib's native color type (exposed for overlay/UI code that needs it).
pub const Color = rl.Color;

/// Convert safe Color enum to raylib Color.
pub fn colorToRl(color: types.Color) rl.Color {
    return switch (color) {
        .black => rl.BLACK,
        .blue => rl.BLUE,
        .dark_gray => rl.DARKGRAY,
        .gray => rl.GRAY,
        .green => rl.GREEN,
        .light_gray => rl.LIGHTGRAY,
        .orange => rl.ORANGE,
        .pink => rl.PINK,
        .purple => rl.PURPLE,
        .ray_white => rl.RAYWHITE,
        .red => rl.RED,
        .white => rl.WHITE,
        .yellow => rl.YELLOW,
    };
}

/// Create a raylib Color from RGBA values.
pub fn rgba(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return rl.Color{ .r = r, .g = g, .b = b, .a = a };
}

/// Draw a circle using safe types.
pub fn drawCircle(circle: types.Circle) void {
    rl.DrawCircle(
        @intFromFloat(circle.center.x),
        @intFromFloat(circle.center.y),
        circle.radius,
        colorToRl(circle.color),
    );
}

/// Draw a rectangle using safe types.
pub fn drawRectangle(rect: types.Rectangle) void {
    rl.DrawRectangle(
        @intFromFloat(rect.x),
        @intFromFloat(rect.y),
        @intFromFloat(rect.width),
        @intFromFloat(rect.height),
        colorToRl(rect.color),
    );
}

/// Draw a line using safe types.
pub fn drawLine(line: types.Line) void {
    rl.DrawLine(
        @intFromFloat(line.start.x),
        @intFromFloat(line.start.y),
        @intFromFloat(line.end.x),
        @intFromFloat(line.end.y),
        colorToRl(line.color),
    );
}

/// Draw text using safe types.
/// Note: The text content must be null-terminated or fit in internal buffer.
pub fn drawText(text: types.Text, buf: *[256:0]u8) void {
    if (text.content.len < buf.len) {
        @memcpy(buf[0..text.content.len], text.content);
        buf[text.content.len] = 0;
        rl.DrawText(
            buf[0..text.content.len :0],
            @intFromFloat(text.pos.x),
            @intFromFloat(text.pos.y),
            text.size,
            colorToRl(text.color),
        );
    }
}

/// Draw text with a raw null-terminated string.
pub fn drawTextRaw(text: [*:0]const u8, x: c_int, y: c_int, size: c_int, color: rl.Color) void {
    rl.DrawText(text, x, y, size, color);
}

/// Draw a rectangle with vertical gradient using safe types.
pub fn drawRectangleGradientV(rg: types.RectangleGradientV) void {
    rl.DrawRectangleGradientV(
        @intFromFloat(rg.x),
        @intFromFloat(rg.y),
        @intFromFloat(rg.width),
        @intFromFloat(rg.height),
        colorToRl(rg.color_top),
        colorToRl(rg.color_bottom),
    );
}

/// Draw a rectangle with horizontal gradient using safe types.
pub fn drawRectangleGradientH(rg: types.RectangleGradientH) void {
    rl.DrawRectangleGradientH(
        @intFromFloat(rg.x),
        @intFromFloat(rg.y),
        @intFromFloat(rg.width),
        @intFromFloat(rg.height),
        colorToRl(rg.color_left),
        colorToRl(rg.color_right),
    );
}

/// Draw a circle with radial gradient using safe types.
pub fn drawCircleGradient(cg: types.CircleGradient) void {
    rl.DrawCircleGradient(
        @intFromFloat(cg.center.x),
        @intFromFloat(cg.center.y),
        cg.radius,
        colorToRl(cg.color_inner),
        colorToRl(cg.color_outer),
    );
}

/// Draw a rectangle with position and size as integers.
pub fn drawRectangleRaw(x: c_int, y: c_int, w: c_int, h: c_int, color: rl.Color) void {
    rl.DrawRectangle(x, y, w, h, color);
}

/// Draw a circle with raw integer/float coordinates.
pub fn drawCircleRaw(x: c_int, y: c_int, radius: f32, color: rl.Color) void {
    rl.DrawCircle(x, y, radius, color);
}

/// Draw a line with raw integer coordinates.
pub fn drawLineRaw(x1: c_int, y1: c_int, x2: c_int, y2: c_int, color: rl.Color) void {
    rl.DrawLine(x1, y1, x2, y2, color);
}

/// Begin drawing frame.
pub fn beginDrawing() void {
    rl.BeginDrawing();
}

/// End drawing frame.
pub fn endDrawing() void {
    rl.EndDrawing();
}

/// Clear the background with a safe color.
pub fn clearBackground(color: types.Color) void {
    rl.ClearBackground(colorToRl(color));
}

/// Clear the background with a raylib color.
pub fn clearBackgroundRaw(color: rl.Color) void {
    rl.ClearBackground(color);
}

/// Initialize a window.
pub fn initWindow(width: c_int, height: c_int, title: [*:0]const u8) void {
    rl.InitWindow(width, height, title);
}

/// Close the window.
pub fn closeWindow() void {
    rl.CloseWindow();
}

/// Check if window should close.
pub fn windowShouldClose() bool {
    return rl.WindowShouldClose();
}

/// Set target FPS.
pub fn setTargetFps(fps: c_int) void {
    rl.SetTargetFPS(fps);
}

/// Get frame time (delta time).
pub fn getFrameTime() f32 {
    return rl.GetFrameTime();
}

/// Keyboard key enum for type-safe key handling.
pub const Key = enum(c_int) {
    space = rl.KEY_SPACE,
    q = rl.KEY_Q,
    f = rl.KEY_F,
    left = rl.KEY_LEFT,
    right = rl.KEY_RIGHT,
    up = rl.KEY_UP,
    down = rl.KEY_DOWN,
    home = rl.KEY_HOME,
    end = rl.KEY_END,
};

/// Check if a key was pressed (not held).
pub fn isKeyPressed(key: Key) bool {
    return rl.IsKeyPressed(@intFromEnum(key));
}

/// Check if a key is currently held down.
pub fn isKeyDown(key: Key) bool {
    return rl.IsKeyDown(@intFromEnum(key));
}

/// Mouse button enum for type-safe button handling.
pub const MouseButton = enum(c_int) {
    left = rl.MOUSE_BUTTON_LEFT,
    middle = rl.MOUSE_BUTTON_MIDDLE,
    right = rl.MOUSE_BUTTON_RIGHT,
};

/// Get mouse position as safe Vector2.
pub fn getMousePosition() types.Vector2 {
    const pos = rl.GetMousePosition();
    return .{ .x = pos.x, .y = pos.y };
}

/// Check if a mouse button is down.
pub fn isMouseButtonDown(button: MouseButton) bool {
    return rl.IsMouseButtonDown(@intFromEnum(button));
}

/// Get mouse wheel movement.
pub fn getMouseWheelMove() f32 {
    return rl.GetMouseWheelMove();
}

/// Get current input state.
pub fn getInputState(frame_count: u64) types.InputState {
    const pos = rl.GetMousePosition();
    return .{
        .frame_count = frame_count,
        .mouse_x = pos.x,
        .mouse_y = pos.y,
        .mouse_wheel = rl.GetMouseWheelMove(),
        .mouse_left = rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT),
        .mouse_middle = rl.IsMouseButtonDown(rl.MOUSE_BUTTON_MIDDLE),
        .mouse_right = rl.IsMouseButtonDown(rl.MOUSE_BUTTON_RIGHT),
    };
}

/// Measure text width.
pub fn measureText(text: [*:0]const u8, font_size: c_int) c_int {
    return rl.MeasureText(text, font_size);
}

/// Get screen width.
pub fn getScreenWidth() c_int {
    return rl.GetScreenWidth();
}

/// Get screen height.
pub fn getScreenHeight() c_int {
    return rl.GetScreenHeight();
}
