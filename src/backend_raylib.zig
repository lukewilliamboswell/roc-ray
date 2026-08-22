//! Raylib backend wrapper.
//!
//! This module provides a clean interface to raylib, accepting generated ABI
//! types and converting them to raylib's C types.
//! All C interop is isolated here.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const ffi = @import("roc_ffi.zig");
/// Capture policy, kept free of raylib so it can be unit tested without a GPU.
const capture = @import("capture.zig");

/// Roc's `Color.Rgba`, the RGBA record that crosses the host boundary.
pub const Color = abi.ColorRgba;

/// Raw raylib C bindings.
pub const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("rlgl.h");
});

/// Native sound value retained in the host resource heap.
pub const Sound = rl.Sound;

/// Native music stream retained in the host resource heap.
pub const Music = rl.Music;

/// Native font retained in the host resource heap.
pub const Font = rl.Font;

/// Scalar data needed to reproduce raylib's glyph advance calculation.
pub const FontGlyphMetric = struct {
    codepoint: u32,
    advance_x: f32,
    offset_x: f32,
    offset_y: f32,
    width: f32,
    height: f32,
};

/// Return the bundled raylib major version for host invariants.
pub fn majorVersion() c_int {
    return rl.RAYLIB_VERSION_MAJOR;
}

/// Native texture retained in the host resource heap.
pub const Texture = rl.Texture2D;

/// Decode an image in caller-owned memory, upload it, then discard the CPU
/// image. Raylib consumes the bytes synchronously; it does not retain them.
pub fn loadTextureFromMemory(file_type: [*:0]const u8, bytes: []const u8) ?Texture {
    if (bytes.len == 0 or bytes.len > std.math.maxInt(c_int)) return null;
    const image = rl.LoadImageFromMemory(file_type, bytes.ptr, @intCast(bytes.len));
    if (!rl.IsImageValid(image)) return null;
    defer rl.UnloadImage(image);
    const texture = rl.LoadTextureFromImage(image);
    if (!rl.IsTextureValid(texture)) return null;
    return texture;
}

/// Native framebuffer-backed texture retained in the host resource heap.
pub const RenderTexture = rl.RenderTexture2D;

/// Native shader program retained in the host resource heap.
pub const Shader = rl.Shader;

/// Persistent packed keyboard state - updated each frame.
/// Bit 0 is held, bit 1 is pressed this frame, and bit 2 is released this frame.
var key_state: [ffi.KEY_COUNT]u8 = [_]u8{0} ** ffi.KEY_COUNT;

/// Persistent packed mouse button state - updated each frame, with the same bits.
var mouse_button_state: [ffi.MOUSE_BUTTON_COUNT]u8 = [_]u8{0} ** ffi.MOUSE_BUTTON_COUNT;

/// Persistent gamepad snapshot, flattened by gamepad then control index.
var gamepad_available: [ffi.GAMEPAD_COUNT]u8 = [_]u8{0} ** ffi.GAMEPAD_COUNT;
var gamepad_button_state: [ffi.GAMEPAD_COUNT * ffi.GAMEPAD_BUTTON_COUNT]u8 = [_]u8{0} ** (ffi.GAMEPAD_COUNT * ffi.GAMEPAD_BUTTON_COUNT);
var gamepad_axes: [ffi.GAMEPAD_COUNT * ffi.GAMEPAD_AXIS_COUNT]f32 = [_]f32{0} ** (ffi.GAMEPAD_COUNT * ffi.GAMEPAD_AXIS_COUNT);

/// raylib's internal codepoint queue is bounded; this also leaves room if its
/// default grows. Any excess is drained so it cannot leak into a later frame.
pub const TEXT_INPUT_CAPACITY: usize = 32;
var text_input: [TEXT_INPUT_CAPACITY]u32 = [_]u32{0} ** TEXT_INPUT_CAPACITY;

fn gamepadButtonIndex(gamepad: usize, button: usize) usize {
    return gamepad * ffi.GAMEPAD_BUTTON_COUNT + button;
}

fn gamepadAxisIndex(gamepad: usize, axis: usize) usize {
    return gamepad * ffi.GAMEPAD_AXIS_COUNT + axis;
}

test "gamepad snapshot indexing is contiguous per device" {
    try std.testing.expectEqual(@as(usize, 0), gamepadButtonIndex(0, 0));
    try std.testing.expectEqual(@as(usize, 17), gamepadButtonIndex(0, 17));
    try std.testing.expectEqual(@as(usize, 18), gamepadButtonIndex(1, 0));
    try std.testing.expectEqual(@as(usize, 23), gamepadAxisIndex(3, 5));
}

fn inputStateBits(down: bool, pressed: bool, released: bool) u8 {
    return (if (down) ffi.INPUT_HELD else 0) |
        (if (pressed) ffi.INPUT_PRESSED else 0) |
        (if (released) ffi.INPUT_RELEASED else 0);
}

fn disconnectedInputState(previous: u8) u8 {
    return if (previous & ffi.INPUT_HELD != 0) ffi.INPUT_RELEASED else 0;
}

/// Derive this frame's packed state from the previous state and one held query.
/// Raylib's pressed/released queries are equivalent to these transitions for
/// keys and mouse buttons, so the host only needs one boundary call per input.
fn nextInputState(previous: u8, down: bool) u8 {
    const was_down = previous & ffi.INPUT_HELD != 0;
    return inputStateBits(down, down and !was_down, !down and was_down);
}

fn raylibGamepadButtonDown(_: void, gamepad: c_int, button: c_int) bool {
    return rl.IsGamepadButtonDown(gamepad, button);
}

fn updateGamepadButtonStates(
    states: *[ffi.GAMEPAD_COUNT * ffi.GAMEPAD_BUTTON_COUNT]u8,
    gamepad: usize,
    available: bool,
    context: anytype,
    comptime is_button_down: anytype,
) void {
    const gamepad_id: c_int = @intCast(gamepad);

    for (0..ffi.GAMEPAD_BUTTON_COUNT) |button| {
        const flat_index = gamepadButtonIndex(gamepad, button);
        if (available) {
            states[flat_index] = nextInputState(
                states[flat_index],
                is_button_down(context, gamepad_id, @intCast(button)),
            );
        } else {
            states[flat_index] = disconnectedInputState(states[flat_index]);
        }
    }
}

test "input state packs held and edge flags" {
    try std.testing.expectEqual(@as(u8, 0), inputStateBits(false, false, false));
    try std.testing.expectEqual(@as(u8, 7), inputStateBits(true, true, true));
    try std.testing.expectEqual(ffi.INPUT_RELEASED, inputStateBits(false, false, true));
}

test "disconnecting a held input synthesizes one release edge" {
    try std.testing.expectEqual(ffi.INPUT_RELEASED, disconnectedInputState(ffi.INPUT_HELD));
    try std.testing.expectEqual(@as(u8, 0), disconnectedInputState(ffi.INPUT_RELEASED));
}

test "input state derives press and release edges from held transitions" {
    const up = nextInputState(0, false);
    try std.testing.expectEqual(@as(u8, 0), up);

    const pressed = nextInputState(up, true);
    try std.testing.expectEqual(ffi.INPUT_HELD | ffi.INPUT_PRESSED, pressed);

    const held = nextInputState(pressed, true);
    try std.testing.expectEqual(ffi.INPUT_HELD, held);

    const released = nextInputState(held, false);
    try std.testing.expectEqual(ffi.INPUT_RELEASED, released);
    try std.testing.expectEqual(@as(u8, 0), nextInputState(released, false));
}

test "gamepad buttons use one held query per connected button" {
    const Query = struct {
        count: usize = 0,
        down: [ffi.GAMEPAD_BUTTON_COUNT]bool = [_]bool{false} ** ffi.GAMEPAD_BUTTON_COUNT,

        fn isDown(self: *@This(), _: c_int, button: c_int) bool {
            self.count += 1;
            return self.down[@intCast(button)];
        }
    };

    var states = [_]u8{0} ** (ffi.GAMEPAD_COUNT * ffi.GAMEPAD_BUTTON_COUNT);
    var query = Query{};

    updateGamepadButtonStates(&states, 0, true, &query, Query.isDown);
    try std.testing.expectEqual(ffi.GAMEPAD_BUTTON_COUNT, query.count);

    updateGamepadButtonStates(&states, 0, false, &query, Query.isDown);
    try std.testing.expectEqual(ffi.GAMEPAD_BUTTON_COUNT, query.count);
}

