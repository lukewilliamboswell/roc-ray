//! Raylib backend wrapper.
//!
//! This module provides a clean interface to raylib, accepting ABI types
//! from roc_platform_abi.zig and converting them to raylib's C types.
//! All C interop is isolated here.

const abi = @import("roc_platform_abi.zig");
const ffi = @import("roc_ffi.zig");

/// Raw raylib C bindings.
pub const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("rlgl.h");
});

/// Persistent keyboard state - updated each frame
var key_state: [ffi.KEY_COUNT]u8 = [_]u8{0} ** ffi.KEY_COUNT;

/// Update keyboard state from raylib (call once per frame)
pub fn updateKeyboardState() void {
    for (0..ffi.KEY_COUNT) |i| {
        const key: c_int = @intCast(i);
        key_state[i] = if (rl.IsKeyDown(key)) 1 else 0;
    }
}

/// Get the current keyboard state array
pub fn getKeyState() *const [ffi.KEY_COUNT]u8 {
    return &key_state;
}

/// Convert abi Color enum to raylib Color.
pub fn colorToRl(color: abi.Color) rl.Color {
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

/// Draw a circle from abi args.
pub fn drawCircle(args: abi.DrawCircleArgs) void {
    rl.DrawCircle(
        @intFromFloat(args.center.x),
        @intFromFloat(args.center.y),
        args.radius,
        colorToRl(args.color),
    );
}

/// Draw a rectangle from abi args.
pub fn drawRectangle(args: abi.DrawRectangleArgs) void {
    rl.DrawRectangle(
        @intFromFloat(args.x),
        @intFromFloat(args.y),
        @intFromFloat(args.width),
        @intFromFloat(args.height),
        colorToRl(args.color),
    );
}

/// Draw a line from abi args.
pub fn drawLine(args: abi.DrawLineArgs) void {
    rl.DrawLine(
        @intFromFloat(args.start.x),
        @intFromFloat(args.start.y),
        @intFromFloat(args.end.x),
        @intFromFloat(args.end.y),
        colorToRl(args.color),
    );
}

/// Draw text with a null-terminated string.
pub fn drawTextZ(text: [*:0]const u8, x: c_int, y: c_int, size: c_int, color: abi.Color) void {
    rl.DrawText(text, x, y, size, colorToRl(color));
}

/// Draw a rectangle with vertical gradient from abi args.
pub fn drawRectangleGradientV(args: abi.DrawRectangle_gradient_vArgs) void {
    rl.DrawRectangleGradientV(
        @intFromFloat(args.x),
        @intFromFloat(args.y),
        @intFromFloat(args.width),
        @intFromFloat(args.height),
        colorToRl(args.color_top),
        colorToRl(args.color_bottom),
    );
}

/// Draw a rectangle with horizontal gradient from abi args.
pub fn drawRectangleGradientH(args: abi.DrawRectangle_gradient_hArgs) void {
    rl.DrawRectangleGradientH(
        @intFromFloat(args.x),
        @intFromFloat(args.y),
        @intFromFloat(args.width),
        @intFromFloat(args.height),
        colorToRl(args.color_left),
        colorToRl(args.color_right),
    );
}

/// Draw a circle with radial gradient from abi args.
pub fn drawCircleGradient(args: abi.DrawCircle_gradientArgs) void {
    rl.DrawCircleGradient(
        @intFromFloat(args.center.x),
        @intFromFloat(args.center.y),
        args.radius,
        colorToRl(args.color_inner),
        colorToRl(args.color_outer),
    );
}

/// Draw FPS counter at specified position.
pub fn drawFps(x: c_int, y: c_int) void {
    rl.DrawFPS(x, y);
}

/// Begin drawing frame.
pub fn beginDrawing() void {
    rl.BeginDrawing();
}

/// End drawing frame.
pub fn endDrawing() void {
    rl.EndDrawing();
}

/// Clear the background with a color.
pub fn clearBackground(color: abi.Color) void {
    rl.ClearBackground(colorToRl(color));
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

/// Set window size.
pub fn setWindowSize(width: c_int, height: c_int) void {
    rl.SetWindowSize(width, height);
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

/// Simple 2D vector for mouse position.
pub const Vec2 = struct { x: f32, y: f32 };

/// Get mouse position.
pub fn getMousePosition() Vec2 {
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
