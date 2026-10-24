//! Removes each path named on the command line, ignoring one that is absent.
//!
//! `zig build` runs this before copying fresh host archives into the source
//! tree, so a failed build leaves no stale archive behind. Zig 0.17 removed
//! custom build steps, so the removal is a program the build runs.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}
