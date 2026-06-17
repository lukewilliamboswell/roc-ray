//! Small XML document parser for TMX/TSX loading.
//!
//! The parser shape is adapted from Jack-Ji/jok 0.16.0
//! `src/utils/xml.zig`, which is MIT licensed. The implementation here is
//! kept local so the TMX loader can return roc-ray-specific flat data without
//! depending on Jok renderer types.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// XML attribute with unescaped value text.
pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

/// XML child content.
pub const Content = union(enum) {
    char_data: []const u8,
    comment: []const u8,
    element: *Element,
};

/// Parsed XML element.
pub const Element = struct {
    tag: []const u8,
    attributes: []Attribute = &.{},
    children: []Content = &.{},

    /// Return the value for an attribute name.
    pub fn getAttribute(self: Element, name: []const u8) ?[]const u8 {
        for (self.attributes) |attribute| {
            if (std.mem.eql(u8, attribute.name, name)) return attribute.value;
        }
        return null;
    }

    /// Return an iterator over child elements.
    pub fn elements(self: Element) ElementIterator {
        return .{ .children = self.children, .index = 0 };
    }

    /// Return the first direct child element with the requested tag.
    pub fn findChildByTag(self: Element, tag: []const u8) ?*Element {
        var it = self.findChildrenByTag(tag);
        return it.next();
    }

    /// Return an iterator over direct child elements matching `tag`.
    pub fn findChildrenByTag(self: Element, tag: []const u8) FindChildrenByTagIterator {
        return .{ .inner = self.elements(), .tag = tag };
    }

    /// Return the concatenated direct character data for this element.
    pub fn text(self: Element, allocator: Allocator) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        for (self.children) |child| {
            if (child == .char_data) try result.appendSlice(allocator, child.char_data);
        }

        return result.toOwnedSlice(allocator);
    }
};

/// Iterator over child elements.
pub const ElementIterator = struct {
    children: []Content,
    index: usize,

    /// Return the next child element.
    pub fn next(self: *ElementIterator) ?*Element {
        while (self.index < self.children.len) {
            const index = self.index;
            self.index += 1;
            if (self.children[index] == .element) return self.children[index].element;
        }
        return null;
    }
};

/// Iterator over child elements filtered by tag.
pub const FindChildrenByTagIterator = struct {
    inner: ElementIterator,
    tag: []const u8,

    /// Return the next matching child element.
    pub fn next(self: *FindChildrenByTagIterator) ?*Element {
        while (self.inner.next()) |element| {
            if (std.mem.eql(u8, element.tag, self.tag)) return element;
        }
        return null;
    }
};

/// Parsed XML document. All element slices live in the arena.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    xml_decl: ?*Element,
    root: *Element,

    /// Free all memory owned by the parsed document.
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

/// XML parse failures.
pub const ParseError = error{
    IllegalCharacter,
    UnexpectedEof,
    UnexpectedCharacter,
    UnclosedValue,
    UnclosedComment,
    InvalidName,
    InvalidEntity,
    NonMatchingClosingTag,
    InvalidDocument,
    OutOfMemory,
};

