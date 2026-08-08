//! Fixed-capacity host-owned resources whose handles use Roc `Box(U64)` ARC.
//!
//! Each live slot starts with Roc's one-word box refcount followed immediately
//! by its boxed payload. The payload includes an opaque lifecycle token. When
//! the final reference is released, `roc_dealloc` receives the slot base and
//! routes it back here so the native value can be destroyed and the slot reused.

const std = @import("std");

const token_index_bits: u6 = 16;
const token_kind_bits: u6 = 8;
const token_generation_shift: u6 = token_index_bits + token_kind_bits;
const token_index_mask: u64 = (@as(u64, 1) << token_index_bits) - 1;
const token_kind_mask: u64 = (@as(u64, 1) << token_kind_bits) - 1;
const max_generation: u64 = std.math.maxInt(u64) >> token_generation_shift;
const debug_refcount_poison: isize = if (@sizeOf(usize) == 8)
    @bitCast(@as(usize, 0xdead_beef_dead_beef))
else
    @bitCast(@as(usize, 0xdead_beef));

/// Result of asking a typed heap to handle a Roc allocation-base pointer.
pub const DeallocRoute = enum {
    not_owned,
    deallocated,
    corrupt,
};

/// This heap is intentionally unsynchronized: roc-ray invokes Roc and all
/// resource effects on the window thread. A live Roc reference pins its slot.
pub fn HostResourceHeap(
    comptime Payload: type,
    comptime T: type,
    comptime capacity: usize,
    comptime kind: u8,
    comptime write_token: fn (*Payload, u64) void,
    comptime read_token: fn (*const Payload) u64,
    comptime destroy: fn (*T) void,
) type {
    comptime {
        if (capacity == 0) @compileError("host resource heap capacity must be non-zero");
        if (capacity > token_index_mask) @compileError("host resource heap exceeds token index space");
        if (kind == 0) @compileError("host resource heap kind must be non-zero");
    }

    return struct {
        const Self = @This();
        const Slot = struct {
            refcount: isize,
            payload: Payload,
            resource: T,
        };

        slots: [capacity]Slot = undefined,
        generations: [capacity]u64 = [_]u64{0} ** capacity,
        live: [capacity]bool = [_]bool{false} ** capacity,
        active_count: usize = 0,
        high_water_count: usize = 0,

        comptime {
            if (@offsetOf(Slot, "payload") != @sizeOf(isize)) {
                @compileError("resource handle payload must immediately follow Roc's refcount");
            }
        }

        pub fn insert(self: *Self, payload: Payload, resource: T) ?*Payload {
            for (&self.live, 0..) |*is_live, index| {
                if (is_live.*) continue;

                const generation = self.generations[index] +| 1;
                if (generation == 0 or generation > max_generation) continue;

                self.generations[index] = generation;
                var initialized_payload = payload;
                write_token(&initialized_payload, encodeToken(index, generation, kind));
                self.slots[index] = .{
                    .refcount = 1,
                    .payload = initialized_payload,
                    .resource = resource,
                };
                is_live.* = true;
                self.active_count += 1;
                self.high_water_count = @max(self.high_water_count, self.active_count);
                return &self.slots[index].payload;
            }
            return null;
        }

        /// Resolve a scalar lifecycle token while the caller owns a live Roc
        /// reference to the corresponding Box handle.
        pub fn get(self: *Self, token: u64) ?*T {
            const decoded = decodeToken(token) orelse return null;
            const index = decoded.index;
            if (decoded.kind != kind or index >= capacity or !self.live[index]) return null;
            if (self.generations[index] != decoded.generation) return null;
            if (read_token(&self.slots[index].payload) != token or self.slots[index].refcount <= 0) return null;
            return &self.slots[index].resource;
        }

        pub fn routeDealloc(self: *Self, ptr: *anyopaque) DeallocRoute {
            const index = self.baseIndex(ptr) orelse {
                return if (self.containsAddress(ptr)) .corrupt else .not_owned;
            };
            if (!self.live[index]) return .corrupt;

            const slot = &self.slots[index];
            if (slot.refcount != 0 and slot.refcount != debug_refcount_poison) return .corrupt;

            const decoded = decodeToken(read_token(&slot.payload)) orelse return .corrupt;
            if (decoded.kind != kind or decoded.index != index or decoded.generation != self.generations[index]) return .corrupt;

            destroy(&slot.resource);
            self.live[index] = false;
            self.active_count -= 1;
            return .deallocated;
        }

        /// Destroy any resources still live after Roc can no longer run.
        pub fn deinitAll(self: *Self) void {
            for (&self.live, 0..) |*is_live, index| {
                if (!is_live.*) continue;
                destroy(&self.slots[index].resource);
                is_live.* = false;
            }
            self.active_count = 0;
        }

        pub fn forEach(self: *Self, callback: anytype) void {
            for (self.live, 0..) |is_live, index| {
                if (is_live) callback(&self.slots[index].resource);
            }
        }

        pub fn active(self: *const Self) usize {
            return self.active_count;
        }

        pub fn highWater(self: *const Self) usize {
            return self.high_water_count;
        }

        pub fn containsAddress(self: *const Self, ptr: *const anyopaque) bool {
            const address = @intFromPtr(ptr);
            const start = @intFromPtr(&self.slots[0]);
            const end = start + @sizeOf(Slot) * capacity;
            return address >= start and address < end;
        }

        fn baseIndex(self: *const Self, ptr: *const anyopaque) ?usize {
            const address = @intFromPtr(ptr);
            const start = @intFromPtr(&self.slots[0]);
            const offset = std.math.sub(usize, address, start) catch return null;
            if (offset % @sizeOf(Slot) != 0) return null;
            const index = offset / @sizeOf(Slot);
            return if (index < capacity) index else null;
        }
    };
}

