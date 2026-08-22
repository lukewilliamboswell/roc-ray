//! The `Udp` effects: one bound datagram socket, and the two syscalls that
//! move bytes through it.
//!
//! `host_native.zig` owns the phase guard, the socket heap and the Roc entry
//! points; this file owns the socket work and the conversion between Roc
//! values and Zig slices. Nothing here touches raylib.
//!
//! ## Why the two directions are shaped differently
//!
//! Receiving waits for a peer, so `receive` is a waiting effect: it parks the
//! calling coroutine on zio's event loop and the frame loop keeps drawing.
//! Sending waits for nothing -- the datagram goes to the kernel and the call is
//! over -- so `send` is an ordinary effect that issues one non-blocking
//! `sendto` on the file descriptor and never reaches the event loop at all.
//! That is what makes it legal in `update!`, which is where a game says "the
//! local player moved, tell the peer" sixty times a second.
//!
//! ## Bounds
//!
//! A datagram is at most `max_datagram_bytes`. One `receive` parks for the
//! first datagram and then drains what the kernel already has, stopping at
//! `max_datagrams_per_batch`, at `max_batch_bytes`, or when the socket runs
//! dry -- whichever comes first. Datagrams that arrive with no receive pending
//! wait in the kernel's own buffer; they are lost only when it overflows,
//! which is the UDP contract and is documented in `Udp.roc`.

const std = @import("std");
const zio = @import("zio");

/// The largest payload an IPv4 UDP datagram can carry: 65535 less the 20-byte
/// IP header and the 8-byte UDP header. A send over this is refused rather
/// than truncated, because a truncated datagram decodes into wrong data.
pub const max_datagram_bytes: usize = 65507;

/// Staging buffer for one datagram. Rounded up from `max_datagram_bytes` so a
/// receive can tell "exactly the maximum" from "larger than we can hold".
pub const receive_buffer_bytes: usize = 65536;

/// The most datagrams one `receive` may return. The app asks for what it
/// wants and this clamps it: the batch is copied into Roc values, and the
/// point of the drain is a frame's worth of traffic, not an unbounded one.
pub const max_datagrams_per_batch: u32 = 64;

/// The most bytes one `receive` may return across the whole batch. Reached
/// before the datagram count only when peers are sending large payloads; the
/// rest stay in the kernel buffer for the next receive.
pub const max_batch_bytes: usize = 256 * 1024;

/// Requested `SO_RCVBUF`. Best effort -- the kernel may grant less, and what
/// it grants is what bounds how long an app may go without receiving before
/// datagrams start being dropped.
pub const requested_receive_buffer_bytes: usize = 1024 * 1024;

// Error codes shared with `Udp.roc`, which turns them back into tag unions.
// `0` is success everywhere. The codes below 8 are shared across the three
// effects so a code never means two things; the ones only one effect can
// produce are numbered past that table.

/// The handle does not resolve to an open socket: it was released, it is a
/// `stub`, or the app is shutting down.
pub const ERR_UNAVAILABLE: u8 = 1;

/// The address string is not a dotted-quad IPv4 literal, or the port is not
/// usable with it.
pub const ERR_INVALID_ADDRESS: u8 = 2;

/// The operating system refused for a reason the host cannot name better.
pub const ERR_FAILED: u8 = 3;

/// No free slot in the socket heap.
pub const ERR_RESOURCE_LIMIT: u8 = 4;

/// Another socket already holds this address and port.
pub const ERR_ADDRESS_IN_USE: u8 = 8;

/// The address is not one of this machine's.
pub const ERR_ADDRESS_UNAVAILABLE: u8 = 9;

/// Binding this port needs privileges this process does not have.
pub const ERR_PERMISSION_DENIED: u8 = 10;

/// The payload is longer than `max_datagram_bytes`.
pub const ERR_TOO_LARGE: u8 = 11;

/// The kernel send buffer is full: the datagram was not sent.
pub const ERR_WOULD_BLOCK: u8 = 12;

/// No route to the destination.
pub const ERR_UNREACHABLE: u8 = 13;

