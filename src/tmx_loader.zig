//! TMX/TSX loader for Tiled-authored maps.
//!
//! Parsing behavior is based on the TMX support in Jack-Ji/jok 0.16.0
//! `src/utils/tiled.zig` (MIT licensed), adapted to return flat data records
//! for Roc rather than renderer-coupled Jok resources.

const std = @import("std");
const xml = @import("xml.zig");

const Allocator = std.mem.Allocator;

/// TMX object shape code.
pub const ObjectKind = enum(u8) {
    rect = 0,
    point = 1,
    ellipse = 2,
    polygon = 3,
};

/// TMX property stored as both text and parsed scalar fields.
pub const Property = struct {
    name: []const u8,
    kind: u8,
    text: []const u8,
    number: f32,
    integer: i64,
    bool_value: bool,
};

/// Tileset metadata flattened from embedded TMX or external TSX.
pub const Tileset = struct {
    first_gid: u64,
    name: []const u8,
    tile_width: f32,
    tile_height: f32,
    tile_count: u64,
    columns: u64,
    image_source: []const u8,
    image_width: f32,
    image_height: f32,
    property_start: u64,
    property_count: u64,
};

/// Tile property range for a tileset tile GID.
pub const TileProperties = struct {
    gid: u64,
    property_start: u64,
    property_count: u64,
};

/// Tile layer metadata plus a range into `Map.gids`.
pub const Layer = struct {
    name: []const u8,
    width: u64,
    height: u64,
    gid_start: u64,
    gid_count: u64,
    property_start: u64,
    property_count: u64,
    visible: bool,
    opacity: f32,
};

/// 2D point used by polygon objects.
pub const Point = struct {
    x: f32,
    y: f32,
};

/// Object layer object metadata.
pub const Object = struct {
    id: u64,
    name: []const u8,
    type_name: []const u8,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    rotation: f32,
    kind: ObjectKind,
    point_start: u64,
    point_count: u64,
    property_start: u64,
    property_count: u64,
};

/// Flat parsed TMX data.
pub const RawMap = struct {
    width: u64,
    height: u64,
    tile_width: f32,
    tile_height: f32,
    map_property_start: u64,
    map_property_count: u64,
    tilesets: []Tileset,
    tile_properties: []TileProperties,
    layers: []Layer,
    gids: []u64,
    objects: []Object,
    points: []Point,
    properties: []Property,
};

/// Loaded map plus arena owning every slice in `raw`.
pub const Map = struct {
    arena: std.heap.ArenaAllocator,
    raw: RawMap,

    /// Free all loaded map memory.
    pub fn deinit(self: *Map) void {
        self.arena.deinit();
    }
};

/// TMX loader failures.
pub const LoadError = error{
    NotFound,
    ReadFailed,
    ParseFailed,
    Unsupported,
    OutOfMemory,
};

const max_file_bytes: usize = 16 * 1024 * 1024;
const property_string: u8 = 0;
const property_int: u8 = 1;
const property_float: u8 = 2;
const property_bool: u8 = 3;

const Builder = struct {
    allocator: Allocator,
    scratch: Allocator,
    io: std.Io,
    tilesets: std.ArrayList(Tileset) = .empty,
    tile_properties: std.ArrayList(TileProperties) = .empty,
    layers: std.ArrayList(Layer) = .empty,
    gids: std.ArrayList(u64) = .empty,
    objects: std.ArrayList(Object) = .empty,
    points: std.ArrayList(Point) = .empty,
    properties: std.ArrayList(Property) = .empty,

    fn appendPropertyRange(self: *Builder, element: *xml.Element) LoadError!Range {
        const start = self.properties.items.len;
        if (element.findChildByTag("properties")) |properties_element| {
            var it = properties_element.findChildrenByTag("property");
            while (it.next()) |property_element| {
                try self.properties.append(self.allocator, try parseProperty(self.allocator, property_element));
            }
        }
        return .{ .start = intCastU64(start), .count = intCastU64(self.properties.items.len - start) };
    }

    fn appendPolygonPoints(self: *Builder, object_x: f32, object_y: f32, text: []const u8) LoadError!Range {
        const start = self.points.items.len;
        var pairs = std.mem.tokenizeAny(u8, text, " \n\t\r");
        while (pairs.next()) |pair| {
            const comma = std.mem.indexOfScalar(u8, pair, ',') orelse return error.ParseFailed;
            const x = parseF32(pair[0..comma]) catch return error.ParseFailed;
            const y = parseF32(pair[comma + 1 ..]) catch return error.ParseFailed;
            try self.points.append(self.allocator, .{ .x = object_x + x, .y = object_y + y });
        }
        return .{ .start = intCastU64(start), .count = intCastU64(self.points.items.len - start) };
    }
};

