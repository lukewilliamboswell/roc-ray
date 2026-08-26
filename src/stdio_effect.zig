//! The `Stdout` and `Stderr` effects: two host-owned rings, and the one thread
//! that drains them.
//!
//! Writing to a standard stream is a queued effect. The call copies the
//! payload into a fixed ring the host owns and returns at once; a dedicated
//! writer thread takes bytes back out and issues the blocking writes. That is
//! what makes `Stdout.line!` legal in `update!`: a pipe whose reader is slow or
//! has stopped blocks the writer thread, never the frame thread, and never a
//! Roc coroutine.
//!
//! ## Bounds
//!
//! Each stream has `ring_capacity` bytes of queue and no more. A payload larger
//! than the whole ring is `ERR_TOO_LARGE` and can never be queued, whatever the
//! app waits for. A payload that does not fit right now is `ERR_BUFFER_FULL`
//! with nothing queued: a write is all-or-nothing, because half a line in a
//! pipe is worse than no line. Pending output is therefore at most two rings'
//! worth, and that is exactly what the orderly drain at shutdown is bounded by.
//!
//! ## Ownership
//!
//! The bytes in a ring are the host's own copy, made while the caller still
//! holds the Roc value. The value is released before the effect returns, so the
//! writer thread never sees a Roc value, the Roc host pointer, or `roc_alloc`.
//! `host_native.zig` owns the phase guard and the Roc entry points; this file
//! owns the rings, the thread, and nothing else.

const std = @import("std");
const builtin = @import("builtin");

/// How many bytes of unwritten output one stream may hold.
///
/// This is the whole bound on a queued write: the largest payload that can ever
/// be accepted, the most that can be in flight at once, and the most the
/// shutdown drain can have left to write.
pub const ring_capacity: usize = 256 * 1024;

/// The ring `Stdout` writes into.
pub const stdout_index: u8 = 0;

/// The ring `Stderr` writes into.
pub const stderr_index: u8 = 1;

/// Every byte of the payload is queued. Mirrored in `StdioHost.roc`.
pub const OK: u8 = 0;

/// There is no drainer: the app has not started, or shutdown has begun. Also
/// how a stream whose reader has gone away answers from then on. Shares the
/// code the file effects use for the same meaning.
pub const ERR_UNAVAILABLE: u8 = 4;

/// The payload is larger than a whole ring, so it can never be queued.
pub const ERR_TOO_LARGE: u8 = 5;

/// The payload does not fit in what is free right now, and nothing was queued.
/// Numbered past the shared table: only a queued effect can saturate.
pub const ERR_BUFFER_FULL: u8 = 11;

/// The most one write syscall carries out of a ring.
///
/// A drain takes this much at a time, so the ring's lock is held for a copy
/// rather than for a write, and a producer gets space back while a large
/// backlog is still going out.
const drain_chunk_bytes: usize = 64 * 1024;

