//! Optional pixel-level smoke test for the rendering backend.
//!
//! Run with `zig build graphical-smoke` on a machine with a display, or under
//! `xvfb-run`, to validate real raylib rasterization rather than only ABI calls.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("backend_raylib.zig");
const abi = @import("roc_platform_abi.zig");
const tilemap_batch = @import("tilemap_batch.zig");
const capture = @import("capture.zig");
const png = @import("png.zig");
const rl = backend.rl;

const Point = struct { x: f32, y: f32 };
const Color = abi.ColorRgba;
const red = Color{ .r = 230, .g = 41, .b = 55, .a = 255 };
const green = Color{ .r = 0, .g = 228, .b = 48, .a = 255 };
const blue = Color{ .r = 0, .g = 121, .b = 241, .a = 255 };
const yellow = Color{ .r = 253, .g = 249, .b = 0, .a = 255 };
const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
const additive_mix = Color{ .r = 230, .g = 162, .b = 255, .a = 255 };
const shader_green = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };
const projective_blue = Color{ .r = 0, .g = 17, .b = 241, .a = 255 };
/// `red` modulated by a pure-blue instance tint: the two zeroed channels and
/// the untouched one are all exact, so this stays an equality assertion.
const instance_tinted = Color{ .r = 0, .g = 0, .b = red.b, .a = 255 };

const TilemapSmokeContext = struct { texture: backend.Texture };

const MetricSnapshot = struct {
    base_size: f32,
    fallback_index: usize,
    line_spacing: f32,
    glyphs: []backend.FontGlyphMetric,
};

const MetricMeasurement = struct {
    width: f32,
    height: f32,
};

/// Copy precisely the scalar data `Draw.Font` receives from a live raylib
/// font. The measurement below deliberately has no access to the font after
/// this point, matching the pure Roc API's ownership boundary.
fn snapshotFontMetrics(allocator: std.mem.Allocator, font: backend.Font) !MetricSnapshot {
    const glyphs = try allocator.alloc(backend.FontGlyphMetric, backend.fontGlyphCount(font));
    var fallback_codepoint: u32 = 0;
    for (glyphs, 0..) |*glyph, index| {
        glyph.* = backend.fontGlyphMetric(font, index);
        if (index == 0 or glyph.codepoint == '?') fallback_codepoint = glyph.codepoint;
    }
    std.sort.pdq(backend.FontGlyphMetric, glyphs, {}, struct {
        fn lessThan(_: void, left: backend.FontGlyphMetric, right: backend.FontGlyphMetric) bool {
            return left.codepoint < right.codepoint;
        }
    }.lessThan);
    return .{
        .base_size = backend.fontBaseSize(font),
        .fallback_index = for (glyphs, 0..) |glyph, index| {
            if (glyph.codepoint == fallback_codepoint) break index;
        } else 0,
        // roc-ray exposes no text-line-spacing setter; this is raylib 6's
        // initial value, retained by `Draw.Font` with the glyph scalars.
        .line_spacing = 2,
        .glyphs = glyphs,
    };
}

fn snapshotGlyphAdvance(snapshot: MetricSnapshot, codepoint: u32) f32 {
    var start: usize = 0;
    var end = snapshot.glyphs.len;
    while (start < end) {
        const middle = start + (end - start) / 2;
        const glyph = snapshot.glyphs[middle];
        if (glyph.codepoint == codepoint) return if (glyph.advance_x > 0) glyph.advance_x else glyph.width + glyph.offset_x;
        if (codepoint < glyph.codepoint) {
            end = middle;
        } else {
            start = middle + 1;
        }
    }
    const fallback = snapshot.glyphs[snapshot.fallback_index];
    return if (fallback.advance_x > 0) fallback.advance_x else fallback.width + fallback.offset_x;
}

const DecodedCodepoint = struct {
    codepoint: u32,
    next: usize,
};