const Range = struct {
    start: u64,
    count: u64,
};

/// Load and parse a TMX file from disk.
pub fn load(allocator: Allocator, io_handle: std.Io, path: []const u8) LoadError!Map {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var builder = Builder{
        .allocator = arena.allocator(),
        .scratch = allocator,
        .io = io_handle,
    };

    const source = try readFile(allocator, io_handle, path);
    defer allocator.free(source);

    var doc = xml.parse(allocator, source) catch return error.ParseFailed;
    defer doc.deinit();

    const raw = try parseRoot(&builder, path, doc.root);
    return .{ .arena = arena, .raw = raw };
}

/// Parse TMX text for tests or tools that already have file contents.
pub fn parseString(allocator: Allocator, text: []const u8) LoadError!Map {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var builder = Builder{
        .allocator = arena.allocator(),
        .scratch = allocator,
        .io = std.Io.failing,
    };

    var doc = xml.parse(allocator, text) catch return error.ParseFailed;
    defer doc.deinit();

    const raw = try parseRoot(&builder, "inline.tmx", doc.root);
    return .{ .arena = arena, .raw = raw };
}

fn parseRoot(builder: *Builder, path: []const u8, root: *xml.Element) LoadError!RawMap {
    if (!std.mem.eql(u8, root.tag, "map")) return error.ParseFailed;

    const orientation = root.getAttribute("orientation") orelse "orthogonal";
    if (!std.mem.eql(u8, orientation, "orthogonal")) return error.Unsupported;
    if (attrEquals(root, "infinite", "1")) return error.Unsupported;

    const map_property_range = try builder.appendPropertyRange(root);

    var element_it = root.elements();
    while (element_it.next()) |child| {
        if (std.mem.eql(u8, child.tag, "tileset")) {
            try parseTileset(builder, path, child);
        } else if (std.mem.eql(u8, child.tag, "layer")) {
            try parseLayer(builder, child);
        } else if (std.mem.eql(u8, child.tag, "objectgroup")) {
            try parseObjectGroup(builder, child);
        }
    }

    return .{
        .width = try requiredU64(root, "width"),
        .height = try requiredU64(root, "height"),
        .tile_width = try requiredF32(root, "tilewidth"),
        .tile_height = try requiredF32(root, "tileheight"),
        .map_property_start = map_property_range.start,
        .map_property_count = map_property_range.count,
        .tilesets = try builder.tilesets.toOwnedSlice(builder.allocator),
        .tile_properties = try builder.tile_properties.toOwnedSlice(builder.allocator),
        .layers = try builder.layers.toOwnedSlice(builder.allocator),
        .gids = try builder.gids.toOwnedSlice(builder.allocator),
        .objects = try builder.objects.toOwnedSlice(builder.allocator),
        .points = try builder.points.toOwnedSlice(builder.allocator),
        .properties = try builder.properties.toOwnedSlice(builder.allocator),
    };
}

fn parseTileset(builder: *Builder, map_path: []const u8, element: *xml.Element) LoadError!void {
    const first_gid = try requiredU64(element, "firstgid");

    if (element.getAttribute("source")) |source| {
        const tileset_path = try resolveRelative(builder.allocator, map_path, source);
        const file_text = try readFile(builder.scratch, builder.io, tileset_path);
        defer builder.scratch.free(file_text);

        var doc = xml.parse(builder.scratch, file_text) catch return error.ParseFailed;
        defer doc.deinit();
        if (!std.mem.eql(u8, doc.root.tag, "tileset")) return error.ParseFailed;
        try parseTilesetElement(builder, tileset_path, first_gid, doc.root);
    } else {
        try parseTilesetElement(builder, map_path, first_gid, element);
    }
}