/// Fixed-capacity host-owned resources the app releases by hand.
///
/// Same slot discipline and same token encoding as `HostResourceHeap`, and
/// deliberately so -- an index plus a generation plus a kind, so a token from a
/// released slot can never be mistaken for the resource that replaced it. What
/// differs is who decides the lifetime. A `HostResourceHeap` slot is pinned by a
/// live Roc `Box`, and Roc's refcount reaching zero is what destroys it; here
/// the handle is a plain integer, which Roc copies and drops with no
/// notification, so nothing in Roc can drive the release. The app asks for it.
///
/// The consequence is stated rather than hidden: a resource the app never
/// releases stays alive until `deinitAll` at shutdown. The host cannot reclaim
/// it earlier, because a copy of the token may still be sitting in the model,
/// and freeing memory a live token names is exactly the bug the generation
/// exists to make impossible. What the host *can* do is bound it -- the table
/// has a fixed number of slots, so a program that forgets is refused a new
/// resource rather than growing without limit.
///
/// Unsynchronized, for the same reason as `HostResourceHeap`: every insert,
/// lookup, and release happens on the window thread.
pub fn HostHandleTable(
    comptime T: type,
    comptime capacity: usize,
    comptime kind: u8,
    comptime destroy: fn (*T) void,
) type {
    comptime {
        if (capacity == 0) @compileError("host handle table capacity must be non-zero");
        if (capacity > token_index_mask) @compileError("host handle table exceeds token index space");
        if (kind == 0) @compileError("host handle table kind must be non-zero");
    }

    return struct {
        const Self = @This();

        resources: [capacity]T = undefined,
        generations: [capacity]u64 = [_]u64{0} ** capacity,
        live: [capacity]bool = [_]bool{false} ** capacity,
        active_count: usize = 0,
        high_water_count: usize = 0,

        /// Take ownership of `resource` and return the token naming it.
        ///
        /// Null means every slot is taken. The caller still owns `resource` in
        /// that case and must destroy it -- there is no half-transferred state.
        pub fn insert(self: *Self, resource: T) ?u64 {
            for (&self.live, 0..) |*is_live, index| {
                if (is_live.*) continue;

                const generation = self.generations[index] +| 1;
                if (generation == 0 or generation > max_generation) continue;

                self.generations[index] = generation;
                self.resources[index] = resource;
                is_live.* = true;
                self.active_count += 1;
                self.high_water_count = @max(self.high_water_count, self.active_count);
                return encodeToken(index, generation, kind);
            }
            return null;
        }

        /// Resolve a token, or null if it names a released or foreign slot.
        pub fn get(self: *Self, token: u64) ?*T {
            const index = self.liveIndex(token) orelse return null;
            return &self.resources[index];
        }

        /// Destroy the resource a token names. False if it was already gone.
        ///
        /// Releasing twice is not an error the app can avoid noticing its way
        /// out of -- the second call simply finds a stale token, which is the
        /// same answer any other use of it gets.
        pub fn release(self: *Self, token: u64) bool {
            const index = self.liveIndex(token) orelse return false;
            destroy(&self.resources[index]);
            self.live[index] = false;
            self.active_count -= 1;
            return true;
        }

        /// Destroy whatever the app still holds. Shutdown only.
        pub fn deinitAll(self: *Self) void {
            for (&self.live, 0..) |*is_live, index| {
                if (!is_live.*) continue;
                destroy(&self.resources[index]);
                is_live.* = false;
            }
            self.active_count = 0;
        }

        pub fn active(self: *const Self) usize {
            return self.active_count;
        }

        pub fn highWater(self: *const Self) usize {
            return self.high_water_count;
        }

        fn liveIndex(self: *const Self, token: u64) ?usize {
            const decoded = decodeToken(token) orelse return null;
            if (decoded.kind != kind or decoded.index >= capacity) return null;
            if (!self.live[decoded.index]) return null;
            if (self.generations[decoded.index] != decoded.generation) return null;
            return decoded.index;
        }
    };
}