/// Two rings, the thread that drains them, and the files they drain into.
///
/// Parameterized by capacity so a test can exercise saturation and wraparound
/// on a ring small enough to fill by hand, against the same code the process
/// runs with `ring_capacity`.
pub fn Streams(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        /// One stream's unwritten bytes, oldest first.
        const Ring = struct {
            bytes: [capacity]u8 = undefined,
            /// Where the next byte to be written out lives.
            head: usize = 0,
            /// How many bytes are queued from `head` on.
            len: usize = 0,
            /// Set once the drainer has seen this stream's far end go away. A
            /// dead ring is emptied and refuses everything after, rather than
            /// accumulating output nothing will ever read.
            dead: bool = false,
            high_water: usize = 0,
            oldest_at_ns: u64 = 0,

            fn push(self: *Ring, payload: []const u8) void {
                var offset: usize = 0;
                while (offset < payload.len) {
                    const at = (self.head + self.len) % capacity;
                    const run = @min(payload.len - offset, capacity - at);
                    @memcpy(self.bytes[at..][0..run], payload[offset..][0..run]);
                    self.len += run;
                    offset += run;
                }
            }

            /// Copy out the longest run that is contiguous in the ring and that
            /// `out` can hold, and forget it. A payload that wrapped comes out
            /// over two takes, in order.
            fn take(self: *Ring, out: []u8) usize {
                const run = @min(@min(self.len, capacity - self.head), out.len);
                @memcpy(out[0..run], self.bytes[self.head..][0..run]);
                self.head = (self.head + run) % capacity;
                self.len -= run;
                return run;
            }

            fn clear(self: *Ring) void {
                self.head = 0;
                self.len = 0;
            }
        };

        rings: [2]Ring = .{ .{}, .{} },
        files: [2]std.Io.File = undefined,
        /// Futex backend for the lock and the wakeups. Set by `arm`, and the
        /// same value on both threads: these are ordinary address-based
        /// futexes, so the producer and the drainer meet on the address.
        io: std.Io = undefined,
        /// Guards every field above, and `stopping`. Held for a copy at a time
        /// and never across a write, so a frame thread that contends with the
        /// drainer waits for a `memcpy` rather than for a pipe.
        mutex: std.Io.Mutex = .init,
        /// Signalled when a ring gains bytes, and broadcast when stopping.
        wake: std.Io.Condition = .init,
        thread: ?std.Thread = null,
        /// Which ring the drainer looks at first, so a chatty stream cannot
        /// starve the other one.
        next: u8 = 0,
        /// Set by `stop`. The drainer finishes what is queued and then exits.
        stopping: bool = false,
        /// Whether writes are being accepted. Read before the lock is taken,
        /// because `io` is only valid once `arm` has run.
        accepting: std.atomic.Value(bool) = .init(false),
        observer: ?*const fn (Self.QueueObservation) void = null,

        /// Byte-unit pressure event for one standard-stream ring.
        pub const QueueObservation = struct {
            operation: enum(u8) { reserve, release, saturation },
            stream: u8,
            timestamp_ns: u64,
            amount: usize,
            current: usize,
            high_water: usize,
            capacity_bytes: usize,
            oldest_at_ns: u64,
        };

        /// Install an observer for the active host run.
        pub fn setObserver(self: *Self, next: ?*const fn (Self.QueueObservation) void) void {
            self.observer = next;
        }

        fn nowNs(self: *Self) u64 {
            return @intCast(@max(std.Io.Clock.awake.now(self.io).nanoseconds, 0));
        }

        fn observe(self: *Self, event: Self.QueueObservation) void {
            if (self.observer) |callback| callback(event);
        }

        /// Take the two destination files and begin accepting writes, without
        /// starting a drainer.
        ///
        /// `start` is this plus the thread. On its own it is what a test that
        /// is checking the ring's own arithmetic uses: saturation and
        /// wraparound are then reachable without racing a drainer for them.
        pub fn arm(self: *Self, io: std.Io, out_file: std.Io.File, err_file: std.Io.File) void {
            self.io = io;
            self.files = .{ out_file, err_file };
            for (&self.rings) |*ring| {
                ring.clear();
                ring.dead = false;
                ring.high_water = 0;
                ring.oldest_at_ns = 0;
            }
            self.next = 0;
            self.stopping = false;
            self.accepting.store(true, .release);
        }

        /// Begin accepting writes and start the thread that drains them.
        ///
        /// The two files are the drain destinations: the process passes its own
        /// standard output and standard error, and a test passes a pipe.
        pub fn start(
            self: *Self,
            gpa: std.mem.Allocator,
            io: std.Io,
            out_file: std.Io.File,
            err_file: std.Io.File,
        ) std.Thread.SpawnError!void {
            std.debug.assert(self.thread == null);
            self.arm(io, out_file, err_file);
            errdefer self.accepting.store(false, .release);
            self.thread = try std.Thread.spawn(.{}, drainLoop, .{ self, gpa });
        }

        /// Refuse further writes, drain what is already queued, and join the
        /// writer.
        ///
        /// Joining is the wait: the drainer returns once both rings are empty
        /// or their destinations are dead, so this is bounded by two rings of
        /// pending output and by how fast the far end reads them.
        pub fn stop(self: *Self) void {
            const thread = self.thread orelse {
                self.accepting.store(false, .release);
                return;
            };
            self.mutex.lockUncancelable(self.io);
            self.accepting.store(false, .release);
            self.stopping = true;
            self.wake.broadcast(self.io);
            self.mutex.unlock(self.io);

            thread.join();
            self.thread = null;
            self.stopping = false;
        }

        /// Copy one payload into a stream's ring, whole or not at all.
        ///
        /// `head` and `tail` are one payload in that order, so a line reserves
        /// its text and its newline together and nothing another write can land
        /// between them.
        pub fn queue(self: *Self, stream: u8, head: []const u8, tail: []const u8) u8 {
            const total = head.len + tail.len;
            // Checked first, and without the lock: a payload past the whole
            // ring is refused for a reason no amount of draining changes.
            if (total > capacity) return ERR_TOO_LARGE;
            // Before the lock, because `io` is only valid once armed.
            if (!self.accepting.load(.acquire)) return ERR_UNAVAILABLE;

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (!self.accepting.load(.monotonic)) return ERR_UNAVAILABLE;
            const ring = &self.rings[stream];
            if (ring.dead) return ERR_UNAVAILABLE;
            if (capacity - ring.len < total) {
                const now = self.nowNs();
                self.observe(.{ .operation = .saturation, .stream = stream, .timestamp_ns = now, .amount = total, .current = ring.len, .high_water = ring.high_water, .capacity_bytes = capacity, .oldest_at_ns = ring.oldest_at_ns });
                return ERR_BUFFER_FULL;
            }
            const was_empty = ring.len == 0;
            ring.push(head);
            ring.push(tail);
            const now = self.nowNs();
            ring.high_water = @max(ring.high_water, ring.len);
            if (was_empty) ring.oldest_at_ns = now;
            self.observe(.{ .operation = .reserve, .stream = stream, .timestamp_ns = now, .amount = total, .current = ring.len, .high_water = ring.high_water, .capacity_bytes = capacity, .oldest_at_ns = ring.oldest_at_ns });
            self.wake.signal(self.io);
            return OK;
        }

        /// How many of this stream's bytes are queued but not yet written.
        pub fn pending(self: *Self, stream: u8) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.rings[stream].len;
        }

        /// Whether the drainer has seen this stream's far end go away.
        pub fn isDead(self: *Self, stream: u8) bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.rings[stream].dead;
        }

        /// Pick a ring that has bytes to write, alternating between the two.
        fn nextReadyLocked(self: *Self) ?u8 {
            var probe: u8 = 0;
            while (probe < 2) : (probe += 1) {
                const index: u8 = (self.next + probe) % 2;
                if (self.rings[index].len != 0) {
                    self.next = (index + 1) % 2;
                    return index;
                }
            }
            return null;
        }

        /// The writer thread: copy a chunk out under the lock, write it outside
        /// the lock, and repeat until stopped and empty.
        fn drainLoop(self: *Self, gpa: std.mem.Allocator) void {
            // std's threaded implementation is the one backend that behaves the
            // same for a terminal, a pipe, a file redirect and a Windows console
            // handle, and it is what installs the handler that turns a write to
            // a closed pipe into an error rather than a signal that kills the
            // process. Blocking here is the whole point: this thread exists so
            // that no other one has to.
            var threaded: std.Io.Threaded = .init(gpa, .{});
            defer threaded.deinit();
            const write_io = threaded.io();

            var scratch: [drain_chunk_bytes]u8 = undefined;
            while (true) {
                var stream: u8 = undefined;
                var taken: usize = 0;
                var file: std.Io.File = undefined;
                {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    while (true) {
                        if (self.nextReadyLocked()) |ready| {
                            stream = ready;
                            break;
                        }
                        if (self.stopping) return;
                        self.wake.waitUncancelable(self.io, &self.mutex);
                    }
                    taken = self.rings[stream].take(&scratch);
                    const ring = &self.rings[stream];
                    const now = self.nowNs();
                    self.observe(.{ .operation = .release, .stream = stream, .timestamp_ns = now, .amount = taken, .current = ring.len, .high_water = ring.high_water, .capacity_bytes = capacity, .oldest_at_ns = ring.oldest_at_ns });
                    if (ring.len == 0) ring.oldest_at_ns = 0;
                    file = self.files[stream];
                }

                if (writeChunk(file, write_io, scratch[0..taken])) continue;

                // The far end is gone, or the stream failed in a way retrying
                // cannot help. Drop what is queued and refuse the rest: an app
                // told `Ok({})` for output nothing can ever read is worse off
                // than one told the stream is `Unavailable`.
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                self.rings[stream].dead = true;
                self.rings[stream].clear();
            }
        }

        /// Write every byte, retrying short writes. False once the stream is no
        /// longer worth writing to.
        fn writeChunk(file: std.Io.File, io: std.Io, bytes: []const u8) bool {
            var remaining = bytes;
            while (remaining.len > 0) {
                const written = std.Io.File.writeStreaming(file, io, &.{}, &.{remaining}, 1) catch return false;
                // No progress is not something a retry loop can resolve.
                if (written == 0) return false;
                remaining = remaining[written..];
            }
            return true;
        }
    };
}