fn parseTilesetElement(builder: *Builder, tileset_path: []const u8, first_gid: u64, element: *xml.Element) LoadError!void {
    const properties = try builder.appendPropertyRange(element);
    const image = element.findChildByTag("image") orelse return error.Unsupported;
    if (image.findChildByTag("data") != null) return error.Unsupported;

    const image_source = image.getAttribute("source") orelse return error.Unsupported;
    const resolved_image = try resolveRelative(builder.allocator, tileset_path, image_source);

    try parseTilePropertyRanges(builder, element, first_gid);

    try builder.tilesets.append(builder.allocator, .{
        .first_gid = first_gid,
        .name = try dupeAttr(builder.allocator, element, "name", ""),
        .tile_width = try requiredF32(element, "tilewidth"),
        .tile_height = try requiredF32(element, "tileheight"),
        .tile_count = try optionalU64(element, "tilecount", 0),
        .columns = try optionalU64(element, "columns", 0),
        .image_source = resolved_image,
        .image_width = try optionalF32(image, "width", 0),
        .image_height = try optionalF32(image, "height", 0),
        .property_start = properties.start,
        .property_count = properties.count,
    });
}

fn parseTilePropertyRanges(builder: *Builder, element: *xml.Element, first_gid: u64) LoadError!void {
    var it = element.findChildrenByTag("tile");
    while (it.next()) |tile_element| {
        const local_id = try requiredU64(tile_element, "id");
        const properties = try builder.appendPropertyRange(tile_element);
        try builder.tile_properties.append(builder.allocator, .{
            .gid = first_gid + local_id,
            .property_start = properties.start,
            .property_count = properties.count,
        });
    }
}

fn parseLayer(builder: *Builder, element: *xml.Element) LoadError!void {
    const data = element.findChildByTag("data") orelse return error.ParseFailed;
    const encoding = data.getAttribute("encoding") orelse return error.Unsupported;
    if (!std.mem.eql(u8, encoding, "csv")) return error.Unsupported;
    if (data.getAttribute("compression") != null) return error.Unsupported;

    const properties = try builder.appendPropertyRange(element);
    const gid_start = builder.gids.items.len;
    const text = data.text(builder.scratch) catch return error.ParseFailed;
    defer builder.scratch.free(text);
    try parseCsvGids(builder, text);

    const width = try requiredU64(element, "width");
    const height = try requiredU64(element, "height");
    const expected = width * height;
    const count = builder.gids.items.len - gid_start;
    if (count != expected) return error.ParseFailed;

    try builder.layers.append(builder.allocator, .{
        .name = try dupeAttr(builder.allocator, element, "name", ""),
        .width = width,
        .height = height,
        .gid_start = intCastU64(gid_start),
        .gid_count = intCastU64(count),
        .property_start = properties.start,
        .property_count = properties.count,
        .visible = !attrEquals(element, "visible", "0"),
        .opacity = try optionalF32(element, "opacity", 1),
    });
}

fn parseCsvGids(builder: *Builder, text: []const u8) LoadError!void {
    var items = std.mem.tokenizeAny(u8, text, ", \n\t\r");
    while (items.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \n\t\r");
        if (trimmed.len == 0) continue;
        try builder.gids.append(builder.allocator, parseU64(trimmed) catch return error.ParseFailed);
    }
}

fn parseObjectGroup(builder: *Builder, element: *xml.Element) LoadError!void {
    var it = element.findChildrenByTag("object");
    while (it.next()) |object_element| {
        try parseObject(builder, object_element);
    }
}

fn parseObject(builder: *Builder, element: *xml.Element) LoadError!void {
    const x = try optionalF32(element, "x", 0);
    const y = try optionalF32(element, "y", 0);
    var kind: ObjectKind = .rect;
    var point_range = Range{ .start = intCastU64(builder.points.items.len), .count = 0 };

    if (element.findChildByTag("point") != null) {
        kind = .point;
    } else if (element.findChildByTag("ellipse") != null) {
        kind = .ellipse;
    } else if (element.findChildByTag("polygon")) |polygon| {
        kind = .polygon;
        point_range = try builder.appendPolygonPoints(x, y, polygon.getAttribute("points") orelse return error.ParseFailed);
    }

    const properties = try builder.appendPropertyRange(element);
    try builder.objects.append(builder.allocator, .{
        .id = try optionalU64(element, "id", intCastU64(builder.objects.items.len)),
        .name = try dupeAttr(builder.allocator, element, "name", ""),
        .type_name = try dupeObjectType(builder.allocator, element),
        .x = x,
        .y = y,
        .width = try optionalF32(element, "width", 0),
        .height = try optionalF32(element, "height", 0),
        .rotation = try optionalF32(element, "rotation", 0),
        .kind = kind,
        .point_start = point_range.start,
        .point_count = point_range.count,
        .property_start = properties.start,
        .property_count = properties.count,
    });
}