const Parser = struct {
    source: []const u8,
    offset: usize = 0,
    line: usize = 1,
    column: usize = 1,

    fn init(source: []const u8) Parser {
        return .{ .source = source };
    }

    fn peek(self: Parser) ?u8 {
        if (self.offset >= self.source.len) return null;
        return self.source[self.offset];
    }

    fn consume(self: *Parser) !u8 {
        if (self.offset >= self.source.len) return error.UnexpectedEof;
        return self.consumeNoEof();
    }

    fn consumeNoEof(self: *Parser) u8 {
        std.debug.assert(self.offset < self.source.len);
        const c = self.source[self.offset];
        self.offset += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    fn eat(self: *Parser, expected: u8) bool {
        self.expect(expected) catch return false;
        return true;
    }

    fn expect(self: *Parser, expected: u8) !void {
        const actual = self.peek() orelse return error.UnexpectedEof;
        if (actual != expected) return error.UnexpectedCharacter;
        _ = self.consumeNoEof();
    }

    fn eatStr(self: *Parser, expected: []const u8) bool {
        self.expectStr(expected) catch return false;
        return true;
    }

    fn expectStr(self: *Parser, expected: []const u8) !void {
        if (self.source.len < self.offset + expected.len) return error.UnexpectedEof;
        if (!std.mem.startsWith(u8, self.source[self.offset..], expected)) return error.UnexpectedCharacter;
        for (expected) |_| _ = self.consumeNoEof();
    }

    fn eatWs(self: *Parser) bool {
        var found = false;
        while (self.peek()) |ch| {
            switch (ch) {
                ' ', '\t', '\n', '\r' => {
                    found = true;
                    _ = self.consumeNoEof();
                },
                else => return found,
            }
        }
        return found;
    }
};

const ElementKind = enum { xml_decl, element };

/// Parse a complete XML document.
pub fn parse(backing_allocator: Allocator, source: []const u8) ParseError!Document {
    var parser = Parser.init(source);
    var document = Document{
        .arena = std.heap.ArenaAllocator.init(backing_allocator),
        .xml_decl = null,
        .root = undefined,
    };
    errdefer document.deinit();

    const allocator = document.arena.allocator();
    _ = parser.eatWs();
    try skipComments(&parser, allocator);
    document.xml_decl = try parseElement(&parser, allocator, .xml_decl);
    _ = parser.eatWs();
    try skipComments(&parser, allocator);
    document.root = (try parseElement(&parser, allocator, .element)) orelse return error.InvalidDocument;
    _ = parser.eatWs();
    try skipComments(&parser, allocator);
    _ = parser.eatWs();
    if (parser.peek() != null) return error.InvalidDocument;

    return document;
}

fn parseElement(parser: *Parser, allocator: Allocator, comptime kind: ElementKind) ParseError!?*Element {
    const start = parser.offset;
    const tag = switch (kind) {
        .xml_decl => blk: {
            if (!parser.eatStr("<?xml")) return null;
            break :blk "xml";
        },
        .element => blk: {
            if (!parser.eat('<')) return null;
            const parsed = parseNameNoDupe(parser) catch {
                parser.offset = start;
                return null;
            };
            break :blk parsed;
        },
    };

    var attributes = std.ArrayList(Attribute).empty;
    errdefer attributes.deinit(allocator);
    var children = std.ArrayList(Content).empty;
    errdefer children.deinit(allocator);

    while (true) {
        _ = parser.eatWs();
        switch (parser.peek() orelse return error.UnexpectedEof) {
            '/', '>', '?' => break,
            else => try attributes.append(allocator, try parseAttribute(parser, allocator)),
        }
    }

    switch (kind) {
        .xml_decl => try parser.expectStr("?>"),
        .element => {
            if (!parser.eatStr("/>")) {
                try parser.expect('>');
                while (true) {
                    if (parser.peek() == null) return error.UnexpectedEof;
                    if (std.mem.startsWith(u8, parser.source[parser.offset..], "</")) break;
                    try children.append(allocator, try parseContent(parser, allocator));
                }

                try parser.expectStr("</");
                const closing_tag = try parseNameNoDupe(parser);
                if (!std.mem.eql(u8, tag, closing_tag)) return error.NonMatchingClosingTag;
                _ = parser.eatWs();
                try parser.expect('>');
            }
        },
    }

    const element = try allocator.create(Element);
    element.* = .{
        .tag = try allocator.dupe(u8, tag),
        .attributes = try attributes.toOwnedSlice(allocator),
        .children = try children.toOwnedSlice(allocator),
    };
    return element;
}

fn parseContent(parser: *Parser, allocator: Allocator) ParseError!Content {
    if (try parseCharData(parser, allocator)) |char_data| return .{ .char_data = char_data };
    if (try parseComment(parser, allocator)) |comment| return .{ .comment = comment };
    if (try parseElement(parser, allocator, .element)) |element| return .{ .element = element };
    return error.UnexpectedCharacter;
}

fn parseAttribute(parser: *Parser, allocator: Allocator) ParseError!Attribute {
    const name = try parseNameNoDupe(parser);
    _ = parser.eatWs();
    try parser.expect('=');
    _ = parser.eatWs();
    const value = try parseAttributeValue(parser, allocator);
    return .{ .name = try allocator.dupe(u8, name), .value = value };
}

fn parseAttributeValue(parser: *Parser, allocator: Allocator) ParseError![]const u8 {
    const quote = try parser.consume();
    if (quote != '"' and quote != '\'') return error.UnexpectedCharacter;

    const begin = parser.offset;
    while (true) {
        const c = parser.consume() catch return error.UnclosedValue;
        if (c == quote) break;
    }
    const end = parser.offset - 1;
    return try unescape(allocator, parser.source[begin..end]);
}

fn parseNameNoDupe(parser: *Parser) ParseError![]const u8 {
    const begin = parser.offset;
    while (parser.peek()) |ch| {
        switch (ch) {
            ' ', '\t', '\n', '\r', '&', '"', '\'', '<', '>', '?', '=', '/' => break,
            else => _ = parser.consumeNoEof(),
        }
    }

    if (begin == parser.offset) return error.InvalidName;
    return parser.source[begin..parser.offset];
}

fn parseCharData(parser: *Parser, allocator: Allocator) ParseError!?[]const u8 {
    const begin = parser.offset;
    while (parser.peek()) |ch| {
        if (ch == '<') break;
        _ = parser.consumeNoEof();
    }
    if (begin == parser.offset) return null;
    return try unescape(allocator, parser.source[begin..parser.offset]);
}

fn skipComments(parser: *Parser, allocator: Allocator) ParseError!void {
    while ((try parseComment(parser, allocator)) != null) {
        _ = parser.eatWs();
    }
}

fn parseComment(parser: *Parser, allocator: Allocator) ParseError!?[]const u8 {
    if (!parser.eatStr("<!--")) return null;
    const begin = parser.offset;
    while (!parser.eatStr("-->")) {
        _ = parser.consume() catch return error.UnclosedComment;
    }
    return try allocator.dupe(u8, parser.source[begin .. parser.offset - "-->".len]);
}

fn unescape(allocator: Allocator, text: []const u8) ParseError![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '&') == null) return try allocator.dupe(u8, text);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '&') {
            try result.append(allocator, text[index]);
            index += 1;
            continue;
        }

        const end = std.mem.indexOfScalarPos(u8, text, index, ';') orelse return error.InvalidEntity;
        try appendEntity(allocator, &result, text[index + 1 .. end]);
        index = end + 1;
    }

    return result.toOwnedSlice(allocator);
}