fn encodeToken(index: usize, generation: u64, comptime kind: u8) u64 {
    return (generation << token_generation_shift) |
        (@as(u64, kind) << token_index_bits) |
        @as(u64, @intCast(index + 1));
}

fn decodeToken(token: u64) ?struct { index: usize, kind: u8, generation: u64 } {
    const encoded_index = token & token_index_mask;
    const encoded_kind = (token >> token_index_bits) & token_kind_mask;
    const generation = token >> token_generation_shift;
    if (encoded_index == 0 or encoded_kind == 0 or generation == 0) return null;
    return .{ .index = @intCast(encoded_index - 1), .kind = @intCast(encoded_kind), .generation = generation };
}

/// A handle-table payload that owns real heap storage.
///
/// Deliberately not a plain integer, and deliberately not built with
/// `std.mem.zeroes`: a resource with nothing to free cannot tell a table that
/// destroys correctly from one that never destroys at all. Every test below
/// runs on `std.testing.allocator`, so a missed `destroy` fails the test.
const OwnedBytes = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    fn init(allocator: std.mem.Allocator, len: usize, fill: u8) !OwnedBytes {
        const bytes = try allocator.alloc(u8, len);
        @memset(bytes, fill);
        return .{ .allocator = allocator, .bytes = bytes };
    }

    fn destroy(self: *OwnedBytes) void {
        self.allocator.free(self.bytes);
        self.bytes = &.{};
    }
};

const OwnedBytesTable = HostHandleTable(OwnedBytes, 2, 9, OwnedBytes.destroy);

test "an explicitly released slot frees its storage and is reused" {
    var table: OwnedBytesTable = .{};
    defer table.deinitAll();

    const first = table.insert(try OwnedBytes.init(std.testing.allocator, 32, 'a')).?;
    try std.testing.expectEqual(@as(usize, 1), table.active());
    try std.testing.expectEqual(@as(usize, 32), table.get(first).?.bytes.len);

    // The storage is freed here, not at shutdown. `std.testing.allocator` is
    // the assertion: if `release` forgot to destroy, this test leaks.
    try std.testing.expect(table.release(first));
    try std.testing.expectEqual(@as(usize, 0), table.active());

    const second = table.insert(try OwnedBytes.init(std.testing.allocator, 8, 'b')).?;
    try std.testing.expectEqual(@as(usize, 8), table.get(second).?.bytes.len);
    try std.testing.expect(table.release(second));
}

test "a released token stays released once its slot is handed to someone else" {
    var table: OwnedBytesTable = .{};
    defer table.deinitAll();

    const stale = table.insert(try OwnedBytes.init(std.testing.allocator, 16, 'a')).?;
    try std.testing.expect(table.release(stale));

    // Same slot, new generation. Without the generation this token would read
    // the replacement's bytes, which is precisely the confusion it prevents.
    const fresh = table.insert(try OwnedBytes.init(std.testing.allocator, 16, 'b')).?;
    try std.testing.expect(stale != fresh);
    try std.testing.expect(table.get(stale) == null);
    try std.testing.expect(!table.release(stale));
    try std.testing.expectEqual(@as(u8, 'b'), table.get(fresh).?.bytes[0]);
    try std.testing.expectEqual(@as(usize, 1), table.active());
}

test "a full table refuses rather than evicting a resource someone may still hold" {
    var table: OwnedBytesTable = .{};
    defer table.deinitAll();

    _ = table.insert(try OwnedBytes.init(std.testing.allocator, 4, 'a')).?;
    _ = table.insert(try OwnedBytes.init(std.testing.allocator, 4, 'b')).?;

    // The caller keeps ownership of a refused resource, so it frees it itself.
    var refused = try OwnedBytes.init(std.testing.allocator, 4, 'c');
    try std.testing.expect(table.insert(refused) == null);
    refused.destroy();

    // Nothing the app never released is lost: shutdown frees both.
    try std.testing.expectEqual(@as(usize, 2), table.active());
    try std.testing.expectEqual(@as(usize, 2), table.highWater());
    table.deinitAll();
    try std.testing.expectEqual(@as(usize, 0), table.active());
}