fn parseProperty(allocator: Allocator, element: *xml.Element) LoadError!Property {
    const name = try dupeAttr(allocator, element, "name", "");
    const type_name = element.getAttribute("type") orelse "string";
    const value = if (element.getAttribute("value")) |value_attr| value_attr else blk: {
        const text = element.text(allocator) catch return error.ParseFailed;
        break :blk text;
    };
    const text = try allocator.dupe(u8, value);

    if (std.mem.eql(u8, type_name, "int")) {
        const parsed = parseI64(value) catch return error.ParseFailed;
        return .{ .name = name, .kind = property_int, .text = text, .number = @floatFromInt(parsed), .integer = parsed, .bool_value = parsed != 0 };
    }
    if (std.mem.eql(u8, type_name, "float")) {
        const parsed = parseF32(value) catch return error.ParseFailed;
        return .{ .name = name, .kind = property_float, .text = text, .number = parsed, .integer = @intFromFloat(parsed), .bool_value = parsed != 0 };
    }
    if (std.mem.eql(u8, type_name, "bool")) {
        const parsed = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
        return .{ .name = name, .kind = property_bool, .text = text, .number = if (parsed) 1 else 0, .integer = if (parsed) 1 else 0, .bool_value = parsed };
    }

    return .{ .name = name, .kind = property_string, .text = text, .number = 0, .integer = 0, .bool_value = false };
}

fn readFile(allocator: Allocator, io_handle: std.Io, path: []const u8) LoadError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io_handle, path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => error.NotFound,
        else => error.ReadFailed,
    };
}

fn resolveRelative(allocator: Allocator, base_path: []const u8, source: []const u8) LoadError![]const u8 {
    if (std.fs.path.isAbsolute(source)) return allocator.dupe(u8, source) catch return error.OutOfMemory;
    const dirname = std.fs.path.dirname(base_path) orelse ".";
    return std.fs.path.join(allocator, &.{ dirname, source }) catch return error.OutOfMemory;
}

fn dupeObjectType(allocator: Allocator, element: *xml.Element) LoadError![]const u8 {
    if (element.getAttribute("type")) |type_name| return allocator.dupe(u8, type_name) catch return error.OutOfMemory;
    if (element.getAttribute("class")) |class_name| return allocator.dupe(u8, class_name) catch return error.OutOfMemory;
    return allocator.dupe(u8, "") catch return error.OutOfMemory;
}

fn dupeAttr(allocator: Allocator, element: *xml.Element, name: []const u8, default: []const u8) LoadError![]const u8 {
    return allocator.dupe(u8, element.getAttribute(name) orelse default) catch return error.OutOfMemory;
}

fn requiredU64(element: *xml.Element, name: []const u8) LoadError!u64 {
    return parseU64(element.getAttribute(name) orelse return error.ParseFailed) catch return error.ParseFailed;
}

fn optionalU64(element: *xml.Element, name: []const u8, default: u64) LoadError!u64 {
    return parseU64(element.getAttribute(name) orelse return default) catch return error.ParseFailed;
}

fn requiredF32(element: *xml.Element, name: []const u8) LoadError!f32 {
    return parseF32(element.getAttribute(name) orelse return error.ParseFailed) catch return error.ParseFailed;
}

fn optionalF32(element: *xml.Element, name: []const u8, default: f32) LoadError!f32 {
    return parseF32(element.getAttribute(name) orelse return default) catch return error.ParseFailed;
}

fn parseU64(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n\t\r"), 10);
}

fn parseI64(text: []const u8) !i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, " \n\t\r"), 10);
}

fn parseF32(text: []const u8) !f32 {
    return std.fmt.parseFloat(f32, std.mem.trim(u8, text, " \n\t\r"));
}

fn attrEquals(element: *xml.Element, name: []const u8, expected: []const u8) bool {
    return if (element.getAttribute(name)) |actual| std.mem.eql(u8, actual, expected) else false;
}

