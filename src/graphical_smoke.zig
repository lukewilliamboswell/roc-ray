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
const Color = abi.Color;
const red = Color{ .r = 230, .g = 41, .b = 55, .a = 255 };
const green = Color{ .r = 0, .g = 228, .b = 48, .a = 255 };
const blue = Color{ .r = 0, .g = 121, .b = 241, .a = 255 };
const yellow = Color{ .r = 253, .g = 249, .b = 0, .a = 255 };
const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
const additive_mix = Color{ .r = 230, .g = 162, .b = 255, .a = 255 };
const shader_green = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };

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

/// Render representative primitives and assert exact framebuffer pixels.
pub fn main() !void {
    rl.SetConfigFlags(rl.FLAG_WINDOW_HIDDEN | rl.FLAG_WINDOW_UNDECORATED);
    rl.InitWindow(64, 64, "roc-ray graphical smoke");
    if (!rl.IsWindowReady()) return error.WindowUnavailable;
    defer rl.CloseWindow();

    var atlas_image = rl.GenImageColor(16, 8, backend.colorToRl(red));
    defer rl.UnloadImage(atlas_image);
    rl.ImageDrawRectangle(&atlas_image, 8, 0, 8, 8, backend.colorToRl(blue));
    const atlas = rl.LoadTextureFromImage(atlas_image);
    defer rl.UnloadTexture(atlas);

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
        .max_col = 0,
        .max_row = 0,
        .min_col = 0,
        .min_row = 0,
        .origin_x = 44,
        .origin_y = 28,
        .selector_kind = tilemap_batch.selector_all,
        .selector_value = 0,
    }, TilemapSmokeContext{ .texture = atlas }, submitTilemapSmokeQuad, tilemapSmokeTextureToken);
    if (tilemap_submitted != 1) return error.TilemapBatchCount;
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
}
