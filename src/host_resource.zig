//! Fixed-capacity host-owned resources whose handles use Roc `Box(U64)` ARC.
//!
//! Each live slot starts with Roc's one-word box refcount followed immediately
//! by its opaque `U64` token. Roc receives a pointer to that token. When the
//! final reference is released, `roc_dealloc` receives the slot base and routes
//! it back here so the native value can be destroyed and the slot reused.

const std = @import("std");

const token_index_bits: u6 = 16;
const token_index_mask: u64 = (@as(u64, 1) << token_index_bits) - 1;
const max_generation: u64 = std.math.maxInt(u64) >> token_index_bits;
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
    comptime T: type,
    comptime capacity: usize,
    comptime destroy: fn (*T) void,
) type {
    comptime {
        if (capacity == 0) @compileError("host resource heap capacity must be non-zero");
        if (capacity > token_index_mask) @compileError("host resource heap exceeds token index space");
    }

    return struct {
        const Self = @This();
        const Slot = struct {
            refcount: isize,
            token: u64,
            resource: T,
        };

        slots: [capacity]Slot = undefined,
        generations: [capacity]u64 = [_]u64{0} ** capacity,
        live: [capacity]bool = [_]bool{false} ** capacity,
        active_count: usize = 0,
        high_water_count: usize = 0,

        comptime {
            if (@offsetOf(Slot, "token") != @sizeOf(isize)) {
                @compileError("resource handle payload must immediately follow Roc's refcount");
            }
        }

        pub fn insert(self: *Self, resource: T) ?*u64 {
            for (&self.live, 0..) |*is_live, index| {
                if (is_live.*) continue;

                const generation = self.generations[index] +| 1;
                if (generation == 0 or generation > max_generation) continue;

                self.generations[index] = generation;
                self.slots[index] = .{
                    .refcount = 1,
                    .token = encodeToken(index, generation),
                    .resource = resource,
                };
                is_live.* = true;
                self.active_count += 1;
                self.high_water_count = @max(self.high_water_count, self.active_count);
                return &self.slots[index].token;
            }
            return null;
        }

        /// Resolve a scalar lifecycle token while the caller owns a live Roc
        /// reference to the corresponding Box handle.
        pub fn get(self: *Self, token: u64) ?*T {
            const decoded = decodeToken(token) orelse return null;
            const index = decoded.index;
            if (index >= capacity or !self.live[index]) return null;
            if (self.generations[index] != decoded.generation) return null;
            if (self.slots[index].token != token or self.slots[index].refcount <= 0) return null;
            return &self.slots[index].resource;
        }

        pub fn routeDealloc(self: *Self, ptr: *anyopaque) DeallocRoute {
            const index = self.baseIndex(ptr) orelse {
                return if (self.containsAddress(ptr)) .corrupt else .not_owned;
            };
            if (!self.live[index]) return .corrupt;

            const slot = &self.slots[index];
            if (slot.refcount != 0 and slot.refcount != debug_refcount_poison) return .corrupt;

            const decoded = decodeToken(slot.token) orelse return .corrupt;
            if (decoded.index != index or decoded.generation != self.generations[index]) return .corrupt;

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

fn encodeToken(index: usize, generation: u64) u64 {
    return (generation << token_index_bits) | @as(u64, @intCast(index + 1));
}

fn decodeToken(token: u64) ?struct { index: usize, generation: u64 } {
    const encoded_index = token & token_index_mask;
    const generation = token >> token_index_bits;
    if (encoded_index == 0 or generation == 0) return null;
    return .{ .index = @intCast(encoded_index - 1), .generation = generation };
}

test "final Roc deallocation destroys and reuses a resource slot" {
    const Resource = struct { value: usize };
    const Counter = struct {
        var total: usize = 0;
        fn destroy(resource: *Resource) void {
            total += resource.value;
        }
    };
    const Heap = HostResourceHeap(Resource, 1, Counter.destroy);
    var heap: Heap = .{};

    const first = heap.insert(.{ .value = 2 }).?;
    const token = first.*;
    try std.testing.expectEqual(@as(usize, 2), heap.get(token).?.value);
    try std.testing.expect(heap.insert(.{ .value = 99 }) == null);

    const base: *isize = @ptrFromInt(@intFromPtr(first) - @sizeOf(isize));
    base.* = 0;
    try std.testing.expectEqual(DeallocRoute.deallocated, heap.routeDealloc(base));
    try std.testing.expectEqual(@as(usize, 2), Counter.total);
    try std.testing.expect(heap.get(token) == null);

    const replacement = heap.insert(.{ .value = 3 }).?;
    try std.testing.expectEqual(first, replacement);
    try std.testing.expect(replacement.* != token);
    heap.deinitAll();
    try std.testing.expectEqual(@as(usize, 5), Counter.total);
}

test "deallocation routing rejects foreign and misaligned pointers" {
    const noDestroy = struct {
        fn call(_: *u64) void {}
    }.call;
    const Heap = HostResourceHeap(u64, 1, noDestroy);
    var heap: Heap = .{};
    const handle = heap.insert(42).?;
    var foreign: usize = 0;

    try std.testing.expectEqual(DeallocRoute.not_owned, heap.routeDealloc(&foreign));
    try std.testing.expectEqual(DeallocRoute.corrupt, heap.routeDealloc(handle));
    heap.deinitAll();
}
