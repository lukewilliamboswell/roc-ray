//! A non-recursive enumeration of one opened, confined directory.
const std = @import("std");
const confined_path = @import("confined_path.zig");

/// Maximum number of entries advanced by one read.
pub const max_batch_entries = 64;
/// Maximum encoded batch size, with a kind byte and a NUL for every name.
pub const max_batch_bytes = max_batch_entries * (std.Io.Dir.max_name_bytes + 2);

comptime {
    if (max_batch_bytes > 64 * 1024) @compileError("directory cursor batch exceeds its documented byte bound");
}

/// Entry kinds in a listing. Mirrored in the Roc adapter.
pub const EntryKind = enum(u8) { file = 1, directory = 2, other = 3 };

/// Preserve file and directory kinds and report every other kind as Other.
pub fn entryKind(kind: std.Io.File.Kind) EntryKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        else => .other,
    };
}

/// Encoded bytes used by a batch, or the terminal outcome.
pub const Next = union(enum) {
    entries: usize,
    end,
    invalid_name,
    read_failed,
    unavailable,
};

const Terminal = enum {
    end,
    invalid_name,
    read_failed,
    unavailable,

    fn asNext(terminal: Terminal) Next {
        return switch (terminal) {
            .end => .end,
            .invalid_name => .invalid_name,
            .read_failed => .read_failed,
            .unavailable => .unavailable,
        };
    }
};

/// Retains one native directory until its end, an error, or explicit release.
pub const Cursor = struct {
    iterator: ?std.Io.Dir.Iterator,
    terminal: Terminal = .end,
    pub fn open(io: std.Io, root: []const u8, path: []const u8) !Cursor {
        const base = try confined_path.openRoot(io, root, false);
        defer base.close(io);
        const directory = try confined_path.openDir(io, base, path, .{ .iterate = true });
        return .{ .iterator = directory.iterateAssumeFirstIteration() };
    }

    pub fn close(cursor: *Cursor, io: std.Io) void {
        if (cursor.iterator) |*iterator| {
            iterator.reader.dir.close(io);
            cursor.iterator = null;
        }
    }

    pub fn terminalResult(cursor: *const Cursor) ?Next {
        return if (cursor.iterator == null) cursor.terminal.asNext() else null;
    }

    pub fn next(cursor: *Cursor, io: std.Io, output: *[max_batch_bytes]u8) Next {
        const iterator = if (cursor.iterator) |*it| it else return cursor.terminal.asNext();
        var used: usize = 0;
        for (0..max_batch_entries) |_| {
            const entry = iterator.next(io) catch |err| {
                const terminal: Terminal = switch (err) {
                    error.Canceled => .unavailable,
                    else => .read_failed,
                };
                return cursor.finish(io, terminal, used);
            } orelse return cursor.finish(io, .end, used);
            // Windows can return WTF-8 for a name with an unpaired surrogate.
            // POSIX names are arbitrary bytes. Neither can become a Roc Str.
            if (entry.name.len == 0 or entry.name.len > std.Io.Dir.max_name_bytes or
                !std.unicode.utf8ValidateSlice(entry.name))
            {
                return cursor.finish(io, .invalid_name, used);
            }
            output[used] = @backingInt(entryKind(entry.kind));
            @memcpy(output[used + 1 ..][0..entry.name.len], entry.name);
            used += entry.name.len + 2;
            output[used - 1] = 0;
        }
        return .{ .entries = used };
    }

    fn finish(cursor: *Cursor, io: std.Io, terminal: Terminal, used: usize) Next {
        cursor.close(io);
        cursor.terminal = terminal;
        return if (used > 0) .{ .entries = used } else terminal.asNext();
    }
};

test "cursor walks several bounded batches once and retains end" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const total = max_batch_entries * 2 + 3;
    for (0..total) |index| {
        var name_buffer: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "entry-{d}", .{index});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    }

    var real_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path_len = try tmp.dir.realPath(io, &real_path);
    var cursor = try Cursor.open(io, real_path[0..real_path_len], "");
    defer cursor.close(io);

    var seen: std.StaticBitSet(total) = .empty;
    var bytes: [max_batch_bytes]u8 = undefined;
    for ([_]usize{ max_batch_entries, max_batch_entries, 3 }) |expected_count| {
        const next_result = cursor.next(io, &bytes);
        try std.testing.expect(next_result == .entries);
        var encoded_entries = std.mem.splitScalar(u8, bytes[0 .. next_result.entries - 1], 0);
        var count: usize = 0;
        while (encoded_entries.next()) |encoded| {
            try std.testing.expect(encoded.len > "entry-".len + 1);
            try std.testing.expectEqual(@backingInt(EntryKind.file), encoded[0]);
            try std.testing.expect(std.mem.startsWith(u8, encoded[1..], "entry-"));
            const index = try std.fmt.parseInt(usize, encoded["entry-".len + 1 ..], 10);
            try std.testing.expect(index < total);
            try std.testing.expect(!seen.isSet(index));
            seen.set(index);
            count += 1;
        }
        try std.testing.expectEqual(expected_count, count);
    }
    try std.testing.expectEqual(total, seen.count());
    try std.testing.expectEqual(Next.end, cursor.next(io, &bytes));
    try std.testing.expectEqual(Next.end, cursor.next(io, &bytes));
    try std.testing.expect(cursor.iterator == null);
}

test "a non-UTF-8 name is a terminal outcome" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "name-\xff", .data = "" });

    const dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    var cursor: Cursor = .{ .iterator = dir.iterateAssumeFirstIteration() };
    defer cursor.close(io);
    var bytes: [max_batch_bytes]u8 = undefined;
    try std.testing.expectEqual(Next.invalid_name, cursor.next(io, &bytes));
    try std.testing.expectEqual(Next.invalid_name, cursor.next(io, &bytes));
    try std.testing.expect(cursor.iterator == null);
}