/// The process's own two streams. One instance, because there is one standard
/// output and one standard error.
pub const HostStreams = Streams(ring_capacity);
/// Pressure event emitted by the process stream rings.
pub const QueueObservation = HostStreams.QueueObservation;

var process_streams: HostStreams = .{};

/// Install or remove process-stream pressure observation.
pub fn setObserver(next: ?*const fn (QueueObservation) void) void {
    process_streams.setObserver(next);
}

/// Start draining the process's standard streams.
///
/// The files are passed in rather than taken from the process so a host test
/// can point the real entry points at a pipe. A writer thread that cannot be
/// spawned leaves every write answering `Unavailable`, which is the truth:
/// there is no drainer.
pub fn activate(gpa: std.mem.Allocator, io: std.Io, out_file: std.Io.File, err_file: std.Io.File) void {
    process_streams.start(gpa, io, out_file, err_file) catch |err| {
        std.log.err("roc-ray: could not start the stdio writer: {s}", .{@errorName(err)});
    };
}

/// Drain what the app queued and stop accepting writes. Called once, last, on
/// the orderly shutdown path.
pub fn shutdown() void {
    process_streams.stop();
}

/// Queue one payload for a process stream. See `Streams.queue`.
pub fn write(stream: u8, head: []const u8, tail: []const u8) u8 {
    return process_streams.queue(stream, head, tail);
}

