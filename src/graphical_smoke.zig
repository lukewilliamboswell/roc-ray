//! Optional pixel-level smoke test for the rendering backend.
//!
//! Run with `zig build graphical-smoke` on a machine with a display, or under
//! `xvfb-run`, to validate real raylib rasterization rather than only ABI calls.

const std = @import("std");
const backend = @import("backend_raylib.zig");
const abi = @import("roc_platform_abi.zig");
const tilemap_batch = @import("tilemap_batch.zig");
const rl = backend.rl;

const Point = struct { x: f32, y: f32 };
const Color = abi.ColorRgba;
const red = Color{ .r = 230, .g = 41, .b = 55, .a = 255 };
const green = Color{ .r = 0, .g = 228, .b = 48, .a = 255 };
const blue = Color{ .r = 0, .g = 121, .b = 241, .a = 255 };
const yellow = Color{ .r = 253, .g = 249, .b = 0, .a = 255 };
const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
const additive_mix = Color{ .r = 230, .g = 162, .b = 255, .a = 255 };
const shader_green = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };
const projective_blue = Color{ .r = 0, .g = 17, .b = 241, .a = 255 };

const TilemapSmokeContext = struct { texture: backend.Texture };

fn tilemapSmokeTextureToken(tileset: anytype) u64 {
    return tileset.texture_token;
}

fn submitTilemapSmokeQuad(context: TilemapSmokeContext, quad: tilemap_batch.Quad) bool {
    backend.drawTextureQuad(context.texture, .{
        .source = quad.source,
        .top_left = quad.top_left,
        .bottom_left = quad.bottom_left,
        .bottom_right = quad.bottom_right,
        .top_right = quad.top_right,
        .q_top_left = 1,
        .q_bottom_left = 1,
        .q_bottom_right = 1,
        .q_top_right = 1,
        .tint = white,
    });
    return true;
}

fn expectPixel(image: rl.Image, x: c_int, y: c_int, expected: Color) !void {
    const actual = rl.GetImageColor(image, x, y);
    if (actual.r != expected.r or actual.g != expected.g or actual.b != expected.b or actual.a != expected.a) {
        std.log.err("pixel ({d}, {d}) expected rgba({d}, {d}, {d}, {d}), got rgba({d}, {d}, {d}, {d})", .{
            x,        y,        expected.r, expected.g, expected.b, expected.a,
            actual.r, actual.g, actual.b,   actual.a,
        });
        return error.PixelMismatch;
    }
}

/// Draw a known frame, capture it the way the host does, and read the file back.
///
/// This runs in a frame of its own so the assertions in `main` keep testing the
/// buffer they always did. It is the only check that the capture path survives
/// the whole round trip, and it pins down three things that each fail silently:
///
///  - The readback happens *before* `EndDrawing` swaps the buffers; afterwards
///    the back buffer's contents are undefined.
///  - The pending draw batch is flushed first. raylib only submits batched 2D
///    geometry on a texture/shader switch, when the batch fills, or from
///    `EndDrawing` -- and a readback does no flushing of its own. The solid
///    rectangles below have no state change after them, so they are still
///    sitting in the batch when the capture runs.
///  - `ExportImage` really encodes PNG in the vendored archive, and the decoded
///    pixels match what was drawn.
fn captureRoundTrip() !void {
    rl.BeginDrawing();
    backend.clearBackground(black);
    backend.drawRectangle(.{ .x = 0, .y = 0, .width = 32, .height = 32, .color = red });
    backend.drawRectangle(.{ .x = 32, .y = 0, .width = 32, .height = 32, .color = green });

    var shot = backend.captureFramebuffer() orelse return error.CaptureUnavailable;
    defer shot.deinit();

    var scaled = backend.captureFramebuffer() orelse return error.CaptureUnavailable;
    defer scaled.deinit();

    rl.EndDrawing();

    if (shot.width() == 0 or shot.height() == 0) return error.CaptureEmpty;
    if (shot.pixels().len != shot.width() * shot.height() * 4) return error.CaptureStrideMismatch;

    const path = "roc-ray-capture-smoke.png";
    if (!shot.exportPng(path)) return error.CaptureExportFailed;
    const io = std.Io.Threaded.global_single_threaded.io();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const decoded = rl.LoadImage(path);
    defer rl.UnloadImage(decoded);
    if (!rl.IsImageValid(decoded)) return error.CaptureDecodeFailed;
    if (decoded.width != @as(c_int, @intCast(shot.width()))) return error.CaptureDecodeSizeMismatch;
    if (decoded.height != @as(c_int, @intCast(shot.height()))) return error.CaptureDecodeSizeMismatch;

    try expectPixel(decoded, 16, 16, red);
    try expectPixel(decoded, 48, 16, green);
    try expectPixel(decoded, 100, 60, black);

    // Halving is the default recording scale, so exercise it too. Sample well
    // inside each block so filtering at the seam cannot decide the result.
    const half_width = shot.width() / 2;
    const half_height = shot.height() / 2;
    scaled.resize(half_width, half_height);
    if (scaled.width() != half_width or scaled.height() != half_height) return error.CaptureResizeFailed;
    if (scaled.pixels().len != half_width * half_height * 4) return error.CaptureResizeStrideMismatch;
    try expectPixel(scaled.image, 6, 6, red);
    try expectPixel(scaled.image, 26, 6, green);
}

