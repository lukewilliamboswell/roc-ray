//! Capture policy: output-path sandboxing, frame budgets, stride and scale
//! gating, and the recording state machine.
//!
//! Deliberately free of raylib and of any GPU dependency, so the whole policy
//! layer is exercised by `zig test` on a machine with no display. Framebuffer
//! access lives in `backend_raylib.zig`; encoding lives behind `Sink`.

const std = @import("std");

/// Write a single still image.
pub const format_png: u8 = 0;
/// Write an animated GIF, encoded incrementally into an open file.
pub const format_gif: u8 = 1;
/// Write a VP8 video in a WebM container, streamed frame by frame.
pub const format_webm: u8 = 2;

/// Advance simulation time with raylib's real frame delta.
pub const timing_real_time: u8 = 0;
/// Advance simulation time in exact `1/fps` steps, ignoring the wall clock.
pub const timing_fixed_step: u8 = 1;

/// Leave the recording free of any pointer glyph.
pub const cursor_none: u8 = 0;
/// Composite a pointer glyph at the mouse position before each readback.
pub const cursor_draw: u8 = 1;

// Encoder effort, as chosen by `Capture.Quality` on the Roc side. These numbers
// are the contract between `types/Capture.roc`'s `quality_code` and this host,
// so they must not be renumbered without changing both. Only the palette-
// quantized formats have anything to spend the extra effort on, so today this
// binds GIF and is ignored by PNG and WebM.

/// Coarse palette search: smaller files everywhere and a materially faster
/// encode on colourful frames, at the cost of visible banding.
pub const quality_fast: u8 = 0;
/// The default: indistinguishable from `quality_best` on frames colourful
/// enough that the encoder reduces the palette anyway, and a little smaller and
/// faster on flat ones.
pub const quality_balanced: u8 = 1;
/// Full palette search, matching what msf_gif's own examples use.
pub const quality_best: u8 = 2;

/// The request succeeded.
pub const err_none: u8 = 0;
/// The path was empty, absolute, contained `..`, or held a NUL byte.
pub const err_path_invalid: u8 = 1;
/// The path resolved outside the configured output directory.
pub const err_path_escapes: u8 = 2;
/// A recording is already running.
pub const err_already_recording: u8 = 3;
/// No recording is running.
pub const err_not_recording: u8 = 4;
/// The requested format is not compiled into this host.
pub const err_unsupported_format: u8 = 5;
/// The recording would exceed the host's in-memory encoding budget.
pub const err_budget_exceeded: u8 = 6;
/// A frame buffer could not be allocated.
pub const err_out_of_memory: u8 = 7;
/// The output file could not be created or written.
pub const err_write_failed: u8 = 8;
/// The encoder rejected a frame or failed to finalize.
pub const err_encode_failed: u8 = 9;
/// The host declined to start the work, and nothing was captured or written.
///
/// Distinct from `err_already_recording`, which says a specific request is
/// still outstanding. This one says the host is at its limit across all
/// requests -- the same operation offered on a later frame may well be taken,
/// which is exactly the difference an app needs to decide whether to retry.
pub const err_busy: u8 = 10;

/// No recording is active.
pub const status_idle: u8 = 0;
/// A recording is running and accepting frames.
pub const status_active: u8 = 1;
/// A recording stopped early; `Session.failure` holds the reason.
pub const status_failed: u8 = 2;

/// Largest in-memory footprint a buffering encoder may reach, in bytes.
///
/// No shipped format buffers -- see `formatBuffers` -- so this currently binds
/// nothing. It exists so that a sink which does have to hold a whole recording
/// fails at `start!` with a clear error, instead of driving the process into
/// the OOM killer part-way through a long capture.
pub const default_memory_budget_bytes: u64 = 256 * 1024 * 1024;

/// Longest path we will assemble from the output directory and a request.
pub const path_capacity: usize = 1024;