const testing = std.testing;

/// A ring small enough to fill by hand, so saturation and wraparound are
/// reachable without a quarter of a megabyte of test data.
const TestStreams = Streams(32);

/// A pipe, and its two ends as `std.Io.File`s. POSIX only; the tests that use
/// it skip elsewhere.
const TestPipe = struct {
    read_end: std.Io.File,
    write_end: std.Io.File,

    fn open() !TestPipe {
        const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
        return .{
            .read_end = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
            .write_end = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
        };
    }

    fn closeRead(self: *TestPipe) void {
        std.Io.Threaded.closeFd(self.read_end.handle);
    }

    fn closeWrite(self: *TestPipe) void {
        std.Io.Threaded.closeFd(self.write_end.handle);
    }

    /// Read exactly `out.len` bytes, or fail. The drainer is writing them from
    /// another thread, so a short read is normal rather than the end.
    fn readExactly(self: *TestPipe, out: []u8) !void {
        var filled: usize = 0;
        while (filled < out.len) {
            const got = try std.posix.read(self.read_end.handle, out[filled..]);
            if (got == 0) return error.EndOfStream;
            filled += got;
        }
    }
};

test "a payload larger than the whole ring can never be queued" {
    var streams: TestStreams = .{};
    var oversized: [33]u8 = undefined;
    @memset(&oversized, 'x');

    // Refused before the drainer is even consulted: no amount of draining
    // makes room for something the ring cannot hold.
    try testing.expectEqual(ERR_TOO_LARGE, streams.queue(stdout_index, &oversized, &.{}));

    // A line queues its newline with its text, so the longest string a line can
    // carry is one byte shorter than the longest a plain write can.
    try testing.expectEqual(ERR_TOO_LARGE, streams.queue(stdout_index, oversized[0..32], "\n"));
}

