//! Raylib backend wrapper.
//!
//! This module provides a clean interface to raylib, accepting generated ABI
//! types and converting them to raylib's C types.
//! All C interop is isolated here.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const ffi = @import("roc_ffi.zig");

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

/// Native texture retained in the host resource heap.
pub const Texture = rl.Texture2D;

/// Native framebuffer-backed texture retained in the host resource heap.
pub const RenderTexture = rl.RenderTexture2D;

/// Native shader program retained in the host resource heap.
pub const Shader = rl.Shader;

/// Persistent packed keyboard state - updated each frame.
/// Bit 0 is held, bit 1 is pressed this frame, and bit 2 is released this frame.
var key_state: [ffi.KEY_COUNT]u8 = [_]u8{0} ** ffi.KEY_COUNT;

/// Persistent packed mouse button state - updated each frame, with the same bits.
var mouse_button_state: [ffi.MOUSE_BUTTON_COUNT]u8 = [_]u8{0} ** ffi.MOUSE_BUTTON_COUNT;

fn inputStateBits(down: bool, pressed: bool, released: bool) u8 {
    return (if (down) ffi.INPUT_HELD else 0) |
        (if (pressed) ffi.INPUT_PRESSED else 0) |
        (if (released) ffi.INPUT_RELEASED else 0);
}

test "input state packs held and edge flags" {
    try std.testing.expectEqual(@as(u8, 0), inputStateBits(false, false, false));
    try std.testing.expectEqual(@as(u8, 7), inputStateBits(true, true, true));
    try std.testing.expectEqual(ffi.INPUT_RELEASED, inputStateBits(false, false, true));
}

/// Update keyboard state from raylib (call once per frame)
pub fn updateKeyboardState() void {
    for (0..ffi.KEY_COUNT) |i| {
        const key: c_int = @intCast(i);
        key_state[i] = inputStateBits(
            rl.IsKeyDown(key),
            rl.IsKeyPressed(key),
            rl.IsKeyReleased(key),
        );
    }
}

/// Get the current packed keyboard state array.
pub fn getKeyState() *const [ffi.KEY_COUNT]u8 {
    return &key_state;
}

/// Update mouse button state from raylib (call once per frame)
pub fn updateMouseButtonState() void {
    for (0..ffi.MOUSE_BUTTON_COUNT) |i| {
        const button: c_int = @intCast(i);
        mouse_button_state[i] = inputStateBits(
            rl.IsMouseButtonDown(button),
            rl.IsMouseButtonPressed(button),
            rl.IsMouseButtonReleased(button),
        );
    }
}

/// Get the current packed mouse button state array.
pub fn getMouseButtonState() *const [ffi.MOUSE_BUTTON_COUNT]u8 {
    return &mouse_button_state;
}

/// Return raylib's built-in font, which is not owned by a resource heap.
pub fn defaultFont() Font {
    return rl.GetFontDefault();
}

/// Load a custom font.
pub fn loadFont(path: [*:0]const u8, size: c_int) ?Font {
    const font_size = if (size < 1) 1 else size;
    const font = rl.LoadFontEx(path, font_size, null, 0);
    if (!rl.IsFontValid(font)) return null;

    rl.SetTextureFilter(font.texture, rl.TEXTURE_FILTER_BILINEAR);
    return font;
}

/// Unload a custom font when its host resource slot is released.
pub fn unloadFont(font: Font) void {
    rl.UnloadFont(font);
}

/// Load a texture from disk.
pub fn loadTexture(path: [*:0]const u8) ?Texture {
    const texture = rl.LoadTexture(path);
    if (!rl.IsTextureValid(texture)) return null;
    return texture;
}

/// Unload a texture when its host resource slot is released.
pub fn unloadTexture(texture: Texture) void {
    rl.UnloadTexture(texture);
}

