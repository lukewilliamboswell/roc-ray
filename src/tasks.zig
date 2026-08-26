//! Coroutine-backed app tasks.
//!
//! One zio executor, on the frame thread, runs every task. A task is a boxed
//! Roc closure `() => Msg` handed over by the `Task.spawn!` effect; it runs on
//! its own coroutine stack, parks on the host when it waits, and its message is
//! collected by the frame loop in completion order. No Roc value ever runs on
//! another thread.
const std = @import("std");
const zio = @import("zio");
const abi = @import("roc_platform_abi.zig");

/// A finished task's message, wrapped in the erased thunk Roc calls to unwrap
/// it. The host only moves it; only `receive_task_results` ever calls it.
pub const TaskResult = abi.RocErasedCallable;

/// How many tasks may be running at once.
///
/// Past this, `Task.spawn!` queues the closure and starts it when a slot
/// frees. It never refuses: a refusal would need an error type on every
/// spawn, and an app that wanted two hundred files read would have to write
/// the pacing that this queue already is. Each live task owns a coroutine
/// stack, which is what the cap is really bounding.
pub const max_live_tasks: usize = 32;

/// Scalar host-owned task state attached to every observer event. No Roc
/// value, closure, or message is exposed through this interface.
pub const ObserverCounters = struct {
    live: usize,
    queued: usize,
    finished: usize,
    delivered: usize,
};

/// Where a task was held when orderly shutdown made delivery impossible.
pub const CancellationStage = enum { queued, live, finished };

/// One point in the host-observed lifecycle of an application task.
pub const ObserverEvent = struct {
    task_id: u64,
    cycle: u64,
    timestamp_ns: u64,
    counters: ObserverCounters,
    kind: Kind,

    pub const Kind = union(enum) {
        spawned,
        queued: struct { tasks_ahead: usize },
        started: struct { queued_cycles: u64 },
        parked: struct { effect: []const u8, millis_hint: u64 },
        resumed: struct { effect: []const u8 },
        finished,
        delivered,
        cancelled: CancellationStage,
    };
};

/// Scalar occupancy change for the delayed-start closure queue. `capacity` is
/// null because this queue is proportional to explicit application spawns; the
/// separate `max_live_tasks` limit bounds coroutine stacks, not pending work.
pub const QueueObservation = struct {
    pub const Operation = enum(u8) { reserve = 0, release = 1 };

    operation: Operation,
    cycle: u64,
    timestamp_ns: u64,
    amount: usize,
    current: usize,
    high_water: usize,
    capacity: ?usize = null,
    oldest_at_ns: u64,
};

/// Optional synchronous observation of the task registry. Both callbacks run
/// on the frame thread. `on_event` must copy an effect name if it retains it;
/// every other field is scalar host data. Supplying the clock separately keeps
/// task tests deterministic and lets Observatory use its run-wide monotonic
/// clock without coupling this module to the recorder.
pub const Observer = struct {
    context: *anyopaque,
    now_ns: *const fn (context: *anyopaque) u64,
    on_event: *const fn (context: *anyopaque, event: ObserverEvent) void,
    on_queue: ?*const fn (context: *anyopaque, event: QueueObservation) void = null,
};

/// Identity captured immediately before a waiting effect parks. Passing it
/// back on resume keeps attribution correct when another coroutine ran while
/// this one waited.
pub const ParkToken = struct { task_id: u64 };