/// A resolved capture request, flattened from the Roc-side `Recording`.
pub const Request = struct {
    path: []const u8,
    format: u8,
    fps: i32,
    max_frames: u64,
    scale_numerator: u32,
    scale_denominator: u32,
    every_nth: u32,
    timing: u8,
    cursor: u8,
    quality: u8,
};

/// Why a running recording stopped early, or `err_none` if it did not.
pub const Failure = u8;

/// Reject a request path that could resolve outside the output directory.
///
/// This guards the path an app names at runtime, not the output directory
/// itself -- that is chosen by the app author in `App.Config` and is used as
/// given. Absolute paths, parent traversal, NUL bytes, and `~` are refused
/// rather than normalized: silently rewriting a path an app asked for is worse
/// than failing it.
pub fn validateRelativePath(path: []const u8) u8 {
    if (path.len == 0) return err_path_invalid;
    if (path.len > path_capacity) return err_path_invalid;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return err_path_invalid;
    if (path[0] == '/' or path[0] == '\\' or path[0] == '~') return err_path_invalid;
    // A Windows drive letter (`C:`) or an alternate data stream both escape.
    if (std.mem.indexOfScalar(u8, path, ':') != null) return err_path_invalid;

    var components = std.mem.splitAny(u8, path, "/\\");
    var saw_component = false;
    while (components.next()) |component| {
        if (component.len == 0) continue;
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) return err_path_escapes;
        saw_component = true;
    }
    if (!saw_component) return err_path_invalid;
    return err_none;
}

/// Join a validated request path under the output directory.
///
/// Returns the slice of `buffer` holding the result. The caller has already
/// run `validateRelativePath`, so this cannot produce an escaping path.
pub fn joinOutputPath(buffer: []u8, output_dir: []const u8, path: []const u8) ?[]const u8 {
    const dir = std.mem.trimEnd(u8, output_dir, "/\\");
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) {
        if (path.len > buffer.len) return null;
        @memcpy(buffer[0..path.len], path);
        return buffer[0..path.len];
    }
    const needed = dir.len + 1 + path.len;
    if (needed > buffer.len) return null;
    @memcpy(buffer[0..dir.len], dir);
    buffer[dir.len] = '/';
    @memcpy(buffer[dir.len + 1 ..][0..path.len], path);
    return buffer[0..needed];
}

/// Apply a scale ratio to one framebuffer axis, never yielding zero.
///
/// A recording scaled below one pixel in either axis would produce an encoder
/// error rather than a useful file, so clamp up instead.
pub fn scaleAxis(value: u32, numerator: u32, denominator: u32) u32 {
    if (denominator == 0 or numerator == 0) return value;
    const scaled = (@as(u64, value) * @as(u64, numerator)) / @as(u64, denominator);
    if (scaled == 0) return 1;
    return std.math.cast(u32, scaled) orelse value;
}

/// A framebuffer or render-target size in pixels.
pub const Extent = struct {
    width: u32,
    height: u32,
};

/// Most render targets a GPU downscale is allowed to walk through.
///
/// The first is the framebuffer size and the last is the recording size, so
/// this caps the halving chain at six steps -- a 64x reduction, well past any
/// ratio worth recording. A deeper request still works: the last step just
/// shrinks by more than half, which costs quality, not correctness.
pub const max_downscale_levels: usize = 8;

/// The chain of render-target sizes a GPU downscale renders through.
pub const DownscalePlan = struct {
    levels: [max_downscale_levels]Extent,
    count: usize,

    /// The framebuffer size the chain starts from.
    pub fn source(self: DownscalePlan) Extent {
        return self.levels[0];
    }

    /// The recording size the chain ends at.
    pub fn target(self: DownscalePlan) Extent {
        return self.levels[self.count - 1];
    }
};