/// Every string below is valid UTF-8, exactly as `Str` values are. This is the
/// same byte-to-codepoint boundary used by `Draw.Font.measure`.
fn decodeUtf8(text: []const u8, index: usize) DecodedCodepoint {
    const first: u32 = text[index];
    if (first < 0x80) return .{ .codepoint = first, .next = index + 1 };
    if (first < 0xE0) return .{
        .codepoint = (first - 0xC0) * 64 + @as(u32, text[index + 1]) - 0x80,
        .next = index + 2,
    };
    if (first < 0xF0) return .{
        .codepoint = (first - 0xE0) * 4096 + (@as(u32, text[index + 1]) - 0x80) * 64 + @as(u32, text[index + 2]) - 0x80,
        .next = index + 3,
    };
    return .{
        .codepoint = (first - 0xF0) * 262144 + (@as(u32, text[index + 1]) - 0x80) * 4096 + (@as(u32, text[index + 2]) - 0x80) * 64 + @as(u32, text[index + 3]) - 0x80,
        .next = index + 4,
    };
}

/// Pure equivalent of `Draw.Font.measure` for a native parity check.
fn measureSnapshot(snapshot: MetricSnapshot, text: []const u8, size: f32, spacing: f32) MetricMeasurement {
    if (text.len == 0 or text[0] == 0) return .{ .width = 0, .height = 0 };

    var index: usize = 0;
    var line_width: f32 = 0;
    var widest_width: f32 = 0;
    var line_codepoints: usize = 0;
    var widest_codepoints: usize = 0;
    var height = size;
    while (index < text.len and text[index] != 0) {
        const decoded = decodeUtf8(text, index);
        index = decoded.next;
        if (decoded.codepoint == '\n') {
            widest_width = @max(widest_width, line_width);
            widest_codepoints = @max(widest_codepoints, line_codepoints);
            line_width = 0;
            line_codepoints = 0;
            height += size + snapshot.line_spacing;
        } else {
            line_width += snapshotGlyphAdvance(snapshot, decoded.codepoint);
            line_codepoints += 1;
        }
    }
    const widest_codepoint_count = @max(widest_codepoints, line_codepoints);
    return .{
        .width = @max(widest_width, line_width) * (size / snapshot.base_size) + (@as(f32, @floatFromInt(widest_codepoint_count)) - 1) * spacing,
        .height = height,
    };
}

fn expectMeasurementEqual(actual: MetricMeasurement, expected: rl.Vector2, label: []const u8) !void {
    const tolerance: f32 = 0.001;
    if (!std.math.approxEqAbs(f32, actual.width, expected.x, tolerance) or !std.math.approxEqAbs(f32, actual.height, expected.y, tolerance)) {
        std.log.err("{s}: scalar snapshot measured ({d:.3}, {d:.3}), raylib MeasureTextEx measured ({d:.3}, {d:.3})", .{
            label, actual.width, actual.height, expected.x, expected.y,
        });
        return error.FontMetricParity;
    }
}

/// Compare the host snapshot/pure path with the renderer's own MeasureTextEx.
/// This is intentionally a real-GL smoke check rather than the headless metric
/// fixture: it catches a change in raylib's default or loaded-font semantics.
fn expectFontMetricParity(allocator: std.mem.Allocator, font: backend.Font, label: []const u8) !void {
    const snapshot = try snapshotFontMetrics(allocator, font);
    const cases = [_]struct { text: [:0]const u8, size: f32, spacing: f32 }{
        .{ .text = "iii", .size = 20, .spacing = 1 },
        .{ .text = "WWW", .size = 20, .spacing = 1 },
        .{ .text = "A\nWi", .size = 31, .spacing = 2.5 },
        .{ .text = "café", .size = 17, .spacing = 0 },
        .{ .text = "i\x00WWW", .size = 20, .spacing = 1 },
    };
    for (cases) |case| {
        const native = backend.measureTextZ(case.text.ptr, font, case.size, case.spacing);
        try expectMeasurementEqual(measureSnapshot(snapshot, case.text, case.size, case.spacing), native, label);
    }
}