/// The deadline expired before any datagram arrived.
pub const ERR_TIMEOUT: u8 = 14;

/// Another task is already parked in `receive` on this socket.
pub const ERR_ALREADY_RECEIVING: u8 = 15;

/// One open UDP socket, and everything that belongs to it.
///
/// The receive buffer lives here rather than in one shared static because two
/// tasks may be parked in `receive` on two different sockets at the same time.
/// `receiving` is what makes that "two different sockets" rather than "two
/// receives racing on one": a second receive on a busy socket is refused.
pub const Socket = struct {
    inner: zio.net.Socket,
    /// The address actually bound, which differs from the one asked for
    /// whenever the app passed port 0 and let the OS choose.
    local_ip: u32,
    local_port: u16,
    /// True while a task is parked in `receive` on this socket.
    receiving: bool = false,
    buffer: [receive_buffer_bytes]u8 = undefined,
};

/// One datagram in a finished batch: where it came from, and where its bytes
/// sit in the batch's shared payload buffer.
///
/// The wire shape is scalars only, and this is why: a `List` whose elements
/// carry a `Str` or a `List(U8)` is the refcounted-element-in-list shape
/// `roc glue` still mishandles (see `TODO(compiler)` in `platform/TaskHost.roc`,
/// and `FilesHost.list!`, which flattens for the same reason). The whole batch
/// therefore travels as one flat byte list plus this index.
pub const Slice = struct {
    ip: u32,
    port: u16,
    start: u64,
    len: u64,
};

/// A finished batch, before it is turned into Roc values.
pub const Batch = struct {
    slices: []const Slice,
    payload: []const u8,
};

/// Parse a dotted-quad IPv4 literal into host-order bytes.
///
/// Host order, not network order: `Udp.roc` formats this back to a string with
/// shifts, and doing that on a network-order word would make the Roc code
/// endian-dependent for no reason.
pub fn parseIp4(text: []const u8) ?u32 {
    var octets: [4]u8 = undefined;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, text, '.');
    while (parts.next()) |part| {
        if (count == 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        // No leading zeros: "010.0.0.1" is octal in some resolvers and decimal
        // in others, so it is refused rather than silently picking one.
        if (part.len > 1 and part[0] == '0') return null;
        var value: u16 = 0;
        for (part) |byte| {
            if (byte < '0' or byte > '9') return null;
            value = value * 10 + (byte - '0');
        }
        if (value > 255) return null;
        octets[count] = @intCast(value);
        count += 1;
    }
    if (count != 4) return null;
    return (@as(u32, octets[0]) << 24) |
        (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) |
        @as(u32, octets[3]);
}

/// The zio address for a host-order IPv4 word and a port.
pub fn addressOf(ip: u32, port: u16) zio.net.IpAddress {
    const octets = [4]u8{
        @truncate(ip >> 24),
        @truncate(ip >> 16),
        @truncate(ip >> 8),
        @truncate(ip),
    };
    return zio.net.IpAddress.initIp4(octets, port);
}

/// The host-order IPv4 word and port of a zio address, or null when it is not
/// IPv4. Only IPv4 sockets are bound, so a peer address that is not IPv4
/// cannot arrive; this reports rather than asserting because the value comes
/// from the kernel.
pub fn decodeIp4(address: zio.net.IpAddress) ?struct { ip: u32, port: u16 } {
    if (address.getFamily() != .ipv4) return null;
    const octets: [4]u8 = @bitCast(address.in.addr);
    return .{
        .ip = (@as(u32, octets[0]) << 24) |
            (@as(u32, octets[1]) << 16) |
            (@as(u32, octets[2]) << 8) |
            @as(u32, octets[3]),
        .port = std.mem.bigToNative(u16, address.in.port),
    };
}

/// How a bind ended.
pub const BindOutcome = union(enum) {
    ok: Socket,
    err: u8,
};