/// Plan the render targets that shrink a framebuffer to the recording size.
///
/// Returns null when there is nothing to gain -- the recording is already the
/// framebuffer size, or is larger than it, in which case a full-resolution
/// readback moves no more data than a scaled one and the CPU path is simpler.
///
/// Every intermediate step halves both axes, because a bilinear sample of a
/// texture drawn at exactly half size lands on a texel corner and averages the
/// 2x2 block around it. Chaining halvings therefore box-filters the whole
/// source, where a single bilinear step straight down to a quarter would read
/// four of every sixteen pixels and alias badly. The chain stops halving once
/// another halving would undershoot, and a final step covers the remainder.
pub fn planDownscale(
    source_width: u32,
    source_height: u32,
    target_width: u32,
    target_height: u32,
) ?DownscalePlan {
    if (source_width == 0 or source_height == 0) return null;
    if (target_width == 0 or target_height == 0) return null;
    if (target_width > source_width or target_height > source_height) return null;
    if (target_width == source_width and target_height == source_height) return null;

    var plan = DownscalePlan{
        .levels = [_]Extent{.{ .width = 0, .height = 0 }} ** max_downscale_levels,
        .count = 1,
    };
    plan.levels[0] = .{ .width = source_width, .height = source_height };

    // Leave room for the final exact-size step, which always runs unless a
    // halving happens to land on the requested size.
    while (plan.count < max_downscale_levels - 1) {
        const current = plan.levels[plan.count - 1];
        const halved_width = current.width / 2;
        const halved_height = current.height / 2;
        if (halved_width < target_width or halved_height < target_height) break;
        plan.levels[plan.count] = .{ .width = halved_width, .height = halved_height };
        plan.count += 1;
    }

    const last = plan.levels[plan.count - 1];
    if (last.width != target_width or last.height != target_height) {
        plan.levels[plan.count] = .{ .width = target_width, .height = target_height };
        plan.count += 1;
    }

    // A plan of one level is the framebuffer itself, which the caller already
    // has: only a real chain is worth building render targets for.
    if (plan.count < 2) return null;
    return plan;
}

/// Bytes a buffering encoder needs to hold an entire recording.
///
/// Saturates rather than wrapping so an absurd request reports a huge number
/// and is refused, instead of overflowing into a small one and being accepted.
pub fn estimateBufferedBytes(width: u32, height: u32, frames: u64) u64 {
    const pixels = @as(u64, width) *| @as(u64, height);
    return pixels *| 4 *| frames;
}

/// Does this format accumulate every frame in memory before finalizing?
///
/// None currently do. PNG writes a file per frame, and both GIF and WebM
/// encode incrementally into an open container, so memory stays bounded by a
/// single frame however long the recording runs. The budget gate stays because
/// it is what decides that, and a future buffering sink must opt into it here
/// rather than silently growing without a limit.
pub fn formatBuffers(format: u8) bool {
    _ = format;
    return false;
}

/// Fold an unrecognized quality code onto the default.
///
/// Roc only ever sends 0-2, so this binds only if the two sides drift or if a
/// future Roc release adds a level this host predates. Falling back to the
/// default beats failing a recording over a knob nobody asked to be strict.
pub fn normalizeQuality(value: u8) u8 {
    return switch (value) {
        quality_fast, quality_balanced, quality_best => value,
        else => quality_balanced,
    };
}

/// How many source frames a recording will actually keep.
pub fn plannedFrameCount(max_frames: u64, every_nth: u32) u64 {
    const stride = @max(every_nth, 1);
    if (max_frames == 0) return 0;
    return (max_frames + stride - 1) / stride;
}