/// Behaviour the host supplies: the Roc entry points and the phase guard.
pub fn Tasks(comptime Hooks: type) type {
    return struct {
        const Self = @This();

        const Live = struct {
            id: u64,
            started_cycle: u64,
            handle: zio.JoinHandle(void),
        };

        pub const Finished = struct { id: u64, result: TaskResult };

        /// A spawn that arrived while every slot was taken.
        const Queued = struct { id: u64, spawned_cycle: u64, queued_at_ns: u64, run: abi.RocErasedCallable };

        allocator: std.mem.Allocator,
        rt: ?*zio.Runtime = null,
        live: std.ArrayListUnmanaged(Live) = .empty,
        /// Closures waiting for a live slot, oldest first.
        queued: std.ArrayListUnmanaged(Queued) = .empty,
        finished: std.ArrayListUnmanaged(Finished) = .empty,
        /// The results the last `takeFinished` handed to the frame loop.
        /// Two buffers take turns rather than one being freed and allocated
        /// again every frame a task completes on.
        delivered: std.ArrayListUnmanaged(Finished) = .empty,
        next_id: u64 = 1,
        cycle: u64 = 0,
        trace: bool = false,
        /// Count of tasks abandoned (cancelled and dropped) at shutdown.
        abandoned: u64 = 0,
        /// Nanoseconds the last pump took, for the per-frame overhead number.
        last_pump_ns: u64 = 0,
        /// Totals over the run, reported at shutdown when tracing.
        pump_count: u64 = 0,
        pump_total_ns: u64 = 0,
        /// Pumps that took no task work at all (the idle cost of the scheme).
        idle_pump_count: u64 = 0,
        idle_pump_total_ns: u64 = 0,
        progress: u64 = 0,
        observer: ?Observer = null,
        queued_high_water: usize = 0,
        queued_oldest_at_ns: u64 = 0,
        /// The task whose Roc code is executing right now. It is cleared
        /// before another coroutine can run; waiting effects capture it in a
        /// `ParkToken` before yielding.
        executing_task_id: u64 = 0,

        /// Pointer to the live registry, for the task body and the sleep effect.
        var current: ?*Self = null;

        pub fn init(allocator: std.mem.Allocator, trace: bool) !Self {
            const rt = try zio.Runtime.init(allocator, .{
                .executors = .exact(1),
                .enable_main_executor = true,
            });
            return Self{ .allocator = allocator, .rt = rt, .trace = trace };
        }

        pub fn activate(self: *Self) void {
            current = self;
        }

        pub fn setObserver(self: *Self, observer: ?Observer) void {
            self.observer = observer;
        }

        fn counters(self: *const Self) ObserverCounters {
            return .{
                .live = self.live.items.len,
                .queued = self.queued.items.len,
                .finished = self.finished.items.len,
                .delivered = self.delivered.items.len,
            };
        }

        fn observe(self: *Self, task_id: u64, kind: ObserverEvent.Kind) void {
            const observer = self.observer orelse return;
            observer.on_event(observer.context, .{
                .task_id = task_id,
                .cycle = self.cycle,
                .timestamp_ns = observer.now_ns(observer.context),
                .counters = self.counters(),
                .kind = kind,
            });
        }

        fn observeQueue(self: *Self, operation: QueueObservation.Operation, amount: usize, timestamp_ns: u64) void {
            const observer = self.observer orelse return;
            const callback = observer.on_queue orelse return;
            callback(observer.context, .{
                .operation = operation,
                .cycle = self.cycle,
                .timestamp_ns = timestamp_ns,
                .amount = amount,
                .current = self.queued.items.len,
                .high_water = self.queued_high_water,
                .oldest_at_ns = self.queued_oldest_at_ns,
            });
        }

        /// The runtime a waiting effect performs its IO through, or null when
        /// no app is running (unit tests, or a runtime that would not start).
        pub fn currentRuntime() ?*zio.Runtime {
            const self = current orelse return null;
            return self.rt;
        }

        pub fn liveCount(self: *const Self) usize {
            return self.live.items.len;
        }

        /// Spawns waiting for a slot. Non-zero means the cap is binding.
        pub fn queuedCount(self: *const Self) usize {
            return self.queued.items.len;
        }

        /// Spawn one erased closure on the active registry (`Task.spawn!`).
        /// Without a runtime the closure is released and nothing runs.
        pub fn spawnCurrent(roc_host: *abi.RocHost, run: abi.RocErasedCallable) void {
            const self = current orelse {
                abi.decrefErasedCallable(run, roc_host);
                return;
            };
            self.spawn(roc_host, run);
        }

        fn spawn(self: *Self, roc_host: *abi.RocHost, run: abi.RocErasedCallable) void {
            if (self.rt == null) {
                abi.decrefErasedCallable(run, roc_host);
                return;
            }
            const id = self.next_id;
            self.next_id += 1;
            self.observe(id, .spawned);
            if (self.trace) std.log.info("[TASK {d}] spawned on cycle {d}", .{ id, self.cycle });

            // Past the cap the closure waits its turn rather than being
            // refused. `drainQueued` starts it as soon as a slot frees.
            if (self.live.items.len >= max_live_tasks) {
                const queued_at_ns = if (self.observer) |observer| observer.now_ns(observer.context) else 0;
                self.queued.append(self.allocator, .{ .id = id, .spawned_cycle = self.cycle, .queued_at_ns = queued_at_ns, .run = run }) catch {
                    std.log.err("roc-ray: out of memory queueing task {d}; dropping it", .{id});
                    abi.decrefErasedCallable(run, roc_host);
                    return;
                };
                self.queued_high_water = @max(self.queued_high_water, self.queued.items.len);
                if (self.queued.items.len == 1) self.queued_oldest_at_ns = queued_at_ns;
                self.observeQueue(.reserve, 1, queued_at_ns);
                self.observe(id, .{ .queued = .{ .tasks_ahead = self.queued.items.len - 1 } });
                if (self.trace) std.log.info("[TASK {d}] queued behind {d} live task(s)", .{ id, self.live.items.len });
                return;
            }
            self.start(roc_host, id, run, 0);
        }

        /// Put one closure on its own coroutine, with a slot known to be free.
        fn start(self: *Self, roc_host: *abi.RocHost, id: u64, run: abi.RocErasedCallable, queued_cycles: u64) void {
            const rt = self.rt orelse {
                abi.decrefErasedCallable(run, roc_host);
                return;
            };
            self.live.ensureUnusedCapacity(self.allocator, 1) catch @panic("roc-ray: out of memory spawning a task");
            const handle = rt.spawn(body, .{ id, run, queued_cycles }) catch |err| {
                std.log.err("roc-ray: could not spawn task {d}: {s}", .{ id, @errorName(err) });
                abi.decrefErasedCallable(run, roc_host);
                return;
            };
            self.live.appendAssumeCapacity(.{ .id = id, .started_cycle = self.cycle, .handle = handle });
        }

        /// Start as many queued closures as there are free slots, oldest first.
        ///
        /// FIFO, and that is a guarantee: a queued task runs after every task
        /// queued before it, so the order tasks are spawned in is the order
        /// they are started in.
        fn drainQueued(self: *Self, roc_host: *abi.RocHost) void {
            var started: usize = 0;
            while (started < self.queued.items.len and self.live.items.len < max_live_tasks) : (started += 1) {
                const item = self.queued.items[started];
                if (self.trace) std.log.info("[TASK {d}] dequeued on cycle {d}", .{ item.id, self.cycle });
                self.start(roc_host, item.id, item.run, self.cycle -| item.spawned_cycle);
            }
            if (started != 0) {
                std.mem.copyForwards(Queued, self.queued.items[0 .. self.queued.items.len - started], self.queued.items[started..]);
                self.queued.shrinkRetainingCapacity(self.queued.items.len - started);
                self.queued_oldest_at_ns = if (self.queued.items.len == 0) 0 else self.queued.items[0].queued_at_ns;
                const released_at = if (self.observer) |observer| observer.now_ns(observer.context) else 0;
                self.observeQueue(.release, started, released_at);
            }
        }

        /// The coroutine body: run the Roc closure to completion on this stack.
        fn body(id: u64, run: abi.RocErasedCallable, queued_cycles: u64) void {
            const self = current orelse unreachable;
            self.executing_task_id = id;
            self.progress += 1;
            self.observe(id, .{ .started = .{ .queued_cycles = queued_cycles } });
            if (self.trace) std.log.info("[TASK {d}] started on cycle {d}", .{ id, self.cycle });
            Hooks.enterTaskPhase(id);
            const result = Hooks.runTask(run);
            Hooks.leaveTaskPhase(id);
            self.executing_task_id = 0;
            self.progress += 1;
            if (self.trace) std.log.info("[TASK {d}] finished on cycle {d}", .{ id, self.cycle });
            self.finished.append(self.allocator, .{ .id = id, .result = result }) catch {
                std.log.err("roc-ray: out of memory storing task {d}'s result; dropping it", .{id});
                Hooks.dropResult(result);
                return;
            };
            self.observe(id, .finished);
        }

        /// Called from inside a waiting effect on a task coroutine, around the park.
        pub fn tracePark(id_hint: []const u8, millis: u64) void {
            _ = observePark(id_hint, millis);
        }

        /// Observe a wait and return the identity its resume must use.
        pub fn observePark(id_hint: []const u8, millis: u64) ParkToken {
            const self = current orelse return .{ .task_id = 0 };
            if (self.trace) std.log.info("[TASK] {s} parking {d} ms on cycle {d}", .{ id_hint, millis, self.cycle });
            const token = ParkToken{ .task_id = self.executing_task_id };
            if (token.task_id != 0) self.observe(token.task_id, .{ .parked = .{ .effect = id_hint, .millis_hint = millis } });
            self.executing_task_id = 0;
            return token;
        }

        pub fn traceResume(id_hint: []const u8) void {
            const self = current orelse return;
            observeResume(.{ .task_id = self.executing_task_id }, id_hint);
        }

        /// Observe the matching resume after a waiting effect returns.
        pub fn observeResume(token: ParkToken, id_hint: []const u8) void {
            const self = current orelse return;
            self.executing_task_id = token.task_id;
            self.progress += 1;
            if (self.trace) std.log.info("[TASK] {s} resumed on cycle {d}", .{ id_hint, self.cycle });
            if (token.task_id != 0) self.observe(token.task_id, .{ .resumed = .{ .effect = id_hint } });
        }

        /// Private host correlation identity for the currently running task.
        pub fn executingTaskId() u64 {
            const self = current orelse return 0;
            return self.executing_task_id;
        }

        /// Give the executor one turn: run every ready task until it parks or
        /// finishes, and poll the event loop so parked tasks can wake.
        pub const PumpMode = union(enum) {
            /// Yield from the frame loop's main task and return as soon as it
            /// is ready again.
            yield,
            /// Block the frame loop for this long, running tasks and the event
            /// loop meanwhile (headless pacing).
            sleep_ns: u64,
        };

        pub fn pump(self: *Self, cycle: u64, mode: PumpMode) void {
            self.cycle = cycle;
            if (self.rt == null) return;
            var stopwatch = zio.Stopwatch.start();
            switch (mode) {
                .yield => self.turnUntilQuiet(),
                .sleep_ns => |ns| zio.sleep(.fromNanoseconds(@intCast(ns))) catch {},
            }
            self.last_pump_ns = @intCast(stopwatch.read().toNanoseconds());
            self.pump_count += 1;
            self.pump_total_ns += self.last_pump_ns;
            if (self.live.items.len == 0 and mode == .yield) {
                self.idle_pump_count += 1;
                self.idle_pump_total_ns += self.last_pump_ns;
            }
            self.reap();
            if (self.queued.items.len != 0) {
                self.drainQueued(Hooks.host());
                // The tasks just started have not run at all yet. Give them
                // their turn now rather than a frame from now.
                zio.yield() catch {};
                self.reap();
            }
        }

        /// Give the executor turns until the tasks stop making progress.
        ///
        /// Not `zio.yield()`: its fast path spends a scheduling quantum and
        /// returns without touching the event loop whenever no other task is
        /// already runnable, and the frame thread is the executor's main task,
        /// so one yield per frame polled I/O only every few dozen frames. A
        /// datagram that arrived during the vsync wait sat unseen for that
        /// long.
        ///
        /// A zero-length sleep parks the main task on a timer that is already
        /// due, which is the one public way to make the executor run its loop.
        /// One such turn does only part of the job: the loop polls, readies
        /// the tasks whose I/O completed, and returns to the main task before
        /// running them, because the same poll fired the timer. The next turn
        /// runs them, and a task that then submits another operation -- the
        /// drain half of `Udp.receive!` does exactly that -- needs the pair
        /// again before it can finish. So the turns repeat while any task
        /// starts, resumes or finishes, and for `quiet_turns` beyond that.
        fn turnUntilQuiet(self: *Self) void {
            var turns: usize = 0;
            var quiet: usize = 0;
            while (turns < max_turns and quiet < quiet_turns) : (turns += 1) {
                const before = self.progress;
                zio.sleep(.zero) catch {};
                quiet = if (self.progress == before) quiet + 1 else 0;
            }
        }

        /// Turns of no visible progress before a pump concludes the tasks are
        /// at rest.
        ///
        /// Not one, and not two: progress is only visible when a task's Roc
        /// code runs, and a completion the kernel already has takes several
        /// turns to reach that point -- the poll that reaps it, the turn that
        /// runs the task, the poll for the operation it submits next, and the
        /// turn that runs it again. Measured at five for a `Udp.receive!`
        /// whose datagram arrived while the last frame was being drawn, which
        /// is the case a game's peer traffic is made of. Stopping short of
        /// that is what left the receive to be delivered a frame or two later
        /// than the frame it was ready in.
        const quiet_turns: usize = 6;

        /// Turns one pump will spend chasing tasks that keep resuming. The
        /// bound is what keeps a pathological task from holding the frame.
        const max_turns: usize = 12;

        /// Release the join handles of tasks that have finished.
        fn reap(self: *Self) void {
            var index: usize = 0;
            while (index < self.live.items.len) {
                if (self.live.items[index].handle.hasResult()) {
                    var removed = self.live.swapRemove(index);
                    removed.handle.join();
                } else {
                    index += 1;
                }
            }
        }

        /// The finished tasks' results in completion order, for the host to
        /// stage as responses. The results are the caller's to move; the
        /// slice itself is on loan until `releaseTaken`, and tasks that
        /// finish meanwhile collect into the other buffer.
        ///
        /// The slice is not the caller's to free, and deliberately so: it is
        /// the shorter `items` of a list whose allocation is capacity-sized,
        /// and an allocator handed that back would be freeing at a size it
        /// never allocated at.
        pub fn takeFinished(self: *Self) []const Finished {
            if (self.trace and self.finished.items.len != 0) {
                std.log.info("[TASK] delivering {d} result(s) as messages on cycle {d}", .{ self.finished.items.len, self.cycle });
            }
            std.mem.swap(std.ArrayListUnmanaged(Finished), &self.finished, &self.delivered);
            for (self.delivered.items) |item| self.observe(item.id, .delivered);
            return self.delivered.items;
        }

        /// Give back a slice returned by `takeFinished` once its items are
        /// moved. The buffer stays here for the next frame to fill.
        pub fn releaseTaken(self: *Self, taken: []const Finished) void {
            std.debug.assert(taken.len == self.delivered.items.len);
            self.delivered.clearRetainingCapacity();
        }

        /// Cancel every live task, run each to completion on the cancelled
        /// path, drop any undelivered results, then tear the runtime down.
        pub fn deinit(self: *Self) void {
            // Queued closures never started, so nothing owns them but this
            // list. Drop them before the runtime goes away.
            for (self.queued.items) |item| {
                self.observe(item.id, .{ .cancelled = .queued });
                Hooks.dropResult(item.run);
            }
            const cancelled_queued = self.queued.items.len;
            self.queued.clearRetainingCapacity();
            self.queued_oldest_at_ns = 0;
            if (cancelled_queued != 0) {
                const released_at = if (self.observer) |observer| observer.now_ns(observer.context) else 0;
                self.observeQueue(.release, cancelled_queued, released_at);
            }
            if (self.rt) |rt| {
                for (self.live.items) |*item| {
                    if (self.trace) std.log.info("[TASK {d}] cancelling at shutdown", .{item.id});
                    // Announce cancellation while the coroutine's host-side
                    // identity and diagnostic zones are still intact. The
                    // observer synchronously records any aborted zones before
                    // the stack is torn down.
                    self.observe(item.id, .{ .cancelled = .live });
                    item.handle.cancel();
                    self.abandoned += 1;
                }
                self.live.clearRetainingCapacity();
                for (self.finished.items) |item| {
                    self.observe(item.id, .{ .cancelled = .finished });
                    Hooks.dropResult(item.result);
                }
                self.finished.clearRetainingCapacity();
                if (self.abandoned != 0) std.log.warn("roc-ray: {d} task(s) abandoned at shutdown", .{self.abandoned});
                if (self.trace and self.pump_count != 0) {
                    std.log.info("[TASK] {d} pumps, mean {d} ns; {d} idle pumps, mean {d} ns", .{
                        self.pump_count,
                        self.pump_total_ns / self.pump_count,
                        self.idle_pump_count,
                        if (self.idle_pump_count == 0) 0 else self.idle_pump_total_ns / self.idle_pump_count,
                    });
                }
                rt.deinit();
                self.rt = null;
            }
            self.live.deinit(self.allocator);
            self.queued.deinit(self.allocator);
            self.finished.deinit(self.allocator);
            // Empty by now: whoever took the results gave the buffer back
            // before the app could exit. Only its capacity is left to drop.
            self.delivered.deinit(self.allocator);
            if (current == self) current = null;
        }
    };
}