fn loadProportionalTestFont() ?backend.Font {
    // CI's Linux image carries DejaVu. The other candidates make the same
    // native coverage available to local macOS and Windows contributors
    // without making a system font a required repository asset.
    const candidates = switch (builtin.os.tag) {
        .linux => &.{"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"},
        .macos => &.{"/System/Library/Fonts/Supplemental/Arial.ttf"},
        .windows => &.{"C:\\Windows\\Fonts\\arial.ttf"},
        else => &.{},
    };
    inline for (candidates) |path| {
        if (backend.loadFont(path.ptr, 32)) |font| return font;
    }
    return null;
}

fn expectNativeFontMetricParity(allocator: std.mem.Allocator) !void {
    try expectFontMetricParity(allocator, backend.defaultFont(), "default font");

    if (loadProportionalTestFont()) |font| {
        defer backend.unloadFont(font);
        try expectFontMetricParity(allocator, font, "loaded proportional font");

        const iii = backend.measureTextZ("iii", font, 20, 1);
        const www = backend.measureTextZ("WWW", font, 20, 1);
        if (std.math.approxEqAbs(f32, iii.x, www.x, 0.001)) return error.FontNotProportional;
    } else {
        std.log.warn("no known proportional system font; skipped loaded-font metric parity", .{});
    }
}

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

/// Shrink a known frame on the GPU and assert the readback holds real pixels.
///
/// The scaled path never touches `ImageResize`, so `captureRoundTrip` says
/// nothing about it. What can fail silently here, and what each assertion pins:
///
///  - The chain preserves row order. Every step draws with raylib's
///    render-target flip, so an odd number of steps must come out the same way
///    up as an even one. Half scale is one step and quarter is two, and the
///    coloured blocks are only in the top half, so a flip turns them black.
///  - The blit really copies the frame. A chain that read an empty render
///    target would return a plausible, entirely black image.
///  - The batch is flushed before the blit, for the same reason as above: the
///    rectangles have no state change after them.
fn downscaleRoundTrip() !void {
    const width = rl.GetRenderWidth();
    const height = rl.GetRenderHeight();
    // The sample points below are worked out for this framebuffer, so say so
    // rather than letting a HiDPI backing scale turn into a pixel mismatch.
    if (width != 128 or height != 96) return error.UnexpectedRenderSize;

    // Built inside the frame exactly as the host builds it, on the first
    // captured frame of a recording rather than up front.
    rl.BeginDrawing();
    backend.clearBackground(black);
    backend.drawRectangle(.{ .x = 0, .y = 0, .width = 32, .height = 32, .color = red });
    backend.drawRectangle(.{ .x = 32, .y = 0, .width = 32, .height = 32, .color = green });

    const half_plan = capture.planDownscale(
        @intCast(width),
        @intCast(height),
        @intCast(@divTrunc(width, 2)),
        @intCast(@divTrunc(height, 2)),
    ) orelse return error.DownscalePlanMissing;
    var half = backend.CaptureDownscaler.init(half_plan) orelse return error.DownscaleUnavailable;
    defer half.deinit();
    if (!half.matches(half_plan)) return error.DownscaleSizeMismatch;

    const quarter_plan = capture.planDownscale(
        @intCast(width),
        @intCast(height),
        @intCast(@divTrunc(width, 4)),
        @intCast(@divTrunc(height, 4)),
    ) orelse return error.DownscalePlanMissing;
    var quarter = backend.CaptureDownscaler.init(quarter_plan) orelse return error.DownscaleUnavailable;
    defer quarter.deinit();

    // A recording that stops and restarts at another scale reuses the chain
    // only if `matches` says the sizes still line up. If it ever said yes to
    // the wrong plan, the encoder would silently be handed frames of the size
    // the *previous* recording asked for.
    if (quarter.matches(half_plan)) return error.DownscaleMatchedWrongPlan;
    if (half.matches(quarter_plan)) return error.DownscaleMatchedWrongPlan;

    var half_frame = half.readFrame() orelse return error.DownscaleReadFailed;
    defer half_frame.deinit();
    var quarter_frame = quarter.readFrame() orelse return error.DownscaleReadFailed;
    defer quarter_frame.deinit();

    // The window has to survive the detour through the render targets: a chain
    // that left its own framebuffer bound would present a blank frame.
    var after = backend.captureFramebuffer() orelse return error.CaptureUnavailable;
    defer after.deinit();

    rl.EndDrawing();

    if (half_frame.width() != 64 or half_frame.height() != 48) return error.DownscaleSizeMismatch;
    if (half_frame.pixels().len != 64 * 48 * 4) return error.DownscaleStrideMismatch;
    try expectPixel(half_frame.image, 6, 6, red);
    try expectPixel(half_frame.image, 26, 6, green);
    try expectPixel(half_frame.image, 50, 30, black);

    if (quarter_frame.width() != 32 or quarter_frame.height() != 24) return error.DownscaleSizeMismatch;
    if (quarter_frame.pixels().len != 32 * 24 * 4) return error.DownscaleStrideMismatch;
    try expectPixel(quarter_frame.image, 3, 3, red);
    try expectPixel(quarter_frame.image, 11, 3, green);
    try expectPixel(quarter_frame.image, 25, 15, black);

    try expectPixel(after.image, 16, 16, red);
    try expectPixel(after.image, 48, 16, green);
    try expectPixel(after.image, 100, 60, black);

    // A second frame through the same chain, which is what a recording does for
    // every frame after its first. Nothing clears the render targets, so this
    // is what says each step rewrites every pixel of the one below it -- and
    // that the readback sees this frame's draws rather than the last one's.
    rl.BeginDrawing();
    backend.clearBackground(blue);
    var reused = half.readFrame() orelse return error.DownscaleReadFailed;
    defer reused.deinit();
    rl.EndDrawing();

    try expectPixel(reused.image, 6, 6, blue);
    try expectPixel(reused.image, 26, 6, blue);
    try expectPixel(reused.image, 50, 30, blue);
}

