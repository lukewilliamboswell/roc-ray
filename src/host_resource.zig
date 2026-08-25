//! Fixed-capacity host-owned resources whose handles use Roc `Box(payload)` ARC.
//!
//! Each live slot starts with Roc's one-word box refcount followed immediately
//! by its typed payload. That payload includes an opaque lifecycle token and may
//! also carry immutable metadata such as texture dimensions or file-byte length.
//! When the final reference is released, `roc_dealloc` receives the slot base
//! and routes it back here so the native value can be destroyed and the slot
//! reused.

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

/// Every typed host resource, and the byte its lifecycle tokens carry.
///
/// This enum is the sole authority for those numbers: a heap declares itself
/// with a member rather than an integer, so two resources cannot silently pick
/// the same one. Tokens are never persisted, so the values only have to stay
/// stable within a build -- but they are pinned anyway, because a token that
/// changes meaning between two branches is exactly the collision this prevents.
pub const Kind = enum(u8) {
    sound = 1,
    music,
    font,
    texture,
    render_texture,
    shader,
    prepared_text,
    file_bytes,
    store,
    udp_socket,
    sqlite_db,
    sqlite_stmt,

    comptime {
        // Zero is the reserved "not a token" byte; `decodeToken` rejects it.
        for (std.enums.values(Kind)) |kind| {
            if (@intFromEnum(kind) == 0) @compileError("host resource kind must be non-zero");
        }
    }
};

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
    comptime kind: Kind,
    comptime write_token: fn (*Payload, u64) void,
    comptime read_token: fn (*const Payload) u64,
    comptime destroy: fn (*T) void,
) type {
    comptime {
        if (capacity == 0) @compileError("host resource heap capacity must be non-zero");
        if (capacity > token_index_mask) @compileError("host resource heap exceeds token index space");
    }

    return struct {
        const Self = @This();

        /// Which resource this heap owns. Read by the host's coverage check.
        pub const resource_kind: Kind = kind;

        const Slot = struct {
            refcount: isize,
            payload: Payload,
            resource: T,
        };

        slots: [capacity]Slot = undefined,
        generations: [capacity]u64 = [_]u64{0} ** capacity,
        live: [capacity]bool = [_]bool{false} ** capacity,
        /// Slots whose last Roc reference is gone but whose native resource is
        /// still alive. They stay `live` so the slot cannot be handed out
        /// again before the resource behind it has been destroyed.
        retired: [capacity]bool = [_]bool{false} ** capacity,
        retired_count: usize = 0,
        active_count: usize = 0,
        high_water_count: usize = 0,

        comptime {
            if (@offsetOf(Slot, "payload") != @sizeOf(isize)) {
                @compileError("resource handle payload must immediately follow Roc's refcount");
            }
        }

        pub fn insert(self: *Self, payload: Payload, resource: T) ?*Payload {
            // A retired slot is not free until its resource is gone. Rather
            // than report a limit the app has already released its way out of,
            // finish the outstanding destruction first -- the budget is there
            // to keep destruction off a frame's critical path, not to make
            // released resources unrecoverable.
            if (self.retired_count != 0 and self.active_count == capacity) {
                _ = self.drainRetired(self.retired_count);
            }

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

            // Retire rather than destroy. The final reference is dropped
            // wherever the value stopped being reachable, and for a model
            // field that is inside the *pure* `update` -- so destroying here
            // would put a GPU or audio-device call inside a transition whose
            // whole contract is that it does not make any.
            //
            // Roc's allocation is finished with either way; only the native
            // resource behind it outlives this call.
            self.retired[index] = true;
            self.retired_count += 1;
            return .deallocated;
        }

        /// Destroy up to `budget` retired resources. Returns how many went.
        ///
        /// Constant-time per resource and called where a stall is expected --
        /// the end of a frame -- rather than wherever a refcount happened to
        /// reach zero.
        pub fn drainRetired(self: *Self, budget: usize) usize {
            if (self.retired_count == 0 or budget == 0) return 0;
            var destroyed: usize = 0;
            for (&self.retired, 0..) |*is_retired, index| {
                if (destroyed == budget) break;
                if (!is_retired.*) continue;
                destroy(&self.slots[index].resource);
                is_retired.* = false;
                self.live[index] = false;
                self.retired_count -= 1;
                self.active_count -= 1;
                destroyed += 1;
            }
            return destroyed;
        }

        /// How many resources are waiting to be destroyed.
        pub fn retiredCount(self: *const Self) usize {
            return self.retired_count;
        }

        /// Destroy any resources still live after Roc can no longer run.
        pub fn deinitAll(self: *Self) void {
            // Retired slots are still `live`, so this covers both the resources
            // the app still holds and the ones waiting on the retirement queue.
            for (&self.live, 0..) |*is_live, index| {
                if (!is_live.*) continue;
                destroy(&self.slots[index].resource);
                is_live.* = false;
                self.retired[index] = false;
            }
            self.active_count = 0;
            self.retired_count = 0;
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

fn encodeToken(index: usize, generation: u64, comptime kind: Kind) u64 {
    return (generation << token_generation_shift) |
        (@as(u64, @intFromEnum(kind)) << token_index_bits) |
        @as(u64, @intCast(index + 1));
}

/// A kind byte that names no `Kind` is not a token this host ever emitted, so
/// it fails here rather than reaching a heap that would have to decide.
fn decodeToken(token: u64) ?struct { index: usize, kind: Kind, generation: u64 } {
    if (token == std.math.maxInt(u64)) return null;
    const encoded_index = token & token_index_mask;
    const encoded_kind = (token >> token_index_bits) & token_kind_mask;
    const generation = token >> token_generation_shift;
    if (encoded_index == 0 or generation == 0) return null;
    const kind = std.enums.fromInt(Kind, encoded_kind) orelse return null;
    return .{ .index = @intCast(encoded_index - 1), .kind = kind, .generation = generation };
}

test "zero is not a resource token" {
    try std.testing.expect(decodeToken(0) == null);
}

test "maximum u64 is not a resource token" {
    try std.testing.expect(decodeToken(std.math.maxInt(u64)) == null);
}

test "a kind byte no resource claims is not a resource token" {
    // The token layout has room for kind bytes that name nothing, and every
    // one of them means the word was never a handle this host handed out.
    const unclaimed_kind: u64 = 0xfe;
    const token = (@as(u64, 1) << token_generation_shift) |
        (unclaimed_kind << token_index_bits) | 1;
    try std.testing.expect(decodeToken(token) == null);
}

test "resource heaps never emit or resolve zero, including after slot reuse" {
    const Token = struct {
        fn write(payload: *u64, token: u64) void {
            payload.* = token;
        }
        fn read(payload: *const u64) u64 {
            return payload.*;
        }
        fn destroy(_: *u8) void {}
    };
    const Heap = HostResourceHeap(u64, u8, 1, .texture, Token.write, Token.read, Token.destroy);
    var heap: Heap = .{};

    try std.testing.expect(heap.get(0) == null);

    const first = heap.insert(0, 1).?;
    const first_token = first.*;
    try std.testing.expect(first_token != 0);
    try std.testing.expect(heap.get(0) == null);

    const base: *isize = @ptrFromInt(@intFromPtr(first) - @sizeOf(isize));
    base.* = 0;
    try std.testing.expectEqual(DeallocRoute.deallocated, heap.routeDealloc(base));
    try std.testing.expectEqual(@as(usize, 1), heap.drainRetired(1));

    const replacement = heap.insert(0, 2).?;
    try std.testing.expect(replacement.* != 0);
    try std.testing.expect(replacement.* != first_token);
    try std.testing.expect(heap.get(0) == null);
    heap.deinitAll();
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
    const Heap = HostResourceHeap(u64, Resource, 1, .sound, Token.write, Token.read, Counter.destroy);
    var heap: Heap = .{};

    const first = heap.insert(0, .{ .value = 2 }).?;
    const token = first.*;
    try std.testing.expectEqual(@as(usize, 2), heap.get(token).?.value);
    try std.testing.expect(heap.insert(0, .{ .value = 99 }) == null);

    const base: *isize = @ptrFromInt(@intFromPtr(first) - @sizeOf(isize));
    base.* = 0;
    try std.testing.expectEqual(DeallocRoute.deallocated, heap.routeDealloc(base));
    // Roc's allocation is finished with, and the handle is dead...
    try std.testing.expect(heap.get(token) == null);
    // ...but the native resource is not destroyed here. Releasing the final
    // reference happens inside the pure `update`, which may make no effects.
    try std.testing.expectEqual(@as(usize, 0), Counter.total);
    try std.testing.expectEqual(@as(usize, 1), heap.retiredCount());

    try std.testing.expectEqual(@as(usize, 1), heap.drainRetired(4));
    try std.testing.expectEqual(@as(usize, 2), Counter.total);
    try std.testing.expectEqual(@as(usize, 0), heap.retiredCount());

    const replacement = heap.insert(0, .{ .value = 3 }).?;
    try std.testing.expectEqual(first, replacement);
    try std.testing.expect(replacement.* != token);
    heap.deinitAll();
    try std.testing.expectEqual(@as(usize, 5), Counter.total);
}

test "a slot the app released is reusable before the budget gets to it" {
    // The budget exists to keep destruction off a frame's critical path, not
    // to make a released resource unavailable until the next frame. An app
    // that releases a texture and immediately loads another must not be told
    // it is out of textures.
    const Resource = struct { value: usize };
    const Counter = struct {
        var destroyed: usize = 0;
        fn destroy(_: *Resource) void {
            destroyed += 1;
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
    const Heap = HostResourceHeap(u64, Resource, 1, .sound, Token.write, Token.read, Counter.destroy);
    var heap: Heap = .{};
    Counter.destroyed = 0;

    const first = heap.insert(0, .{ .value = 1 }).?;
    const base: *isize = @ptrFromInt(@intFromPtr(first) - @sizeOf(isize));
    base.* = 0;
    try std.testing.expectEqual(DeallocRoute.deallocated, heap.routeDealloc(base));
    try std.testing.expectEqual(@as(usize, 1), heap.retiredCount());

    // No frame has ended, so nothing has been drained -- and the insert still
    // succeeds, by finishing the outstanding destruction itself.
    try std.testing.expect(heap.insert(0, .{ .value = 2 }) != null);
    try std.testing.expectEqual(@as(usize, 1), Counter.destroyed);
    try std.testing.expectEqual(@as(usize, 0), heap.retiredCount());
    heap.deinitAll();
}

test "a retirement queue longer than the budget drains across frames" {
    const Resource = struct { value: usize };
    const Counter = struct {
        var destroyed: usize = 0;
        fn destroy(_: *Resource) void {
            destroyed += 1;
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
    const Heap = HostResourceHeap(u64, Resource, 8, .sound, Token.write, Token.read, Counter.destroy);
    var heap: Heap = .{};
    Counter.destroyed = 0;

    var payloads: [8]*u64 = undefined;
    for (&payloads, 0..) |*slot, index| slot.* = heap.insert(0, .{ .value = index }).?;
    for (payloads) |payload| {
        const base: *isize = @ptrFromInt(@intFromPtr(payload) - @sizeOf(isize));
        base.* = 0;
        try std.testing.expectEqual(DeallocRoute.deallocated, heap.routeDealloc(base));
    }
    try std.testing.expectEqual(@as(usize, 8), heap.retiredCount());

    // A frame destroys its budget and no more; the rest wait for the next one.
    try std.testing.expectEqual(@as(usize, 3), heap.drainRetired(3));
    try std.testing.expectEqual(@as(usize, 5), heap.retiredCount());
    try std.testing.expectEqual(@as(usize, 3), heap.drainRetired(3));
    try std.testing.expectEqual(@as(usize, 2), heap.drainRetired(3));
    try std.testing.expectEqual(@as(usize, 8), Counter.destroyed);
    try std.testing.expectEqual(@as(usize, 0), heap.active());
    heap.deinitAll();
}

test "shutdown destroys resources still waiting on the retirement queue" {
    const Resource = struct { value: usize };
    const Counter = struct {
        var destroyed: usize = 0;
        fn destroy(_: *Resource) void {
            destroyed += 1;
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
    const Heap = HostResourceHeap(u64, Resource, 2, .sound, Token.write, Token.read, Counter.destroy);
    var heap: Heap = .{};
    Counter.destroyed = 0;

    const retired_payload = heap.insert(0, .{ .value = 1 }).?;
    _ = heap.insert(0, .{ .value = 2 }).?;
    const base: *isize = @ptrFromInt(@intFromPtr(retired_payload) - @sizeOf(isize));
    base.* = 0;
    try std.testing.expectEqual(DeallocRoute.deallocated, heap.routeDealloc(base));

    // One retired, one still held. Exit must not leak either.
    heap.deinitAll();
    try std.testing.expectEqual(@as(usize, 2), Counter.destroyed);
    try std.testing.expectEqual(@as(usize, 0), heap.retiredCount());
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
    const Heap = HostResourceHeap(u64, u64, 1, .sound, Token.write, Token.read, noDestroy);
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
    const Heap = HostResourceHeap(Payload, u8, 1, .sound, Token.write, Token.read, noDestroy);
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
    const SoundHeap = HostResourceHeap(u64, u8, 1, .sound, Token.write, Token.read, Token.destroy);
    const MusicHeap = HostResourceHeap(u64, u8, 1, .music, Token.write, Token.read, Token.destroy);
    var sounds: SoundHeap = .{};
    var music: MusicHeap = .{};

    const sound = sounds.insert(0, 1).?;
    const music_handle = music.insert(0, 2).?;
    try std.testing.expect(music.get(sound.*) == null);
    try std.testing.expect(sounds.get(music_handle.*) == null);
    sounds.deinitAll();
    music.deinitAll();
}