/// The recording state machine plus the resolved policy for the active run.
///
/// A capture failure never propagates as a Zig error into the frame loop: it
/// latches here, the recording stops accepting frames, and the app keeps
/// running. Roc observes it on the next `status!` or `stop!`.
pub const Session = struct {
    status: u8 = status_idle,
    failure: Failure = err_none,
    format: u8 = format_png,
    timing: u8 = timing_real_time,
    cursor: u8 = cursor_none,
    quality: u8 = quality_balanced,
    fps: i32 = 25,
    max_frames: u64 = 0,
    every_nth: u32 = 1,
    scale_numerator: u32 = 1,
    scale_denominator: u32 = 1,
    width: u32 = 0,
    height: u32 = 0,
    /// Source frames seen since `start`, including ones skipped by stride.
    source_frames: u64 = 0,
    /// Frames handed to the encoder.
    captured_frames: u64 = 0,
    /// Frames the stride or the frame cap discarded.
    dropped_frames: u64 = 0,
    memory_budget_bytes: u64 = default_memory_budget_bytes,

    /// Clear all state, as at host startup or between headless runs.
    pub fn reset(self: *Session) void {
        self.* = .{};
    }

    /// Is this session accepting frames right now?
    pub fn isActive(self: *const Session) bool {
        return self.status == status_active;
    }

    /// Validate a request and move to `active`, or return the refusal code.
    ///
    /// `width`/`height` are the framebuffer dimensions the recording will be
    /// sampled at, needed up front so the memory budget can be checked before
    /// a single frame is allocated.
    pub fn start(self: *Session, request: Request, width: u32, height: u32) u8 {
        if (self.status == status_active) return err_already_recording;

        const path_result = validateRelativePath(request.path);
        if (path_result != err_none) return path_result;

        if (request.format != format_png and
            request.format != format_gif and
            request.format != format_webm)
        {
            return err_unsupported_format;
        }

        const scaled_width = scaleAxis(width, request.scale_numerator, request.scale_denominator);
        const scaled_height = scaleAxis(height, request.scale_numerator, request.scale_denominator);

        if (formatBuffers(request.format)) {
            const frames = plannedFrameCount(request.max_frames, request.every_nth);
            const needed = estimateBufferedBytes(scaled_width, scaled_height, frames);
            if (needed > self.memory_budget_bytes) return err_budget_exceeded;
        }

        self.status = status_active;
        self.failure = err_none;
        self.format = request.format;
        self.timing = request.timing;
        self.cursor = request.cursor;
        self.quality = normalizeQuality(request.quality);
        self.fps = if (request.fps > 0) request.fps else 25;
        self.max_frames = request.max_frames;
        self.every_nth = @max(request.every_nth, 1);
        self.scale_numerator = request.scale_numerator;
        self.scale_denominator = request.scale_denominator;
        self.width = scaled_width;
        self.height = scaled_height;
        self.source_frames = 0;
        self.captured_frames = 0;
        self.dropped_frames = 0;
        return err_none;
    }

    /// Decide whether the frame now on screen should be handed to the encoder.
    ///
    /// Advances the source-frame counter, so call it exactly once per rendered
    /// frame while active.
    pub fn shouldCaptureFrame(self: *Session) bool {
        if (self.status != status_active) return false;

        const index = self.source_frames;
        self.source_frames += 1;

        if (self.max_frames != 0 and self.captured_frames >= self.max_frames) {
            self.dropped_frames += 1;
            return false;
        }
        if (index % self.every_nth != 0) {
            self.dropped_frames += 1;
            return false;
        }
        self.captured_frames += 1;
        return true;
    }

    /// Has the recording reached its configured frame cap?
    pub fn reachedFrameCap(self: *const Session) bool {
        return self.max_frames != 0 and self.captured_frames >= self.max_frames;
    }

    /// Seconds per frame to report to Roc, or null to use raylib's real delta.
    pub fn fixedStepSeconds(self: *const Session) ?f32 {
        if (self.status != status_active) return null;
        if (self.timing != timing_fixed_step) return null;
        if (self.fps <= 0) return null;
        // Divided by the stride: `fps` is the rate the finished file plays at,
        // while this step applies to every rendered frame. Keeping one frame in
        // four for a 25fps recording means those four rendered frames together
        // have to represent 1/25s, or the result plays back at 4x speed.
        const stride: f32 = @floatFromInt(@max(self.every_nth, 1));
        return 1.0 / (@as(f32, @floatFromInt(self.fps)) * stride);
    }

    /// Latch a failure, stop accepting frames, and keep the app running.
    pub fn fail(self: *Session, reason: Failure) void {
        if (self.status != status_active) return;
        self.status = status_failed;
        self.failure = reason;
    }

    /// Leave the active state, returning the code Roc should observe.
    ///
    /// A recording that already failed reports its latched reason rather than
    /// pretending the stop succeeded.
    pub fn stop(self: *Session) u8 {
        switch (self.status) {
            status_active => {
                self.status = status_idle;
                return err_none;
            },
            status_failed => {
                const reason = self.failure;
                self.status = status_idle;
                self.failure = err_none;
                return reason;
            },
            else => return err_not_recording,
        }
    }
};