/// Open and bind one IPv4 UDP socket.
///
/// The socket is opened non-blocking by zio, which is what lets `send` issue a
/// bare `sendto` later and get `WouldBlock` instead of stalling the frame.
/// zio writes the address the kernel actually assigned back into the socket,
/// so an app that asked for port 0 learns its ephemeral port from the bind
/// rather than needing a second effect for it.
pub fn bind(ip: u32, port: u16) BindOutcome {
    var socket = zio.net.IpAddress.bind(addressOf(ip, port), .{ .reuse_address = true }) catch |err| {
        return .{ .err = bindErrorCode(err) };
    };
    errdefer socket.close();

    // Best effort: a kernel that grants less just means less headroom before
    // an app that stops receiving starts losing datagrams.
    socket.setReceiveBufferSize(requested_receive_buffer_bytes) catch {};

    const bound = decodeIp4(socket.address.ip) orelse {
        socket.close();
        return .{ .err = ERR_FAILED };
    };
    return .{ .ok = .{ .inner = socket, .local_ip = bound.ip, .local_port = bound.port } };
}

/// Send one datagram, without waiting for anything.
///
/// This deliberately does not go through zio's `sendTo`, which submits to the
/// event loop and can park the caller. `send` is legal in `update!`, where
/// parking would be a frame cost and would let another task's Roc code run in
/// the middle of an update; issuing the syscall directly on the non-blocking
/// descriptor cannot do either. A full kernel send buffer comes back as
/// `EAGAIN`, which is `ERR_WOULD_BLOCK`: the datagram was not sent, and UDP
/// has no promise that it would have been.
pub fn send(socket: *Socket, ip: u32, port: u16, bytes: []const u8) u8 {
    if (bytes.len > max_datagram_bytes) return ERR_TOO_LARGE;

    const address = addressOf(ip, port);
    var storage = [1]zio.os.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    const written = zio.os.net.sendto(
        socket.inner.handle,
        &storage,
        .{},
        &address.any,
        @sizeOf(zio.os.net.sockaddr.in),
    ) catch |err| return sendErrorCode(err);

    // A datagram is all-or-nothing on the wire, so a short count is not a
    // partial send to retry; it is the kernel reporting something this host
    // does not model. Report it rather than pretending the peer got it all.
    if (written != bytes.len) return ERR_FAILED;
    return 0;
}

/// How a receive ended.
pub const ReceiveOutcome = union(enum) {
    ok: Batch,
    err: u8,
};

/// Wait for at least one datagram, then drain what is already buffered.
///
/// The park and the drain are different operations, and separating them is
/// what makes this usable at frame rate: a task delivers its message exactly
/// once, so a receive that returned a single datagram would cap a respawned
/// listener at one datagram per frame. Parking once and then draining costs
/// one syscall per extra datagram and no further park, and the app gets a
/// frame's worth of ordered traffic per message.
///
/// `slices` and `payload` are filled in place and belong to the caller, which
/// turns them into Roc values and then discards them.
pub fn receive(
    socket: *Socket,
    timeout_ms: u64,
    max_datagrams: u32,
    slices: *std.ArrayList(Slice),
    payload: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) ReceiveOutcome {
    if (socket.receiving) return .{ .err = ERR_ALREADY_RECEIVING };
    socket.receiving = true;
    defer socket.receiving = false;

    const wanted = std.math.clamp(max_datagrams, 1, max_datagrams_per_batch);
    const timeout: zio.Timeout = if (timeout_ms == 0) .none else .fromMilliseconds(timeout_ms);

    // The first datagram is the one worth waiting for.
    const first = socket.inner.receiveFrom(&socket.buffer, timeout) catch |err| {
        return .{ .err = receiveErrorCode(err) };
    };
    if (!appendDatagram(socket, first, slices, payload, allocator)) return .{ .err = ERR_FAILED };

    // Everything after it is already in the kernel, or is not coming: a
    // zero-length deadline turns "nothing more right now" into `Timeout`
    // rather than a second park.
    while (slices.items.len < wanted and payload.items.len < max_batch_bytes) {
        const next = socket.inner.receiveFrom(&socket.buffer, .fromNanoseconds(0)) catch |err| switch (err) {
            error.Timeout, error.WouldBlock => break,
            // A cancellation mid-drain still has a batch worth delivering, and
            // the caller is about to be torn down anyway.
            error.Canceled => break,
            else => break,
        };
        if (!appendDatagram(socket, next, slices, payload, allocator)) break;
    }

    return .{ .ok = .{ .slices = slices.items, .payload = payload.items } };
}