test "a forged or foreign token resolves to nothing instead of to memory" {
    var table: OwnedBytesTable = .{};
    defer table.deinitAll();

    const OtherTable = HostHandleTable(OwnedBytes, 2, 10, OwnedBytes.destroy);
    var other: OtherTable = .{};
    defer other.deinitAll();

    const mine = table.insert(try OwnedBytes.init(std.testing.allocator, 4, 'a')).?;
    const theirs = other.insert(try OwnedBytes.init(std.testing.allocator, 4, 'b')).?;

    // Zero is what an uninitialized handle looks like, and it must never
    // resolve. Nor may a token of a different kind, or one past the table.
    try std.testing.expect(table.get(0) == null);
    try std.testing.expect(!table.release(0));
    try std.testing.expect(table.get(theirs) == null);
    try std.testing.expect(other.get(mine) == null);
    try std.testing.expect(table.get(std.math.maxInt(u64)) == null);
}

test "final Roc deallocation destroys and reuses a resource slot" {
    const Resource = struct { value: usize };
    const Counter = struct {
        var total: usize = 0;
        fn destroy(resource: *Resource) void {
            total += resource.value;
        }
    };
    const Token = struct {
        fn write(payload: *u64, token: u64) void {
            payload.* = token;
        }
        fn read(payload: *const u64) u64 {
            return payload.*;
        }
    };
    const Heap = HostResourceHeap(u64, Resource, 1, 1, Token.write, Token.read, Counter.destroy);
    var heap: Heap = .{};

    const first = heap.insert(0, .{ .value = 2 }).?;
    const token = first.*;
    try std.testing.expectEqual(@as(usize, 2), heap.get(token).?.value);
    try std.testing.expect(heap.insert(0, .{ .value = 99 }) == null);

    const base: *isize = @ptrFromInt(@intFromPtr(first) - @sizeOf(isize));
    base.* = 0;
    try std.testing.expectEqual(DeallocRoute.deallocated, heap.routeDealloc(base));
    try std.testing.expectEqual(@as(usize, 2), Counter.total);
    try std.testing.expect(heap.get(token) == null);

    const replacement = heap.insert(0, .{ .value = 3 }).?;
    try std.testing.expectEqual(first, replacement);
    try std.testing.expect(replacement.* != token);
    heap.deinitAll();
    try std.testing.expectEqual(@as(usize, 5), Counter.total);
}

test "deallocation routing rejects foreign and misaligned pointers" {
    const noDestroy = struct {
        fn call(_: *u64) void {}
    }.call;
    const Token = struct {
        fn write(payload: *u64, token: u64) void {
            payload.* = token;
        }
        fn read(payload: *const u64) u64 {
            return payload.*;
        }
    };
    const Heap = HostResourceHeap(u64, u64, 1, 1, Token.write, Token.read, noDestroy);
    var heap: Heap = .{};
    const handle = heap.insert(0, 42).?;
    var foreign: usize = 0;

    try std.testing.expectEqual(DeallocRoute.not_owned, heap.routeDealloc(&foreign));
    try std.testing.expectEqual(DeallocRoute.corrupt, heap.routeDealloc(handle));
    heap.deinitAll();
}

test "boxed payload keeps immutable metadata beside its lifecycle token" {
    const Payload = extern struct {
        token: u64,
        width: f32,
        height: f32,
    };
    const Token = struct {
        fn write(payload: *Payload, token: u64) void {
            payload.token = token;
        }
        fn read(payload: *const Payload) u64 {
            return payload.token;
        }
    };
    const noDestroy = struct {
        fn call(_: *u8) void {}
    }.call;
    const Heap = HostResourceHeap(Payload, u8, 1, 1, Token.write, Token.read, noDestroy);
    var heap: Heap = .{};

    const payload = heap.insert(.{ .token = 0, .width = 64, .height = 32 }, 7).?;
    try std.testing.expect(payload.token != 0);
    try std.testing.expectEqual(@as(f32, 64), payload.width);
    try std.testing.expectEqual(@as(f32, 32), payload.height);
    try std.testing.expectEqual(@as(u8, 7), heap.get(payload.token).?.*);
    heap.deinitAll();
}

test "resource kind prevents cross-type scalar token lookup" {
    const Token = struct {
        fn write(payload: *u64, token: u64) void {
            payload.* = token;
        }
        fn read(payload: *const u64) u64 {
            return payload.*;
        }
        fn destroy(_: *u8) void {}
    };
    const SoundHeap = HostResourceHeap(u64, u8, 1, 1, Token.write, Token.read, Token.destroy);
    const MusicHeap = HostResourceHeap(u64, u8, 1, 2, Token.write, Token.read, Token.destroy);
    var sounds: SoundHeap = .{};
    var music: MusicHeap = .{};

    const sound = sounds.insert(0, 1).?;
    const music_handle = music.insert(0, 2).?;
    try std.testing.expect(music.get(sound.*) == null);
    try std.testing.expect(sounds.get(music_handle.*) == null);
    sounds.deinitAll();
    music.deinitAll();
}