test "validateRelativePath accepts ordinary relative paths" {
    try std.testing.expectEqual(err_none, validateRelativePath("shot.png"));
    try std.testing.expectEqual(err_none, validateRelativePath("captures/demo.gif"));
    try std.testing.expectEqual(err_none, validateRelativePath("./nested/a.png"));
}

test "validateRelativePath refuses escapes and malformed paths" {
    try std.testing.expectEqual(err_path_invalid, validateRelativePath(""));
    try std.testing.expectEqual(err_path_invalid, validateRelativePath("/etc/passwd"));
    try std.testing.expectEqual(err_path_invalid, validateRelativePath("\\windows\\system32"));
    try std.testing.expectEqual(err_path_invalid, validateRelativePath("~/secret.png"));
    try std.testing.expectEqual(err_path_invalid, validateRelativePath("C:/boot.ini"));
    try std.testing.expectEqual(err_path_invalid, validateRelativePath("shot\x00.png"));
    try std.testing.expectEqual(err_path_invalid, validateRelativePath("."));
    try std.testing.expectEqual(err_path_escapes, validateRelativePath("../escape.png"));
    try std.testing.expectEqual(err_path_escapes, validateRelativePath("a/../../b.png"));
    try std.testing.expectEqual(err_path_escapes, validateRelativePath("a\\..\\..\\b.png"));
}

test "joinOutputPath places requests under the output directory" {
    var buffer: [path_capacity]u8 = undefined;
    try std.testing.expectEqualStrings("shot.png", joinOutputPath(&buffer, ".", "shot.png").?);
    try std.testing.expectEqualStrings("shot.png", joinOutputPath(&buffer, "", "shot.png").?);
    try std.testing.expectEqualStrings("out/shot.png", joinOutputPath(&buffer, "out", "shot.png").?);
    try std.testing.expectEqualStrings("out/shot.png", joinOutputPath(&buffer, "out/", "shot.png").?);
    try std.testing.expectEqualStrings("out/a/b.png", joinOutputPath(&buffer, "out", "a/b.png").?);
}

test "joinOutputPath refuses to overflow its buffer" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(null, joinOutputPath(&buffer, "output", "much-too-long.png"));
}

test "scaleAxis halves and quarters without reaching zero" {
    try std.testing.expectEqual(@as(u32, 400), scaleAxis(800, 1, 2));
    try std.testing.expectEqual(@as(u32, 150), scaleAxis(600, 1, 4));
    try std.testing.expectEqual(@as(u32, 800), scaleAxis(800, 1, 1));
    // A ratio that would round down to nothing still yields a drawable pixel.
    try std.testing.expectEqual(@as(u32, 1), scaleAxis(3, 1, 8));
    // Degenerate ratios fall back to the source size rather than dividing by zero.
    try std.testing.expectEqual(@as(u32, 640), scaleAxis(640, 1, 0));
    try std.testing.expectEqual(@as(u32, 640), scaleAxis(640, 0, 2));
}

test "planDownscale halves down to a half-scale recording in one step" {
    const plan = planDownscale(1920, 1080, 960, 540).?;
    try std.testing.expectEqual(@as(usize, 2), plan.count);
    try std.testing.expectEqual(Extent{ .width = 1920, .height = 1080 }, plan.source());
    try std.testing.expectEqual(Extent{ .width = 960, .height = 540 }, plan.target());
}

