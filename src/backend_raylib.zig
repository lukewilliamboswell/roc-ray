//! Raylib backend wrapper.
//!
//! This module provides a clean interface to raylib, accepting ABI types
//! from roc_platform_abi.zig and converting them to raylib's C types.
//! All C interop is isolated here.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const ffi = @import("roc_ffi.zig");

/// Raw raylib C bindings.
pub const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("rlgl.h");
});

/// Persistent keyboard state - updated each frame.
/// `key_state` is the held (down) state; `key_pressed_state` is the edge
/// (pressed-this-frame) state.
var key_state: [ffi.KEY_COUNT]u8 = [_]u8{0} ** ffi.KEY_COUNT;
var key_pressed_state: [ffi.KEY_COUNT]u8 = [_]u8{0} ** ffi.KEY_COUNT;

/// Update keyboard state from raylib (call once per frame)
pub fn updateKeyboardState() void {
    for (0..ffi.KEY_COUNT) |i| {
        const key: c_int = @intCast(i);
        key_state[i] = if (rl.IsKeyDown(key)) 1 else 0;
        key_pressed_state[i] = if (rl.IsKeyPressed(key)) 1 else 0;
    }
}

/// Get the current keyboard down-state array
pub fn getKeyState() *const [ffi.KEY_COUNT]u8 {
    return &key_state;
}

/// Get the keyboard pressed-this-frame (edge) state array
pub fn getKeyPressedState() *const [ffi.KEY_COUNT]u8 {
    return &key_pressed_state;
}

const MAX_FONTS: usize = 32;

/// Custom fonts loaded by the host. Handle 0 is always raylib's default font;
/// loaded fonts use handles 1..MAX_FONTS.
var fonts: [MAX_FONTS]rl.Font = undefined;
var font_count: usize = 0;

fn fontFromHandle(handle: u64) rl.Font {
    if (handle == 0) return rl.GetFontDefault();
    if (handle > @as(u64, @intCast(font_count))) return rl.GetFontDefault();

    const index: usize = @intCast(handle - 1);
    return fonts[index];
}

/// Load a custom font and return its handle, or null on failure.
pub fn loadFont(path: [*:0]const u8, size: c_int) ?u64 {
    if (font_count >= MAX_FONTS) return null;

    const font_size = if (size < 1) 1 else size;
    const font = rl.LoadFontEx(path, font_size, null, 0);
    if (!rl.IsFontValid(font)) return null;

    fonts[font_count] = font;
    font_count += 1;
    return @intCast(font_count);
}

/// Unload all custom fonts. The default font is owned by raylib.
pub fn unloadFonts() void {
    var i: usize = 0;
    while (i < font_count) : (i += 1) {
        rl.UnloadFont(fonts[i]);
    }
    font_count = 0;
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
pub fn drawTextZ(text: [*:0]const u8, font_handle: u64, pos: rl.Vector2, size: f32, spacing: f32, color: abi.Color) void {
    rl.DrawTextEx(fontFromHandle(font_handle), text, pos, size, spacing, colorToRl(color));
}

/// Measure text with a null-terminated string.
pub fn measureTextZ(text: [*:0]const u8, font_handle: u64, size: f32, spacing: f32) rl.Vector2 {
    return rl.MeasureTextEx(fontFromHandle(font_handle), text, size, spacing);
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
        rl.Vector2{ .x = args.center.x, .y = args.center.y },
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
    unloadFonts();
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

/// Get frame time (delta time) in seconds since the previous frame.
pub fn getFrameTime() f32 {
    return rl.GetFrameTime();
}

/// Get elapsed time in seconds since the window was initialized (monotonic).
pub fn getTime() f64 {
    return rl.GetTime();
}

/// Seed raylib's random number generator.
pub fn setRandomSeed(seed: u32) void {
    rl.SetRandomSeed(seed);
}

/// Get a random value in the range [min, max] (both endpoints included).
pub fn getRandomValue(min: c_int, max: c_int) c_int {
    return rl.GetRandomValue(min, max);
}

// --- Audio ---------------------------------------------------------------

const TONE_SAMPLE_RATE: u32 = 44100;
const MAX_TONE_MS: i32 = 1000;
const MAX_SOUNDS: usize = 32;

/// Generated sounds, owned by the host and addressed by handle (index).
var sounds: [MAX_SOUNDS]rl.Sound = undefined;
var sound_count: usize = 0;
/// Scratch buffer for tone generation (mono 16-bit, up to MAX_TONE_MS).
var tone_buf: [TONE_SAMPLE_RATE]i16 = undefined;

/// Initialize the audio device (call once, after the window exists).
pub fn initAudioDevice() void {
    rl.InitAudioDevice();
}

/// Unload generated sounds and close the audio device.
pub fn closeAudioDevice() void {
    var i: usize = 0;
    while (i < sound_count) : (i += 1) rl.UnloadSound(sounds[i]);
    rl.CloseAudioDevice();
}

/// Generate a short sine tone, store it, and return its handle.
/// Duration is clamped to [1, MAX_TONE_MS] ms; if the table is full the
/// existing handle 0 is returned rather than allocating.
pub fn genTone(freq: f32, ms: i32) usize {
    if (sound_count >= MAX_SOUNDS) return 0;

    const dur_ms: i32 = if (ms < 1) 1 else if (ms > MAX_TONE_MS) MAX_TONE_MS else ms;
    const frames: usize = @intCast(@divTrunc(@as(i64, TONE_SAMPLE_RATE) * dur_ms, 1000));
    const fade: f32 = 0.005 * @as(f32, @floatFromInt(TONE_SAMPLE_RATE)); // 5ms anti-click ramp

    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const t: f32 = fi / @as(f32, @floatFromInt(TONE_SAMPLE_RATE));
        const wave_sample = std.math.sin(2.0 * std.math.pi * freq * t);
        const tail: f32 = @as(f32, @floatFromInt(frames)) - fi;
        const env: f32 = @min(1.0, @min(fi / fade, tail / fade));
        tone_buf[i] = @intFromFloat(wave_sample * env * 8000.0);
    }

    const wave = rl.Wave{
        .frameCount = @intCast(frames),
        .sampleRate = TONE_SAMPLE_RATE,
        .sampleSize = 16,
        .channels = 1,
        .data = @ptrCast(&tone_buf),
    };
    const handle = sound_count;
    sounds[handle] = rl.LoadSoundFromWave(wave);
    sound_count += 1;
    return handle;
}

/// Play a previously generated sound by handle (no-op if out of range).
pub fn playSoundHandle(handle: usize) void {
    if (handle < sound_count) rl.PlaySound(sounds[handle]);
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

/// Get screen width.
pub fn getScreenWidth() c_int {
    return rl.GetScreenWidth();
}

/// Get screen height.
pub fn getScreenHeight() c_int {
    return rl.GetScreenHeight();
}