test "gamepad button edges survive disconnect and reconnect" {
    const Query = struct {
        down: [ffi.GAMEPAD_BUTTON_COUNT]bool = [_]bool{false} ** ffi.GAMEPAD_BUTTON_COUNT,

        fn isDown(self: *@This(), _: c_int, button: c_int) bool {
            return self.down[@intCast(button)];
        }
    };

    const button = 3;
    const index = gamepadButtonIndex(0, button);
    var states = [_]u8{0} ** (ffi.GAMEPAD_COUNT * ffi.GAMEPAD_BUTTON_COUNT);
    var query = Query{};

    query.down[button] = true;
    updateGamepadButtonStates(&states, 0, true, &query, Query.isDown);
    try std.testing.expectEqual(ffi.INPUT_HELD | ffi.INPUT_PRESSED, states[index]);

    updateGamepadButtonStates(&states, 0, true, &query, Query.isDown);
    try std.testing.expectEqual(ffi.INPUT_HELD, states[index]);

    updateGamepadButtonStates(&states, 0, false, &query, Query.isDown);
    try std.testing.expectEqual(ffi.INPUT_RELEASED, states[index]);

    updateGamepadButtonStates(&states, 0, false, &query, Query.isDown);
    try std.testing.expectEqual(@as(u8, 0), states[index]);

    updateGamepadButtonStates(&states, 0, true, &query, Query.isDown);
    try std.testing.expectEqual(ffi.INPUT_HELD | ffi.INPUT_PRESSED, states[index]);
}

/// Update keyboard state from raylib (call once per frame)
pub fn updateKeyboardState() void {
    for (0..ffi.KEY_COUNT) |i| {
        const key: c_int = @intCast(i);
        key_state[i] = nextInputState(key_state[i], rl.IsKeyDown(key));
    }
}

/// Advance the packed keyboard state from caller-supplied held flags.
///
/// Used by the virtual keyboard in place of `updateKeyboardState`, and by a
/// headless run, which has no hardware to ask at all. It runs the same
/// `nextInputState` edge detection, so a scripted key produces real
/// pressed-this-frame and released-this-frame bits and an app's ordinary
/// key handling reacts to it exactly as it would to hardware.
pub fn updateKeyboardStateFrom(down: *const [ffi.KEY_COUNT]bool) void {
    for (0..ffi.KEY_COUNT) |i| {
        key_state[i] = nextInputState(key_state[i], down[i]);
    }
}

/// Forget every key's held and edge bits.
///
/// Called when an app lifetime starts, so a key held when one app exited is
/// not still held when the next one begins.
pub fn clearKeyState() void {
    key_state = [_]u8{0} ** ffi.KEY_COUNT;
}

/// Get the current packed keyboard state array.
pub fn getKeyState() *const [ffi.KEY_COUNT]u8 {
    return &key_state;
}

/// Update mouse button state from raylib (call once per frame)
pub fn updateMouseButtonState() void {
    for (0..ffi.MOUSE_BUTTON_COUNT) |i| {
        const button: c_int = @intCast(i);
        mouse_button_state[i] = nextInputState(mouse_button_state[i], rl.IsMouseButtonDown(button));
    }
}

/// Get the current packed mouse button state array.
pub fn getMouseButtonState() *const [ffi.MOUSE_BUTTON_COUNT]u8 {
    return &mouse_button_state;
}

/// Forget every mouse button's held and edge bits, as `clearKeyState` does.
pub fn clearMouseButtonState() void {
    mouse_button_state = [_]u8{0} ** ffi.MOUSE_BUTTON_COUNT;
}

/// Advance the packed mouse button state from caller-supplied down flags.
///
/// Used by the virtual mouse in place of `updateMouseButtonState`. It runs the
/// same `nextInputState` edge detection, so a scripted pointer produces real
/// pressed-this-frame and released-this-frame bits and an app's ordinary click
/// handling reacts to it exactly as it would to hardware.
pub fn updateMouseButtonStateFrom(down: *const [ffi.MOUSE_BUTTON_COUNT]bool) void {
    for (0..ffi.MOUSE_BUTTON_COUNT) |i| {
        mouse_button_state[i] = nextInputState(mouse_button_state[i], down[i]);
    }
}

/// Sample all supported gamepads once for this frame.
pub fn updateGamepadState() void {
    for (0..ffi.GAMEPAD_COUNT) |gamepad| {
        const gamepad_id: c_int = @intCast(gamepad);
        const available = rl.IsGamepadAvailable(gamepad_id);
        gamepad_available[gamepad] = if (available) 1 else 0;
        updateGamepadButtonStates(
            &gamepad_button_state,
            gamepad,
            available,
            {},
            raylibGamepadButtonDown,
        );

        const native_axis_count: usize = if (available)
            @intCast(@max(rl.GetGamepadAxisCount(gamepad_id), 0))
        else
            0;
        for (0..ffi.GAMEPAD_AXIS_COUNT) |axis| {
            const flat_index = gamepadAxisIndex(gamepad, axis);
            gamepad_axes[flat_index] = if (axis < native_axis_count)
                rl.GetGamepadAxisMovement(gamepad_id, @intCast(axis))
            else
                0;
        }
    }
}

/// Get the sampled gamepad availability array.
pub fn getGamepadAvailability() *const [ffi.GAMEPAD_COUNT]u8 {
    return &gamepad_available;
}

/// Get the sampled packed gamepad button-state array.
pub fn getGamepadButtonState() *const [ffi.GAMEPAD_COUNT * ffi.GAMEPAD_BUTTON_COUNT]u8 {
    return &gamepad_button_state;
}

/// Get the sampled gamepad axis array.
pub fn getGamepadAxes() *const [ffi.GAMEPAD_COUNT * ffi.GAMEPAD_AXIS_COUNT]f32 {
    return &gamepad_axes;
}

/// Drain this frame's queued Unicode input and return a stable scratch slice.
pub fn getTextInput() []const u32 {
    var count: usize = 0;
    while (true) {
        const codepoint = rl.GetCharPressed();
        if (codepoint <= 0) break;
        if (count < text_input.len) {
            text_input[count] = @intCast(codepoint);
            count += 1;
        }
    }
    return text_input[0..count];
}

/// Return raylib's built-in font, which is not owned by a resource heap.
pub fn defaultFont() Font {
    return rl.GetFontDefault();
}

/// Load a custom font directly from a filesystem path.
pub fn loadFont(path: [*:0]const u8, size: c_int) ?Font {
    const font = rl.LoadFontEx(path, @max(size, 1), null, 0);
    if (!rl.IsFontValid(font)) return null;
    rl.SetTextureFilter(font.texture, rl.TEXTURE_FILTER_BILINEAR);
    return font;
}

/// Unload a custom font when its host resource slot is released.
pub fn unloadFont(font: Font) void {
    rl.UnloadFont(font);
}

/// Return a font's base pixel size for `MeasureTextEx` scaling.
pub fn fontBaseSize(font: Font) f32 {
    return @floatFromInt(font.baseSize);
}

/// Return the number of glyphs available for scalar metric snapshotting.
pub fn fontGlyphCount(font: Font) usize {
    if (font.glyphCount <= 0 or font.glyphs == null or font.recs == null) return 0;
    return @intCast(font.glyphCount);
}

/// Read the same glyph advance used by raylib's `MeasureTextEx`.
pub fn fontGlyphMetric(font: Font, index: usize) FontGlyphMetric {
    const glyph = font.glyphs[index];
    const rec = font.recs[index];
    return .{
        .codepoint = if (glyph.value > 0) @intCast(glyph.value) else 0,
        .advance_x = @floatFromInt(glyph.advanceX),
        .offset_x = @floatFromInt(glyph.offsetX),
        .offset_y = @floatFromInt(glyph.offsetY),
        .width = rec.width,
        .height = rec.height,
    };
}

/// Unload a texture when its host resource slot is released.
pub fn unloadTexture(texture: Texture) void {
    rl.UnloadTexture(texture);
}