/// Copy one received datagram into the batch. False means out of memory, in
/// which case what has been collected so far is still worth delivering.
fn appendDatagram(
    socket: *Socket,
    result: zio.net.ReceiveFromResult,
    slices: *std.ArrayList(Slice),
    payload: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) bool {
    // A datagram from a family this socket cannot have bound is not something
    // the app can reply to, so it is dropped rather than delivered with a
    // meaningless address.
    const from = switch (result.from.getType()) {
        .ip => decodeIp4(result.from.ip) orelse return true,
        else => return true,
    };
    const start = payload.items.len;
    payload.appendSlice(allocator, socket.buffer[0..result.len]) catch return false;
    slices.append(allocator, .{
        .ip = from.ip,
        .port = from.port,
        .start = start,
        .len = result.len,
    }) catch {
        payload.shrinkRetainingCapacity(start);
        return false;
    };
    return true;
}

/// Name a failed bind in the app's vocabulary.
fn bindErrorCode(err: anyerror) u8 {
    return switch (err) {
        error.AddressInUse => ERR_ADDRESS_IN_USE,
        error.AddressNotAvailable => ERR_ADDRESS_UNAVAILABLE,
        error.AccessDenied, error.PermissionDenied => ERR_PERMISSION_DENIED,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => ERR_RESOURCE_LIMIT,
        error.Canceled => ERR_UNAVAILABLE,
        else => ERR_FAILED,
    };
}

/// Name a failed send in the app's vocabulary.
///
/// `WouldBlock` is deliberately not folded into the generic failure: it is the
/// app outrunning the link, which it can do something about, and every other
/// code here is something it cannot.
fn sendErrorCode(err: anyerror) u8 {
    return switch (err) {
        error.WouldBlock => ERR_WOULD_BLOCK,
        error.MessageTooBig => ERR_TOO_LARGE,
        error.NetworkUnreachable, error.NetworkDown => ERR_UNREACHABLE,
        error.AccessDenied, error.PermissionDenied => ERR_PERMISSION_DENIED,
        error.Canceled => ERR_UNAVAILABLE,
        else => ERR_FAILED,
    };
}

/// Name a failed receive in the app's vocabulary.
fn receiveErrorCode(err: anyerror) u8 {
    return switch (err) {
        error.Timeout, error.WouldBlock => ERR_TIMEOUT,
        // Only shutdown cancels a parked receive, and the message a cancelled
        // task produces is dropped before it reaches `update!` anyway.
        error.Canceled => ERR_UNAVAILABLE,
        else => ERR_FAILED,
    };
}

test "dotted-quad parsing accepts addresses and refuses ambiguity" {
    try std.testing.expectEqual(@as(?u32, 0x7f000001), parseIp4("127.0.0.1"));
    try std.testing.expectEqual(@as(?u32, 0), parseIp4("0.0.0.0"));
    try std.testing.expectEqual(@as(?u32, 0xffffffff), parseIp4("255.255.255.255"));
    try std.testing.expectEqual(@as(?u32, 0xc0a80101), parseIp4("192.168.1.1"));

    try std.testing.expectEqual(@as(?u32, null), parseIp4(""));
    try std.testing.expectEqual(@as(?u32, null), parseIp4("127.0.0"));
    try std.testing.expectEqual(@as(?u32, null), parseIp4("127.0.0.1.1"));
    try std.testing.expectEqual(@as(?u32, null), parseIp4("256.0.0.1"));
    try std.testing.expectEqual(@as(?u32, null), parseIp4("127.0.0."));
    try std.testing.expectEqual(@as(?u32, null), parseIp4("::1"));
    try std.testing.expectEqual(@as(?u32, null), parseIp4("localhost"));
    // Leading zeros are refused rather than guessed at.
    try std.testing.expectEqual(@as(?u32, null), parseIp4("010.0.0.1"));
}