/// Export an offscreen target larger than the window and read the file back.
///
/// The point of `Capture.screenshot_texture!` is output that is not capped at
/// the window, so the target here is twice the window in each axis. Four things
/// fail silently without these assertions:
///
///  - The image really is the target's size. A readback that fell back to the
///    framebuffer would produce a plausible 128x96 PNG.
///  - The rows come out upright. A render target stores them bottom-up, so a
///    missing flip puts the red corner at the bottom and nothing else changes.
///  - Alpha survives. The framebuffer path forces it opaque, which would make
///    an exported sprite or figure unusable on any other background.
///  - `png.encodeRgba` -- the encoder the export uses, not raylib's -- writes a
///    file with those dimensions that a decoder actually accepts.
fn renderTargetExportRoundTrip() !void {
    const width: c_int = 256;
    const height: c_int = 192;
    const target = backend.loadRenderTexture(width, height) orelse return error.RenderTextureUnavailable;
    defer backend.unloadRenderTexture(target);

    // Drawn in a frame of its own, the way an app fills a target during
    // `render!`, so the readback below sees a completed frame rather than a
    // batch raylib has not submitted.
    rl.BeginDrawing();
    backend.beginTextureMode(target);
    backend.clearBackground(transparent);
    backend.drawRectangle(.{ .x = 0, .y = 0, .width = 64, .height = 64, .color = red });
    backend.drawRectangle(.{ .x = 192, .y = 0, .width = 64, .height = 64, .color = green });
    backend.drawRectangle(.{ .x = 0, .y = 128, .width = 64, .height = 64, .color = blue });
    backend.endTextureMode();
    rl.EndDrawing();

    var image = backend.readRenderTexture(target) orelse return error.RenderTextureReadFailed;
    defer image.deinit();

    if (image.width() != 256 or image.height() != 192) return error.RenderTextureSizeMismatch;
    if (image.width() <= @as(u32, @intCast(rl.GetScreenWidth()))) return error.RenderTextureNotLargerThanWindow;
    if (image.height() <= @as(u32, @intCast(rl.GetScreenHeight()))) return error.RenderTextureNotLargerThanWindow;
    if (image.pixels().len != image.width() * image.height() * 4) return error.RenderTextureStrideMismatch;

    try expectPixel(image.image, 8, 8, red);
    try expectPixel(image.image, 200, 8, green);
    try expectPixel(image.image, 8, 180, blue);
    try expectPixel(image.image, 128, 96, transparent);

    const allocator = std.heap.page_allocator;
    const encoded = try png.encodeRgba(allocator, image.pixels(), image.width(), image.height());
    defer allocator.free(encoded);

    // The IHDR dimensions, at their fixed offsets: eight signature bytes, a
    // four-byte length, the "IHDR" type, then width and height.
    if (!std.mem.eql(u8, encoded[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a })) return error.PngSignatureMismatch;
    if (!std.mem.eql(u8, encoded[12..16], "IHDR")) return error.PngHeaderMissing;
    if (std.mem.readInt(u32, encoded[16..20], .big) != 256) return error.PngWidthMismatch;
    if (std.mem.readInt(u32, encoded[20..24], .big) != 192) return error.PngHeightMismatch;

    const path = "roc-ray-render-texture-smoke.png";
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = encoded });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const decoded = rl.LoadImage(path);
    defer rl.UnloadImage(decoded);
    if (!rl.IsImageValid(decoded)) return error.RenderTextureDecodeFailed;
    if (decoded.width != width or decoded.height != height) return error.RenderTextureDecodeSizeMismatch;
    try expectPixel(decoded, 8, 8, red);
    try expectPixel(decoded, 200, 8, green);
    try expectPixel(decoded, 8, 180, blue);
    try expectPixel(decoded, 128, 96, transparent);
}