/// Generate a solid-color texture, releasing the temporary CPU image before return.
pub fn generateColorTexture(width: i32, height: i32, color: Color) ?Texture {
    if (width <= 0 or height <= 0) return null;
    const image = rl.GenImageColor(width, height, colorToRl(color));
    defer rl.UnloadImage(image);
    if (!rl.IsImageValid(image)) return null;

    const texture = rl.LoadTextureFromImage(image);
    if (!rl.IsTextureValid(texture)) return null;
    return texture;
}

/// Generate a checkerboard texture, releasing the temporary CPU image before return.
pub fn generateCheckedTexture(args: anytype) ?Texture {
    if (args.width <= 0 or args.height <= 0 or args.checks_x <= 0 or args.checks_y <= 0) return null;
    const image = rl.GenImageChecked(
        args.width,
        args.height,
        args.checks_x,
        args.checks_y,
        colorToRl(args.color_a),
        colorToRl(args.color_b),
    );
    defer rl.UnloadImage(image);
    if (!rl.IsImageValid(image)) return null;

    const texture = rl.LoadTextureFromImage(image);
    if (!rl.IsTextureValid(texture)) return null;
    return texture;
}

/// Replace all pixels in a texture from tightly packed RGBA colors.
pub fn updateTexture(texture: Texture, pixels: []const Color) void {
    comptime std.debug.assert(@sizeOf(Color) == @sizeOf(rl.Color));
    rl.UpdateTexture(texture, pixels.ptr);
}

/// One rectangle of a texture. `area` is in pixels and must lie inside it;
/// raylib does no bounds checking of its own, so the caller does.
pub fn updateTextureRegion(texture: Texture, area: struct { x: i32, y: i32, width: i32, height: i32 }, pixels: []const Color) void {
    comptime std.debug.assert(@sizeOf(Color) == @sizeOf(rl.Color));
    rl.UpdateTextureRec(texture, .{
        .x = @floatFromInt(area.x),
        .y = @floatFromInt(area.y),
        .width = @floatFromInt(area.width),
        .height = @floatFromInt(area.height),
    }, pixels.ptr);
}

/// Set a texture's scaling filter from the Roc enum code.
pub fn setTextureFilter(texture: Texture, code: u8) void {
    const filter: c_int = switch (code) {
        0 => rl.TEXTURE_FILTER_POINT,
        1 => rl.TEXTURE_FILTER_BILINEAR,
        2 => rl.TEXTURE_FILTER_TRILINEAR,
        3 => rl.TEXTURE_FILTER_ANISOTROPIC_4X,
        4 => rl.TEXTURE_FILTER_ANISOTROPIC_8X,
        5 => rl.TEXTURE_FILTER_ANISOTROPIC_16X,
        else => return,
    };
    rl.SetTextureFilter(texture, filter);
}

/// Set a texture's coordinate wrapping mode from the Roc enum code.
pub fn setTextureWrap(texture: Texture, code: u8) void {
    const wrap: c_int = switch (code) {
        0 => rl.TEXTURE_WRAP_REPEAT,
        1 => rl.TEXTURE_WRAP_CLAMP,
        2 => rl.TEXTURE_WRAP_MIRROR_REPEAT,
        3 => rl.TEXTURE_WRAP_MIRROR_CLAMP,
        else => return,
    };
    rl.SetTextureWrap(texture, wrap);
}

/// Create a framebuffer-backed texture for offscreen 2D rendering.
pub fn loadRenderTexture(width: c_int, height: c_int) ?RenderTexture {
    const target = rl.LoadRenderTexture(width, height);
    if (!rl.IsRenderTextureValid(target)) return null;
    return target;
}

/// Release a framebuffer and its color/depth attachments.
pub fn unloadRenderTexture(target: RenderTexture) void {
    rl.UnloadRenderTexture(target);
}

/// Return the color attachment so normal texture drawing can sample it.
pub fn renderTextureColor(target: RenderTexture) Texture {
    return target.texture;
}

/// Load shader source code, using raylib's default stage when a pointer is null.
pub fn loadShaderFromMemory(vertex_source: ?[*:0]const u8, fragment_source: ?[*:0]const u8) ?Shader {
    const shader = rl.LoadShaderFromMemory(vertex_source, fragment_source);
    if (!rl.IsShaderValid(shader)) return null;
    return shader;
}

/// Decode a font from caller-owned bytes. Raylib copies/decodes synchronously
/// and the returned Font does not retain `bytes`.
pub fn loadFontFromMemory(file_type: [*:0]const u8, bytes: []const u8, size: c_int) ?Font {
    if (bytes.len == 0 or bytes.len > std.math.maxInt(c_int) or size <= 0) return null;
    const font = rl.LoadFontFromMemory(file_type, bytes.ptr, @intCast(bytes.len), size, null, 0);
    if (!rl.IsFontValid(font)) return null;
    rl.SetTextureFilter(font.texture, rl.TEXTURE_FILTER_BILINEAR);
    return font;
}

/// Release a GPU shader program.
pub fn unloadShader(shader: Shader) void {
    rl.UnloadShader(shader);
}

/// Resolve and cache a uniform location on the Roc side.
pub fn shaderLocation(shader: Shader, name: [*:0]const u8) c_int {
    return rl.GetShaderLocation(shader, name);
}

/// Update scalar/vector shader values without allocating.
pub fn setShaderFloat(shader: Shader, location: c_int, value: f32) void {
    rl.SetShaderValue(shader, location, &value, rl.SHADER_UNIFORM_FLOAT);
}

/// Update a signed integer uniform.
pub fn setShaderInt(shader: Shader, location: c_int, value: i32) void {
    rl.SetShaderValue(shader, location, &value, rl.SHADER_UNIFORM_INT);
}

/// Update a two-component float vector uniform.
pub fn setShaderVec2(shader: Shader, location: c_int, value: [2]f32) void {
    rl.SetShaderValue(shader, location, &value, rl.SHADER_UNIFORM_VEC2);
}

/// Update a three-component float vector uniform.
pub fn setShaderVec3(shader: Shader, location: c_int, value: [3]f32) void {
    rl.SetShaderValue(shader, location, &value, rl.SHADER_UNIFORM_VEC3);
}

/// Update a four-component float vector uniform.
pub fn setShaderVec4(shader: Shader, location: c_int, value: [4]f32) void {
    rl.SetShaderValue(shader, location, &value, rl.SHADER_UNIFORM_VEC4);
}

/// Bind a texture to a sampler2D uniform.
pub fn setShaderTexture(shader: Shader, location: c_int, texture: Texture) void {
    rl.SetShaderValueTexture(shader, location, texture);
}

/// Return a native texture's width in pixels.
pub fn textureWidth(texture: Texture) f32 {
    return @floatFromInt(texture.width);
}

/// Return a native texture's height in pixels.
pub fn textureHeight(texture: Texture) f32 {
    return @floatFromInt(texture.height);
}

/// Convert an ABI RGBA color record to raylib Color.
pub fn colorToRl(color: anytype) rl.Color {
    return .{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = color.a,
    };
}

test "colorToRl preserves Roc RGBA channel order" {
    const black = colorToRl(Color{
        .r = 0,
        .g = 0,
        .b = 0,
        .a = 255,
    });
    try std.testing.expectEqual(@as(u8, 0), black.r);
    try std.testing.expectEqual(@as(u8, 0), black.g);
    try std.testing.expectEqual(@as(u8, 0), black.b);
    try std.testing.expectEqual(@as(u8, 255), black.a);

    const red = colorToRl(Color{
        .r = 230,
        .g = 41,
        .b = 55,
        .a = 255,
    });
    try std.testing.expectEqual(@as(u8, 230), red.r);
    try std.testing.expectEqual(@as(u8, 41), red.g);
    try std.testing.expectEqual(@as(u8, 55), red.b);
    try std.testing.expectEqual(@as(u8, 255), red.a);
}

fn toVector2(point: anytype) rl.Vector2 {
    return .{ .x = point.x, .y = point.y };
}

fn rectFromArgs(args: anytype) rl.Rectangle {
    return .{ .x = args.x, .y = args.y, .width = args.width, .height = args.height };
}