test "a write with no drainer is unavailable rather than queued" {
    var streams: TestStreams = .{};
    try testing.expectEqual(ERR_UNAVAILABLE, streams.queue(stdout_index, "hello", "\n"));
}

test "saturation is reported, and the ring is left exactly as it was" {
    var streams: TestStreams = .{};
    // Armed but with no thread, so nothing can drain: the ring's own arithmetic
    // is what is under test, free of timing.
    streams.arm(testing.io, .stdout(), .stderr());

    try testing.expectEqual(OK, streams.queue(stdout_index, "0123456789abcdef", &.{}));
    try testing.expectEqual(OK, streams.queue(stdout_index, "0123456789abcde", "f"));
    try testing.expectEqual(@as(usize, 32), streams.pending(stdout_index));

    // Full to the byte. One more is `BufferFull` with nothing queued, which is
    // a different answer from `TooLarge`: this one a drain can fix.
    try testing.expectEqual(ERR_BUFFER_FULL, streams.queue(stdout_index, "!", &.{}));
    try testing.expectEqual(@as(usize, 32), streams.pending(stdout_index));

    // A line that half fits is refused whole, rather than queuing its text and
    // dropping its newline.
    var drained: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 16), streams.rings[stdout_index].take(&drained));
    try testing.expectEqual(ERR_BUFFER_FULL, streams.queue(stdout_index, "0123456789abcdef", "\n"));
    try testing.expectEqual(@as(usize, 16), streams.pending(stdout_index));

    // The other stream has a ring of its own and is unaffected.
    try testing.expectEqual(OK, streams.queue(stderr_index, "!", &.{}));
    try testing.expectEqual(@as(usize, 1), streams.pending(stderr_index));
}

test "stream observer reports byte reserve saturation and high water" {
    const Probe = struct {
        var events: [2]TestStreams.QueueObservation = undefined;
        var count: usize = 0;
        fn callback(event: TestStreams.QueueObservation) void {
            events[count] = event;
            count += 1;
        }
    };
    var streams: TestStreams = .{};
    streams.arm(testing.io, .stdout(), .stderr());
    streams.setObserver(Probe.callback);
    Probe.count = 0;
    try testing.expectEqual(OK, streams.queue(stdout_index, "0123456789abcdef0123456789abcdef", &.{}));
    try testing.expectEqual(ERR_BUFFER_FULL, streams.queue(stdout_index, "!", &.{}));
    try testing.expectEqual(@as(usize, 2), Probe.count);
    try testing.expectEqual(.reserve, Probe.events[0].operation);
    try testing.expectEqual(@as(usize, 32), Probe.events[0].high_water);
    try testing.expectEqual(.saturation, Probe.events[1].operation);
    try testing.expectEqual(@as(usize, 32), Probe.events[1].current);
    try testing.expect(Probe.events[1].oldest_at_ns != 0);
}