fn expectChannels(label: []const u8, actual: [4]u8, expected: Color) !void {
    if (actual[0] != expected.r or actual[1] != expected.g or actual[2] != expected.b or actual[3] != expected.a) {
        std.log.err("{s} expected rgba({d}, {d}, {d}, {d}), got rgba({d}, {d}, {d}, {d})", .{
            label,     expected.r, expected.g, expected.b, expected.a,
            actual[0], actual[1],  actual[2],  actual[3],
        });
        return error.PixelMismatch;
    }
}

/// Assert every pixel of a copied region against one expected colour.
fn expectRegionUniform(label: []const u8, bytes: []const u8, expected: Color) !void {
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 4) {
        try expectChannels(label, .{ bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3] }, expected);
    }
}

fn expectCode(actual: u8, expected: u8) !void {
    if (actual != expected) {
        std.log.err("expected capture code {d}, got {d}", .{ expected, actual });
        return error.ReadbackCodeMismatch;
    }
}

/// Read pixels back the way `Capture.pixel_at!` and `Capture.read_region!` do,
/// and assert the exact colours and the exact orientation.
///
/// The host slices both readbacks with `capture.pixelAt` and
/// `capture.copyRegion` out of whatever `captureFramebuffer` or
/// `readRenderTexture` produced, so those three together are the whole path an
/// app sees. Four things fail silently without these assertions:
///
///  - The framebuffer readback is top-down and the render-target readback is
///    flipped to match. A render target stores its rows bottom-up, so a
///    missing flip still yields a plausible image of the right size with the
///    colours in the wrong rows.
///  - The region is cut with the source's stride, not the region's. A
///    single-stride copy of a region narrower than its source produces a
///    sheared image that is still exactly the right length.
///  - Alpha differs between the two sources by design: the framebuffer
///    readback forces it opaque and a target keeps what the app drew. A region
///    that quietly lost a target's transparency would look right in every
///    opaque assertion.
///  - The bounds refusals are computed against the source's real dimensions,
///    which only a live readback knows.
fn pixelReadbackRoundTrip() !void {
    const width = rl.GetRenderWidth();
    const height = rl.GetRenderHeight();
    if (width != 128 or height != 96) return error.UnexpectedRenderSize;

    rl.BeginDrawing();
    backend.clearBackground(black);
    backend.drawRectangle(.{ .x = 0, .y = 0, .width = 32, .height = 32, .color = red });
    backend.drawRectangle(.{ .x = 32, .y = 0, .width = 32, .height = 32, .color = green });
    backend.drawRectangle(.{ .x = 0, .y = 64, .width = 32, .height = 32, .color = blue });

    // Taken inside the frame, exactly where the host's capture hook takes the
    // snapshot a `Screen` readback later slices.
    var frame = backend.captureFramebuffer() orelse return error.CaptureUnavailable;
    defer frame.deinit();
    rl.EndDrawing();

    const screen = frame.pixels();
    if (screen.len != frame.width() * frame.height() * 4) return error.CaptureStrideMismatch;

    // The single-pixel read, on each drawn block and on the background.
    try expectChannels("screen (16, 16)", capture.pixelAt(screen, frame.width(), 16, 16), red);
    try expectChannels("screen (48, 16)", capture.pixelAt(screen, frame.width(), 48, 16), green);
    try expectChannels("screen (16, 80)", capture.pixelAt(screen, frame.width(), 16, 80), blue);
    try expectChannels("screen (100, 48)", capture.pixelAt(screen, frame.width(), 100, 48), black);

    // A region straddling the red/green seam. Its rows are narrower than the
    // framebuffer, so only the source's stride puts the seam in the middle of
    // each row rather than walking it across them.
    const seam = capture.Region{ .x = 28, .y = 4, .width = 8, .height = 2 };
    try expectCode(capture.validateRegion(seam, frame.width(), frame.height()), capture.err_none);
    var seam_bytes: [8 * 2 * 4]u8 = undefined;
    capture.copyRegion(&seam_bytes, screen, frame.width(), seam);
    try expectRegionUniform("seam row 0 left", seam_bytes[0..16], red);
    try expectRegionUniform("seam row 0 right", seam_bytes[16..32], green);
    try expectRegionUniform("seam row 1 left", seam_bytes[32..48], red);
    try expectRegionUniform("seam row 1 right", seam_bytes[48..64], green);

    // A region straddling the black/blue seam, which is what pins the row
    // order: upside down, these four rows would all be black.
    const vertical = capture.Region{ .x = 4, .y = 62, .width = 1, .height = 4 };
    var vertical_bytes: [1 * 4 * 4]u8 = undefined;
    capture.copyRegion(&vertical_bytes, screen, frame.width(), vertical);
    try expectRegionUniform("above the blue block", vertical_bytes[0..8], black);
    try expectRegionUniform("below the blue seam", vertical_bytes[8..16], blue);

    // Bounds against the framebuffer's real size, which is the only place the
    // refusal can be checked against a source an app really has.
    try expectCode(capture.validatePoint(127, 95, frame.width(), frame.height()), capture.err_none);
    try expectCode(capture.validatePoint(128, 95, frame.width(), frame.height()), capture.err_region_out_of_bounds);
    try expectCode(
        capture.validateRegion(.{ .x = 120, .y = 0, .width = 16, .height = 1 }, frame.width(), frame.height()),
        capture.err_region_out_of_bounds,
    );

    // The other source: an offscreen target, whose rows are stored bottom-up
    // and whose alpha the app chose.
    const target = backend.loadRenderTexture(32, 16) orelse return error.RenderTextureUnavailable;
    defer backend.unloadRenderTexture(target);

    rl.BeginDrawing();
    backend.beginTextureMode(target);
    backend.clearBackground(transparent);
    backend.drawRectangle(.{ .x = 0, .y = 0, .width = 8, .height = 8, .color = red });
    backend.drawRectangle(.{ .x = 24, .y = 8, .width = 8, .height = 8, .color = green });
    backend.endTextureMode();
    rl.EndDrawing();

    var offscreen = backend.readRenderTexture(target) orelse return error.RenderTextureReadFailed;
    defer offscreen.deinit();
    if (offscreen.width() != 32 or offscreen.height() != 16) return error.RenderTextureSizeMismatch;
    const target_pixels = offscreen.pixels();

    // Red was drawn at the target's top-left. Bottom-up rows would put it at
    // the bottom and leave this transparent.
    try expectChannels("target (2, 2)", capture.pixelAt(target_pixels, offscreen.width(), 2, 2), red);
    try expectChannels("target (28, 12)", capture.pixelAt(target_pixels, offscreen.width(), 28, 12), green);
    // Alpha survives here, where the framebuffer readback forces it opaque.
    try expectChannels("target (16, 4)", capture.pixelAt(target_pixels, offscreen.width(), 16, 4), transparent);

    const corner = capture.Region{ .x = 0, .y = 0, .width = 4, .height = 4 };
    try expectCode(capture.validateRegion(corner, offscreen.width(), offscreen.height()), capture.err_none);
    var corner_bytes: [4 * 4 * 4]u8 = undefined;
    capture.copyRegion(&corner_bytes, target_pixels, offscreen.width(), corner);
    try expectRegionUniform("target top-left corner", &corner_bytes, red);

    capture.copyRegion(&corner_bytes, target_pixels, offscreen.width(), .{ .x = 28, .y = 0, .width = 4, .height = 4 });
    try expectRegionUniform("target top-right corner", &corner_bytes, transparent);
}