fn cameraFromArgs(args: anytype) rl.Camera2D {
    return .{
        .target = toVector2(args.target),
        .offset = toVector2(args.offset),
        .rotation = args.rotation,
        .zoom = args.zoom,
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

fn drawSegment(start: anytype, end: anytype, thickness: f32, color: Color) void {
    const thick = positiveThickness(thickness) orelse return;
    rl.DrawLineEx(toVector2(start), toVector2(end), thick, colorToRl(color));
}

/// Draw a circle from abi args.
pub fn drawCircle(args: anytype) void {
    rl.DrawCircle(
        @intFromFloat(args.center.x),
        @intFromFloat(args.center.y),
        args.radius,
        colorToRl(args.color),
    );
}

/// Draw a thick circle outline from abi args.
pub fn drawCircleLines(args: anytype) void {
    const thick = positiveThickness(args.thickness) orelse return;
    const half = thick * 0.5;
    const inner_radius = @max(0, args.radius - half);
    const outer_radius = args.radius + half;

    rl.DrawRing(
        toVector2(args.center),
        inner_radius,
        outer_radius,
        0,
        360,
        64,
        colorToRl(args.color),
    );
}

/// Draw a rectangle from abi args.
pub fn drawRectangle(args: anytype) void {
    rl.DrawRectangle(
        @intFromFloat(args.x),
        @intFromFloat(args.y),
        @intFromFloat(args.width),
        @intFromFloat(args.height),
        colorToRl(args.color),
    );
}

/// Draw a rectangle outline from abi args.
pub fn drawRectangleLines(args: anytype) void {
    const thick = positiveThickness(args.thickness) orelse return;
    rl.DrawRectangleLinesEx(rectFromArgs(args), thick, colorToRl(args.color));
}

/// Draw a rounded rectangle from abi args.
pub fn drawRoundedRectangle(args: anytype) void {
    rl.DrawRectangleRounded(
        rectFromArgs(args),
        roundedness(args.width, args.height, args.radius),
        positiveSegments(args.segments),
        colorToRl(args.color),
    );
}

/// Draw a rounded rectangle outline from abi args.
pub fn drawRoundedRectangleLines(args: anytype) void {
    const thick = positiveThickness(args.thickness) orelse return;
    rl.DrawRectangleRoundedLinesEx(
        rectFromArgs(args),
        roundedness(args.width, args.height, args.radius),
        positiveSegments(args.segments),
        thick,
        colorToRl(args.color),
    );
}

/// Draw a line from abi args.
pub fn drawLine(args: anytype) void {
    drawSegment(args.start, args.end, args.thickness, args.color);
}

/// Draw a triangle from abi args.
pub fn drawTriangle(args: anytype) void {
    rl.DrawTriangle(toVector2(args.a), toVector2(args.b), toVector2(args.c), colorToRl(args.color));
}

/// Draw a triangle outline from abi args.
pub fn drawTriangleLines(args: anytype) void {
    drawSegment(args.a, args.b, args.thickness, args.color);
    drawSegment(args.b, args.c, args.thickness, args.color);
    drawSegment(args.c, args.a, args.thickness, args.color);
}

fn polygonSignedArea(points: anytype) f32 {
    var twice_area: f32 = 0;
    for (points, 0..) |point, i| {
        const next = points[(i + 1) % points.len];
        twice_area += point.x * next.y - next.x * point.y;
    }
    return twice_area * 0.5;
}

test "polygonSignedArea detects either boundary order" {
    const Point = struct { x: f32, y: f32 };
    const clockwise = [_]Point{
        .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 0 },
    };
    const counter_clockwise = [_]Point{
        .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 2 }, .{ .x = 0, .y = 2 },
    };
    try std.testing.expect(polygonSignedArea(&clockwise) < 0);
    try std.testing.expect(polygonSignedArea(&counter_clockwise) > 0);
}

/// Draw a filled convex polygon as an allocation-free triangle fan.
/// Points must be ordered clockwise or counter-clockwise around the boundary.
pub fn drawPolygon(points: anytype, color: Color) void {
    if (points.len < 3) return;

    const reverse = polygonSignedArea(points) > 0;
    var i: usize = 1;
    while (i + 1 < points.len) : (i += 1) {
        if (reverse) {
            rl.DrawTriangle(toVector2(points[0]), toVector2(points[i + 1]), toVector2(points[i]), colorToRl(color));
        } else {
            rl.DrawTriangle(toVector2(points[0]), toVector2(points[i]), toVector2(points[i + 1]), colorToRl(color));
        }
    }
}