test "a payload that wraps the ring comes out in order" {
    var streams: TestStreams = .{};
    streams.arm(testing.io, .stdout(), .stderr());

    // Push the head most of the way round and take it back out, so the next
    // payload starts near the end of the buffer and wraps.
    try testing.expectEqual(OK, streams.queue(stdout_index, "0123456789abcdefghijklmnopqrstuv", &.{}));
    var drained: [32]u8 = undefined;
    try testing.expectEqual(@as(usize, 32), streams.rings[stdout_index].take(&drained));

    try testing.expectEqual(OK, streams.queue(stdout_index, "wrapped-", "line\n"));
    var out: [13]u8 = undefined;
    var filled: usize = 0;
    while (filled < out.len) {
        filled += streams.rings[stdout_index].take(out[filled..]);
    }
    try testing.expectEqualStrings("wrapped-line\n", &out);
}

test "the drainer writes every queued byte to the pipe, in order" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pipe = try TestPipe.open();
    defer pipe.closeRead();

    var streams: TestStreams = .{};
    try streams.start(testing.allocator, testing.io, pipe.write_end, pipe.write_end);

    // Far more than the ring holds, in small writes: the point is that order
    // survives both the wraparound and the chunking the drainer does. A
    // saturated queue is waited out rather than dropped, which is what an app
    // that cannot afford to lose a line does with `BufferFull`.
    var expected: std.ArrayListUnmanaged(u8) = .empty;
    defer expected.deinit(testing.allocator);
    var written: usize = 0;
    while (written < 200) {
        var digits: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&digits, "{d}", .{written}) catch unreachable;
        switch (streams.queue(stdout_index, text, "\n")) {
            OK => {
                try expected.appendSlice(testing.allocator, text);
                try expected.append(testing.allocator, '\n');
                written += 1;
            },
            ERR_BUFFER_FULL => std.Thread.yield() catch {},
            else => return error.UnexpectedWriteCode,
        }
    }

    streams.stop();
    pipe.closeWrite();

    const seen = try testing.allocator.alloc(u8, expected.items.len);
    defer testing.allocator.free(seen);
    try pipe.readExactly(seen);
    try testing.expectEqualStrings(expected.items, seen);
}

test "shutdown drains what was queued before the process exits" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pipe = try TestPipe.open();
    defer pipe.closeRead();

    var streams: TestStreams = .{};
    try streams.start(testing.allocator, testing.io, pipe.write_end, pipe.write_end);

    // Queued and then shut down at once, which is the "print, then exit in the
    // same update!" case: the bytes are still in the ring when the app is over,
    // and the drain is what gets them out of the process.
    try testing.expectEqual(OK, streams.queue(stdout_index, "last words", "\n"));
    streams.stop();
    pipe.closeWrite();

    var seen: [11]u8 = undefined;
    try pipe.readExactly(&seen);
    try testing.expectEqualStrings("last words\n", &seen);

    // Shutdown is over, so there is no drainer: a later write is refused rather
    // than left in a ring nobody will empty.
    try testing.expectEqual(ERR_UNAVAILABLE, streams.queue(stdout_index, "too late", "\n"));
}

test "a stream whose reader has gone away is unavailable from then on" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pipe = try TestPipe.open();
    defer pipe.closeWrite();

    var streams: TestStreams = .{};
    try streams.start(testing.allocator, testing.io, pipe.write_end, pipe.write_end);
    defer streams.stop();

    // `myapp | head -1`: the reader is gone before the write goes out. The
    // drainer is the one that finds out, and it records it for the next call.
    pipe.closeRead();

    var attempt: usize = 0;
    while (attempt < 100_000) : (attempt += 1) {
        if (streams.queue(stdout_index, "into the void", "\n") == ERR_UNAVAILABLE) break;
        std.Thread.yield() catch {};
    }
    try testing.expect(streams.isDead(stdout_index));
    try testing.expectEqual(ERR_UNAVAILABLE, streams.queue(stdout_index, "and again", "\n"));
}