fn intCastU64(value: usize) u64 {
    return @intCast(value);
}

test "tmx parses map attributes and CSV layer gids" {
    var map = try parseString(std.testing.allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<map version="1.10" tiledversion="1.10.2" orientation="orthogonal" renderorder="right-down" width="2" height="2" tilewidth="16" tileheight="16" infinite="0">
        \\ <tileset firstgid="1" name="demo" tilewidth="16" tileheight="16" tilecount="4" columns="2">
        \\  <image source="tiles.png" width="32" height="32"/>
        \\ </tileset>
        \\ <layer id="1" name="Ground" width="2" height="2">
        \\  <data encoding="csv">1,0,2,3</data>
        \\ </layer>
        \\</map>
    );
    defer map.deinit();

    try std.testing.expectEqual(@as(u64, 2), map.raw.width);
    try std.testing.expectEqual(@as(u64, 1), map.raw.tilesets.len);
    try std.testing.expectEqualStrings("./tiles.png", map.raw.tilesets[0].image_source);
    try std.testing.expectEqual(@as(u64, 4), map.raw.gids.len);
    try std.testing.expectEqual(@as(u64, 2), map.raw.gids[2]);
}

test "tmx parses properties and object layers" {
    var map = try parseString(std.testing.allocator,
        \\<map orientation="orthogonal" width="1" height="1" tilewidth="16" tileheight="16">
        \\ <properties><property name="theme" value="cave"/></properties>
        \\ <objectgroup name="Objects">
        \\  <object id="7" name="gem-a" type="gem" x="10" y="20">
        \\   <point/>
        \\   <properties>
        \\    <property name="value" type="int" value="5"/>
        \\    <property name="floating" type="bool" value="true"/>
        \\   </properties>
        \\  </object>
        \\  <object id="8" type="hazard" x="0" y="0">
        \\   <polygon points="0,0 16,0 8,12"/>
        \\  </object>
        \\ </objectgroup>
        \\</map>
    );
    defer map.deinit();

    try std.testing.expectEqual(@as(u64, 1), map.raw.map_property_count);
    try std.testing.expectEqualStrings("theme", map.raw.properties[0].name);
    try std.testing.expectEqual(@as(usize, 2), map.raw.objects.len);
    try std.testing.expectEqual(ObjectKind.point, map.raw.objects[0].kind);
    try std.testing.expectEqual(ObjectKind.polygon, map.raw.objects[1].kind);
    try std.testing.expectEqual(@as(usize, 3), map.raw.points.len);
    try std.testing.expectEqual(@as(i64, 5), map.raw.properties[1].integer);
    try std.testing.expect(map.raw.properties[2].bool_value);
}

test "tmx resolves external TSX paths relative to TMX" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "tiles.tsx",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<tileset version="1.10" name="demo" tilewidth="16" tileheight="16" tilecount="4" columns="2">
        \\ <image source="images/tiles.png" width="32" height="32"/>
        \\</tileset>
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "map.tmx",
        .data =
        \\<map orientation="orthogonal" width="1" height="1" tilewidth="16" tileheight="16">
        \\ <tileset firstgid="5" source="tiles.tsx"/>
        \\ <layer name="Ground" width="1" height="1"><data encoding="csv">5</data></layer>
        \\</map>
        ,
    });

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/map.tmx", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    var map = try load(std.testing.allocator, std.testing.io, path);
    defer map.deinit();

    const expected_image_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/images/tiles.png", .{tmp.sub_path});
    defer std.testing.allocator.free(expected_image_path);

    try std.testing.expectEqual(@as(u64, 5), map.raw.tilesets[0].first_gid);
    try std.testing.expectEqualStrings(expected_image_path, map.raw.tilesets[0].image_source);
}

test "tmx rejects unsupported encodings and orientations" {
    try std.testing.expectError(error.Unsupported, parseString(std.testing.allocator,
        \\<map orientation="isometric" width="1" height="1" tilewidth="16" tileheight="16"/>
    ));

    try std.testing.expectError(error.Unsupported, parseString(std.testing.allocator,
        \\<map orientation="orthogonal" width="1" height="1" tilewidth="16" tileheight="16">
        \\ <layer name="Ground" width="1" height="1"><data encoding="base64">AAAA</data></layer>
        \\</map>
    ));
}
