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
/// (pressed-this-frame) state; `key_released_state` is the release edge state.
var key_state: [ffi.KEY_COUNT]u8 = [_]u8{0} ** ffi.KEY_COUNT;
var key_pressed_state: [ffi.KEY_COUNT]u8 = [_]u8{0} ** ffi.KEY_COUNT;
var key_released_state: [ffi.KEY_COUNT]u8 = [_]u8{0} ** ffi.KEY_COUNT;

/// Persistent mouse button state - updated each frame.
var mouse_button_state: [ffi.MOUSE_BUTTON_COUNT]u8 = [_]u8{0} ** ffi.MOUSE_BUTTON_COUNT;
var mouse_button_pressed_state: [ffi.MOUSE_BUTTON_COUNT]u8 = [_]u8{0} ** ffi.MOUSE_BUTTON_COUNT;
var mouse_button_released_state: [ffi.MOUSE_BUTTON_COUNT]u8 = [_]u8{0} ** ffi.MOUSE_BUTTON_COUNT;

/// Update keyboard state from raylib (call once per frame)
pub fn updateKeyboardState() void {
    for (0..ffi.KEY_COUNT) |i| {
        const key: c_int = @intCast(i);
        key_state[i] = if (rl.IsKeyDown(key)) 1 else 0;
        key_pressed_state[i] = if (rl.IsKeyPressed(key)) 1 else 0;
        key_released_state[i] = if (rl.IsKeyReleased(key)) 1 else 0;
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

/// Get the keyboard released-this-frame (edge) state array
pub fn getKeyReleasedState() *const [ffi.KEY_COUNT]u8 {
    return &key_released_state;
}

/// Update mouse button state from raylib (call once per frame)
pub fn updateMouseButtonState() void {
    for (0..ffi.MOUSE_BUTTON_COUNT) |i| {
        const button: c_int = @intCast(i);
        mouse_button_state[i] = if (rl.IsMouseButtonDown(button)) 1 else 0;
        mouse_button_pressed_state[i] = if (rl.IsMouseButtonPressed(button)) 1 else 0;
        mouse_button_released_state[i] = if (rl.IsMouseButtonReleased(button)) 1 else 0;
    }
}

/// Get the current mouse button down-state array
pub fn getMouseButtonState() *const [ffi.MOUSE_BUTTON_COUNT]u8 {
    return &mouse_button_state;
}

/// Get the mouse button pressed-this-frame (edge) state array
pub fn getMouseButtonPressedState() *const [ffi.MOUSE_BUTTON_COUNT]u8 {
    return &mouse_button_pressed_state;
}

/// Get the mouse button released-this-frame (edge) state array
pub fn getMouseButtonReleasedState() *const [ffi.MOUSE_BUTTON_COUNT]u8 {
    return &mouse_button_released_state;
}

const MAX_FONTS: usize = 32;
const MAX_TEXTURES: usize = 128;

/// Custom fonts loaded by the host. Handle 0 is always raylib's default font;
/// loaded fonts use handles 1..MAX_FONTS.
var fonts: [MAX_FONTS]rl.Font = undefined;
var font_count: usize = 0;

/// Textures loaded by the host. Handle 0 is invalid; loaded textures use
/// handles 1..MAX_TEXTURES.
var textures: [MAX_TEXTURES]rl.Texture2D = undefined;
var texture_count: usize = 0;

/// Host texture handle and dimensions returned to Roc after loading.
pub const TextureInfo = struct {
    handle: u64,
    width: f32,
    height: f32,
};

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

fn textureFromHandle(handle: u64) ?rl.Texture2D {
    if (handle == 0) return null;
    if (handle > @as(u64, @intCast(texture_count))) return null;

    const index: usize = @intCast(handle - 1);
    return textures[index];
}

/// Load a texture from disk and return its handle plus dimensions, or null on failure.
pub fn loadTexture(path: [*:0]const u8) ?TextureInfo {
    if (texture_count >= MAX_TEXTURES) return null;

    const texture = rl.LoadTexture(path);
    if (!rl.IsTextureValid(texture)) return null;

    textures[texture_count] = texture;
    texture_count += 1;

    return .{
        .handle = @intCast(texture_count),
        .width = @floatFromInt(texture.width),
        .height = @floatFromInt(texture.height),
    };
}

/// Unload all custom textures.
pub fn unloadTextures() void {
    var i: usize = 0;
    while (i < texture_count) : (i += 1) {
        rl.UnloadTexture(textures[i]);
    }
    texture_count = 0;
}

/// Convert an ABI RGBA color record to raylib Color.
pub fn colorToRl(color: anytype) rl.Color {
    return .{
        .r = color.@"r",
        .g = color.@"g",
        .b = color.@"b",
        .a = color.@"a",
    };
}

fn toVector2(point: anytype) rl.Vector2 {
    return .{ .x = point.@"x", .y = point.@"y" };
}

fn rectFromArgs(args: anytype) rl.Rectangle {
    return .{ .x = args.@"x", .y = args.@"y", .width = args.@"width", .height = args.@"height" };
}

fn cameraFromArgs(args: anytype) rl.Camera2D {
    return .{
        .target = toVector2(args.@"target"),
        .offset = toVector2(args.@"offset"),
        .rotation = args.@"rotation",
        .zoom = args.@"zoom",
    };
}

fn positiveThickness(thickness: f32) ?f32 {
    if (thickness <= 0) return null;
    return thickness;
}

fn positiveSegments(segments: i32) c_int {
    return if (segments < 4) 8 else @intCast(segments);
}

fn absF32(value: f32) f32 {
    return if (value < 0) -value else value;
}

fn roundedness(width: f32, height: f32, radius: f32) f32 {
    if (radius <= 0) return 0;
    const min_dim = @min(absF32(width), absF32(height));
    if (min_dim <= 0) return 0;
    return @min(1, radius / min_dim);
}

fn drawSegment(start: anytype, end: anytype, thickness: f32, color: abi.Color) void {
    const thick = positiveThickness(thickness) orelse return;
    rl.DrawLineEx(toVector2(start), toVector2(end), thick, colorToRl(color));
}

/// Draw a circle from abi args.
pub fn drawCircle(args: anytype) void {
    rl.DrawCircle(
        @intFromFloat(args.@"center".@"x"),
        @intFromFloat(args.@"center".@"y"),
        args.@"radius",
        colorToRl(args.@"color"),
    );
}

/// Draw a thick circle outline from abi args.
pub fn drawCircleLines(args: anytype) void {
    const thick = positiveThickness(args.@"thickness") orelse return;
    const half = thick * 0.5;
    const inner_radius = @max(0, args.@"radius" - half);
    const outer_radius = args.@"radius" + half;

    rl.DrawRing(
        toVector2(args.@"center"),
        inner_radius,
        outer_radius,
        0,
        360,
        64,
        colorToRl(args.@"color"),
    );
}

/// Draw a rectangle from abi args.
pub fn drawRectangle(args: anytype) void {
    rl.DrawRectangle(
        @intFromFloat(args.@"x"),
        @intFromFloat(args.@"y"),
        @intFromFloat(args.@"width"),
        @intFromFloat(args.@"height"),
        colorToRl(args.@"color"),
    );
}

/// Draw a rectangle outline from abi args.
pub fn drawRectangleLines(args: anytype) void {
    const thick = positiveThickness(args.@"thickness") orelse return;
    rl.DrawRectangleLinesEx(rectFromArgs(args), thick, colorToRl(args.@"color"));
}

/// Draw a rounded rectangle from abi args.
pub fn drawRoundedRectangle(args: anytype) void {
    rl.DrawRectangleRounded(
        rectFromArgs(args),
        roundedness(args.@"width", args.@"height", args.@"radius"),
        positiveSegments(args.@"segments"),
        colorToRl(args.@"color"),
    );
}

/// Draw a rounded rectangle outline from abi args.
pub fn drawRoundedRectangleLines(args: anytype) void {
    const thick = positiveThickness(args.@"thickness") orelse return;
    rl.DrawRectangleRoundedLinesEx(
        rectFromArgs(args),
        roundedness(args.@"width", args.@"height", args.@"radius"),
        positiveSegments(args.@"segments"),
        thick,
        colorToRl(args.@"color"),
    );
}

/// Draw a line from abi args.
pub fn drawLine(args: anytype) void {
    drawSegment(args.@"start", args.@"end", args.@"thickness", args.@"color");
}

/// Draw a triangle from abi args.
pub fn drawTriangle(args: anytype) void {
    rl.DrawTriangle(toVector2(args.@"a"), toVector2(args.@"b"), toVector2(args.@"c"), colorToRl(args.@"color"));
}

/// Draw a triangle outline from abi args.
pub fn drawTriangleLines(args: anytype) void {
    drawSegment(args.@"a", args.@"b", args.@"thickness", args.@"color");
    drawSegment(args.@"b", args.@"c", args.@"thickness", args.@"color");
    drawSegment(args.@"c", args.@"a", args.@"thickness", args.@"color");
}

/// Draw a filled polygon by fanning triangles from the point centroid.
pub fn drawPolygon(points: anytype, color: abi.Color) void {
    if (points.len < 3) return;

    var center = rl.Vector2{ .x = 0, .y = 0 };
    for (points) |point| {
        center.x += point.@"x";
        center.y += point.@"y";
    }
    const len_f: f32 = @floatFromInt(points.len);
    center.x /= len_f;
    center.y /= len_f;

    for (points, 0..) |point, i| {
        const next = points[(i + 1) % points.len];
        rl.DrawTriangle(center, toVector2(point), toVector2(next), colorToRl(color));
    }
}

/// Draw a polygon outline from abi args.
pub fn drawPolygonLines(points: anytype, thickness: f32, color: abi.Color) void {
    if (points.len < 2) return;
    const thick = positiveThickness(thickness) orelse return;

    if (points.len == 2) {
        drawSegment(points[0], points[1], thick, color);
        return;
    }

    for (points, 0..) |point, i| {
        const next = points[(i + 1) % points.len];
        drawSegment(point, next, thick, color);
    }
}

/// Draw text with a null-terminated string.
pub fn drawTextZ(text: [*:0]const u8, font_handle: u64, pos: rl.Vector2, size: f32, spacing: f32, color: abi.Color) void {
    rl.DrawTextEx(fontFromHandle(font_handle), text, pos, size, spacing, colorToRl(color));
}

/// Draw a texture region into a destination rectangle.
pub fn drawTexture(args: anytype) void {
    const texture = textureFromHandle(args.@"texture") orelse return;
    rl.DrawTexturePro(
        texture,
        rectFromArgs(args.@"source"),
        rectFromArgs(args.@"dest"),
        toVector2(args.@"origin"),
        args.@"rotation",
        colorToRl(args.@"tint"),
    );
}

/// Measure text with a null-terminated string.
pub fn measureTextZ(text: [*:0]const u8, font_handle: u64, size: f32, spacing: f32) rl.Vector2 {
    return rl.MeasureTextEx(fontFromHandle(font_handle), text, size, spacing);
}

/// Draw a rectangle with vertical gradient from abi args.
pub fn drawRectangleGradientV(args: anytype) void {
    rl.DrawRectangleGradientV(
        @intFromFloat(args.x),
        @intFromFloat(args.y),
        @intFromFloat(args.width),
        @intFromFloat(args.height),
        colorToRl(args.@"color_top"),
        colorToRl(args.@"color_bottom"),
    );
}

/// Draw a rectangle with horizontal gradient from abi args.
pub fn drawRectangleGradientH(args: anytype) void {
    rl.DrawRectangleGradientH(
        @intFromFloat(args.x),
        @intFromFloat(args.y),
        @intFromFloat(args.width),
        @intFromFloat(args.height),
        colorToRl(args.@"color_left"),
        colorToRl(args.@"color_right"),
    );
}

/// Draw a circle with radial gradient from abi args.
pub fn drawCircleGradient(args: anytype) void {
    rl.DrawCircleGradient(
        toVector2(args.@"center"),
        args.@"radius",
        colorToRl(args.@"color_inner"),
        colorToRl(args.@"color_outer"),
    );
}

/// Draw FPS counter at specified position.
pub fn drawFps(args: anytype) void {
    var buf: [32:0]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "FPS: {d}", .{rl.GetFPS()}) catch return;
    rl.DrawTextEx(fontFromHandle(0), text.ptr, toVector2(args.@"pos"), args.@"size", 1, colorToRl(args.@"color"));
}

/// Begin drawing frame.
pub fn beginDrawing() void {
    rl.BeginDrawing();
}

/// Begin drawing in 2D camera mode.
pub fn beginMode2D(camera: anytype) void {
    rl.BeginMode2D(cameraFromArgs(camera));
}

/// End drawing in 2D camera mode.
pub fn endMode2D() void {
    rl.EndMode2D();
}

/// End drawing frame.
pub fn endDrawing() void {
    rl.EndDrawing();
}

/// Clear the background with a color.
pub fn clearBackground(color: anytype) void {
    rl.ClearBackground(colorToRl(color));
}

/// Initialize a window.
pub fn initWindow(width: c_int, height: c_int, title: [*:0]const u8) void {
    rl.InitWindow(width, height, title);
}

/// Set flags that must be configured before InitWindow.
pub fn setConfigFlags(flags: c_uint) void {
    rl.SetConfigFlags(flags);
}

/// Build raylib window config flags from Roc app config booleans.
pub fn windowConfigFlags(resizable: bool, fullscreen: bool, vsync: bool) c_uint {
    var flags: c_uint = 0;
    if (resizable) flags |= @as(c_uint, @intCast(rl.FLAG_WINDOW_RESIZABLE));
    if (fullscreen) flags |= @as(c_uint, @intCast(rl.FLAG_FULLSCREEN_MODE));
    if (vsync) flags |= @as(c_uint, @intCast(rl.FLAG_VSYNC_HINT));
    return flags;
}

/// Close the window.
pub fn closeWindow() void {
    unloadTextures();
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

/// Show the OS cursor.
pub fn showCursor() void {
    rl.ShowCursor();
}

/// Hide the OS cursor.
pub fn hideCursor() void {
    rl.HideCursor();
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

/// Set volume for a previously generated sound by handle (no-op if out of range).
pub fn setSoundVolumeHandle(handle: usize, volume: f32) void {
    if (handle < sound_count) {
        const clamped = if (volume < 0.0) 0.0 else if (volume > 1.0) 1.0 else volume;
        rl.SetSoundVolume(sounds[handle], clamped);
    }
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
    right = rl.MOUSE_BUTTON_RIGHT,
    middle = rl.MOUSE_BUTTON_MIDDLE,
    side = rl.MOUSE_BUTTON_SIDE,
    extra = rl.MOUSE_BUTTON_EXTRA,
    forward = rl.MOUSE_BUTTON_FORWARD,
    back = rl.MOUSE_BUTTON_BACK,
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

/// Check if a mouse button was pressed.
pub fn isMouseButtonPressed(button: MouseButton) bool {
    return rl.IsMouseButtonPressed(@intFromEnum(button));
}

/// Check if a mouse button was released.
pub fn isMouseButtonReleased(button: MouseButton) bool {
    return rl.IsMouseButtonReleased(@intFromEnum(button));
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