test "an address survives the trip through zio and back" {
    const ip = parseIp4("192.168.1.1").?;
    const decoded = decodeIp4(addressOf(ip, 9999)).?;
    try std.testing.expectEqual(ip, decoded.ip);
    try std.testing.expectEqual(@as(u16, 9999), decoded.port);

    const loopback = parseIp4("127.0.0.1").?;
    const round = decodeIp4(addressOf(loopback, 1)).?;
    try std.testing.expectEqual(loopback, round.ip);
    try std.testing.expectEqual(@as(u16, 1), round.port);
}

test "operating-system failures fold onto the codes Udp names" {
    try std.testing.expectEqual(ERR_ADDRESS_IN_USE, bindErrorCode(error.AddressInUse));
    try std.testing.expectEqual(ERR_PERMISSION_DENIED, bindErrorCode(error.AccessDenied));
    try std.testing.expectEqual(ERR_FAILED, bindErrorCode(error.Unexpected));
    try std.testing.expectEqual(ERR_WOULD_BLOCK, sendErrorCode(error.WouldBlock));
    try std.testing.expectEqual(ERR_TOO_LARGE, sendErrorCode(error.MessageTooBig));
    try std.testing.expectEqual(ERR_UNREACHABLE, sendErrorCode(error.NetworkUnreachable));
    try std.testing.expectEqual(ERR_TIMEOUT, receiveErrorCode(error.Timeout));
    try std.testing.expectEqual(ERR_UNAVAILABLE, receiveErrorCode(error.Canceled));
}

test "a payload over the datagram ceiling is refused before any syscall" {
    // No socket is opened: the ceiling is checked on the app's own value, so
    // an oversize send cannot reach the descriptor at all.
    var socket: Socket = undefined;
    const oversize = std.testing.allocator.alloc(u8, max_datagram_bytes + 1) catch unreachable;
    defer std.testing.allocator.free(oversize);
    try std.testing.expectEqual(ERR_TOO_LARGE, send(&socket, 0x7f000001, 1, oversize));
}

test "a datagram makes the loopback round trip with its sender's address" {
    const rt = try testRuntime();
    defer rt.deinit();

    // Real syscalls on a real runtime -- the same code path the app takes.
    // Ephemeral ports keep this from colliding with anything else running on
    // the machine.
    const loopback = parseIp4("127.0.0.1").?;

    var sender = switch (bind(loopback, 0)) {
        .ok => |socket| socket,
        .err => |code| return std.testing.expectEqual(@as(u8, 0), code),
    };
    defer sender.inner.close();

    var receiver = switch (bind(loopback, 0)) {
        .ok => |socket| socket,
        .err => |code| return std.testing.expectEqual(@as(u8, 0), code),
    };
    defer receiver.inner.close();

    try std.testing.expect(sender.local_port != 0);
    try std.testing.expect(receiver.local_port != 0);
    try std.testing.expect(sender.local_port != receiver.local_port);

    try std.testing.expectEqual(
        @as(u8, 0),
        send(&sender, receiver.local_ip, receiver.local_port, "ping"),
    );

    var slices: std.ArrayList(Slice) = .empty;
    defer slices.deinit(std.testing.allocator);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(std.testing.allocator);

    const batch = switch (receive(&receiver, 2000, 8, &slices, &payload, std.testing.allocator)) {
        .ok => |value| value,
        .err => |code| return std.testing.expectEqual(@as(u8, 0), code),
    };

    try std.testing.expectEqual(@as(usize, 1), batch.slices.len);
    try std.testing.expectEqualStrings("ping", batch.payload[0..4]);
    // The sender's address, not just the bytes: a receive that reported the
    // wrong peer would make every reply go nowhere.
    try std.testing.expectEqual(loopback, batch.slices[0].ip);
    try std.testing.expectEqual(sender.local_port, batch.slices[0].port);
    try std.testing.expectEqual(@as(u64, 0), batch.slices[0].start);
    try std.testing.expectEqual(@as(u64, 4), batch.slices[0].len);
}