test "planDownscale reaches a quarter through an intermediate halving" {
    // The intermediate level is what makes this a box filter over all sixteen
    // source pixels rather than a bilinear read of four of them.
    const plan = planDownscale(1920, 1080, 480, 270).?;
    try std.testing.expectEqual(@as(usize, 3), plan.count);
    try std.testing.expectEqual(Extent{ .width = 960, .height = 540 }, plan.levels[1]);
    try std.testing.expectEqual(Extent{ .width = 480, .height = 270 }, plan.target());
}

test "planDownscale adds a final step for a ratio that is not a power of two" {
    const plan = planDownscale(1920, 1080, 640, 360).?;
    try std.testing.expectEqual(@as(usize, 3), plan.count);
    try std.testing.expectEqual(Extent{ .width = 960, .height = 540 }, plan.levels[1]);
    try std.testing.expectEqual(Extent{ .width = 640, .height = 360 }, plan.target());
}

test "planDownscale declines anything that is not a downscale" {
    try std.testing.expectEqual(null, planDownscale(1920, 1080, 1920, 1080));
    try std.testing.expectEqual(null, planDownscale(640, 360, 1280, 720));
    // A mixed request that grows one axis still moves more data than it saves.
    try std.testing.expectEqual(null, planDownscale(640, 360, 320, 720));
    try std.testing.expectEqual(null, planDownscale(0, 360, 320, 180));
    try std.testing.expectEqual(null, planDownscale(640, 360, 320, 0));
}

test "planDownscale stays inside its level budget for an extreme ratio" {
    // `Ratio` accepts anything, so the chain has to stop somewhere. It ends at
    // the requested size whatever happens, which is what correctness needs.
    const plan = planDownscale(4096, 4096, 1, 1).?;
    try std.testing.expect(plan.count <= max_downscale_levels);
    try std.testing.expectEqual(Extent{ .width = 1, .height = 1 }, plan.target());
    // Every step shrinks, so no level ever hands the next one an upscale.
    for (1..plan.count) |index| {
        try std.testing.expect(plan.levels[index].width <= plan.levels[index - 1].width);
        try std.testing.expect(plan.levels[index].height <= plan.levels[index - 1].height);
        try std.testing.expect(plan.levels[index].width >= 1);
        try std.testing.expect(plan.levels[index].height >= 1);
    }
}

test "planDownscale matches the sizes scaleAxis produces" {
    // The chain has to end exactly where `Session.start` said the recording
    // is, or the encoder is handed frames of the wrong dimensions.
    for ([_][2]u32{ .{ 1, 2 }, .{ 1, 4 }, .{ 1, 8 }, .{ 2, 3 } }) |ratio| {
        const width = scaleAxis(1920, ratio[0], ratio[1]);
        const height = scaleAxis(1080, ratio[0], ratio[1]);
        const plan = planDownscale(1920, 1080, width, height).?;
        try std.testing.expectEqual(Extent{ .width = width, .height = height }, plan.target());
    }
}

test "estimateBufferedBytes saturates instead of wrapping" {
    try std.testing.expectEqual(@as(u64, 800 * 600 * 4 * 10), estimateBufferedBytes(800, 600, 10));
    try std.testing.expectEqual(@as(u64, 0), estimateBufferedBytes(800, 600, 0));
    // Without saturation this would wrap to a small value and be accepted.
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        estimateBufferedBytes(std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u64)),
    );
}

test "plannedFrameCount rounds a strided recording up" {
    try std.testing.expectEqual(@as(u64, 300), plannedFrameCount(300, 1));
    try std.testing.expectEqual(@as(u64, 150), plannedFrameCount(300, 2));
    try std.testing.expectEqual(@as(u64, 100), plannedFrameCount(299, 3));
    try std.testing.expectEqual(@as(u64, 300), plannedFrameCount(300, 0));
    try std.testing.expectEqual(@as(u64, 0), plannedFrameCount(0, 4));
}

fn testRequest(format: u8) Request {
    return .{
        .path = "out.gif",
        .format = format,
        .fps = 25,
        .max_frames = 100,
        .scale_numerator = 1,
        .scale_denominator = 1,
        .every_nth = 1,
        .timing = timing_fixed_step,
        .cursor = cursor_none,
        .quality = quality_balanced,
    };
}