fn appendEntity(allocator: Allocator, result: *std.ArrayList(u8), entity: []const u8) ParseError!void {
    if (std.mem.eql(u8, entity, "lt")) return result.append(allocator, '<');
    if (std.mem.eql(u8, entity, "gt")) return result.append(allocator, '>');
    if (std.mem.eql(u8, entity, "amp")) return result.append(allocator, '&');
    if (std.mem.eql(u8, entity, "apos")) return result.append(allocator, '\'');
    if (std.mem.eql(u8, entity, "quot")) return result.append(allocator, '"');

    if (std.mem.startsWith(u8, entity, "#x")) {
        const value = std.fmt.parseInt(u21, entity[2..], 16) catch return error.InvalidEntity;
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(value, &buffer) catch return error.InvalidEntity;
        return result.appendSlice(allocator, buffer[0..len]);
    }

    if (std.mem.startsWith(u8, entity, "#")) {
        const value = std.fmt.parseInt(u21, entity[1..], 10) catch return error.InvalidEntity;
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(value, &buffer) catch return error.InvalidEntity;
        return result.appendSlice(allocator, buffer[0..len]);
    }

    return error.InvalidEntity;
}

test "xml parses nested elements and attributes" {
    var doc = try parse(std.testing.allocator,
        \\<?xml version="1.0"?>
        \\<!-- top -->
        \\<map orientation="orthogonal">
        \\  <layer name="Ground"><data encoding="csv">1,2,3</data></layer>
        \\</map>
    );
    defer doc.deinit();

    try std.testing.expectEqualStrings("map", doc.root.tag);
    try std.testing.expectEqualStrings("orthogonal", doc.root.getAttribute("orientation").?);

    const layer = doc.root.findChildByTag("layer").?;
    try std.testing.expectEqualStrings("Ground", layer.getAttribute("name").?);
    try std.testing.expectEqualStrings("1,2,3", std.mem.trim(u8, try layer.findChildByTag("data").?.text(doc.arena.allocator()), " \n\t\r"));
}

test "xml unescapes standard entities" {
    var doc = try parse(std.testing.allocator, "<a value=\"&lt;&amp;&#65;\">Tom &amp; Jerry</a>");
    defer doc.deinit();

    try std.testing.expectEqualStrings("<&A", doc.root.getAttribute("value").?);
    try std.testing.expectEqualStrings("Tom & Jerry", try doc.root.text(doc.arena.allocator()));
}

test "xml rejects mismatched closing tags" {
    try std.testing.expectError(error.NonMatchingClosingTag, parse(std.testing.allocator, "<a></b>"));
}