/// Render representative primitives and assert exact framebuffer pixels.
pub fn main() !void {
    rl.SetConfigFlags(rl.FLAG_WINDOW_HIDDEN | rl.FLAG_WINDOW_UNDECORATED);
    rl.InitWindow(128, 96, "roc-ray graphical smoke");
    if (!rl.IsWindowReady()) return error.WindowUnavailable;
    defer rl.CloseWindow();

    var atlas_image = rl.GenImageColor(16, 8, backend.colorToRl(red));
    defer rl.UnloadImage(atlas_image);
    rl.ImageDrawRectangle(&atlas_image, 8, 0, 8, 8, backend.colorToRl(blue));
    const atlas = rl.LoadTextureFromImage(atlas_image);
    defer rl.UnloadTexture(atlas);

    var projective_image = rl.GenImageColor(16, 16, backend.colorToRl(red));
    defer rl.UnloadImage(projective_image);
    rl.ImageDrawRectangle(&projective_image, 0, 9, 16, 7, backend.colorToRl(blue));
    const projective_texture = rl.LoadTextureFromImage(projective_image);
    defer rl.UnloadTexture(projective_texture);

    const target = backend.loadRenderTexture(24, 8) orelse return error.RenderTextureUnavailable;
    defer backend.unloadRenderTexture(target);
    const fragment_source =
        \\#version 330
        \\in vec2 fragTexCoord;
        \\in vec4 fragColor;
        \\uniform sampler2D texture0;
        \\out vec4 finalColor;
        \\void main() { finalColor = vec4(0.0, 1.0, 0.0, 1.0); }
    ;
    const shader = backend.loadShaderFromMemory(null, fragment_source) orelse return error.ShaderUnavailable;
    defer backend.unloadShader(shader);
    const projective_fragment_source =
        \\#version 330
        \\in vec2 fragTexCoord;
        \\in vec4 fragColor;
        \\uniform sampler2D texture0;
        \\out vec4 finalColor;
        \\void main() {
        \\    finalColor = texture(texture0, fragTexCoord)*fragColor;
        \\    finalColor.g = 17.0/255.0;
        \\}
    ;
    const projective_shader = backend.loadShaderFromMemory(null, projective_fragment_source) orelse return error.ShaderUnavailable;
    defer backend.unloadShader(projective_shader);

    backend.beginTextureMode(target);
    backend.clearBackground(black);
    backend.drawRectangle(.{ .x = 0, .y = 0, .width = 8, .height = 8, .color = red });
    backend.drawRectangle(.{ .x = 8, .y = 0, .width = 8, .height = 8, .color = red });
    backend.beginBlendMode(1);
    backend.drawRectangle(.{ .x = 8, .y = 0, .width = 8, .height = 8, .color = blue });
    backend.endBlendMode();
    backend.beginShaderMode(shader);
    backend.drawRectangle(.{ .x = 16, .y = 0, .width = 8, .height = 8, .color = white });
    backend.endShaderMode();
    backend.endTextureMode();

    const pipeline_image = rl.LoadImageFromTexture(backend.renderTextureColor(target));
    defer rl.UnloadImage(pipeline_image);
    try expectPixel(pipeline_image, 4, 4, red);
    try expectPixel(pipeline_image, 12, 4, additive_mix);
    try expectPixel(pipeline_image, 20, 4, shader_green);

    rl.BeginDrawing();
    backend.clearBackground(black);

    backend.beginScissor(4, 4, 16, 16);
    backend.drawRectangle(.{ .x = 0, .y = 0, .width = 32, .height = 32, .color = red });
    backend.endScissor();

    const polygon = [_]Point{
        .{ .x = 24, .y = 4 },
        .{ .x = 24, .y = 20 },
        .{ .x = 40, .y = 20 },
        .{ .x = 40, .y = 4 },
    };
    backend.drawPolygon(&polygon, green);

    const reverse_polygon = [_]Point{
        .{ .x = 24, .y = 28 },
        .{ .x = 40, .y = 28 },
        .{ .x = 40, .y = 44 },
        .{ .x = 24, .y = 44 },
    };
    backend.drawPolygon(&reverse_polygon, yellow);

    backend.drawTextureQuad(atlas, .{
        .source = .{ .x = 8, .y = 0, .width = 8, .height = 8 },
        .top_left = Point{ .x = 44, .y = 4 },
        .bottom_left = Point{ .x = 44, .y = 20 },
        .bottom_right = Point{ .x = 60, .y = 20 },
        .top_right = Point{ .x = 60, .y = 4 },
        .q_top_left = 1,
        .q_bottom_left = 1,
        .q_bottom_right = 1,
        .q_top_right = 1,
        .tint = Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
    });

    const tilemap_gids = [_]u64{tilemap_batch.flip_horizontal | 1};
    const tilemap_layers = [_]struct { gid_count: u64, gid_start: u64, height: u64, width: u64, role: u8, visible: bool }{
        .{ .gid_count = 1, .gid_start = 0, .height = 1, .width = 1, .role = 0, .visible = true },
    };
    const tilemap_tilesets = [_]struct { columns: u64, first_gid: u64, texture_token: u64, tile_height: f32, tile_width: f32 }{
        .{ .columns = 1, .first_gid = 1, .texture_token = 1, .tile_height = 8, .tile_width = 16 },
    };
    const tilemap_submitted = tilemap_batch.draw(.{
        .culled = false,
        .gids = &tilemap_gids,
        .layers = &tilemap_layers,
        .tilesets = &tilemap_tilesets,
        .map_tile_height = 16,
        .map_tile_width = 16,
        .max_col = @as(u64, 0),
        .max_row = @as(u64, 0),
        .min_col = @as(u64, 0),
        .min_row = @as(u64, 0),
        .origin_x = 44,
        .origin_y = 28,
        .selector_kind = tilemap_batch.selector_all,
        .selector_value = 0,
    }, TilemapSmokeContext{ .texture = atlas }, submitTilemapSmokeQuad, tilemapSmokeTextureToken);
    if (tilemap_submitted != 1) return error.TilemapBatchCount;

    backend.beginShaderMode(projective_shader);
    backend.drawTextureQuad(projective_texture, .{
        .source = .{ .x = 0, .y = 0, .width = 16, .height = 16 },
        .top_left = Point{ .x = 68, .y = 4 },
        .bottom_left = Point{ .x = 68, .y = 88 },
        .bottom_right = Point{ .x = 124, .y = 88 },
        .top_right = Point{ .x = 100, .y = 4 },
        .q_top_left = 1,
        .q_bottom_left = 4.0 / 7.0,
        .q_bottom_right = 4.0 / 7.0,
        .q_top_right = 1,
        .tint = white,
    });
    backend.endShaderMode();
    rl.EndDrawing();

    const screen = rl.LoadImageFromScreen();
    defer rl.UnloadImage(screen);
    try expectPixel(screen, 8, 8, red);
    try expectPixel(screen, 2, 2, black);
    try expectPixel(screen, 30, 10, green);
    try expectPixel(screen, 30, 36, yellow);
    try expectPixel(screen, 52, 10, blue);
    try expectPixel(screen, 48, 36, blue);
    try expectPixel(screen, 56, 36, red);
    // This point is texture v=0.6 under the exact homography, but v<0.5
    // under the old two-triangle affine mapping. The custom green channel also
    // proves projective drawing preserved the caller's fragment shader.
    try expectPixel(screen, 72, 43, projective_blue);

    try captureRoundTrip();
}
