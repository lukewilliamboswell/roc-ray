//! Resolving an app's relative path beneath a directory handle's root.
//!
//! A `Files.Dir`, an asset store, or a database directory is a root plus
//! paths relative to it. Nothing an app writes as a path may reach outside
//! that root, so resolution here refuses three things:
//!
//! - a path that is not plainly relative: absolute, a drive, a backslash, a
//!   NUL, or an empty, `.`, or `..` component;
//! - a symbolic link anywhere beneath the root, which could lead anywhere;
//! - on Linux, any resolution the kernel sees leaving the root
//!   (`RESOLVE_BENEATH`), which also closes the window between checking a
//!   name and opening it.
//!
//! The root itself is opened by its path and may be reached through links:
//! it is what the app was granted, however the filesystem spells it.
//!
//! Links are refused rather than followed when they stay inside the root, so
//! the rule is the same on every operating system. This is platform policy
//! rather than an operating-system sandbox; a process that swaps directories
//! between a check and a use on a system without `RESOLVE_BENEATH` is outside
//! what it promises.

const std = @import("std");
const Dir = std.Io.Dir;
const File = std.Io.File;

/// A resolution the rules above refuse. Everything else is the filesystem's
/// own error, passed through for the caller to name.
pub const Error = error{Escapes};

/// Whether `path` is plainly relative: non-empty, with no absolute prefix,
/// drive, backslash, NUL, or empty, `.`, or `..` component.
pub fn isSafeRelative(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    if (std.mem.indexOfAny(u8, path, "\\\x00:") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Open the root a handle names. The caller closes it.
pub fn openRoot(io: std.Io, root: []const u8, iterate: bool) !Dir {
    if (root.len == 0 or !std.fs.path.isAbsolute(root)) return error.Escapes;
    return Dir.openDirAbsolute(io, root, .{ .iterate = iterate });
}

/// Open the directory `path` names beneath `root`, one component at a time,
/// never following a link. An empty `path` is the root itself. With `create`,
/// missing directories are made on the way.
pub fn openDir(io: std.Io, root: Dir, path: []const u8, options: struct { create: bool = false, iterate: bool = false }) !Dir {
    if (path.len != 0 and !isSafeRelative(path)) return error.Escapes;
    // Reopen the root so the caller always owns what it gets back.
    var current = try root.openDir(io, ".", .{ .iterate = options.iterate and path.len == 0 });
    if (path.len == 0) return current;
    errdefer current.close(io);
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        const last = parts.peek() == null;
        const next = openChild(io, current, part, options.create, options.iterate and last) catch |err| return err;
        current.close(io);
        current = next;
    }
    return current;
}

fn openChild(io: std.Io, parent: Dir, name: []const u8, create: bool, iterate: bool) !Dir {
    const options: Dir.OpenOptions = .{ .follow_symlinks = false, .iterate = iterate };
    return parent.openDir(io, name, options) catch |err| switch (err) {
        error.FileNotFound => {
            if (!create) return err;
            parent.createDir(io, name, .default_dir) catch |create_err| switch (create_err) {
                // Another writer made it first; open what is there, still
                // refusing a link.
                error.PathAlreadyExists => {},
                else => return create_err,
            };
            return parent.openDir(io, name, options) catch |open_err| return linkIsEscape(io, parent, name, open_err);
        },
        else => return linkIsEscape(io, parent, name, err),
    };
}

/// Opening a link without following it fails with the operating system's own
/// spelling -- `ELOOP` for a file, `ENOTDIR` for a directory on Linux -- and
/// `ENOTDIR` is also what a plain file in the way produces. A stat that does
/// not follow the name tells the two apart.
fn linkIsEscape(io: std.Io, parent: Dir, name: []const u8, err: anyerror) anyerror {
    switch (err) {
        error.SymLinkLoop => return error.Escapes,
        error.NotDir => {
            const found = parent.statFile(io, name, .{ .follow_symlinks = false }) catch return err;
            return if (found.kind == .sym_link) error.Escapes else err;
        },
        else => return err,
    }
}

/// The directory holding `path`'s last component, and that component's name.
/// The caller closes `dir`.
pub const Parent = struct { dir: Dir, name: []const u8 };

/// Open the directory that holds `path`'s last component, creating missing
/// directories on the way when `create` is set.
pub fn openParent(io: std.Io, root: Dir, path: []const u8, create: bool) !Parent {
    if (!isSafeRelative(path)) return error.Escapes;
    const split = std.mem.lastIndexOfScalar(u8, path, '/');
    const parent_path = if (split) |index| path[0..index] else "";
    const name = if (split) |index| path[index + 1 ..] else path;
    return .{ .dir = try openDir(io, root, parent_path, .{ .create = create }), .name = name };
}

/// Open the file `path` names beneath `root` for reading. A link is refused.
pub fn openFile(io: std.Io, root: Dir, path: []const u8) !File {
    const parent = try openParent(io, root, path, false);
    defer parent.dir.close(io);
    if (@import("builtin").os.tag == .windows) {
        // Zig opens a no-follow file for overlapped I/O on Windows, and an
        // ordinary read of that handle fails. So refuse a reparse point by
        // stat instead, then open normally. The parents were already walked
        // without following, so only this last name is checked this way.
        const found = try parent.dir.statFile(io, parent.name, .{ .follow_symlinks = false });
        if (found.kind == .sym_link) return error.Escapes;
        return parent.dir.openFile(io, parent.name, .{});
    }
    return parent.dir.openFile(io, parent.name, .{ .follow_symlinks = false, .resolve_beneath = true }) catch |err|
        return linkIsEscape(io, parent.dir, parent.name, err);
}

/// Read a whole file beneath `root`, stopping at `limit`.
pub fn readFileAlloc(io: std.Io, root: Dir, path: []const u8, allocator: std.mem.Allocator, limit: std.Io.Limit) ![]u8 {
    var file = try openFile(io, root, path);
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, limit) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

/// Stat what `path` names beneath `root`, without following a link. An empty
/// `path` is the root itself.
pub fn statFile(io: std.Io, root: Dir, path: []const u8) !File.Stat {
    if (path.len == 0) return root.statFile(io, ".", .{});
    const parent = try openParent(io, root, path, false);
    defer parent.dir.close(io);
    return parent.dir.statFile(io, parent.name, .{ .follow_symlinks = false });
}

/// Replace a whole file beneath `root`, creating missing parents. An existing
/// link at the name is refused rather than written through.
pub fn writeFile(io: std.Io, root: Dir, path: []const u8, bytes: []const u8) !void {
    const parent = try openParent(io, root, path, true);
    defer parent.dir.close(io);
    if (parent.dir.statFile(io, parent.name, .{ .follow_symlinks = false })) |existing| {
        if (existing.kind == .sym_link) return error.Escapes;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var file = try parent.dir.createFile(io, parent.name, .{ .resolve_beneath = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

/// The path `path` names beneath `root`, for a consumer that can only take a
/// path, such as SQLite. Every directory on the way is checked as `openDir`
/// checks it, and so is the last component when it exists. Returned in
/// `allocator`'s memory.
pub fn checkedPath(io: std.Io, root_path: []const u8, root: Dir, path: []const u8, create_parents: bool, allocator: std.mem.Allocator) ![]u8 {
    const parent = try openParent(io, root, path, create_parents);
    defer parent.dir.close(io);
    if (parent.dir.statFile(io, parent.name, .{ .follow_symlinks = false })) |existing| {
        if (existing.kind == .sym_link) return error.Escapes;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    return std.fs.path.join(allocator, &.{ root_path, path });
}

test "only plainly relative paths are accepted" {
    for ([_][]const u8{ "a.txt", "dir/a.txt", "a/b/c" }) |path| try std.testing.expect(isSafeRelative(path));
    for ([_][]const u8{ "", "/etc/passwd", "../up", "a/../b", "./a", "a//b", "a/", "a\\b", "C:x", "a\x00b" }) |path| {
        try std.testing.expect(!isSafeRelative(path));
    }
}

test "reads, writes, and stats stay beneath the root" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/inner");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/inner/a.txt", .data = "inside" });
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "outside" });

    var root = try tmp.dir.openDir(io, "root", .{});
    defer root.close(io);

    const read = try readFileAlloc(io, root, "inner/a.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(read);
    try std.testing.expectEqualStrings("inside", read);
    try std.testing.expectError(error.Escapes, readFileAlloc(io, root, "../secret.txt", std.testing.allocator, .limited(64)));

    try writeFile(io, root, "made/on/the/way.txt", "new");
    const made = try statFile(io, root, "made/on/the/way.txt");
    try std.testing.expectEqual(File.Kind.file, made.kind);
    try std.testing.expectEqual(File.Kind.directory, (try statFile(io, root, "")).kind);

    var listed = try openDir(io, root, "inner", .{ .iterate = true });
    defer listed.close(io);
    var walker = listed.iterate();
    try std.testing.expectEqualStrings("a.txt", (try walker.next(io)).?.name);
}

test "links beneath the root are refused, wherever they point" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/inner");
    try tmp.dir.createDirPath(io, "elsewhere");
    try tmp.dir.writeFile(io, .{ .sub_path = "elsewhere/secret.txt", .data = "outside" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/inner/a.txt", .data = "inside" });

    var root = try tmp.dir.openDir(io, "root", .{});
    defer root.close(io);
    try root.symLink(io, "../elsewhere", "out_dir", .{ .is_directory = true });
    try root.symLink(io, "../elsewhere/secret.txt", "out_file", .{});
    try root.symLink(io, "inner/a.txt", "in_file", .{});

    try std.testing.expectError(error.Escapes, readFileAlloc(io, root, "out_dir/secret.txt", std.testing.allocator, .limited(64)));
    try std.testing.expectError(error.Escapes, readFileAlloc(io, root, "out_file", std.testing.allocator, .limited(64)));
    try std.testing.expectError(error.Escapes, readFileAlloc(io, root, "in_file", std.testing.allocator, .limited(64)));
    try std.testing.expectError(error.Escapes, writeFile(io, root, "out_file", "clobber"));
    try std.testing.expectError(error.Escapes, writeFile(io, root, "out_dir/new.txt", "planted"));
    try std.testing.expectError(error.Escapes, openDir(io, root, "out_dir", .{}));
    try std.testing.expectEqual(File.Kind.sym_link, (try statFile(io, root, "out_file")).kind);

    const untouched = try tmp.dir.readFileAlloc(io, "elsewhere/secret.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(untouched);
    try std.testing.expectEqualStrings("outside", untouched);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "elsewhere/new.txt", .{}));
}