/// Draw a polygon outline from abi args.
pub fn drawPolygonLines(points: anytype, thickness: f32, color: Color) void {
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
pub fn drawTextZ(text: [*:0]const u8, font: Font, pos: rl.Vector2, size: f32, spacing: f32, color: Color) void {
    rl.DrawTextEx(font, text, pos, size, spacing, colorToRl(color));
}

/// Draw text anchored at a fractional point within its measured bounds.
/// Top-left alignment ({ 0, 0 }) skips measurement entirely.
pub fn drawTextAlignedZ(text: [*:0]const u8, font: Font, pos: rl.Vector2, size: f32, spacing: f32, color: Color, alignment: rl.Vector2) void {
    const origin = if (alignment.x == 0 and alignment.y == 0) pos else blk: {
        const measured = rl.MeasureTextEx(font, text, size, spacing);
        break :blk textOrigin(pos, measured, alignment);
    };
    rl.DrawTextEx(font, text, origin, size, spacing, colorToRl(color));
}

/// Resolve an anchor position to the top-left drawing origin for measured text.
pub fn textOrigin(pos: rl.Vector2, measured: rl.Vector2, alignment: rl.Vector2) rl.Vector2 {
    return .{
        .x = pos.x - measured.x * alignment.x,
        .y = pos.y - measured.y * alignment.y,
    };
}

test "textOrigin applies fractional alignment" {
    const pos = rl.Vector2{ .x = 100, .y = 80 };
    const measured = rl.Vector2{ .x = 40, .y = 20 };
    try std.testing.expectEqual(rl.Vector2{ .x = 100, .y = 80 }, textOrigin(pos, measured, .{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(rl.Vector2{ .x = 80, .y = 70 }, textOrigin(pos, measured, .{ .x = 0.5, .y = 0.5 }));
    try std.testing.expectEqual(rl.Vector2{ .x = 60, .y = 60 }, textOrigin(pos, measured, .{ .x = 1, .y = 1 }));
}

/// Draw a texture region into a destination rectangle.
pub fn drawTexture(texture: Texture, args: anytype) void {
    rl.DrawTexturePro(
        texture,
        rectFromArgs(args.source),
        rectFromArgs(args.dest),
        toVector2(args.origin),
        args.rotation,
        colorToRl(args.tint),
    );
}

/// Draw one texture once per borrowed instance, in list order.
///
/// The batching this buys is on the Roc side, not the GPU side: a per-sprite
/// `texture!` pays one hosted-effect crossing per sprite, and that crossing --
/// not `DrawTexturePro` -- is what caps instance counts. `DrawTexturePro` only
/// appends vertices to rlgl's active batch, which is flushed in bulk, so a
/// plain loop over the whole list already amortizes well.
///
/// The loop is deliberately shaped as "take the shared value once, take a
/// borrowed slice of per-instance fields, iterate": a future shape-instance
/// batch (rectangles, circles, or lines for plotting) can follow it by
/// swapping the shared texture for a shared style and the element accessor
/// for its own, with no other structure to reproduce.
pub fn drawTextureInstances(texture: Texture, instances: anytype) void {
    for (instances) |instance| drawTexture(texture, instance);
}

fn textureRegionUv(texture: Texture, x: f32, y: f32) rl.Vector2 {
    return .{
        .x = x / @as(f32, @floatFromInt(texture.width)),
        .y = y / @as(f32, @floatFromInt(texture.height)),
    };
}

test "textureRegionUv normalizes source pixels" {
    const texture = Texture{ .id = 1, .width = 64, .height = 32, .mipmaps = 1, .format = 1 };
    const uv = textureRegionUv(texture, 16, 24);
    try std.testing.expectEqual(@as(f32, 0.25), uv.x);
    try std.testing.expectEqual(@as(f32, 0.75), uv.y);
}

fn projectiveModelview(modelview: rl.Matrix) rl.Matrix {
    return .{
        .m0 = modelview.m0,
        .m1 = modelview.m1,
        .m2 = modelview.m2,
        .m3 = modelview.m3,
        .m4 = modelview.m4,
        .m5 = modelview.m5,
        .m6 = modelview.m6,
        .m7 = modelview.m7,
        .m8 = modelview.m12,
        .m9 = modelview.m13,
        .m10 = modelview.m14,
        .m11 = modelview.m15,
        .m12 = 0,
        .m13 = 0,
        .m14 = 0,
        .m15 = 0,
    };
}

fn textureQuadIsProjective(weights: [4]f32) bool {
    return weights[0] != weights[1] or weights[0] != weights[2] or weights[0] != weights[3];
}

test "projective modelview scales the complete transformed position by q" {
    const modelview = rl.Matrix{
        .m0 = 2,
        .m1 = 0,
        .m2 = 0,
        .m3 = 0,
        .m4 = 0,
        .m5 = 3,
        .m6 = 0,
        .m7 = 0,
        .m8 = 0,
        .m9 = 0,
        .m10 = 1,
        .m11 = 0,
        .m12 = 5,
        .m13 = -7,
        .m14 = 0,
        .m15 = 1,
    };
    const projective = projectiveModelview(modelview);
    const x: f32 = 11;
    const y: f32 = 13;
    const q: f32 = 0.4;

    const transformed_x = projective.m0 * (x * q) + projective.m4 * (y * q) + projective.m8 * q + projective.m12;
    const transformed_y = projective.m1 * (x * q) + projective.m5 * (y * q) + projective.m9 * q + projective.m13;
    const transformed_w = projective.m3 * (x * q) + projective.m7 * (y * q) + projective.m11 * q + projective.m15;

    try std.testing.expectApproxEqAbs(q * (2 * x + 5), transformed_x, 0.0001);
    try std.testing.expectApproxEqAbs(q * (3 * y - 7), transformed_y, 0.0001);
    try std.testing.expectApproxEqAbs(q, transformed_w, 0.0001);
}

test "equal quad weights retain the batched affine fast path" {
    try std.testing.expect(!textureQuadIsProjective(.{ 1, 1, 1, 1 }));
    try std.testing.expect(textureQuadIsProjective(.{ 1, 0.75, 0.5, 0.8 }));
}

/// Draw a texture source region across a validated planar projection.
pub fn drawTextureQuad(texture: Texture, args: anytype) void {
    const tint = colorToRl(args.tint);
    if (texture.width <= 0 or texture.height <= 0) return;
    const uv_top_left = textureRegionUv(texture, args.source.x, args.source.y);
    const uv_bottom_left = textureRegionUv(texture, args.source.x, args.source.y + args.source.height);
    const uv_bottom_right = textureRegionUv(texture, args.source.x + args.source.width, args.source.y + args.source.height);
    const uv_top_right = textureRegionUv(texture, args.source.x + args.source.width, args.source.y);

    const uvs = [_]rl.Vector2{ uv_top_left, uv_bottom_left, uv_bottom_right, uv_top_right };
    const vertices = [_]rl.Vector2{
        toVector2(args.top_left),
        toVector2(args.bottom_left),
        toVector2(args.bottom_right),
        toVector2(args.top_right),
    };
    const weights = [_]f32{
        args.q_top_left,
        args.q_bottom_left,
        args.q_bottom_right,
        args.q_top_right,
    };
    // Horizontal/vertical Tiled flips can reverse the destination winding.
    // Reverse vertex/UV pairs together so raylib's back-face culling still
    // accepts the quad without changing global rlgl state for every tile.
    const cross = (vertices[1].x - vertices[0].x) * (vertices[2].y - vertices[0].y) -
        (vertices[1].y - vertices[0].y) * (vertices[2].x - vertices[0].x);
    const order = if (cross > 0)
        [_]usize{ 3, 2, 1, 0 }
    else
        [_]usize{ 0, 1, 2, 3 };

    const projective = textureQuadIsProjective(weights);
    const saved_modelview = if (projective) rl.rlGetMatrixModelview() else undefined;
    if (projective) {
        // Earlier batched vertices must use the matrix active when they were
        // submitted. Flush this quad before restoring that matrix as well.
        rl.rlDrawRenderBatchActive();
        rl.rlSetMatrixModelview(projectiveModelview(saved_modelview));
    }

    rl.rlSetTexture(texture.id);
    rl.rlBegin(rl.RL_QUADS);
    rl.rlColor4ub(tint.r, tint.g, tint.b, tint.a);
    for (order) |i| {
        rl.rlTexCoord2f(uvs[i].x, uvs[i].y);
        if (projective) {
            const q = weights[i];
            rl.rlVertex3f(vertices[i].x * q, vertices[i].y * q, q);
        } else {
            rl.rlVertex2f(vertices[i].x, vertices[i].y);
        }
    }
    rl.rlEnd();
    if (projective) {
        rl.rlDrawRenderBatchActive();
        rl.rlSetMatrixModelview(saved_modelview);
    } else {
        rl.rlSetTexture(0);
    }
}

/// Measure text with a null-terminated string.
pub fn measureTextZ(text: [*:0]const u8, font: Font, size: f32, spacing: f32) rl.Vector2 {
    return rl.MeasureTextEx(font, text, size, spacing);
}

/// Draw a rectangle with vertical gradient from abi args.
pub fn drawRectangleGradientV(args: anytype) void {
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
pub fn drawRectangleGradientH(args: anytype) void {
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
pub fn drawCircleGradient(args: anytype) void {
    rl.DrawCircleGradient(
        toVector2(args.center),
        args.radius,
        colorToRl(args.color_inner),
        colorToRl(args.color_outer),
    );
}

/// Draw FPS counter at specified position.
pub fn drawFps(args: anytype) void {
    var buf: [32:0]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "FPS: {d}", .{rl.GetFPS()}) catch return;
    rl.DrawTextEx(defaultFont(), text.ptr, toVector2(args.pos), args.size, 1, colorToRl(args.color));
}

/// Begin drawing frame.
pub fn beginDrawing() void {
    rl.BeginDrawing();
}

/// Begin clipping subsequent draw calls to screen-space bounds.
pub fn beginScissor(x: f32, y: f32, width: f32, height: f32) void {
    rl.BeginScissorMode(
        @intFromFloat(x),
        @intFromFloat(y),
        @intFromFloat(width),
        @intFromFloat(height),
    );
}

/// End the active screen-space clipping region.
pub fn endScissor() void {
    rl.EndScissorMode();
}

/// Begin drawing in 2D camera mode.
pub fn beginMode2D(camera: anytype) void {
    rl.BeginMode2D(cameraFromArgs(camera));
}

/// End drawing in 2D camera mode.
pub fn endMode2D() void {
    rl.EndMode2D();
}

/// Redirect subsequent draws to an offscreen framebuffer.
pub fn beginTextureMode(target: RenderTexture) void {
    rl.BeginTextureMode(target);
}

/// Restore drawing to the previous framebuffer.
pub fn endTextureMode() void {
    rl.EndTextureMode();
}

/// Apply a custom shader to subsequent draw calls.
pub fn beginShaderMode(shader: Shader) void {
    rl.BeginShaderMode(shader);
}

/// Restore raylib's default shader.
pub fn endShaderMode() void {
    rl.EndShaderMode();
}

/// Apply one of raylib's built-in blend equations.
pub fn beginBlendMode(mode: c_int) void {
    rl.BeginBlendMode(mode);
}

/// Restore normal alpha blending.
pub fn endBlendMode() void {
    rl.EndBlendMode();
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
pub fn windowConfigFlags(resizable: bool, fullscreen: bool, vsync: bool, visible: bool) c_uint {
    var flags: c_uint = @as(c_uint, @intCast(rl.FLAG_WINDOW_HIGHDPI));
    if (resizable) flags |= @as(c_uint, @intCast(rl.FLAG_WINDOW_RESIZABLE));
    if (fullscreen) flags |= @as(c_uint, @intCast(rl.FLAG_FULLSCREEN_MODE));
    if (vsync) flags |= @as(c_uint, @intCast(rl.FLAG_VSYNC_HINT));
    // A hidden window still renders on the GPU, so captures work normally.
    // This is not the same as the `--host-headless` stub backend, which draws
    // nothing at all, and it still needs a display server (use xvfb-run on a
    // machine without one).
    if (!visible) flags |= @as(c_uint, @intCast(rl.FLAG_WINDOW_HIDDEN));
    return flags;
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

/// Mouse cursor shapes exposed by raylib.
pub const MouseCursor = enum(c_int) {
    default = 0,
    arrow = 1,
    ibeam = 2,
    crosshair = 3,
    pointing_hand = 4,
    resize_ew = 5,
    resize_ns = 6,
    resize_nwse = 7,
    resize_nesw = 8,
    resize_all = 9,
    not_allowed = 10,
};

/// Set the OS cursor shape.
pub fn setMouseCursor(cursor: MouseCursor) void {
    rl.SetMouseCursor(@intFromEnum(cursor));
}

/// Show the OS cursor.
pub fn showCursor() void {
    rl.ShowCursor();
}

/// Hide the OS cursor.
pub fn hideCursor() void {
    rl.HideCursor();
}

/// Lock and hide the OS cursor.
pub fn disableCursor() void {
    rl.DisableCursor();
}

/// Unlock the OS cursor and make it visible.
pub fn enableCursor() void {
    rl.EnableCursor();
}

/// Suggest a window size to the native window manager.
///
/// The dimensions observed from the window afterward are authoritative.
pub fn suggestWindowSize(width: c_int, height: c_int) void {
    rl.SetWindowSize(width, height);
}

/// Suggest the smallest size to which the window manager should resize.
/// raylib maps 0 to GLFW_DONT_CARE, leaving that axis unconstrained. Requires
/// a live window, and only binds where a resizable-window backend honors it.
pub fn suggestWindowMinSize(width: c_int, height: c_int) void {
    rl.SetWindowMinSize(width, height);
}

/// Set the key that closes the window, or raylib's KEY_NULL (0) to disable it.
/// InitWindow resets this to KEY_ESCAPE, so this must be called after it.
pub fn setExitKey(key: c_int) void {
    rl.SetExitKey(key);
}

/// Read UTF-8 text from the system clipboard.
///
/// The returned pointer is owned by the windowing backend: never free it, and
/// copy it before the next clipboard call invalidates it. Returns null when the
/// clipboard is empty or holds non-text content. Requires a live window.
pub fn getClipboardText() ?[*:0]const u8 {
    const text = rl.GetClipboardText();
    if (text == null) return null;
    return @ptrCast(text);
}

/// Replace the system clipboard contents. raylib copies the string, so the
/// caller keeps ownership. Requires a live window.
pub fn setClipboardText(text: [*:0]const u8) void {
    rl.SetClipboardText(text);
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

const AUDIO_SAMPLE_RATE: u32 = 44100;
const MAX_GEN_SOUND_MS: i32 = 5000;
/// Scratch buffer for procedural generation (mono 16-bit).
var gen_sound_buf: [AUDIO_SAMPLE_RATE * @as(usize, @intCast(MAX_GEN_SOUND_MS)) / 1000]i16 = undefined;

/// Initialize the audio device (call once, after the window exists).
pub fn initAudioDevice() void {
    rl.InitAudioDevice();
}

/// Close the audio device after all host resource heaps have been drained.
pub fn closeAudioDevice() void {
    rl.CloseAudioDevice();
}

/// Unload a native sound when its host resource slot is released.
pub fn unloadSound(sound: Sound) void {
    rl.UnloadSound(sound);
}

/// Unload a native music stream when its host resource slot is released.
pub fn unloadMusic(music: Music) void {
    rl.UnloadMusicStream(music);
}

fn clampF32(value: f32, min: f32, max: f32) f32 {
    return if (value < min) min else if (value > max) max else value;
}

fn clampI32(value: i32, min: i32, max: i32) i32 {
    return if (value < min) min else if (value > max) max else value;
}

fn msToFrames(ms: i32) usize {
    const clamped = if (ms <= 0) 0 else ms;
    return @intCast(@divTrunc(@as(i64, AUDIO_SAMPLE_RATE) * clamped, 1000));
}

fn envelopeAt(frame: usize, frames: usize, attack: usize, decay: usize, sustain_in: f32, release: usize) f32 {
    if (frames == 0) return 0;

    const sustain = clampF32(sustain_in, 0.0, 1.0);
    const frame_f: f32 = @floatFromInt(frame);

    if (attack > 0 and frame < attack) {
        return frame_f / @as(f32, @floatFromInt(attack));
    }

    if (decay > 0 and frame < attack + decay) {
        const amount = (frame_f - @as(f32, @floatFromInt(attack))) / @as(f32, @floatFromInt(decay));
        return 1.0 + (sustain - 1.0) * clampF32(amount, 0.0, 1.0);
    }

    if (release > 0) {
        const release_start = if (release >= frames) 0 else frames - release;
        if (frame >= release_start) {
            const tail = frames - frame;
            return sustain * (@as(f32, @floatFromInt(tail)) / @as(f32, @floatFromInt(release)));
        }
    }

    return sustain;
}

fn waveformSample(waveform: u8, phase: f32, random_state: *u32) f32 {
    return switch (waveform) {
        1 => if (phase < 0.5) 1.0 else -1.0,
        2 => 1.0 - 4.0 * absF32(phase - 0.5),
        3 => phase * 2.0 - 1.0,
        4 => blk: {
            random_state.* = random_state.* *% 1664525 +% 1013904223;
            const raw: f32 = @floatFromInt(random_state.* >> 8);
            break :blk raw / 16777215.0 * 2.0 - 1.0;
        },
        else => std.math.sin(2.0 * std.math.pi * phase),
    };
}

/// Load a sound effect from disk.
pub fn loadSound(path: [*:0]const u8) ?Sound {
    const sound = rl.LoadSound(path);
    if (!rl.IsSoundValid(sound)) return null;
    return sound;
}

/// Generate a short procedural sound.
pub fn genSound(args: anytype) ?Sound {
    const dur_ms = clampI32(args.ms, 1, MAX_GEN_SOUND_MS);
    const frames = msToFrames(dur_ms);
    if (frames == 0 or frames > gen_sound_buf.len) return null;

    const attack = msToFrames(args.attack_ms);
    const decay = msToFrames(args.decay_ms);
    const release = msToFrames(args.release_ms);
    const volume = clampF32(args.volume, 0.0, 1.0);

    var phase: f32 = 0.0;
    var random_state: u32 = 0x9e3779b9 ^ @as(u32, @bitCast(args.freq_start));
    const sample_rate: f32 = @floatFromInt(AUDIO_SAMPLE_RATE);
    const frames_f: f32 = @floatFromInt(frames);

    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const amount = @as(f32, @floatFromInt(i)) / frames_f;
        const freq = @max(1.0, args.freq_start + (args.freq_end - args.freq_start) * amount);
        phase += freq / sample_rate;
        phase -= @floor(phase);

        const env = envelopeAt(i, frames, attack, decay, args.sustain, release);
        const sample = waveformSample(args.waveform, phase, &random_state) * env * volume;
        gen_sound_buf[i] = @intFromFloat(clampF32(sample, -1.0, 1.0) * 32767.0);
    }

    const wave = rl.Wave{
        .frameCount = @intCast(frames),
        .sampleRate = AUDIO_SAMPLE_RATE,
        .sampleSize = 16,
        .channels = 1,
        .data = @ptrCast(&gen_sound_buf),
    };

    const sound = rl.LoadSoundFromWave(wave);
    if (!rl.IsSoundValid(sound)) return null;
    return sound;
}

/// Generate a short sine tone.
pub fn genTone(freq: f32, ms: i32) ?Sound {
    return genSound(.{
        .waveform = @as(u8, 0),
        .freq_start = freq,
        .freq_end = freq,
        .ms = ms,
        .attack_ms = 5,
        .decay_ms = 12,
        .sustain = 0.8,
        .release_ms = 8,
        .volume = 0.55,
    });
}

/// Play a native sound.
pub fn playSound(sound: Sound) void {
    rl.PlaySound(sound);
}

/// Stop a native sound and rewind it.
pub fn stopSound(sound: Sound) void {
    rl.StopSound(sound);
}

/// Pause a native sound.
pub fn pauseSound(sound: Sound) void {
    rl.PauseSound(sound);
}

/// Resume a paused native sound.
pub fn resumeSound(sound: Sound) void {
    rl.ResumeSound(sound);
}

/// Check whether a native sound is currently playing.
pub fn isSoundPlaying(sound: Sound) bool {
    return rl.IsSoundPlaying(sound);
}

/// Set a native sound's volume.
pub fn setSoundVolume(sound: Sound, volume: f32) void {
    rl.SetSoundVolume(sound, clampF32(volume, 0.0, 1.0));
}

/// Set a native sound's pitch.
pub fn setSoundPitch(sound: Sound, pitch: f32) void {
    rl.SetSoundPitch(sound, clampF32(pitch, 0.05, 8.0));
}

/// Set a native sound's stereo pan.
pub fn setSoundPan(sound: Sound, pan: f32) void {
    rl.SetSoundPan(sound, clampF32(pan, -1.0, 1.0));
}

/// Load a music stream from disk.
pub fn loadMusic(path: [*:0]const u8) ?Music {
    var stream = rl.LoadMusicStream(path);
    if (!rl.IsMusicValid(stream)) return null;
    stream.looping = true;
    return stream;
}

/// Advance one native music stream.
pub fn updateMusicStream(stream: *Music) void {
    rl.UpdateMusicStream(stream.*);
}

/// Start a native music stream.
pub fn playMusic(stream: Music) void {
    rl.PlayMusicStream(stream);
}

/// Stop a native music stream.
pub fn stopMusic(stream: Music) void {
    rl.StopMusicStream(stream);
}

/// Pause a native music stream.
pub fn pauseMusic(stream: Music) void {
    rl.PauseMusicStream(stream);
}

/// Resume a native music stream.
pub fn resumeMusic(stream: Music) void {
    rl.ResumeMusicStream(stream);
}

/// Set a native music stream's volume.
pub fn setMusicVolume(stream: Music, volume: f32) void {
    rl.SetMusicVolume(stream, clampF32(volume, 0.0, 1.0));
}

/// Set a native music stream's pitch.
pub fn setMusicPitch(stream: Music, pitch: f32) void {
    rl.SetMusicPitch(stream, clampF32(pitch, 0.05, 8.0));
}

/// Set a native music stream's stereo pan.
pub fn setMusicPan(stream: Music, pan: f32) void {
    rl.SetMusicPan(stream, clampF32(pan, -1.0, 1.0));
}

/// Enable or disable looping on a native music stream.
pub fn setMusicLooping(stream: *Music, looping: bool) void {
    stream.looping = looping;
}

/// Check whether a native music stream is currently playing.
pub fn isMusicPlaying(stream: Music) bool {
    return rl.IsMusicStreamPlaying(stream);
}

/// Seek a native music stream to a position in seconds.
pub fn seekMusic(stream: Music, seconds: f32) void {
    rl.SeekMusicStream(stream, @max(0, seconds));
}

/// Return a native music stream's duration in seconds.
pub fn musicLength(stream: Music) f32 {
    return rl.GetMusicTimeLength(stream);
}

/// Return a native music stream's current playback position in seconds.
pub fn musicTimePlayed(stream: Music) f32 {
    return rl.GetMusicTimePlayed(stream);
}

/// Set global audio output volume.
pub fn setMasterVolume(volume: f32) void {
    rl.SetMasterVolume(clampF32(volume, 0, 1));
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

/// Get mouse movement since the previous frame.
pub fn getMouseDelta() Vec2 {
    const delta = rl.GetMouseDelta();
    return .{ .x = delta.x, .y = delta.y };
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

/// Get horizontal and vertical mouse wheel movement.
pub fn getMouseWheelMoveV() Vec2 {
    const movement = rl.GetMouseWheelMoveV();
    return .{ .x = movement.x, .y = movement.y };
}

/// Get screen width.
pub fn getScreenWidth() c_int {
    return rl.GetScreenWidth();
}

/// Get screen height.
pub fn getScreenHeight() c_int {
    return rl.GetScreenHeight();
}

/// Whether the window currently has keyboard input focus.
pub fn isWindowFocused() bool {
    return rl.IsWindowFocused();
}

/// Whether the window is currently minimized.
pub fn isWindowMinimized() bool {
    return rl.IsWindowMinimized();
}

/// Get framebuffer width in pixels, which exceeds the screen width on HiDPI.
pub fn getRenderWidth() c_int {
    return rl.GetRenderWidth();
}

/// Get framebuffer height in pixels, which exceeds the screen height on HiDPI.
pub fn getRenderHeight() c_int {
    return rl.GetRenderHeight();
}

/// A CPU-side RGBA8 readback of the framebuffer, owned by raylib's allocator.
///
/// Every raylib allocation for a capture stays behind this type so the rest of
/// the host never has to reason about `UnloadImage` pairing.
pub const CaptureImage = struct {
    image: rl.Image,

    /// Tightly packed top-down RGBA8 pixels, four bytes each.
    pub fn pixels(self: CaptureImage) []u8 {
        const count = @as(usize, @intCast(self.image.width)) *
            @as(usize, @intCast(self.image.height)) * 4;
        const bytes: [*]u8 = @ptrCast(self.image.data);
        return bytes[0..count];
    }

    /// Width in pixels.
    pub fn width(self: CaptureImage) u32 {
        return @intCast(self.image.width);
    }

    /// Height in pixels.
    pub fn height(self: CaptureImage) u32 {
        return @intCast(self.image.height);
    }

    /// Rescale in place with bicubic filtering, reallocating the pixel buffer.
    pub fn resize(self: *CaptureImage, new_width: u32, new_height: u32) void {
        if (new_width == self.width() and new_height == self.height()) return;
        rl.ImageResize(&self.image, @intCast(new_width), @intCast(new_height));
    }

    /// Write this image as a PNG, returning false if the write failed.
    pub fn exportPng(self: CaptureImage, path: [*:0]const u8) bool {
        return rl.ExportImage(self.image, path);
    }

    /// Release the pixel buffer.
    pub fn deinit(self: CaptureImage) void {
        rl.UnloadImage(self.image);
    }
};

/// `GL_COLOR_BUFFER_BIT`, the only attachment a capture blit has to move.
///
/// `rlgl.h` exposes `RL_READ_FRAMEBUFFER` and `RL_DRAW_FRAMEBUFFER` but not the
/// blit masks, and the GL headers are raylib's own -- so the value is spelled
/// out here rather than reached for through a second OpenGL dependency.
const gl_color_buffer_bit: c_int = 0x00004000;

/// A reusable GPU pipeline that shrinks the framebuffer before it is read back.
///
/// `glReadPixels` cannot scale, so a `Half` or `Quarter` recording that reads
/// the framebuffer and resizes afterwards transfers, allocates, and filters 4x
/// or 16x more pixels than it keeps. This does the shrink on the GPU so the
/// readback is already the size of the finished frame, and reuses its render
/// targets for the whole recording instead of allocating per frame.
///
/// The frame is first blitted 1:1 into a render target, because the default
/// framebuffer is not a texture and cannot be sampled. raylib's blit is
/// hardcoded to `GL_NEAREST`, which at 1:1 is exact; the filtering all happens
/// in the halving steps that follow, where bilinear sampling averages 2x2
/// blocks. See `capture.planDownscale` for why the chain halves.
pub const CaptureDownscaler = struct {
    /// Render targets matching `capture.DownscalePlan.levels`, so `targets[0]`
    /// is framebuffer-sized and the last is the recording size.
    targets: [capture.max_downscale_levels]RenderTexture,
    count: usize,

    /// Build the render-target chain, or null if the GPU refused any of them.
    ///
    /// A partially built chain is torn down rather than returned, so a refusal
    /// never leaks the targets that did load.
    pub fn init(plan: capture.DownscalePlan) ?CaptureDownscaler {
        var self = CaptureDownscaler{
            .targets = undefined,
            .count = 0,
        };

        while (self.count < plan.count) {
            const extent = plan.levels[self.count];
            const target = rl.LoadRenderTexture(
                @intCast(extent.width),
                @intCast(extent.height),
            );
            if (!rl.IsRenderTextureValid(target)) {
                rl.UnloadRenderTexture(target);
                self.deinit();
                return null;
            }
            // Bilinear is what makes a halving step a 2x2 average instead of a
            // point sample, and clamping keeps the edge taps from wrapping
            // around to the opposite side of the frame.
            rl.SetTextureFilter(target.texture, rl.TEXTURE_FILTER_BILINEAR);
            rl.SetTextureWrap(target.texture, rl.TEXTURE_WRAP_CLAMP);
            self.targets[self.count] = target;
            self.count += 1;
        }
        return self;
    }

    /// Does this chain already produce exactly what `plan` asks for?
    ///
    /// Sizes are compared level by level rather than only end to end, so a
    /// window resize or a second recording at a different scale rebuilds
    /// instead of quietly encoding frames of the wrong dimensions.
    pub fn matches(self: CaptureDownscaler, plan: capture.DownscalePlan) bool {
        if (self.count != plan.count) return false;
        for (self.targets[0..self.count], plan.levels[0..plan.count]) |target, extent| {
            if (target.texture.width != @as(c_int, @intCast(extent.width))) return false;
            if (target.texture.height != @as(c_int, @intCast(extent.height))) return false;
        }
        return true;
    }

    /// Release every render target. Requires a live GL context.
    pub fn deinit(self: *CaptureDownscaler) void {
        for (self.targets[0..self.count]) |target| rl.UnloadRenderTexture(target);
        self.count = 0;
    }

    /// Shrink the current framebuffer through the chain and read the result.
    ///
    /// Carries the same ordering requirement as `captureFramebuffer`: the
    /// pending draw batch is flushed first, and this must run before
    /// `endDrawing` swaps the buffers away.
    pub fn readFrame(self: *CaptureDownscaler) ?CaptureImage {
        std.debug.assert(self.count >= 2);
        flushRenderBatch();

        // Restore whatever was bound rather than assuming the default
        // framebuffer, so a capture cannot silently redirect the app's drawing.
        const previous_framebuffer = rl.rlGetActiveFramebuffer();
        const source = self.targets[0];

        // Read from framebuffer 0 explicitly: the presented frame is the one
        // being recorded, whatever else may be bound.
        rl.rlBindFramebuffer(rl.RL_READ_FRAMEBUFFER, 0);
        rl.rlBindFramebuffer(rl.RL_DRAW_FRAMEBUFFER, source.id);
        rl.rlBlitFramebuffer(
            0,
            0,
            source.texture.width,
            source.texture.height,
            0,
            0,
            source.texture.width,
            source.texture.height,
            gl_color_buffer_bit,
        );
        rl.rlEnableFramebuffer(previous_framebuffer);

        // Copy the source colour through verbatim. The default framebuffer's
        // alpha is whatever the app's clear colour left there, and blending
        // against it would darken or erase the frame.
        rl.rlDisableColorBlend();
        var level: usize = 1;
        while (level < self.count) : (level += 1) {
            drawDownscaleLevel(self.targets[level - 1].texture, self.targets[level]);
        }
        rl.rlEnableColorBlend();

        // `rlReadScreenPixels` reads whatever framebuffer is bound and flips the
        // rows, exactly as it does for the default framebuffer -- which is why
        // every step above preserves the framebuffer's own row order.
        const last = self.targets[self.count - 1];
        rl.rlEnableFramebuffer(last.id);
        const data = rl.rlReadScreenPixels(last.texture.width, last.texture.height);
        rl.rlEnableFramebuffer(previous_framebuffer);
        if (data == null) return null;

        return .{ .image = .{
            .data = @ptrCast(data),
            .width = last.texture.width,
            .height = last.texture.height,
            .mipmaps = 1,
            .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
        } };
    }
};

/// Draw one downscale level into the next, filling it exactly.
///
/// The negative source height is raylib's render-target flip. It is not
/// cosmetic here: drawing a render texture upright would invert the row order,
/// so an odd-length chain would come out upside down and an even-length one
/// would not.
fn drawDownscaleLevel(from: Texture, to: RenderTexture) void {
    rl.BeginTextureMode(to);
    rl.DrawTexturePro(
        from,
        .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(from.width),
            .height = -@as(f32, @floatFromInt(from.height)),
        },
        .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(to.texture.width),
            .height = @floatFromInt(to.texture.height),
        },
        .{ .x = 0, .y = 0 },
        0,
        rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
    );
    // `EndTextureMode` submits the batch, so the level is complete before
    // the next input samples it.
    rl.EndTextureMode();
}

/// Submit raylib's batched geometry so the framebuffer reflects it.
///
/// raylib accumulates 2D draw calls in a vertex batch and only submits them on
/// a texture or shader switch, when the batch fills, or from `EndDrawing`. A
/// readback is plain `glReadPixels` and does no flushing of its own, so
/// without this a capture silently misses the tail of the frame.
pub fn flushRenderBatch() void {
    rl.rlDrawRenderBatchActive();
}

/// Read the current framebuffer into a CPU image.
///
/// This is raylib's thin wrapper over `rlReadScreenPixels`, not
/// `TakeScreenshot`: it skips the `basePath` prefixing and 512-byte truncation
/// that make `TakeScreenshot` unusable for a capture pipeline. The result is
/// already upright, and alpha is forced opaque by the readback itself.
///
/// Must be called before `endDrawing` swaps the buffers -- afterwards the back
/// buffer's contents are undefined. Flushes the pending batch first.
pub fn captureFramebuffer() ?CaptureImage {
    flushRenderBatch();
    const image = rl.LoadImageFromScreen();
    if (!rl.IsImageValid(image)) return null;
    return .{ .image = image };
}

/// Read an offscreen render target into a CPU image, upright and with alpha.
///
/// `LoadImageFromTexture` reads the colour attachment through `glGetTexImage`,
/// which keeps the alpha the app drew. `rlReadScreenPixels` -- what
/// `captureFramebuffer` and the downscaler use -- forces alpha opaque, which is
/// right for a window's frame and wrong for an offscreen composition that may
/// be exported with transparency.
///
/// A render target stores its rows bottom-up: the same inversion
/// `drawDownscaleLevel` compensates for with a negative source height. Flipped
/// here rather than left to the caller, so every consumer sees the row order
/// the rest of the capture path already assumes.
///
/// The pending batch is flushed first for the reason `captureFramebuffer`
/// gives: raylib may still be holding the draws that filled the target.
pub fn readRenderTexture(target: RenderTexture) ?CaptureImage {
    flushRenderBatch();
    var image = rl.LoadImageFromTexture(target.texture);
    if (!rl.IsImageValid(image)) return null;
    // `LoadRenderTexture` always allocates an RGBA8 attachment, so this
    // converts nothing today. It is here because `CaptureImage.pixels` computes
    // its length as four bytes per pixel, and a future attachment format would
    // otherwise be read as a buffer overrun rather than as a conversion.
    if (image.format != rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8) {
        rl.ImageFormat(&image, rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8);
        if (image.format != rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8) {
            rl.UnloadImage(image);
            return null;
        }
    }
    rl.ImageFlipVertical(&image);
    return .{ .image = image };
}

/// Draw a pointer glyph at a position, for compositing into a recording.
///
/// The operating system cursor is not part of the framebuffer, so a capture
/// never shows a pointer unless something draws one. This runs in the capture
/// hook rather than in the app's `render!`, so the glyph appears in the file
/// without the app having to know about it -- and without it appearing twice
/// alongside a real cursor on screen.
///
/// `pressed` draws a ring around the arrow so a click is visible in a silent
/// recording, where there is otherwise no cue that anything happened.
pub fn drawCaptureCursor(x: f32, y: f32, pressed: bool, scale: f32) void {
    const size = @max(scale, 0.1) * 18;
    const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = Color{ .r = 0, .g = 0, .b = 0, .a = 220 };

    // A classic arrow: tip at the hotspot, notch on the trailing edge.
    const points = [_]struct { x: f32, y: f32 }{
        .{ .x = x, .y = y },
        .{ .x = x, .y = y + size },
        .{ .x = x + size * 0.26, .y = y + size * 0.74 },
        .{ .x = x + size * 0.44, .y = y + size * 1.06 },
        .{ .x = x + size * 0.60, .y = y + size * 0.98 },
        .{ .x = x + size * 0.42, .y = y + size * 0.67 },
        .{ .x = x + size * 0.70, .y = y + size * 0.64 },
    };

    if (pressed) {
        drawCircleLines(.{
            .center = .{ .x = x, .y = y },
            .radius = size * 0.95,
            .thickness = @max(size * 0.10, 1),
            .color = white,
        });
    }

    drawPolygon(&points, white);
    drawPolygonLines(&points, @max(size * 0.09, 1), black);
}