test "a session carries the requested quality" {
    var session = Session{};
    var request = testRequest(format_gif);
    request.quality = quality_fast;
    try std.testing.expectEqual(err_none, session.start(request, 64, 64));
    try std.testing.expectEqual(quality_fast, session.quality);
}

test "an unrecognized quality code falls back to the default" {
    try std.testing.expectEqual(quality_fast, normalizeQuality(quality_fast));
    try std.testing.expectEqual(quality_balanced, normalizeQuality(quality_balanced));
    try std.testing.expectEqual(quality_best, normalizeQuality(quality_best));
    try std.testing.expectEqual(quality_balanced, normalizeQuality(3));
    try std.testing.expectEqual(quality_balanced, normalizeQuality(255));

    var session = Session{};
    var request = testRequest(format_gif);
    request.quality = 200;
    try std.testing.expectEqual(err_none, session.start(request, 64, 64));
    try std.testing.expectEqual(quality_balanced, session.quality);
}

test "reset clears a session back to the default quality" {
    var session = Session{};
    var request = testRequest(format_gif);
    request.quality = quality_best;
    try std.testing.expectEqual(err_none, session.start(request, 64, 64));
    session.reset();
    try std.testing.expectEqual(quality_balanced, session.quality);
}

test "a session starts idle and refuses to stop" {
    var session = Session{};
    try std.testing.expect(!session.isActive());
    try std.testing.expectEqual(err_not_recording, session.stop());
}

test "starting twice reports AlreadyRecording" {
    var session = Session{};
    try std.testing.expectEqual(err_none, session.start(testRequest(format_gif), 320, 240));
    try std.testing.expect(session.isActive());
    try std.testing.expectEqual(err_already_recording, session.start(testRequest(format_gif), 320, 240));
    try std.testing.expectEqual(err_none, session.stop());
    try std.testing.expect(!session.isActive());
}

test "start validates the path before anything else" {
    var session = Session{};
    var request = testRequest(format_gif);
    request.path = "../escape.gif";
    try std.testing.expectEqual(err_path_escapes, session.start(request, 320, 240));
    try std.testing.expect(!session.isActive());
}

test "start refuses an unknown format" {
    var session = Session{};
    var request = testRequest(format_gif);
    request.format = 99;
    try std.testing.expectEqual(err_unsupported_format, session.start(request, 320, 240));
    try std.testing.expect(!session.isActive());
}

test "every shipped format streams, so none hits the memory budget" {
    // A long full-resolution GIF would be many gigabytes if it were buffered.
    // It is accepted because msf_gif encodes incrementally into an open file.
    var session = Session{};
    session.memory_budget_bytes = 1024;
    for ([_]u8{ format_png, format_gif, format_webm }) |format| {
        var request = testRequest(format);
        request.max_frames = 100_000;
        try std.testing.expectEqual(err_none, session.start(request, 1920, 1080));
        try std.testing.expectEqual(err_none, session.stop());
    }
}

test "a buffering format would be refused once it exceeds the budget" {
    // Guards the gate itself, which no shipped format currently trips.
    const frames = plannedFrameCount(10_000, 1);
    const needed = estimateBufferedBytes(1920, 1080, frames);
    try std.testing.expect(needed > default_memory_budget_bytes);

    var session = Session{};
    session.memory_budget_bytes = 1024 * 1024;
    var request = testRequest(format_gif);
    request.max_frames = 10_000;
    try std.testing.expect(!formatBuffers(request.format));
    try std.testing.expectEqual(err_none, session.start(request, 1920, 1080));
}

test "scaling shrinks the recorded frame size" {
    var session = Session{};
    var request = testRequest(format_gif);
    request.scale_numerator = 1;
    request.scale_denominator = 8;
    try std.testing.expectEqual(err_none, session.start(request, 1920, 1080));
    try std.testing.expectEqual(@as(u32, 240), session.width);
    try std.testing.expectEqual(@as(u32, 135), session.height);
}