/// Render representative primitives and assert exact framebuffer pixels.
pub fn main() !void {
    rl.SetConfigFlags(rl.FLAG_WINDOW_HIDDEN | rl.FLAG_WINDOW_UNDECORATED);
    rl.InitWindow(128, 96, "roc-ray graphical smoke");
    if (!rl.IsWindowReady()) return error.WindowUnavailable;
    defer rl.CloseWindow();

    var metric_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer metric_arena.deinit();
    try expectNativeFontMetricParity(metric_arena.allocator());

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

    // One batched call has to be indistinguishable from the same instances
    // drawn one at a time, so each instance below varies a different field:
    // source region, destination size, tint, and list order. Instance 3
    // overlaps instance 0 and must win, because the loop draws in list order.
    const instances = [_]abi.DrawHostDraw_texture_instancesArg0Instances{
        .{
            .source = .{ .x = 0, .y = 0, .width = 8, .height = 8 },
            .dest = .{ .x = 4, .y = 52, .width = 8, .height = 8 },
            .origin = .{ .x = 0, .y = 0 },
            .rotation = 0,
            .tint = white,
        },
        .{
            .source = .{ .x = 8, .y = 0, .width = 8, .height = 8 },
            .dest = .{ .x = 20, .y = 52, .width = 8, .height = 8 },
            .origin = .{ .x = 0, .y = 0 },
            .rotation = 0,
            .tint = white,
        },
        .{
            .source = .{ .x = 0, .y = 0, .width = 8, .height = 8 },
            .dest = .{ .x = 36, .y = 52, .width = 16, .height = 8 },
            .origin = .{ .x = 0, .y = 0 },
            .rotation = 0,
            .tint = Color{ .r = 0, .g = 0, .b = 255, .a = 255 },
        },
        .{
            .source = .{ .x = 8, .y = 0, .width = 8, .height = 8 },
            .dest = .{ .x = 4, .y = 52, .width = 4, .height = 8 },
            .origin = .{ .x = 0, .y = 0 },
            .rotation = 0,
            .tint = white,
        },
    };
    backend.drawTextureInstances(atlas, &instances);

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

    // Read the frame back before `EndDrawing` swaps it away, for the reason
    // `captureRoundTrip` documents: after the swap the back buffer's contents
    // are undefined, which on macOS reads back as an empty buffer.
    var shot = backend.captureFramebuffer() orelse return error.CaptureUnavailable;
    defer shot.deinit();
    rl.EndDrawing();

    const screen = shot.image;
    try expectPixel(screen, 8, 8, red);
    try expectPixel(screen, 2, 2, black);
    try expectPixel(screen, 30, 10, green);
    try expectPixel(screen, 30, 36, yellow);
    try expectPixel(screen, 52, 10, blue);
    try expectPixel(screen, 48, 36, blue);
    try expectPixel(screen, 56, 36, red);
    try expectPixel(screen, 5, 56, blue);
    try expectPixel(screen, 10, 56, red);
    try expectPixel(screen, 24, 56, blue);
    try expectPixel(screen, 34, 56, black);
    try expectPixel(screen, 44, 56, instance_tinted);
    // This point is texture v=0.6 under the exact homography, but v<0.5
    // under the old two-triangle affine mapping. The custom green channel also
    // proves projective drawing preserved the caller's fragment shader.
    try expectPixel(screen, 72, 43, projective_blue);

    try captureRoundTrip();
    try downscaleRoundTrip();
    try renderTargetExportRoundTrip();
    try pixelReadbackRoundTrip();
}
