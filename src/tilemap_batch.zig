//! Allocation-free iteration for one borrowed flat tilemap render plan.
//!
//! The Roc host and native graphical smoke test share this path so culling,
//! role selection, atlas lookup, origin placement, and Tiled flips cannot drift.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");

/// Select one layer by its prepared index.
pub const selector_layer: u8 = 0;
/// Select every layer matching one drawable role.
pub const selector_role: u8 = 1;
/// Select every ordinary drawable layer.
pub const selector_all: u8 = 2;
/// Prepared role code for collision layers that remain drawable.
pub const role_solid: u8 = 1;
/// Prepared role code excluded from ordinary role/all drawing.
pub const role_hidden: u8 = 2;
/// Tiled global-ID horizontal flip flag.
pub const flip_horizontal: u64 = 0x8000_0000;
/// Tiled global-ID vertical flip flag.
pub const flip_vertical: u64 = 0x4000_0000;
/// Tiled global-ID anti-diagonal flip flag.
pub const flip_diagonal: u64 = 0x2000_0000;
/// Tiled global-ID payload after stripping all transform flags.
pub const gid_mask: u64 = 0x0fff_ffff;

/// One resolved tile quad submitted by the batch iterator.
pub const Quad = struct {
    raw_gid: u64,
    texture_token: u64,
    source: abi.MathRect,
    top_left: abi.MathVec2,
    bottom_left: abi.MathVec2,
    bottom_right: abi.MathVec2,
    top_right: abi.MathVec2,
};

fn layerSelected(args: anytype, layer_index: usize, layer: anytype) bool {
    if (!layer.visible) return false;
    return switch (args.selector_kind) {
        selector_layer => args.selector_value == layer_index,
        selector_role => args.selector_value < role_hidden and layer.role == args.selector_value,
        selector_all => layer.role <= role_solid,
        else => false,
    };
}

fn tilesetIndexForGid(tilesets: anytype, gid: u64) ?usize {
    var found: ?usize = null;
    for (tilesets, 0..) |tileset, index| {
        if (gid >= tileset.first_gid) found = index;
    }
    return found;
}

fn transformedCorner(dest: abi.MathRect, corner_x: f32, corner_y: f32, raw_gid: u64) abi.MathVec2 {
    const diagonal = (raw_gid & flip_diagonal) != 0;
    const horizontal = (raw_gid & flip_horizontal) != 0;
    const vertical = (raw_gid & flip_vertical) != 0;
    const diagonal_x = if (diagonal) 1 - corner_y else corner_x;
    const diagonal_y = if (diagonal) 1 - corner_x else corner_y;
    const x = if (horizontal) 1 - diagonal_x else diagonal_x;
    const y = if (vertical) 1 - diagonal_y else diagonal_y;
    return .{ .x = dest.x + x * dest.width, .y = dest.y + y * dest.height };
}

fn drawGid(args: anytype, context: anytype, submit: anytype, textureToken: anytype, raw_gid: u64, col: u64, row: u64) bool {
    const gid = raw_gid & gid_mask;
    if (gid == 0) return false;
    const tileset_index = tilesetIndexForGid(args.tilesets, gid) orelse return false;
    const tileset = args.tilesets[tileset_index];
    const columns = @max(tileset.columns, 1);
    const local = gid - tileset.first_gid;
    const source: abi.MathRect = .{
        .x = @as(f32, @floatFromInt(local % columns)) * tileset.tile_width,
        .y = @as(f32, @floatFromInt(local / columns)) * tileset.tile_height,
        .width = tileset.tile_width,
        .height = tileset.tile_height,
    };
    const dest: abi.MathRect = .{
        .x = args.origin_x + @as(f32, @floatFromInt(col)) * args.map_tile_width,
        .y = args.origin_y + @as(f32, @floatFromInt(row)) * args.map_tile_height,
        .width = args.map_tile_width,
        .height = args.map_tile_height,
    };
    return submit(context, Quad{
        .raw_gid = raw_gid,
        .texture_token = textureToken(tileset),
        .source = source,
        .top_left = transformedCorner(dest, 0, 0, raw_gid),
        .bottom_left = transformedCorner(dest, 0, 1, raw_gid),
        .bottom_right = transformedCorner(dest, 1, 1, raw_gid),
        .top_right = transformedCorner(dest, 1, 0, raw_gid),
    });
}

fn drawLayer(args: anytype, context: anytype, submit: anytype, textureToken: anytype, layer: anytype) usize {
    if (layer.width == 0 or layer.height == 0 or layer.gid_count == 0) return 0;
    const min_col = if (args.culled) args.min_col else 0;
    const min_row = if (args.culled) args.min_row else 0;
    const max_col = @min(if (args.culled) args.max_col else layer.width - 1, layer.width - 1);
    const max_row = @min(if (args.culled) args.max_row else layer.height - 1, layer.height - 1);
    if (min_col > max_col or min_row > max_row) return 0;

    var submitted: usize = 0;
    var row = min_row;
    while (true) {
        var col = min_col;
        while (true) {
            if (std.math.mul(u64, row, layer.width)) |row_offset| {
                if (std.math.add(u64, row_offset, col)) |cell_offset| {
                    if (cell_offset < layer.gid_count) {
                        if (std.math.add(u64, layer.gid_start, cell_offset)) |gid_index_u64| {
                            if (std.math.cast(usize, gid_index_u64)) |gid_index| {
                                if (gid_index < args.gids.len and drawGid(args, context, submit, textureToken, args.gids[gid_index], col, row)) {
                                    submitted += 1;
                                }
                            }
                        } else |_| {}
                    }
                } else |_| {}
            } else |_| {}
            if (col == max_col) break;
            col += 1;
        }
        if (row == max_row) break;
        row += 1;
    }
    return submitted;
}

/// Draw every selected tile from borrowed slices, returning accepted quads.
pub fn draw(args: anytype, context: anytype, submit: anytype, textureToken: anytype) usize {
    var submitted: usize = 0;
    for (args.layers, 0..) |layer, layer_index| {
        if (layerSelected(args, layer_index, layer)) {
            submitted += drawLayer(args, context, submit, textureToken, layer);
        }
    }
    return submitted;
}