const ObserverTestCapture = struct {
    now: u64 = 100,
    len: usize = 0,
    events: [16]ObserverEvent = undefined,
    queue_len: usize = 0,
    queue_events: [8]QueueObservation = undefined,

    fn timestamp(context: *anyopaque) u64 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.now += 10;
        return self.now;
    }

    fn append(context: *anyopaque, event: ObserverEvent) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.events[self.len] = event;
        self.len += 1;
    }

    fn appendQueue(context: *anyopaque, event: QueueObservation) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.queue_events[self.queue_len] = event;
        self.queue_len += 1;
    }

    fn observer(self: *@This()) Observer {
        return .{ .context = self, .now_ns = timestamp, .on_event = append, .on_queue = appendQueue };
    }
};

const ObserverTestHooks = struct {
    fn dropResult(_: anytype) void {}
};

test "task observer preserves lifecycle ordering cardinality timestamps and scalar counters" {
    const Registry = Tasks(ObserverTestHooks);
    var registry = Registry{ .allocator = std.testing.allocator, .cycle = 7 };
    defer registry.deinit();

    var capture = ObserverTestCapture{};
    registry.setObserver(capture.observer());

    registry.observe(41, .spawned);
    registry.observe(41, .{ .queued = .{ .tasks_ahead = 3 } });
    registry.observe(41, .{ .started = .{ .queued_cycles = 2 } });
    registry.observe(41, .{ .parked = .{ .effect = "time.sleep", .millis_hint = 25 } });
    registry.observe(41, .{ .resumed = .{ .effect = "time.sleep" } });
    registry.observe(41, .finished);
    registry.observe(41, .delivered);

    try std.testing.expectEqual(@as(usize, 7), capture.len);
    for (capture.events[0..capture.len], 0..) |event, index| {
        try std.testing.expectEqual(@as(u64, 41), event.task_id);
        try std.testing.expectEqual(@as(u64, 7), event.cycle);
        try std.testing.expectEqual(@as(u64, 110 + index * 10), event.timestamp_ns);
        try std.testing.expectEqual(@as(usize, 0), event.counters.live);
        try std.testing.expectEqual(@as(usize, 0), event.counters.queued);
        try std.testing.expectEqual(@as(usize, 0), event.counters.finished);
        try std.testing.expectEqual(@as(usize, 0), event.counters.delivered);
    }
    try std.testing.expect(capture.events[0].kind == .spawned);
    try std.testing.expectEqual(@as(usize, 3), capture.events[1].kind.queued.tasks_ahead);
    try std.testing.expectEqual(@as(u64, 2), capture.events[2].kind.started.queued_cycles);
    try std.testing.expectEqualStrings("time.sleep", capture.events[3].kind.parked.effect);
    try std.testing.expectEqual(@as(u64, 25), capture.events[3].kind.parked.millis_hint);
    try std.testing.expectEqualStrings("time.sleep", capture.events[4].kind.resumed.effect);
    try std.testing.expect(capture.events[5].kind == .finished);
    try std.testing.expect(capture.events[6].kind == .delivered);
}