test "one receive drains several datagrams and stops at the batch limit" {
    const rt = try testRuntime();
    defer rt.deinit();

    const loopback = parseIp4("127.0.0.1").?;

    var sender = switch (bind(loopback, 0)) {
        .ok => |socket| socket,
        .err => |code| return std.testing.expectEqual(@as(u8, 0), code),
    };
    defer sender.inner.close();

    var receiver = switch (bind(loopback, 0)) {
        .ok => |socket| socket,
        .err => |code| return std.testing.expectEqual(@as(u8, 0), code),
    };
    defer receiver.inner.close();

    for ([_][]const u8{ "one", "two", "three", "four", "five" }) |message| {
        try std.testing.expectEqual(
            @as(u8, 0),
            send(&sender, receiver.local_ip, receiver.local_port, message),
        );
    }

    var slices: std.ArrayList(Slice) = .empty;
    defer slices.deinit(std.testing.allocator);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(std.testing.allocator);

    // Ask for three of the five. The drain must stop at what was asked for and
    // leave the rest in the kernel rather than returning everything.
    const batch = switch (receive(&receiver, 2000, 3, &slices, &payload, std.testing.allocator)) {
        .ok => |value| value,
        .err => |code| return std.testing.expectEqual(@as(u8, 0), code),
    };
    try std.testing.expectEqual(@as(usize, 3), batch.slices.len);
    try std.testing.expectEqualStrings("one", sliceOf(batch, 0));
    try std.testing.expectEqualStrings("two", sliceOf(batch, 1));
    try std.testing.expectEqualStrings("three", sliceOf(batch, 2));

    // The two left behind are still there, and a second receive gets them
    // without waiting for anything new.
    slices.clearRetainingCapacity();
    payload.clearRetainingCapacity();
    const rest = switch (receive(&receiver, 2000, 64, &slices, &payload, std.testing.allocator)) {
        .ok => |value| value,
        .err => |code| return std.testing.expectEqual(@as(u8, 0), code),
    };
    try std.testing.expectEqual(@as(usize, 2), rest.slices.len);
    try std.testing.expectEqualStrings("four", sliceOf(rest, 0));
    try std.testing.expectEqualStrings("five", sliceOf(rest, 1));
}

test "a receive with nothing to receive reports the deadline" {
    const rt = try testRuntime();
    defer rt.deinit();

    const loopback = parseIp4("127.0.0.1").?;
    var socket = switch (bind(loopback, 0)) {
        .ok => |value| value,
        .err => |code| return std.testing.expectEqual(@as(u8, 0), code),
    };
    defer socket.inner.close();

    var slices: std.ArrayList(Slice) = .empty;
    defer slices.deinit(std.testing.allocator);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(std.testing.allocator);

    switch (receive(&socket, 50, 8, &slices, &payload, std.testing.allocator)) {
        .ok => try std.testing.expect(false),
        .err => |code| try std.testing.expectEqual(ERR_TIMEOUT, code),
    }
}

/// One datagram's bytes out of a batch, for the tests above.
fn sliceOf(batch: Batch, index: usize) []const u8 {
    const entry = batch.slices[index];
    return batch.payload[entry.start..][0..entry.len];
}

/// A runtime for the socket tests, on the calling thread.
///
/// `receive` puts a deadline on its wait, and a deadline is a race between the
/// I/O and a timer, which zio only implements on an event loop -- without a
/// runtime it panics rather than falling back to a blocking read. The app
/// always has one (`src/tasks.zig` starts it), and `enable_main_executor`
/// makes this thread the main task, so the test body waits exactly as `init!`
/// does: it parks the main task and pumps the loop until the answer is in.
fn testRuntime() !*zio.Runtime {
    return zio.Runtime.init(std.testing.allocator, .{
        .executors = .exact(1),
        .enable_main_executor = true,
    });
}