test "stride keeps every nth frame and counts the rest as dropped" {
    var session = Session{};
    var request = testRequest(format_webm);
    request.every_nth = 3;
    request.max_frames = 0;
    try std.testing.expectEqual(err_none, session.start(request, 64, 64));

    var kept: u64 = 0;
    for (0..9) |_| {
        if (session.shouldCaptureFrame()) kept += 1;
    }
    try std.testing.expectEqual(@as(u64, 3), kept);
    try std.testing.expectEqual(@as(u64, 3), session.captured_frames);
    try std.testing.expectEqual(@as(u64, 6), session.dropped_frames);
    try std.testing.expectEqual(@as(u64, 9), session.source_frames);
}

test "the frame cap stops capture without stopping the app" {
    var session = Session{};
    var request = testRequest(format_webm);
    request.max_frames = 2;
    try std.testing.expectEqual(err_none, session.start(request, 64, 64));

    try std.testing.expect(session.shouldCaptureFrame());
    try std.testing.expect(session.shouldCaptureFrame());
    try std.testing.expect(session.reachedFrameCap());
    try std.testing.expect(!session.shouldCaptureFrame());
    try std.testing.expectEqual(@as(u64, 2), session.captured_frames);
    try std.testing.expect(session.isActive());
}

test "an idle session never captures" {
    var session = Session{};
    try std.testing.expect(!session.shouldCaptureFrame());
    try std.testing.expectEqual(@as(u64, 0), session.source_frames);
}

test "fixedStepSeconds only applies to an active fixed-step recording" {
    var session = Session{};
    try std.testing.expectEqual(null, session.fixedStepSeconds());

    var request = testRequest(format_webm);
    request.timing = timing_real_time;
    try std.testing.expectEqual(err_none, session.start(request, 64, 64));
    try std.testing.expectEqual(null, session.fixedStepSeconds());
    _ = session.stop();

    request.timing = timing_fixed_step;
    request.fps = 50;
    try std.testing.expectEqual(err_none, session.start(request, 64, 64));
    try std.testing.expectEqual(@as(f32, 0.02), session.fixedStepSeconds().?);
    _ = session.stop();

    // A stride slows the simulated step so playback stays at the stated rate:
    // four rendered frames at 1/100s make up one 1/25s frame of output.
    request.fps = 25;
    request.every_nth = 4;
    try std.testing.expectEqual(err_none, session.start(request, 64, 64));
    try std.testing.expectEqual(@as(f32, 0.01), session.fixedStepSeconds().?);
}

test "a failure latches, halts capture, and surfaces on stop" {
    var session = Session{};
    try std.testing.expectEqual(err_none, session.start(testRequest(format_gif), 64, 64));
    try std.testing.expect(session.shouldCaptureFrame());

    session.fail(err_write_failed);
    try std.testing.expectEqual(status_failed, session.status);
    try std.testing.expect(!session.isActive());
    try std.testing.expect(!session.shouldCaptureFrame());

    try std.testing.expectEqual(err_write_failed, session.stop());
    try std.testing.expectEqual(status_idle, session.status);
    try std.testing.expectEqual(err_none, session.failure);
}

test "failing an idle session changes nothing" {
    var session = Session{};
    session.fail(err_out_of_memory);
    try std.testing.expectEqual(status_idle, session.status);
    try std.testing.expectEqual(err_none, session.failure);
}

test "reset returns a used session to its startup state" {
    var session = Session{};
    try std.testing.expectEqual(err_none, session.start(testRequest(format_gif), 64, 64));
    _ = session.shouldCaptureFrame();
    session.fail(err_encode_failed);

    session.reset();
    try std.testing.expectEqual(status_idle, session.status);
    try std.testing.expectEqual(err_none, session.failure);
    try std.testing.expectEqual(@as(u64, 0), session.source_frames);
    try std.testing.expectEqual(@as(u64, 0), session.captured_frames);
}