test "task observer distinguishes every cancellation stage exactly once" {
    const Registry = Tasks(ObserverTestHooks);
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();

    var capture = ObserverTestCapture{};
    registry.setObserver(capture.observer());
    registry.observe(1, .{ .cancelled = .queued });
    registry.observe(2, .{ .cancelled = .live });
    registry.observe(3, .{ .cancelled = .finished });

    try std.testing.expectEqual(@as(usize, 3), capture.len);
    try std.testing.expectEqual(CancellationStage.queued, capture.events[0].kind.cancelled);
    try std.testing.expectEqual(CancellationStage.live, capture.events[1].kind.cancelled);
    try std.testing.expectEqual(CancellationStage.finished, capture.events[2].kind.cancelled);
}

test "disabled task observation does not call a clock or retain observer state" {
    const Registry = Tasks(ObserverTestHooks);
    var registry = Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();

    registry.observe(1, .spawned);
    try std.testing.expect(registry.observer == null);
}

test "pending task queue observation is scalar and has no invented capacity" {
    const Registry = Tasks(ObserverTestHooks);
    var registry = Registry{ .allocator = std.testing.allocator, .cycle = 12 };
    defer registry.deinit();

    var capture = ObserverTestCapture{};
    registry.setObserver(capture.observer());
    registry.queued_high_water = 3;
    registry.queued_oldest_at_ns = 80;
    registry.observeQueue(.reserve, 1, 110);
    registry.queued_oldest_at_ns = 0;
    registry.observeQueue(.release, 3, 140);

    try std.testing.expectEqual(@as(usize, 2), capture.queue_len);
    try std.testing.expectEqual(.reserve, capture.queue_events[0].operation);
    try std.testing.expectEqual(@as(u64, 12), capture.queue_events[0].cycle);
    try std.testing.expectEqual(@as(u64, 80), capture.queue_events[0].oldest_at_ns);
    try std.testing.expectEqual(@as(usize, 3), capture.queue_events[0].high_water);
    try std.testing.expect(capture.queue_events[0].capacity == null);
    try std.testing.expectEqual(.release, capture.queue_events[1].operation);
    try std.testing.expectEqual(@as(usize, 3), capture.queue_events[1].amount);
    try std.testing.expect(capture.queue_events[1].capacity == null);
}