/// Generate a solid-color texture, releasing the temporary CPU image before return.
pub fn generateColorTexture(width: i32, height: i32, color: abi.Color) ?Texture {
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
pub fn updateTexture(texture: Texture, pixels: []const abi.Color) void {
    comptime std.debug.assert(@sizeOf(abi.Color) == @sizeOf(rl.Color));
    rl.UpdateTexture(texture, pixels.ptr);
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

/// Load a shader, using raylib's default stage when a path pointer is null.
pub fn loadShader(vertex_path: ?[*:0]const u8, fragment_path: ?[*:0]const u8) ?Shader {
    const shader = rl.LoadShader(vertex_path, fragment_path);
    if (!rl.IsShaderValid(shader)) return null;
    return shader;
}

/// Load shader source code, using raylib's default stage when a pointer is null.
pub fn loadShaderFromMemory(vertex_source: ?[*:0]const u8, fragment_source: ?[*:0]const u8) ?Shader {
    const shader = rl.LoadShaderFromMemory(vertex_source, fragment_source);
    if (!rl.IsShaderValid(shader)) return null;
    return shader;
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
    const black = colorToRl(abi.Color{
        .r = 0,
        .g = 0,
        .b = 0,
        .a = 255,
    });
    try std.testing.expectEqual(@as(u8, 0), black.r);
    try std.testing.expectEqual(@as(u8, 0), black.g);
    try std.testing.expectEqual(@as(u8, 0), black.b);
    try std.testing.expectEqual(@as(u8, 255), black.a);

    const red = colorToRl(abi.Color{
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

fn drawSegment(start: anytype, end: anytype, thickness: f32, color: abi.Color) void {
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
pub fn drawPolygon(points: anytype, color: abi.Color) void {
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
pub fn drawTextZ(text: [*:0]const u8, font: Font, pos: rl.Vector2, size: f32, spacing: f32, color: abi.Color) void {
    rl.DrawTextEx(font, text, pos, size, spacing, colorToRl(color));
}

/// Draw text anchored at a fractional point within its measured bounds.
/// Top-left alignment ({ 0, 0 }) skips measurement entirely.
pub fn drawTextAlignedZ(text: [*:0]const u8, font: Font, pos: rl.Vector2, size: f32, spacing: f32, color: abi.Color, alignment: rl.Vector2) void {
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

/// Draw a texture source region across an arbitrary screen-space quadrilateral.
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
    // Horizontal/vertical Tiled flips can reverse the destination winding.
    // Reverse vertex/UV pairs together so raylib's back-face culling still
    // accepts the quad without changing global rlgl state for every tile.
    const cross = (vertices[1].x - vertices[0].x) * (vertices[2].y - vertices[0].y) -
        (vertices[1].y - vertices[0].y) * (vertices[2].x - vertices[0].x);
    const order = if (cross > 0)
        [_]usize{ 3, 2, 1, 0 }
    else
        [_]usize{ 0, 1, 2, 3 };

    rl.rlSetTexture(texture.id);
    rl.rlBegin(rl.RL_QUADS);
    rl.rlColor4ub(tint.r, tint.g, tint.b, tint.a);
    for (order) |i| {
        rl.rlTexCoord2f(uvs[i].x, uvs[i].y);
        rl.rlVertex2f(vertices[i].x, vertices[i].y);
    }
    rl.rlEnd();
    rl.rlSetTexture(0);
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
pub fn windowConfigFlags(resizable: bool, fullscreen: bool, vsync: bool) c_uint {
    var flags: c_uint = @as(c_uint, @intCast(rl.FLAG_WINDOW_HIGHDPI));
    if (resizable) flags |= @as(c_uint, @intCast(rl.FLAG_WINDOW_RESIZABLE));
    if (fullscreen) flags |= @as(c_uint, @intCast(rl.FLAG_FULLSCREEN_MODE));
    if (vsync) flags |= @as(c_uint, @intCast(rl.FLAG_VSYNC_HINT));
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
