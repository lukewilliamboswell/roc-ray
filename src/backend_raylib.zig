//! Raylib backend wrapper.
//!
//! This module provides a clean interface to raylib, accepting generated ABI
//! types and converting them to raylib's C types.
//! All C interop is isolated here.

const std = @import("std");
const abi = @import("roc_platform_abi.zig");
const ffi = @import("roc_ffi.zig");
/// Capture policy, kept free of raylib so it can be unit tested without a GPU.
const capture = @import("capture.zig");

/// Roc's `Color.Rgba`, the RGBA record that crosses the host boundary.
pub const Color = abi.ColorRgba;

/// Raw raylib C bindings.
pub const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("rlgl.h");
});

/// Native sound value retained in the host resource heap.
pub const Sound = rl.Sound;

/// Native music stream retained in the host resource heap.
pub const Music = rl.Music;

/// Native font retained in the host resource heap.
pub const Font = rl.Font;

/// Scalar data needed to reproduce raylib's glyph advance calculation.
pub const FontGlyphMetric = struct {
    codepoint: u32,
    advance_x: f32,
    offset_x: f32,
    offset_y: f32,
    width: f32,
    height: f32,
};

/// Return the bundled raylib major version for host invariants.
pub fn majorVersion() c_int {
    return rl.RAYLIB_VERSION_MAJOR;
}

/// Native texture retained in the host resource heap.
pub const Texture = rl.Texture2D;

/// Decode an image in caller-owned memory, upload it, then discard the CPU
/// image. Raylib consumes the bytes synchronously; it does not retain them.
pub fn loadTextureFromMemory(file_type: [*:0]const u8, bytes: []const u8) ?Texture {
    if (bytes.len == 0 or bytes.len > std.math.maxInt(c_int)) return null;
    const image = rl.LoadImageFromMemory(file_type, bytes.ptr, @intCast(bytes.len));
    if (!rl.IsImageValid(image)) return null;
    defer rl.UnloadImage(image);
    const texture = rl.LoadTextureFromImage(image);
    if (!rl.IsTextureValid(texture)) return null;
    return texture;
}

/// Native framebuffer-backed texture retained in the host resource heap.
pub const RenderTexture = rl.RenderTexture2D;

/// Native shader program retained in the host resource heap.
pub const Shader = rl.Shader;

/// Persistent packed keyboard state, derived once per input interval.
/// Bit 0 is held, bit 1 is pressed this interval, and bit 2 is released this
/// interval.
var key_state: [ffi.KEY_COUNT]u8 = [_]u8{0} ** ffi.KEY_COUNT;

/// Persistent packed mouse button state, with the same bits.
var mouse_button_state: [ffi.MOUSE_BUTTON_COUNT]u8 = [_]u8{0} ** ffi.MOUSE_BUTTON_COUNT;

/// Persistent gamepad snapshot, flattened by gamepad then control index.
var gamepad_available: [ffi.GAMEPAD_COUNT]u8 = [_]u8{0} ** ffi.GAMEPAD_COUNT;
var gamepad_button_state: [ffi.GAMEPAD_COUNT * ffi.GAMEPAD_BUTTON_COUNT]u8 = [_]u8{0} ** (ffi.GAMEPAD_COUNT * ffi.GAMEPAD_BUTTON_COUNT);
var gamepad_axes: [ffi.GAMEPAD_COUNT * ffi.GAMEPAD_AXIS_COUNT]f32 = [_]f32{0} ** (ffi.GAMEPAD_COUNT * ffi.GAMEPAD_AXIS_COUNT);

/// How many typed codepoints one input interval delivers.
///
/// The host records characters itself, from the window system's character
/// callback, so this is the real bound: raylib's own queue holds sixteen per
/// poll and drops the rest without saying so, and it is not consulted while
/// the callbacks are installed. Past this many the extra codepoints are
/// discarded and the interval is reported as overflowed, never silently cut.
pub const TEXT_INPUT_CAPACITY: usize = 32;

/// How many codepoints raylib's own character queue holds per poll
/// (`MAX_CHAR_PRESSED_QUEUE` in rcore.c). Only the fallback path, with no GLFW
/// window to hook, reads that queue.
const RAYLIB_CHAR_QUEUE_CAPACITY: usize = 16;

/// Typed characters recorded since the interval began, in the order typed.
var text_input: [TEXT_INPUT_CAPACITY]u32 = [_]u32{0} ** TEXT_INPUT_CAPACITY;
var text_input_len: usize = 0;
var text_input_overflowed: bool = false;
var text_input_high_water: usize = 0;
var text_input_oldest_at: u64 = 0;

/// Wheel movement summed since the interval began.
var hardware_wheel: Vec2 = .{ .x = 0, .y = 0 };

/// A press or a release of one key or button.
pub const InputEdge = enum { press, release };

/// Which of the two edge sources a derived state consumes.
///
/// `hardware` is the window system, recorded by the chained GLFW callbacks;
/// `virtual` is a script. The two are kept apart so a scripted keyboard shuts
/// the real one out completely, edges included, and so a tap scripted while
/// hardware was the source does not surface cycles later.
pub const InputSource = enum { hardware, virtual };

/// The edges of every key (or button) recorded since the state was last
/// derived: one byte per code holding the `INPUT_PRESSED` and `INPUT_RELEASED`
/// bits.
///
/// Recording the same edge twice is idempotent. The accumulator says whether at
/// least one press and at least one release happened, not how many or in what
/// order; that is the coalesced view, and it has no capacity to exhaust. The
/// event log below is the authoritative one: it keeps count, order and, for
/// clicks, position.
fn EdgeAccumulator(comptime count: usize) type {
    return struct {
        bits: [count]u8 = [_]u8{0} ** count,

        fn record(self: *@This(), index: usize, edge: InputEdge) void {
            self.bits[index] |= switch (edge) {
                .press => ffi.INPUT_PRESSED,
                .release => ffi.INPUT_RELEASED,
            };
        }

        fn take(self: *@This(), index: usize) u8 {
            const edges = self.bits[index];
            self.bits[index] = 0;
            return edges;
        }

        fn clear(self: *@This()) void {
            self.bits = [_]u8{0} ** count;
        }
    };
}

/// Edges the window system delivered, recorded by the chained GLFW callbacks.
var hardware_key_edges: EdgeAccumulator(ffi.KEY_COUNT) = .{};
var hardware_mouse_button_edges: EdgeAccumulator(ffi.MOUSE_BUTTON_COUNT) = .{};
/// Edges a script placed inside one cycle, for the virtual keyboard.
var virtual_key_edges: EdgeAccumulator(ffi.KEY_COUNT) = .{};

test "an edge accumulator coalesces repeats and empties when taken" {
    var edges: EdgeAccumulator(4) = .{};
    try std.testing.expectEqual(@as(u8, 0), edges.take(1));

    edges.record(1, .press);
    edges.record(1, .release);
    edges.record(1, .press);
    edges.record(3, .release);
    try std.testing.expectEqual(ffi.INPUT_PRESSED | ffi.INPUT_RELEASED, edges.take(1));
    try std.testing.expectEqual(@as(u8, 0), edges.take(1));
    try std.testing.expectEqual(@as(u8, 0), edges.take(2));

    edges.clear();
    try std.testing.expectEqual(@as(u8, 0), edges.take(3));
}

// ---- The event log ----
//
// The packed bits above are the coalesced view: at least one press, at least
// one release. The log is the record: every key edge, click, wheel notch and
// typed character in the order the window system delivered them, with the
// pointer position a click landed at. It is bounded and says when it overflowed;
// the bits, the wheel sum and the text buffer keep recording regardless, so the
// coalesced view stays complete even when the list did not.

/// How many events one input interval records, across every source.
///
/// A human cannot produce this many between two polls even through a
/// multi-second stall -- auto-repeat is not recorded -- so overflow marks a
/// synthetic source or a hung frame, and the flag says so rather than the
/// tail going missing.
pub const INPUT_EVENT_CAPACITY: usize = 256;

/// Scalar-only observation of the host's bounded interval-input buffers.
/// Payloads and key/codepoint values never cross this diagnostic hook.
pub const InputQueueObservation = struct {
    operation: enum(u8) { reserve = 0, release = 1, saturation = 2, overflow = 3 },
    buffer: enum(u8) { hardware_events, virtual_events, text_codepoints },
    amount: usize,
    current: usize,
    high_water: usize,
    capacity: usize,
    oldest_at: u64,
};

/// Returns the observation timestamp used as the oldest-item origin.
pub const InputQueueObserver = *const fn (InputQueueObservation) u64;
var input_queue_observer: ?InputQueueObserver = null;

/// Install or remove input-buffer pressure observation for the active host run.
pub fn setInputQueueObserver(next: ?InputQueueObserver) void {
    input_queue_observer = next;
}

fn observeInputQueue(event: InputQueueObservation) u64 {
    return if (input_queue_observer) |observer| observer(event) else 0;
}

/// What one recorded event was. The numbering is the wire contract with
/// `Devices.events_from_raw` in the types package.
pub const InputEventKind = enum(u8) {
    key_pressed = 0,
    key_released = 1,
    button_pressed = 2,
    button_released = 3,
    wheel = 4,
    text = 5,
};

/// One recorded event in the flat shape that crosses to Roc.
///
/// `code` is the key code, mouse button code or codepoint the kind implies;
/// `x` and `y` are the pointer position for a click and the offsets for a
/// wheel notch, and zero otherwise.
pub const InputEventRecord = extern struct {
    kind: u8,
    code: u32,
    x: f32,
    y: f32,
};

/// Which device an event came from, so a scripted source can shut out the
/// hardware one device at a time.
const InputClass = enum { keyboard, mouse, text };

const LoggedEvent = struct {
    seq: u64,
    class: InputClass,
    record: InputEventRecord,
};

/// Global delivery order across both logs, so the hardware mouse and a
/// scripted keyboard still interleave the way they happened.
var input_event_seq: u64 = 0;

/// One source's events for the interval, in delivery order.
const EventLog = struct {
    buffer: @TypeOf(@as(InputQueueObservation, undefined).buffer),
    entries: [INPUT_EVENT_CAPACITY]LoggedEvent = undefined,
    len: usize = 0,
    overflowed: bool = false,
    high_water: usize = 0,
    oldest_at: u64 = 0,

    fn append(self: *@This(), class: InputClass, record: InputEventRecord) void {
        if (self.len == self.entries.len) {
            self.overflowed = true;
            _ = observeInputQueue(.{ .operation = .overflow, .buffer = self.buffer, .amount = 1, .current = self.len, .high_water = self.high_water, .capacity = self.entries.len, .oldest_at = self.oldest_at });
            return;
        }
        const was_empty = self.len == 0;
        self.entries[self.len] = .{ .seq = input_event_seq, .class = class, .record = record };
        input_event_seq += 1;
        self.len += 1;
        self.high_water = @max(self.high_water, self.len);
        const observed_at = observeInputQueue(.{ .operation = .reserve, .buffer = self.buffer, .amount = 1, .current = self.len, .high_water = self.high_water, .capacity = self.entries.len, .oldest_at = self.oldest_at });
        if (was_empty) self.oldest_at = observed_at;
    }

    fn clear(self: *@This()) void {
        if (self.len != 0) _ = observeInputQueue(.{ .operation = .release, .buffer = self.buffer, .amount = self.len, .current = 0, .high_water = self.high_water, .capacity = self.entries.len, .oldest_at = self.oldest_at });
        self.len = 0;
        self.overflowed = false;
        self.oldest_at = 0;
    }
};

/// Events the window system delivered, recorded by the chained callbacks.
var hardware_events: EventLog = .{ .buffer = .hardware_events };
/// Events a script produced: taps, held-set transitions, typed text.
var virtual_events: EventLog = .{ .buffer = .virtual_events };

/// Which source each device class takes its events from this cycle.
pub const EventSources = struct {
    keyboard: InputSource,
    mouse: InputSource,
    text: InputSource,
};

/// One interval's events, and whether any were dropped past the capacity.
pub const InputEvents = struct {
    events: []const InputEventRecord,
    overflowed: bool,
};

/// Stable scratch the taken events are returned in.
var taken_events: [INPUT_EVENT_CAPACITY]InputEventRecord = undefined;

fn keyRecord(code: usize, edge: InputEdge) InputEventRecord {
    return .{
        .kind = @intFromEnum(@as(InputEventKind, if (edge == .press) .key_pressed else .key_released)),
        .code = @intCast(code),
        .x = 0,
        .y = 0,
    };
}

fn buttonRecord(button: usize, edge: InputEdge, position: Vec2) InputEventRecord {
    return .{
        .kind = @intFromEnum(@as(InputEventKind, if (edge == .press) .button_pressed else .button_released)),
        .code = @intCast(button),
        .x = position.x,
        .y = position.y,
    };
}

fn wheelRecord(x_offset: f32, y_offset: f32) InputEventRecord {
    return .{ .kind = @intFromEnum(InputEventKind.wheel), .code = 0, .x = x_offset, .y = y_offset };
}

fn textRecord(codepoint: u32) InputEventRecord {
    return .{ .kind = @intFromEnum(InputEventKind.text), .code = codepoint, .x = 0, .y = 0 };
}

fn sourceFeeds(sources: EventSources, source: InputSource) bool {
    return sources.keyboard == source or sources.mouse == source or sources.text == source;
}

/// Take the interval's events: both logs merged in delivery order, keeping
/// each event only if its device's source is the log it came from.
///
/// Taken once per cycle, in the same cycle as the packed bits and after they
/// are derived, so an event and the bit it set are never split across two
/// inputs. Both logs are cleared, so an event recorded for a source that was
/// not chosen this cycle is gone rather than surfacing later. A log that
/// overflowed lost events of some class it cannot name, so the overflow is
/// reported if any class was taking from it.
pub fn takeInputEvents(sources: EventSources) InputEvents {
    var count: usize = 0;
    var overflowed = false;
    var h: usize = 0;
    var v: usize = 0;
    while (h < hardware_events.len or v < virtual_events.len) {
        const from_hardware = v == virtual_events.len or
            (h < hardware_events.len and hardware_events.entries[h].seq < virtual_events.entries[v].seq);
        const entry = if (from_hardware) hardware_events.entries[h] else virtual_events.entries[v];
        const source: InputSource = if (from_hardware) .hardware else .virtual;
        if (from_hardware) h += 1 else v += 1;

        const wanted = switch (entry.class) {
            .keyboard => sources.keyboard,
            .mouse => sources.mouse,
            .text => sources.text,
        };
        if (wanted != source) continue;
        if (count == taken_events.len) {
            overflowed = true;
            break;
        }
        taken_events[count] = entry.record;
        count += 1;
    }
    if (hardware_events.overflowed and sourceFeeds(sources, .hardware)) overflowed = true;
    if (virtual_events.overflowed and sourceFeeds(sources, .virtual)) overflowed = true;
    hardware_events.clear();
    virtual_events.clear();
    return .{ .events = taken_events[0..count], .overflowed = overflowed };
}

/// Forget both logs, so one app lifetime cannot inherit another's events.
pub fn clearInputEvents() void {
    hardware_events.clear();
    virtual_events.clear();
}

test "input queue observer reports item reserve release overflow and oldest age" {
    const Probe = struct {
        var events: [INPUT_EVENT_CAPACITY + 8]InputQueueObservation = undefined;
        var len: usize = 0;
        var now: u64 = 100;

        fn observe(event: InputQueueObservation) u64 {
            events[len] = event;
            len += 1;
            now += 1;
            return now;
        }
    };

    clearInputEvents();
    releaseRecordedText();
    virtual_events.high_water = 0;
    text_input_high_water = 0;
    Probe.len = 0;
    Probe.now = 100;
    setInputQueueObserver(Probe.observe);
    defer setInputQueueObserver(null);
    defer clearInputEvents();
    defer releaseRecordedText();

    recordVirtualText('a');
    recordVirtualText('b');
    _ = takeInputEvents(all_virtual);
    try std.testing.expectEqual(@as(usize, 3), Probe.len);
    try std.testing.expectEqual(.reserve, Probe.events[0].operation);
    try std.testing.expectEqual(.virtual_events, Probe.events[0].buffer);
    try std.testing.expectEqual(@as(usize, 1), Probe.events[0].current);
    try std.testing.expectEqual(@as(u64, 101), Probe.events[1].oldest_at);
    try std.testing.expectEqual(.release, Probe.events[2].operation);
    try std.testing.expectEqual(@as(usize, 2), Probe.events[2].amount);
    try std.testing.expectEqual(@as(usize, 0), Probe.events[2].current);

    Probe.len = 0;
    for (0..INPUT_EVENT_CAPACITY + 1) |_| recordVirtualText('x');
    try std.testing.expectEqual(.overflow, Probe.events[INPUT_EVENT_CAPACITY].operation);
    try std.testing.expectEqual(@as(usize, INPUT_EVENT_CAPACITY), Probe.events[INPUT_EVENT_CAPACITY].current);
    try std.testing.expectEqual(@as(usize, INPUT_EVENT_CAPACITY), Probe.events[INPUT_EVENT_CAPACITY].capacity);

    clearInputEvents();
    Probe.len = 0;
    recordCodepoint('z');
    _ = takeRecordedText();
    try std.testing.expectEqual(.text_codepoints, Probe.events[0].buffer);
    try std.testing.expectEqual(.reserve, Probe.events[0].operation);
    try std.testing.expectEqual(.release, Probe.events[2].operation);
    try std.testing.expectEqual(.text_codepoints, Probe.events[2].buffer);
}

const all_hardware = EventSources{ .keyboard = .hardware, .mouse = .hardware, .text = .hardware };
const all_virtual = EventSources{ .keyboard = .virtual, .mouse = .virtual, .text = .virtual };

fn expectEvent(record: InputEventRecord, kind: InputEventKind, code: u32, x: f32, y: f32) !void {
    try std.testing.expectEqual(@intFromEnum(kind), record.kind);
    try std.testing.expectEqual(code, record.code);
    try std.testing.expectEqual(x, record.x);
    try std.testing.expectEqual(y, record.y);
}

test "events keep window-system delivery order across every source" {
    defer clearInputEvents();
    defer clearRecordedHardwareInput();

    recordHardwareKeyEdge(65, .press);
    recordHardwareMouseButtonEdge(0, .press, .{ .x = 12, .y = 34 });
    recordCodepoint('a');
    recordScroll(0, 1);
    recordHardwareMouseButtonEdge(0, .release, .{ .x = 15, .y = 30 });
    recordHardwareKeyEdge(65, .release);

    const taken = takeInputEvents(all_hardware);
    try std.testing.expect(!taken.overflowed);
    try std.testing.expectEqual(@as(usize, 6), taken.events.len);
    try expectEvent(taken.events[0], .key_pressed, 65, 0, 0);
    try expectEvent(taken.events[1], .button_pressed, 0, 12, 34);
    try expectEvent(taken.events[2], .text, 'a', 0, 0);
    try expectEvent(taken.events[3], .wheel, 0, 0, 1);
    try expectEvent(taken.events[4], .button_released, 0, 15, 30);
    try expectEvent(taken.events[5], .key_released, 65, 0, 0);

    // Taken with the interval: the next one starts empty.
    try std.testing.expectEqual(@as(usize, 0), takeInputEvents(all_hardware).events.len);
}

test "the log keeps every tap where the bits keep one" {
    defer clearKeyState();
    defer clearInputEvents();
    const key_e = 69;
    const up: [ffi.KEY_COUNT]bool = @splat(false);

    recordHardwareKeyEdge(key_e, .press);
    recordHardwareKeyEdge(key_e, .release);
    recordHardwareKeyEdge(key_e, .press);
    recordHardwareKeyEdge(key_e, .release);
    deriveKeyboardState(.hardware, &up);
    try std.testing.expectEqual(ffi.INPUT_PRESSED | ffi.INPUT_RELEASED, getKeyState()[key_e]);

    const taken = takeInputEvents(all_hardware);
    try std.testing.expectEqual(@as(usize, 4), taken.events.len);
    try expectEvent(taken.events[0], .key_pressed, key_e, 0, 0);
    try expectEvent(taken.events[1], .key_released, key_e, 0, 0);
    try expectEvent(taken.events[2], .key_pressed, key_e, 0, 0);
    try expectEvent(taken.events[3], .key_released, key_e, 0, 0);
}

test "past the capacity the list reports overflow while the coalesced view keeps recording" {
    defer clearKeyState();
    defer clearInputEvents();
    defer clearRecordedHardwareInput();
    const up: [ffi.KEY_COUNT]bool = @splat(false);

    for (0..INPUT_EVENT_CAPACITY) |_| recordHardwareKeyEdge(65, .press);
    // These are past the cap: dropped from the list, but the bit, the wheel
    // sum and the text buffer still see them.
    recordHardwareKeyEdge(66, .press);
    recordScroll(0, 2);
    recordScroll(0, 3);
    recordCodepoint('z');

    deriveKeyboardState(.hardware, &up);
    try std.testing.expectEqual(ffi.INPUT_PRESSED, getKeyState()[65]);
    try std.testing.expectEqual(ffi.INPUT_PRESSED, getKeyState()[66]);
    try std.testing.expectEqual(@as(f32, 5), takeRecordedWheel().y);
    try std.testing.expectEqualSlices(u32, &.{'z'}, takeRecordedText().codepoints);

    const taken = takeInputEvents(all_hardware);
    try std.testing.expect(taken.overflowed);
    try std.testing.expectEqual(INPUT_EVENT_CAPACITY, taken.events.len);
    try expectEvent(taken.events[INPUT_EVENT_CAPACITY - 1], .key_pressed, 65, 0, 0);

    // The flag travels with the interval that overflowed.
    try std.testing.expect(!takeInputEvents(all_hardware).overflowed);

    // Exactly the capacity is not an overflow.
    for (0..INPUT_EVENT_CAPACITY) |_| recordHardwareKeyEdge(65, .press);
    const exact = takeInputEvents(all_hardware);
    try std.testing.expect(!exact.overflowed);
    try std.testing.expectEqual(INPUT_EVENT_CAPACITY, exact.events.len);
}

test "each device takes events from its own source and the rest are discarded" {
    defer clearKeyState();
    defer clearInputEvents();
    defer clearRecordedHardwareInput();

    recordHardwareKeyEdge(65, .press);
    recordVirtualKeyEdge(66, .press);
    recordHardwareMouseButtonEdge(1, .press, .{ .x = 1, .y = 2 });
    recordCodepoint('h');
    recordVirtualText('v');
    recordVirtualKeyEdge(66, .release);

    // Scripted keyboard and text, hardware mouse: the hardware key and char
    // are not delivered, and what is delivered stays in delivery order.
    const taken = takeInputEvents(.{ .keyboard = .virtual, .mouse = .hardware, .text = .virtual });
    try std.testing.expect(!taken.overflowed);
    try std.testing.expectEqual(@as(usize, 4), taken.events.len);
    try expectEvent(taken.events[0], .key_pressed, 66, 0, 0);
    try expectEvent(taken.events[1], .button_pressed, 1, 1, 2);
    try expectEvent(taken.events[2], .text, 'v', 0, 0);
    try expectEvent(taken.events[3], .key_released, 66, 0, 0);

    // The discarded events do not resurface when the source changes back.
    try std.testing.expectEqual(@as(usize, 0), takeInputEvents(all_hardware).events.len);

    // An overflowed log is reported only to the devices reading from it.
    for (0..INPUT_EVENT_CAPACITY + 1) |_| recordHardwareKeyEdge(65, .press);
    try std.testing.expect(!takeInputEvents(all_virtual).overflowed);
    for (0..INPUT_EVENT_CAPACITY + 1) |_| recordHardwareKeyEdge(65, .press);
    try std.testing.expect(takeInputEvents(.{ .keyboard = .virtual, .mouse = .hardware, .text = .virtual }).overflowed);
}

fn gamepadButtonIndex(gamepad: usize, button: usize) usize {
    return gamepad * ffi.GAMEPAD_BUTTON_COUNT + button;
}

fn gamepadAxisIndex(gamepad: usize, axis: usize) usize {
    return gamepad * ffi.GAMEPAD_AXIS_COUNT + axis;
}

test "gamepad snapshot indexing is contiguous per device" {
    try std.testing.expectEqual(@as(usize, 0), gamepadButtonIndex(0, 0));
    try std.testing.expectEqual(@as(usize, 17), gamepadButtonIndex(0, 17));
    try std.testing.expectEqual(@as(usize, 18), gamepadButtonIndex(1, 0));
    try std.testing.expectEqual(@as(usize, 23), gamepadAxisIndex(3, 5));
}

fn inputStateBits(down: bool, pressed: bool, released: bool) u8 {
    return (if (down) ffi.INPUT_HELD else 0) |
        (if (pressed) ffi.INPUT_PRESSED else 0) |
        (if (released) ffi.INPUT_RELEASED else 0);
}

fn disconnectedInputState(previous: u8) u8 {
    return if (previous & ffi.INPUT_HELD != 0) ffi.INPUT_RELEASED else 0;
}

/// Derive one interval's packed state from the previous state, the level at
/// the interval's end, and the edges recorded during it.
///
/// `edges` is what the window system (or a script) said happened; the level
/// comparison is a second witness to the same transitions. Taking the union
/// means a tap that began and ended inside the interval -- level unchanged,
/// so invisible to the comparison -- still reads as pressed and released, and
/// a transition whose edge was somehow not recorded still reads from the
/// level. Gamepads, which raylib polls with no callback, pass no edges and
/// get level detection alone.
fn nextInputState(previous: u8, down: bool, edges: u8) u8 {
    const was_down = previous & ffi.INPUT_HELD != 0;
    const pressed = edges & ffi.INPUT_PRESSED != 0 or (down and !was_down);
    const released = edges & ffi.INPUT_RELEASED != 0 or (!down and was_down);
    return inputStateBits(down, pressed, released);
}

fn raylibGamepadButtonDown(_: void, gamepad: c_int, button: c_int) bool {
    return rl.IsGamepadButtonDown(gamepad, button);
}

fn updateGamepadButtonStates(
    states: *[ffi.GAMEPAD_COUNT * ffi.GAMEPAD_BUTTON_COUNT]u8,
    gamepad: usize,
    available: bool,
    context: anytype,
    comptime is_button_down: anytype,
) void {
    const gamepad_id: c_int = @intCast(gamepad);

    for (0..ffi.GAMEPAD_BUTTON_COUNT) |button| {
        const flat_index = gamepadButtonIndex(gamepad, button);
        if (available) {
            states[flat_index] = nextInputState(
                states[flat_index],
                is_button_down(context, gamepad_id, @intCast(button)),
                0,
            );
        } else {
            states[flat_index] = disconnectedInputState(states[flat_index]);
        }
    }
}

test "input state packs held and edge flags" {
    try std.testing.expectEqual(@as(u8, 0), inputStateBits(false, false, false));
    try std.testing.expectEqual(@as(u8, 7), inputStateBits(true, true, true));
    try std.testing.expectEqual(ffi.INPUT_RELEASED, inputStateBits(false, false, true));
}

test "disconnecting a held input synthesizes one release edge" {
    try std.testing.expectEqual(ffi.INPUT_RELEASED, disconnectedInputState(ffi.INPUT_HELD));
    try std.testing.expectEqual(@as(u8, 0), disconnectedInputState(ffi.INPUT_RELEASED));
}

test "input state derives press and release edges from held transitions" {
    const up = nextInputState(0, false, 0);
    try std.testing.expectEqual(@as(u8, 0), up);

    const pressed = nextInputState(up, true, 0);
    try std.testing.expectEqual(ffi.INPUT_HELD | ffi.INPUT_PRESSED, pressed);

    const held = nextInputState(pressed, true, 0);
    try std.testing.expectEqual(ffi.INPUT_HELD, held);

    const released = nextInputState(held, false, 0);
    try std.testing.expectEqual(ffi.INPUT_RELEASED, released);
    try std.testing.expectEqual(@as(u8, 0), nextInputState(released, false, 0));
}

test "recorded edges surface even when the level did not change" {
    // A tap inside the interval: the level is up at both ends.
    const tap = nextInputState(0, false, ffi.INPUT_PRESSED | ffi.INPUT_RELEASED);
    try std.testing.expectEqual(ffi.INPUT_PRESSED | ffi.INPUT_RELEASED, tap);

    // Released and pressed again inside the interval: the level is down at
    // both ends, and the app is told about both edges rather than a hold.
    const held = ffi.INPUT_HELD;
    const regrip = nextInputState(held, true, ffi.INPUT_RELEASED | ffi.INPUT_PRESSED);
    try std.testing.expectEqual(ffi.INPUT_HELD | ffi.INPUT_RELEASED | ffi.INPUT_PRESSED, regrip);

    // An edge and a level transition that agree are one edge, not two.
    try std.testing.expectEqual(ffi.INPUT_HELD | ffi.INPUT_PRESSED, nextInputState(0, true, ffi.INPUT_PRESSED));
    try std.testing.expectEqual(ffi.INPUT_RELEASED, nextInputState(held, false, ffi.INPUT_RELEASED));
}

test "gamepad buttons use one held query per connected button" {
    const Query = struct {
        count: usize = 0,
        down: [ffi.GAMEPAD_BUTTON_COUNT]bool = [_]bool{false} ** ffi.GAMEPAD_BUTTON_COUNT,

        fn isDown(self: *@This(), _: c_int, button: c_int) bool {
            self.count += 1;
            return self.down[@intCast(button)];
        }
    };

    var states = [_]u8{0} ** (ffi.GAMEPAD_COUNT * ffi.GAMEPAD_BUTTON_COUNT);
    var query = Query{};

    updateGamepadButtonStates(&states, 0, true, &query, Query.isDown);
    try std.testing.expectEqual(ffi.GAMEPAD_BUTTON_COUNT, query.count);

    updateGamepadButtonStates(&states, 0, false, &query, Query.isDown);
    try std.testing.expectEqual(ffi.GAMEPAD_BUTTON_COUNT, query.count);
}

test "gamepad button edges survive disconnect and reconnect" {
    const Query = struct {
        down: [ffi.GAMEPAD_BUTTON_COUNT]bool = [_]bool{false} ** ffi.GAMEPAD_BUTTON_COUNT,

        fn isDown(self: *@This(), _: c_int, button: c_int) bool {
            return self.down[@intCast(button)];
        }
    };

    const button = 3;
    const index = gamepadButtonIndex(0, button);
    var states = [_]u8{0} ** (ffi.GAMEPAD_COUNT * ffi.GAMEPAD_BUTTON_COUNT);
    var query = Query{};

    query.down[button] = true;
    updateGamepadButtonStates(&states, 0, true, &query, Query.isDown);
    try std.testing.expectEqual(ffi.INPUT_HELD | ffi.INPUT_PRESSED, states[index]);

    updateGamepadButtonStates(&states, 0, true, &query, Query.isDown);
    try std.testing.expectEqual(ffi.INPUT_HELD, states[index]);

    updateGamepadButtonStates(&states, 0, false, &query, Query.isDown);
    try std.testing.expectEqual(ffi.INPUT_RELEASED, states[index]);

    updateGamepadButtonStates(&states, 0, false, &query, Query.isDown);
    try std.testing.expectEqual(@as(u8, 0), states[index]);

    updateGamepadButtonStates(&states, 0, true, &query, Query.isDown);
    try std.testing.expectEqual(ffi.INPUT_HELD | ffi.INPUT_PRESSED, states[index]);
}

// ---- Window-system event callbacks ----
//
// raylib's GLFW platform keeps levels, not queues: its key and mouse-button
// callbacks store the latest action, its scroll callback overwrites the
// wheel, and its character queue is a fixed sixteen per poll. Everything that
// happens between two polls collapses into whatever came last, and the poll
// period is the frame time. So the host chains its own callbacks behind
// raylib's on the same window and records every event itself: edges into the
// accumulators and the log above, wheel offsets into a sum, characters into a
// bounded buffer with an overflow flag. raylib's callback is still forwarded
// every event, so its own state -- and its exit key, which its key callback
// handles -- keep working unchanged. All of it runs on the frame thread,
// inside `glfwPollEvents`.

/// GLFW's window type. Opaque here: the host never dereferences it.
const GlfwWindow = opaque {};
const GlfwKeyFn = ?*const fn (?*GlfwWindow, c_int, c_int, c_int, c_int) callconv(.c) void;
const GlfwMouseButtonFn = ?*const fn (?*GlfwWindow, c_int, c_int, c_int) callconv(.c) void;
const GlfwScrollFn = ?*const fn (?*GlfwWindow, f64, f64) callconv(.c) void;
const GlfwCharFn = ?*const fn (?*GlfwWindow, c_uint) callconv(.c) void;

// Declared by hand rather than through a header: the vendored raylib ships
// only its own headers, but every target's archive carries GLFW. The window
// comes from the current context rather than `GetWindowHandle`, which returns
// the native (HWND / NSWindow) handle on two of the four targets.
extern fn glfwGetCurrentContext() ?*GlfwWindow;
extern fn glfwSetKeyCallback(window: ?*GlfwWindow, callback: GlfwKeyFn) GlfwKeyFn;
extern fn glfwSetMouseButtonCallback(window: ?*GlfwWindow, callback: GlfwMouseButtonFn) GlfwMouseButtonFn;
extern fn glfwSetScrollCallback(window: ?*GlfwWindow, callback: GlfwScrollFn) GlfwScrollFn;
extern fn glfwSetCharCallback(window: ?*GlfwWindow, callback: GlfwCharFn) GlfwCharFn;

const GLFW_RELEASE: c_int = 0;
const GLFW_PRESS: c_int = 1;
const GLFW_REPEAT: c_int = 2;

/// raylib's own callbacks, forwarded every event from the host's.
var raylib_key_callback: GlfwKeyFn = null;
var raylib_mouse_button_callback: GlfwMouseButtonFn = null;
var raylib_scroll_callback: GlfwScrollFn = null;
var raylib_char_callback: GlfwCharFn = null;
var input_callbacks_installed: bool = false;

/// Where a click's position is read from inside the button callback.
///
/// raylib's while the callbacks are installed; the origin before that, so a
/// test can drive the callback without a window (and without linking raylib
/// into the test binary).
var callback_mouse_position: *const fn () Vec2 = &originPosition;

fn originPosition() Vec2 {
    return .{ .x = 0, .y = 0 };
}

/// The pointer as raylib reports it, in the same logical coordinates as
/// `mouse.position()`.
///
/// Read inside the button callback on purpose: GLFW dispatches the motion
/// events that precede a click before the click itself, and raylib's
/// cursor-position callback has already applied its offset and scale by the
/// time ours runs, so this is the position the click landed at without
/// re-deriving raylib's scaling here.
fn raylibMousePosition() Vec2 {
    const position = rl.GetMousePosition();
    return .{ .x = position.x, .y = position.y };
}

fn hostKeyCallback(window: ?*GlfwWindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    if (raylib_key_callback) |forward| forward(window, key, scancode, action, mods);
    recordKeyAction(key, action);
}

fn hostMouseButtonCallback(window: ?*GlfwWindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    if (raylib_mouse_button_callback) |forward| forward(window, button, action, mods);
    recordMouseButtonAction(button, action);
}

fn hostScrollCallback(window: ?*GlfwWindow, x_offset: f64, y_offset: f64) callconv(.c) void {
    if (raylib_scroll_callback) |forward| forward(window, x_offset, y_offset);
    recordScroll(x_offset, y_offset);
}

fn hostCharCallback(window: ?*GlfwWindow, codepoint: c_uint) callconv(.c) void {
    if (raylib_char_callback) |forward| forward(window, codepoint);
    recordCodepoint(codepoint);
}

/// Decode one GLFW key action into an edge, if it is one.
///
/// `GLFW_KEY_UNKNOWN` is -1 and is dropped along with any code past the packed
/// list. Auto-repeat is not an edge: the key is still held, the user did
/// nothing, and treating it as a press would fabricate one per repeat during
/// a stall. raylib still sees the repeat through the forwarded callback.
fn recordKeyAction(key: c_int, action: c_int) void {
    if (key < 0 or key >= ffi.KEY_COUNT) return;
    const edge: InputEdge = switch (action) {
        GLFW_PRESS => .press,
        GLFW_RELEASE => .release,
        else => return,
    };
    recordHardwareKeyEdge(@intCast(key), edge);
}

fn recordMouseButtonAction(button: c_int, action: c_int) void {
    if (button < 0 or button >= ffi.MOUSE_BUTTON_COUNT) return;
    const edge: InputEdge = switch (action) {
        GLFW_PRESS => .press,
        GLFW_RELEASE => .release,
        else => return,
    };
    recordHardwareMouseButtonEdge(@intCast(button), edge, callback_mouse_position());
}

/// Record a key edge the window system delivered: into the coalesced bits
/// and the ordered log alike.
///
/// The callback above is the caller in a windowed run; a test is the other,
/// standing in for the window system between two polls.
pub fn recordHardwareKeyEdge(code: usize, edge: InputEdge) void {
    hardware_key_edges.record(code, edge);
    hardware_events.append(.keyboard, keyRecord(code, edge));
}

/// Record a mouse button edge the window system delivered, with the pointer
/// position the click landed at.
pub fn recordHardwareMouseButtonEdge(button: usize, edge: InputEdge, position: Vec2) void {
    hardware_mouse_button_edges.record(button, edge);
    hardware_events.append(.mouse, buttonRecord(button, edge, position));
}

/// Record a key edge a script placed inside the current cycle.
///
/// A code the host has no slot for is dropped, as `applyVirtualKeys` drops it.
/// Consumed by the next derivation from the virtual source; discarded by a
/// derivation from hardware, where it has no cycle to land in.
pub fn recordVirtualKeyEdge(code: u64, edge: InputEdge) void {
    if (code >= ffi.KEY_COUNT) return;
    virtual_key_edges.record(@intCast(code), edge);
    virtual_events.append(.keyboard, keyRecord(@intCast(code), edge));
}

/// Record a wheel movement a script placed inside the current cycle. The
/// scripted pointer's own sum is the host's; only the event is logged here.
pub fn recordVirtualWheel(x_offset: f32, y_offset: f32) void {
    virtual_events.append(.mouse, wheelRecord(x_offset, y_offset));
}

/// Record one scripted codepoint in the ordered log. The scripted text buffer
/// itself is the host's.
pub fn recordVirtualText(codepoint: u32) void {
    virtual_events.append(.text, textRecord(codepoint));
}

/// Add one scroll event to the interval's wheel movement and the log.
pub fn recordScroll(x_offset: f64, y_offset: f64) void {
    const x: f32 = @floatCast(x_offset);
    const y: f32 = @floatCast(y_offset);
    hardware_wheel.x += x;
    hardware_wheel.y += y;
    hardware_events.append(.mouse, wheelRecord(x, y));
}

/// Append one typed codepoint, or note that the interval's buffer is full;
/// the log records it either way, up to its own capacity.
pub fn recordCodepoint(codepoint: u32) void {
    if (text_input_len < text_input.len) {
        const was_empty = text_input_len == 0;
        text_input[text_input_len] = codepoint;
        text_input_len += 1;
        text_input_high_water = @max(text_input_high_water, text_input_len);
        const observed_at = observeInputQueue(.{ .operation = .reserve, .buffer = .text_codepoints, .amount = 1, .current = text_input_len, .high_water = text_input_high_water, .capacity = text_input.len, .oldest_at = text_input_oldest_at });
        if (was_empty) text_input_oldest_at = observed_at;
    } else {
        text_input_overflowed = true;
        _ = observeInputQueue(.{ .operation = .overflow, .buffer = .text_codepoints, .amount = 1, .current = text_input_len, .high_water = text_input_high_water, .capacity = text_input.len, .oldest_at = text_input_oldest_at });
    }
    hardware_events.append(.text, textRecord(codepoint));
}

/// Chain the host's input callbacks behind raylib's on the live window.
///
/// Called once the window exists: raylib installs its own callbacks in
/// `InitWindow`, and each `glfwSet*Callback` hands back the one it replaces,
/// which is what the host forwards to. Returns false when there is no current
/// GLFW context to hook, in which case edges come from level comparison alone
/// and text from raylib's own queue -- the sampled behaviour the callbacks
/// exist to improve on. Idempotent, so it can never chain to itself.
pub fn installInputEventCallbacks() bool {
    if (input_callbacks_installed) return true;
    const window = glfwGetCurrentContext() orelse return false;
    raylib_key_callback = glfwSetKeyCallback(window, hostKeyCallback);
    raylib_mouse_button_callback = glfwSetMouseButtonCallback(window, hostMouseButtonCallback);
    raylib_scroll_callback = glfwSetScrollCallback(window, hostScrollCallback);
    raylib_char_callback = glfwSetCharCallback(window, hostCharCallback);
    callback_mouse_position = &raylibMousePosition;
    input_callbacks_installed = true;
    clearRecordedHardwareInput();
    return true;
}

/// Forget the callbacks along with the window they were installed on.
fn forgetInputEventCallbacks() void {
    input_callbacks_installed = false;
    raylib_key_callback = null;
    raylib_mouse_button_callback = null;
    raylib_scroll_callback = null;
    raylib_char_callback = null;
    callback_mouse_position = &originPosition;
    clearRecordedHardwareInput();
}

/// Drop everything the window system recorded but nothing has consumed.
fn clearRecordedHardwareInput() void {
    hardware_key_edges.clear();
    hardware_mouse_button_edges.clear();
    hardware_events.clear();
    hardware_wheel = .{ .x = 0, .y = 0 };
    releaseRecordedText();
    text_input_overflowed = false;
}

fn releaseRecordedText() void {
    if (text_input_len != 0) _ = observeInputQueue(.{ .operation = .release, .buffer = .text_codepoints, .amount = text_input_len, .current = 0, .high_water = text_input_high_water, .capacity = text_input.len, .oldest_at = text_input_oldest_at });
    text_input_len = 0;
    text_input_oldest_at = 0;
}

test "GLFW key actions become edges, except repeats and unknown keys" {
    defer clearRecordedHardwareInput();
    const key_a = 65;

    hostKeyCallback(null, key_a, 0, GLFW_PRESS, 0);
    hostKeyCallback(null, key_a, 0, GLFW_REPEAT, 0);
    hostKeyCallback(null, key_a, 0, GLFW_REPEAT, 0);
    try std.testing.expectEqual(ffi.INPUT_PRESSED, hardware_key_edges.take(key_a));

    hostKeyCallback(null, key_a, 0, GLFW_RELEASE, 0);
    try std.testing.expectEqual(ffi.INPUT_RELEASED, hardware_key_edges.take(key_a));

    // GLFW_KEY_UNKNOWN and a code past the packed list have nowhere to land.
    hostKeyCallback(null, -1, 0, GLFW_PRESS, 0);
    hostKeyCallback(null, ffi.KEY_COUNT, 0, GLFW_PRESS, 0);
    for (hardware_key_edges.bits) |bits| try std.testing.expectEqual(@as(u8, 0), bits);

    hostMouseButtonCallback(null, 1, GLFW_PRESS, 0);
    hostMouseButtonCallback(null, ffi.MOUSE_BUTTON_COUNT, GLFW_PRESS, 0);
    try std.testing.expectEqual(ffi.INPUT_PRESSED, hardware_mouse_button_edges.take(1));
    for (hardware_mouse_button_edges.bits) |bits| try std.testing.expectEqual(@as(u8, 0), bits);

    // The log saw exactly the edges: two for A, one for the button; no
    // repeats, no unknown keys.
    const taken = takeInputEvents(all_hardware);
    try std.testing.expectEqual(@as(usize, 3), taken.events.len);
    try expectEvent(taken.events[0], .key_pressed, key_a, 0, 0);
    try expectEvent(taken.events[1], .key_released, key_a, 0, 0);
    try expectEvent(taken.events[2], .button_pressed, 1, 0, 0);
}

test "a click carries the pointer position read at the moment it fired" {
    const Pointer = struct {
        var at: Vec2 = .{ .x = 0, .y = 0 };
        fn position() Vec2 {
            return at;
        }
    };
    callback_mouse_position = &Pointer.position;
    defer forgetInputEventCallbacks();

    Pointer.at = .{ .x = 100, .y = 40 };
    hostMouseButtonCallback(null, 0, GLFW_PRESS, 0);
    Pointer.at = .{ .x = 180, .y = 90 };
    hostMouseButtonCallback(null, 0, GLFW_RELEASE, 0);

    const taken = takeInputEvents(all_hardware);
    try std.testing.expectEqual(@as(usize, 2), taken.events.len);
    try expectEvent(taken.events[0], .button_pressed, 0, 100, 40);
    try expectEvent(taken.events[1], .button_released, 0, 180, 90);
}

test "every event is forwarded to raylib's callback unchanged" {
    const Forwarded = struct {
        var key: [5]c_int = undefined;
        var key_calls: usize = 0;
        var button: [3]c_int = undefined;
        var scroll: [2]f64 = undefined;
        var char: c_uint = 0;

        fn onKey(_: ?*GlfwWindow, k: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
            key = .{ k, scancode, action, mods, 0 };
            key_calls += 1;
        }
        fn onMouseButton(_: ?*GlfwWindow, b: c_int, action: c_int, mods: c_int) callconv(.c) void {
            button = .{ b, action, mods };
        }
        fn onScroll(_: ?*GlfwWindow, x: f64, y: f64) callconv(.c) void {
            scroll = .{ x, y };
        }
        fn onChar(_: ?*GlfwWindow, c: c_uint) callconv(.c) void {
            char = c;
        }
    };
    raylib_key_callback = Forwarded.onKey;
    raylib_mouse_button_callback = Forwarded.onMouseButton;
    raylib_scroll_callback = Forwarded.onScroll;
    raylib_char_callback = Forwarded.onChar;
    defer forgetInputEventCallbacks();

    // The exit key is raylib's to handle, inside its key callback, so the
    // repeat and the press both have to reach it even though only the press
    // is an edge to the host.
    hostKeyCallback(null, 256, 9, GLFW_PRESS, 1);
    hostKeyCallback(null, 256, 9, GLFW_REPEAT, 1);
    try std.testing.expectEqual(@as(usize, 2), Forwarded.key_calls);
    try std.testing.expectEqualSlices(c_int, &.{ 256, 9, GLFW_REPEAT, 1 }, Forwarded.key[0..4]);

    hostMouseButtonCallback(null, 2, GLFW_RELEASE, 4);
    try std.testing.expectEqualSlices(c_int, &.{ 2, GLFW_RELEASE, 4 }, &Forwarded.button);

    hostScrollCallback(null, -1.5, 2.0);
    try std.testing.expectEqualSlices(f64, &.{ -1.5, 2.0 }, &Forwarded.scroll);

    hostCharCallback(null, 0x20ac);
    try std.testing.expectEqual(@as(c_uint, 0x20ac), Forwarded.char);
}

/// Derive the packed keyboard state for one interval.
///
/// `down` is the level at the interval's end and `source` names the edge
/// accumulator to consume; the other accumulator is discarded, so a scripted
/// keyboard never leaks a hardware edge and a script's tap cannot surface after
/// the app hands the keyboard back. A transition the level shows but no edge
/// recorded -- a scripted held set changing between cycles, or a hardware
/// callback that was somehow missed -- is logged here, so the list stays the
/// authoritative record of everything the bits say.
pub fn deriveKeyboardState(source: InputSource, down: *const [ffi.KEY_COUNT]bool) void {
    const consumed, const discarded, const log = switch (source) {
        .hardware => .{ &hardware_key_edges, &virtual_key_edges, &hardware_events },
        .virtual => .{ &virtual_key_edges, &hardware_key_edges, &virtual_events },
    };
    discarded.clear();
    for (0..ffi.KEY_COUNT) |i| {
        const edges = consumed.take(i);
        const next = nextInputState(key_state[i], down[i], edges);
        if (next & ffi.INPUT_PRESSED != 0 and edges & ffi.INPUT_PRESSED == 0) log.append(.keyboard, keyRecord(i, .press));
        if (next & ffi.INPUT_RELEASED != 0 and edges & ffi.INPUT_RELEASED == 0) log.append(.keyboard, keyRecord(i, .release));
        key_state[i] = next;
    }
}

/// Derive the packed mouse button state for one interval, as
/// `deriveKeyboardState` does. Only hardware records button edges; a virtual
/// pointer states levels, so `virtual` consumes nothing and discards the
/// hardware edges, and its transitions are logged with the pointer's scripted
/// position.
pub fn deriveMouseButtonState(source: InputSource, down: *const [ffi.MOUSE_BUTTON_COUNT]bool, position: Vec2) void {
    const log = switch (source) {
        .hardware => &hardware_events,
        .virtual => &virtual_events,
    };
    for (0..ffi.MOUSE_BUTTON_COUNT) |i| {
        const recorded = hardware_mouse_button_edges.take(i);
        const edges = if (source == .hardware) recorded else 0;
        const next = nextInputState(mouse_button_state[i], down[i], edges);
        if (next & ffi.INPUT_PRESSED != 0 and edges & ffi.INPUT_PRESSED == 0) log.append(.mouse, buttonRecord(i, .press, position));
        if (next & ffi.INPUT_RELEASED != 0 and edges & ffi.INPUT_RELEASED == 0) log.append(.mouse, buttonRecord(i, .release, position));
        mouse_button_state[i] = next;
    }
}

/// Update keyboard state from the window system, once per interval.
///
/// The level is raylib's, kept current by the forwarded callbacks; the edges
/// are the host's own record of the interval.
pub fn updateKeyboardState() void {
    var down: [ffi.KEY_COUNT]bool = undefined;
    for (0..ffi.KEY_COUNT) |i| down[i] = rl.IsKeyDown(@intCast(i));
    deriveKeyboardState(.hardware, &down);
}

/// Advance the packed keyboard state from caller-supplied held flags.
///
/// Used by the virtual keyboard in place of `updateKeyboardState`, and by a
/// headless run, which has no hardware to ask at all. It runs the same
/// derivation, so a scripted key produces real pressed-this-interval and
/// released-this-interval bits, and a scripted tap (`recordVirtualKeyEdge`)
/// lands inside one cycle exactly as a hardware tap between two polls does.
pub fn updateKeyboardStateFrom(down: *const [ffi.KEY_COUNT]bool) void {
    deriveKeyboardState(.virtual, down);
}

/// Forget every key's held and edge bits, recorded edges included.
///
/// Called when an app lifetime starts, so a key held when one app exited is
/// not still held when the next one begins.
pub fn clearKeyState() void {
    key_state = [_]u8{0} ** ffi.KEY_COUNT;
    hardware_key_edges.clear();
    virtual_key_edges.clear();
}

/// Get the current packed keyboard state array.
pub fn getKeyState() *const [ffi.KEY_COUNT]u8 {
    return &key_state;
}

/// Update mouse button state from the window system, once per interval.
pub fn updateMouseButtonState() void {
    var down: [ffi.MOUSE_BUTTON_COUNT]bool = undefined;
    for (0..ffi.MOUSE_BUTTON_COUNT) |i| down[i] = rl.IsMouseButtonDown(@intCast(i));
    deriveMouseButtonState(.hardware, &down, raylibMousePosition());
}

/// Get the current packed mouse button state array.
pub fn getMouseButtonState() *const [ffi.MOUSE_BUTTON_COUNT]u8 {
    return &mouse_button_state;
}

/// Forget every mouse button's held and edge bits, as `clearKeyState` does.
pub fn clearMouseButtonState() void {
    mouse_button_state = [_]u8{0} ** ffi.MOUSE_BUTTON_COUNT;
    hardware_mouse_button_edges.clear();
}

/// Advance the packed mouse button state from caller-supplied down flags and
/// the scripted pointer's position.
///
/// Used by the virtual mouse in place of `updateMouseButtonState`. It runs the
/// same derivation, so a scripted pointer produces real pressed-this-interval
/// and released-this-interval bits and an app's ordinary click handling
/// reacts to it exactly as it would to hardware.
pub fn updateMouseButtonStateFrom(down: *const [ffi.MOUSE_BUTTON_COUNT]bool, position: Vec2) void {
    deriveMouseButtonState(.virtual, down, position);
}

test "a tap between two polls is pressed and released, never held" {
    defer clearKeyState();
    defer clearInputEvents();
    const key_e = 69;
    const up: [ffi.KEY_COUNT]bool = @splat(false);

    deriveKeyboardState(.hardware, &up);
    try std.testing.expectEqual(@as(u8, 0), getKeyState()[key_e]);

    // The window system delivers PRESS then RELEASE inside one interval, so
    // the level is up at both polls.
    recordHardwareKeyEdge(key_e, .press);
    recordHardwareKeyEdge(key_e, .release);
    deriveKeyboardState(.hardware, &up);
    try std.testing.expectEqual(ffi.INPUT_PRESSED | ffi.INPUT_RELEASED, getKeyState()[key_e]);

    // Consumed: the next interval is quiet again.
    deriveKeyboardState(.hardware, &up);
    try std.testing.expectEqual(@as(u8, 0), getKeyState()[key_e]);
}

test "a release and re-press between two polls is not one long hold" {
    defer clearMouseButtonState();
    defer clearInputEvents();
    const left = 0;
    const at = Vec2{ .x = 5, .y = 6 };
    var down: [ffi.MOUSE_BUTTON_COUNT]bool = @splat(false);

    down[left] = true;
    recordHardwareMouseButtonEdge(left, .press, at);
    deriveMouseButtonState(.hardware, &down, at);
    try std.testing.expectEqual(ffi.INPUT_HELD | ffi.INPUT_PRESSED, getMouseButtonState()[left]);

    // RELEASE then PRESS inside the interval; the level is down at both polls.
    recordHardwareMouseButtonEdge(left, .release, at);
    recordHardwareMouseButtonEdge(left, .press, at);
    deriveMouseButtonState(.hardware, &down, at);
    try std.testing.expectEqual(ffi.INPUT_HELD | ffi.INPUT_RELEASED | ffi.INPUT_PRESSED, getMouseButtonState()[left]);

    deriveMouseButtonState(.hardware, &down, at);
    try std.testing.expectEqual(ffi.INPUT_HELD, getMouseButtonState()[left]);
}

test "each source consumes its own edges and discards the other's" {
    defer clearKeyState();
    defer clearMouseButtonState();
    defer clearInputEvents();
    const key_a = 65;
    const up: [ffi.KEY_COUNT]bool = @splat(false);
    const origin = Vec2{ .x = 0, .y = 0 };

    // A hardware tap while a script owns the keyboard is not the script's.
    recordHardwareKeyEdge(key_a, .press);
    recordHardwareKeyEdge(key_a, .release);
    deriveKeyboardState(.virtual, &up);
    try std.testing.expectEqual(@as(u8, 0), getKeyState()[key_a]);
    // And it does not resurface when the app hands the keyboard back.
    deriveKeyboardState(.hardware, &up);
    try std.testing.expectEqual(@as(u8, 0), getKeyState()[key_a]);

    // A scripted tap consumed by hardware derivation is likewise gone.
    recordVirtualKeyEdge(key_a, .press);
    recordVirtualKeyEdge(key_a, .release);
    deriveKeyboardState(.hardware, &up);
    try std.testing.expectEqual(@as(u8, 0), getKeyState()[key_a]);
    deriveKeyboardState(.virtual, &up);
    try std.testing.expectEqual(@as(u8, 0), getKeyState()[key_a]);

    // A scripted tap consumed by the virtual source lands.
    recordVirtualKeyEdge(key_a, .press);
    recordVirtualKeyEdge(key_a, .release);
    recordVirtualKeyEdge(ffi.KEY_COUNT + 5, .press);
    deriveKeyboardState(.virtual, &up);
    try std.testing.expectEqual(ffi.INPUT_PRESSED | ffi.INPUT_RELEASED, getKeyState()[key_a]);

    // A virtual pointer states levels only; hardware button edges are dropped.
    const buttons_up: [ffi.MOUSE_BUTTON_COUNT]bool = @splat(false);
    recordHardwareMouseButtonEdge(0, .press, origin);
    deriveMouseButtonState(.virtual, &buttons_up, origin);
    try std.testing.expectEqual(@as(u8, 0), getMouseButtonState()[0]);
    deriveMouseButtonState(.hardware, &buttons_up, origin);
    try std.testing.expectEqual(@as(u8, 0), getMouseButtonState()[0]);
}

test "a level transition with no recorded edge is logged so the list stays complete" {
    defer clearKeyState();
    defer clearMouseButtonState();
    defer clearInputEvents();
    var down: [ffi.KEY_COUNT]bool = @splat(false);
    var buttons: [ffi.MOUSE_BUTTON_COUNT]bool = @splat(false);

    // A scripted held set: S goes down on one cycle and up on the next, and
    // the pointer's button with it, at the scripted position.
    down['S'] = true;
    buttons[0] = true;
    deriveKeyboardState(.virtual, &down);
    deriveMouseButtonState(.virtual, &buttons, .{ .x = 7, .y = 8 });
    down['S'] = false;
    buttons[0] = false;
    deriveKeyboardState(.virtual, &down);
    deriveMouseButtonState(.virtual, &buttons, .{ .x = 9, .y = 10 });

    const taken = takeInputEvents(all_virtual);
    try std.testing.expectEqual(@as(usize, 4), taken.events.len);
    try expectEvent(taken.events[0], .key_pressed, 'S', 0, 0);
    try expectEvent(taken.events[1], .button_pressed, 0, 7, 8);
    try expectEvent(taken.events[2], .key_released, 'S', 0, 0);
    try expectEvent(taken.events[3], .button_released, 0, 9, 10);

    // A recorded edge and the level agreeing is one event, not two.
    recordHardwareKeyEdge('S', .press);
    down['S'] = true;
    deriveKeyboardState(.hardware, &down);
    const once = takeInputEvents(all_hardware);
    try std.testing.expectEqual(@as(usize, 1), once.events.len);
    try expectEvent(once.events[0], .key_pressed, 'S', 0, 0);
}

/// Sample all supported gamepads once for this frame.
///
/// Sampled, not recorded: raylib polls gamepads inside `PollInputEvents` with
/// no callback to chain, so a button pressed and released between two polls
/// is invisible here. That is documented as lossy on the Roc side rather than
/// papered over.
pub fn updateGamepadState() void {
    for (0..ffi.GAMEPAD_COUNT) |gamepad| {
        const gamepad_id: c_int = @intCast(gamepad);
        const available = rl.IsGamepadAvailable(gamepad_id);
        gamepad_available[gamepad] = if (available) 1 else 0;
        updateGamepadButtonStates(
            &gamepad_button_state,
            gamepad,
            available,
            {},
            raylibGamepadButtonDown,
        );

        const native_axis_count: usize = if (available)
            @intCast(@max(rl.GetGamepadAxisCount(gamepad_id), 0))
        else
            0;
        for (0..ffi.GAMEPAD_AXIS_COUNT) |axis| {
            const flat_index = gamepadAxisIndex(gamepad, axis);
            gamepad_axes[flat_index] = if (axis < native_axis_count)
                rl.GetGamepadAxisMovement(gamepad_id, @intCast(axis))
            else
                0;
        }
    }
}

/// Get the sampled gamepad availability array.
pub fn getGamepadAvailability() *const [ffi.GAMEPAD_COUNT]u8 {
    return &gamepad_available;
}

/// Get the sampled packed gamepad button-state array.
pub fn getGamepadButtonState() *const [ffi.GAMEPAD_COUNT * ffi.GAMEPAD_BUTTON_COUNT]u8 {
    return &gamepad_button_state;
}

/// Get the sampled gamepad axis array.
pub fn getGamepadAxes() *const [ffi.GAMEPAD_COUNT * ffi.GAMEPAD_AXIS_COUNT]f32 {
    return &gamepad_axes;
}

/// How many dropped paths one cycle delivers.
///
/// raylib puts no ceiling on a single drop: its window callback allocates for
/// whatever the window system hands over, and the `capacity` field of a
/// `FilePathList` is only filled in by the directory-listing calls. So the
/// bound is the host's, and it is stated rather than implied -- a drop of more
/// than this many files has the extra paths discarded and is reported as an
/// overflow, never silently truncated.
pub const DROPPED_FILES_CAPACITY: usize = 64;

/// raylib's own list for the drop currently being read, owned until released.
var dropped_files: ?rl.FilePathList = null;

/// Borrow the paths from this cycle's drop, if the window saw one.
///
/// The C strings belong to raylib and stay valid only until
/// `releaseDroppedFiles`, so a caller copies what it needs and then releases;
/// the pair is what raylib's load/unload contract requires. An empty slice
/// means no file was dropped, which is every cycle but a handful.
pub fn takeDroppedFiles() []const [*:0]const u8 {
    std.debug.assert(dropped_files == null);
    if (!rl.IsFileDropped()) return &.{};
    const list = rl.LoadDroppedFiles();
    dropped_files = list;
    if (list.paths == null or list.count == 0) return &.{};
    const typed: [*]const [*:0]const u8 = @ptrCast(list.paths);
    return typed[0..@as(usize, list.count)];
}

/// Hand this cycle's drop back to raylib. Safe to call when there was none.
pub fn releaseDroppedFiles() void {
    const list = dropped_files orelse return;
    dropped_files = null;
    rl.UnloadDroppedFiles(list);
}

/// Take the interval's wheel movement: every scroll event summed.
///
/// Taken, not read, so each notch is delivered to exactly one input. The
/// caller takes it every cycle whether or not a scripted pointer is standing
/// in for the hardware one, so notches turned while the pointer was scripted
/// do not land on the cycle the app hands it back. Without callbacks this is
/// raylib's own value, which is the last event of the poll rather than the
/// sum.
pub fn takeMouseWheelMove() Vec2 {
    if (!input_callbacks_installed) return getMouseWheelMoveV();
    return takeRecordedWheel();
}

fn takeRecordedWheel() Vec2 {
    const moved = hardware_wheel;
    hardware_wheel = .{ .x = 0, .y = 0 };
    return moved;
}

test "wheel notches inside one interval are summed, then consumed" {
    defer clearRecordedHardwareInput();
    try std.testing.expectEqual(@as(f32, 0), takeRecordedWheel().y);

    hostScrollCallback(null, 0, 1);
    hostScrollCallback(null, 0, 1);
    hostScrollCallback(null, -0.5, -0.25);
    const moved = takeRecordedWheel();
    try std.testing.expectEqual(@as(f32, -0.5), moved.x);
    try std.testing.expectEqual(@as(f32, 1.75), moved.y);

    const next = takeRecordedWheel();
    try std.testing.expectEqual(@as(f32, 0), next.x);
    try std.testing.expectEqual(@as(f32, 0), next.y);

    // Each notch is its own event in the log.
    const taken = takeInputEvents(all_hardware);
    try std.testing.expectEqual(@as(usize, 3), taken.events.len);
    try expectEvent(taken.events[2], .wheel, 0, -0.5, -0.25);
}

/// One interval's typed text, and whether any of it was discarded.
pub const TextInput = struct {
    codepoints: []const u32,
    overflowed: bool,
};

/// Take the interval's typed text: at most `TEXT_INPUT_CAPACITY` codepoints in
/// the order typed, and whether more arrived than that.
///
/// The slice is a stable scratch buffer that the next recorded character
/// overwrites, so the caller copies it before the next poll. Without callbacks
/// this drains raylib's own queue instead.
pub fn takeTextInput() TextInput {
    if (!input_callbacks_installed) return drainRaylibTextQueue();
    return takeRecordedText();
}

/// Whether typed-text overflow was observed at this host buffer's exact
/// admission point. The raylib fallback can disclose only possible loss when
/// its opaque queue was full, so its interval overflow remains a later fact.
pub fn recordedTextPressureAvailable() bool {
    return input_callbacks_installed;
}

fn takeRecordedText() TextInput {
    const delivered = text_input[0..text_input_len];
    const overflowed = text_input_overflowed;
    releaseRecordedText();
    text_input_overflowed = false;
    return .{ .codepoints = delivered, .overflowed = overflowed };
}

/// raylib's queue holds `RAYLIB_CHAR_QUEUE_CAPACITY` codepoints per poll and
/// drops the rest without saying so. A full queue cannot be told apart from an
/// overflowed one, so it is reported as an overflow: the honest answer is
/// "possibly", and the flag's contract is that a clear flag means nothing was
/// lost. The codepoints are logged as they are drained so the event list sees
/// them on this path too.
fn drainRaylibTextQueue() TextInput {
    var count: usize = 0;
    while (true) {
        const codepoint = rl.GetCharPressed();
        if (codepoint <= 0) break;
        hardware_events.append(.text, textRecord(@intCast(codepoint)));
        if (count < text_input.len) {
            text_input[count] = @intCast(codepoint);
            count += 1;
        }
    }
    return .{
        .codepoints = text_input[0..count],
        .overflowed = count >= RAYLIB_CHAR_QUEUE_CAPACITY,
    };
}

test "typed text past the interval's capacity is reported, not silently cut" {
    defer clearRecordedHardwareInput();

    hostCharCallback(null, 'h');
    hostCharCallback(null, 'i');
    const short = takeRecordedText();
    try std.testing.expectEqualSlices(u32, &.{ 'h', 'i' }, short.codepoints);
    try std.testing.expect(!short.overflowed);

    // Gone once taken: characters arrive on one input and not the next.
    const empty = takeRecordedText();
    try std.testing.expectEqual(@as(usize, 0), empty.codepoints.len);
    try std.testing.expect(!empty.overflowed);

    for (0..TEXT_INPUT_CAPACITY) |i| hostCharCallback(null, @intCast('a' + (i % 26)));
    const exact = takeRecordedText();
    try std.testing.expectEqual(TEXT_INPUT_CAPACITY, exact.codepoints.len);
    try std.testing.expect(!exact.overflowed);

    for (0..TEXT_INPUT_CAPACITY + 1) |_| hostCharCallback(null, 'x');
    const over = takeRecordedText();
    try std.testing.expectEqual(TEXT_INPUT_CAPACITY, over.codepoints.len);
    try std.testing.expect(over.overflowed);

    // The flag travels with the interval that overflowed, not the next one.
    try std.testing.expect(!takeRecordedText().overflowed);

    // The log kept every character, including the one past the text cap.
    const taken = takeInputEvents(all_hardware);
    try std.testing.expectEqual(2 + TEXT_INPUT_CAPACITY + TEXT_INPUT_CAPACITY + 1, taken.events.len);
    try expectEvent(taken.events[0], .text, 'h', 0, 0);
    try expectEvent(taken.events[taken.events.len - 1], .text, 'x', 0, 0);
}

/// Return raylib's built-in font, which is not owned by a resource heap.
pub fn defaultFont() Font {
    return rl.GetFontDefault();
}

/// Load a custom font directly from a filesystem path.
pub fn loadFont(path: [*:0]const u8, size: c_int) ?Font {
    const font = rl.LoadFontEx(path, @max(size, 1), null, 0);
    if (!rl.IsFontValid(font)) return null;
    rl.SetTextureFilter(font.texture, rl.TEXTURE_FILTER_BILINEAR);
    return font;
}

/// Unload a custom font when its host resource slot is released.
pub fn unloadFont(font: Font) void {
    rl.UnloadFont(font);
}

/// Return a font's base pixel size for `MeasureTextEx` scaling.
pub fn fontBaseSize(font: Font) f32 {
    return @floatFromInt(font.baseSize);
}

/// Return the number of glyphs available for scalar metric snapshotting.
pub fn fontGlyphCount(font: Font) usize {
    if (font.glyphCount <= 0 or font.glyphs == null or font.recs == null) return 0;
    return @intCast(font.glyphCount);
}

/// Read the same glyph advance used by raylib's `MeasureTextEx`.
pub fn fontGlyphMetric(font: Font, index: usize) FontGlyphMetric {
    const glyph = font.glyphs[index];
    const rec = font.recs[index];
    return .{
        .codepoint = if (glyph.value > 0) @intCast(glyph.value) else 0,
        .advance_x = @floatFromInt(glyph.advanceX),
        .offset_x = @floatFromInt(glyph.offsetX),
        .offset_y = @floatFromInt(glyph.offsetY),
        .width = rec.width,
        .height = rec.height,
    };
}

/// Unload a texture when its host resource slot is released.
pub fn unloadTexture(texture: Texture) void {
    rl.UnloadTexture(texture);
}

/// Generate a solid-color texture, releasing the temporary CPU image before return.
pub fn generateColorTexture(width: i32, height: i32, color: Color) ?Texture {
    if (width <= 0 or height <= 0) return null;
    const image = rl.GenImageColor(width, height, colorToRl(color));
    defer rl.UnloadImage(image);
    if (!rl.IsImageValid(image)) return null;

    const texture = rl.LoadTextureFromImage(image);
    if (!rl.IsTextureValid(texture)) return null;
    return texture;
}

/// Generate a checkerboard texture, releasing the temporary CPU image before return.
pub fn generateCheckedTexture(args: anytype) ?Texture {
    if (args.width <= 0 or args.height <= 0 or args.checks_x <= 0 or args.checks_y <= 0) return null;
    const image = rl.GenImageChecked(
        args.width,
        args.height,
        args.checks_x,
        args.checks_y,
        colorToRl(args.color_a),
        colorToRl(args.color_b),
    );
    defer rl.UnloadImage(image);
    if (!rl.IsImageValid(image)) return null;

    const texture = rl.LoadTextureFromImage(image);
    if (!rl.IsTextureValid(texture)) return null;
    return texture;
}

/// Roc lays `Color.Rgba` out with its fields sorted, so the bytes arrive as
/// `{a, b, g, r}` while raylib reads `{r, g, b, a}`; uploading the Roc bytes
/// directly paints every pixel with its channels reversed. The pixels are
/// converted into a scratch buffer with `colorToRl` like every other color
/// that crosses into raylib. The scratch buffer failing to allocate is a host
/// failure, not an application outcome, so it stops the program by name.
fn convertPixels(pixels: []const Color) []rl.Color {
    const converted = std.heap.page_allocator.alloc(rl.Color, pixels.len) catch
        @panic("roc-ray: out of memory converting pixels for a texture upload");
    for (pixels, converted) |pixel, *out| out.* = colorToRl(pixel);
    return converted;
}

/// Replace all pixels in a texture from tightly packed RGBA colors.
pub fn updateTexture(texture: Texture, pixels: []const Color) void {
    const converted = convertPixels(pixels);
    defer std.heap.page_allocator.free(converted);
    rl.UpdateTexture(texture, converted.ptr);
}

/// One rectangle of a texture. `area` is in pixels and must lie inside it;
/// raylib does no bounds checking of its own, so the caller does.
pub fn updateTextureRegion(texture: Texture, area: struct { x: i32, y: i32, width: i32, height: i32 }, pixels: []const Color) void {
    const converted = convertPixels(pixels);
    defer std.heap.page_allocator.free(converted);
    rl.UpdateTextureRec(texture, .{
        .x = @floatFromInt(area.x),
        .y = @floatFromInt(area.y),
        .width = @floatFromInt(area.width),
        .height = @floatFromInt(area.height),
    }, converted.ptr);
}

/// Set a texture's scaling filter from the Roc enum code.
pub fn setTextureFilter(texture: Texture, code: u8) void {
    const filter: c_int = switch (code) {
        0 => rl.TEXTURE_FILTER_POINT,
        1 => rl.TEXTURE_FILTER_BILINEAR,
        2 => rl.TEXTURE_FILTER_TRILINEAR,
        3 => rl.TEXTURE_FILTER_ANISOTROPIC_4X,
        4 => rl.TEXTURE_FILTER_ANISOTROPIC_8X,
        5 => rl.TEXTURE_FILTER_ANISOTROPIC_16X,
        else => return,
    };
    rl.SetTextureFilter(texture, filter);
}

/// Set a texture's coordinate wrapping mode from the Roc enum code.
pub fn setTextureWrap(texture: Texture, code: u8) void {
    const wrap: c_int = switch (code) {
        0 => rl.TEXTURE_WRAP_REPEAT,
        1 => rl.TEXTURE_WRAP_CLAMP,
        2 => rl.TEXTURE_WRAP_MIRROR_REPEAT,
        3 => rl.TEXTURE_WRAP_MIRROR_CLAMP,
        else => return,
    };
    rl.SetTextureWrap(texture, wrap);
}

/// Create a framebuffer-backed texture for offscreen 2D rendering.
pub fn loadRenderTexture(width: c_int, height: c_int) ?RenderTexture {
    const target = rl.LoadRenderTexture(width, height);
    if (!rl.IsRenderTextureValid(target)) return null;
    return target;
}

/// Release a framebuffer and its color/depth attachments.
pub fn unloadRenderTexture(target: RenderTexture) void {
    rl.UnloadRenderTexture(target);
}

/// Return the color attachment so normal texture drawing can sample it.
pub fn renderTextureColor(target: RenderTexture) Texture {
    return target.texture;
}

/// Load shader source code, using raylib's default stage when a pointer is null.
pub fn loadShaderFromMemory(vertex_source: ?[*:0]const u8, fragment_source: ?[*:0]const u8) ?Shader {
    const shader = rl.LoadShaderFromMemory(vertex_source, fragment_source);
    if (!rl.IsShaderValid(shader)) return null;
    return shader;
}

/// Decode a font from caller-owned bytes. Raylib copies/decodes synchronously
/// and the returned Font does not retain `bytes`.
pub fn loadFontFromMemory(file_type: [*:0]const u8, bytes: []const u8, size: c_int) ?Font {
    if (bytes.len == 0 or bytes.len > std.math.maxInt(c_int) or size <= 0) return null;
    const font = rl.LoadFontFromMemory(file_type, bytes.ptr, @intCast(bytes.len), size, null, 0);
    if (!rl.IsFontValid(font)) return null;
    rl.SetTextureFilter(font.texture, rl.TEXTURE_FILTER_BILINEAR);
    return font;
}

/// Release a GPU shader program.
pub fn unloadShader(shader: Shader) void {
    rl.UnloadShader(shader);
}

/// Resolve and cache a uniform location on the Roc side.
pub fn shaderLocation(shader: Shader, name: [*:0]const u8) c_int {
    return rl.GetShaderLocation(shader, name);
}

/// Update scalar/vector shader values without allocating.
pub fn setShaderFloat(shader: Shader, location: c_int, value: f32) void {
    rl.SetShaderValue(shader, location, &value, rl.SHADER_UNIFORM_FLOAT);
}

/// Update a signed integer uniform.
pub fn setShaderInt(shader: Shader, location: c_int, value: i32) void {
    rl.SetShaderValue(shader, location, &value, rl.SHADER_UNIFORM_INT);
}

/// Update a two-component float vector uniform.
pub fn setShaderVec2(shader: Shader, location: c_int, value: [2]f32) void {
    rl.SetShaderValue(shader, location, &value, rl.SHADER_UNIFORM_VEC2);
}

/// Update a three-component float vector uniform.
pub fn setShaderVec3(shader: Shader, location: c_int, value: [3]f32) void {
    rl.SetShaderValue(shader, location, &value, rl.SHADER_UNIFORM_VEC3);
}

/// Update a four-component float vector uniform.
pub fn setShaderVec4(shader: Shader, location: c_int, value: [4]f32) void {
    rl.SetShaderValue(shader, location, &value, rl.SHADER_UNIFORM_VEC4);
}

/// Bind a texture to a sampler2D uniform.
pub fn setShaderTexture(shader: Shader, location: c_int, texture: Texture) void {
    rl.SetShaderValueTexture(shader, location, texture);
}

/// Return a native texture's width in pixels.
pub fn textureWidth(texture: Texture) f32 {
    return @floatFromInt(texture.width);
}

/// Return a native texture's height in pixels.
pub fn textureHeight(texture: Texture) f32 {
    return @floatFromInt(texture.height);
}

/// Convert an ABI RGBA color record to raylib Color.
pub fn colorToRl(color: anytype) rl.Color {
    return .{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = color.a,
    };
}

test "colorToRl preserves Roc RGBA channel order" {
    const black = colorToRl(Color{
        .r = 0,
        .g = 0,
        .b = 0,
        .a = 255,
    });
    try std.testing.expectEqual(@as(u8, 0), black.r);
    try std.testing.expectEqual(@as(u8, 0), black.g);
    try std.testing.expectEqual(@as(u8, 0), black.b);
    try std.testing.expectEqual(@as(u8, 255), black.a);

    const red = colorToRl(Color{
        .r = 230,
        .g = 41,
        .b = 55,
        .a = 255,
    });
    try std.testing.expectEqual(@as(u8, 230), red.r);
    try std.testing.expectEqual(@as(u8, 41), red.g);
    try std.testing.expectEqual(@as(u8, 55), red.b);
    try std.testing.expectEqual(@as(u8, 255), red.a);
}

fn toVector2(point: anytype) rl.Vector2 {
    return .{ .x = point.x, .y = point.y };
}

fn rectFromArgs(args: anytype) rl.Rectangle {
    return .{ .x = args.x, .y = args.y, .width = args.width, .height = args.height };
}

fn cameraFromArgs(args: anytype) rl.Camera2D {
    return .{
        .target = toVector2(args.target),
        .offset = toVector2(args.offset),
        .rotation = args.rotation,
        .zoom = args.zoom,
    };
}

fn positiveThickness(thickness: f32) ?f32 {
    if (thickness <= 0) return null;
    return thickness;
}

fn positiveSegments(segments: i32) c_int {
    return if (segments < 4) 8 else @intCast(segments);
}

fn absF32(value: f32) f32 {
    return if (value < 0) -value else value;
}

fn roundedness(width: f32, height: f32, radius: f32) f32 {
    if (radius <= 0) return 0;
    const min_dim = @min(absF32(width), absF32(height));
    if (min_dim <= 0) return 0;
    return @min(1, radius / min_dim);
}

fn drawSegment(start: anytype, end: anytype, thickness: f32, color: Color) void {
    const thick = positiveThickness(thickness) orelse return;
    rl.DrawLineEx(toVector2(start), toVector2(end), thick, colorToRl(color));
}

/// Draw a circle from abi args.
pub fn drawCircle(args: anytype) void {
    rl.DrawCircle(
        @intFromFloat(args.center.x),
        @intFromFloat(args.center.y),
        args.radius,
        colorToRl(args.color),
    );
}

/// Draw a thick circle outline from abi args.
pub fn drawCircleLines(args: anytype) void {
    const thick = positiveThickness(args.thickness) orelse return;
    const half = thick * 0.5;
    const inner_radius = @max(0, args.radius - half);
    const outer_radius = args.radius + half;

    rl.DrawRing(
        toVector2(args.center),
        inner_radius,
        outer_radius,
        0,
        360,
        64,
        colorToRl(args.color),
    );
}

/// Draw a rectangle from abi args.
pub fn drawRectangle(args: anytype) void {
    rl.DrawRectangle(
        @intFromFloat(args.x),
        @intFromFloat(args.y),
        @intFromFloat(args.width),
        @intFromFloat(args.height),
        colorToRl(args.color),
    );
}

/// Draw a rectangle outline from abi args.
pub fn drawRectangleLines(args: anytype) void {
    const thick = positiveThickness(args.thickness) orelse return;
    rl.DrawRectangleLinesEx(rectFromArgs(args), thick, colorToRl(args.color));
}

/// Draw a rounded rectangle from abi args.
pub fn drawRoundedRectangle(args: anytype) void {
    rl.DrawRectangleRounded(
        rectFromArgs(args),
        roundedness(args.width, args.height, args.radius),
        positiveSegments(args.segments),
        colorToRl(args.color),
    );
}

/// Draw a rounded rectangle outline from abi args.
pub fn drawRoundedRectangleLines(args: anytype) void {
    const thick = positiveThickness(args.thickness) orelse return;
    rl.DrawRectangleRoundedLinesEx(
        rectFromArgs(args),
        roundedness(args.width, args.height, args.radius),
        positiveSegments(args.segments),
        thick,
        colorToRl(args.color),
    );
}

/// Draw a line from abi args.
pub fn drawLine(args: anytype) void {
    drawSegment(args.start, args.end, args.thickness, args.color);
}

/// Draw a triangle from abi args.
pub fn drawTriangle(args: anytype) void {
    rl.DrawTriangle(toVector2(args.a), toVector2(args.b), toVector2(args.c), colorToRl(args.color));
}

/// Draw a triangle outline from abi args.
pub fn drawTriangleLines(args: anytype) void {
    drawSegment(args.a, args.b, args.thickness, args.color);
    drawSegment(args.b, args.c, args.thickness, args.color);
    drawSegment(args.c, args.a, args.thickness, args.color);
}

fn polygonSignedArea(points: anytype) f32 {
    var twice_area: f32 = 0;
    for (points, 0..) |point, i| {
        const next = points[(i + 1) % points.len];
        twice_area += point.x * next.y - next.x * point.y;
    }
    return twice_area * 0.5;
}

test "polygonSignedArea detects either boundary order" {
    const Point = struct { x: f32, y: f32 };
    const clockwise = [_]Point{
        .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 0 },
    };
    const counter_clockwise = [_]Point{
        .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 2 }, .{ .x = 0, .y = 2 },
    };
    try std.testing.expect(polygonSignedArea(&clockwise) < 0);
    try std.testing.expect(polygonSignedArea(&counter_clockwise) > 0);
}

/// Draw a filled convex polygon as an allocation-free triangle fan.
/// Points must be ordered clockwise or counter-clockwise around the boundary.
pub fn drawPolygon(points: anytype, color: Color) void {
    if (points.len < 3) return;

    const reverse = polygonSignedArea(points) > 0;
    var i: usize = 1;
    while (i + 1 < points.len) : (i += 1) {
        if (reverse) {
            rl.DrawTriangle(toVector2(points[0]), toVector2(points[i + 1]), toVector2(points[i]), colorToRl(color));
        } else {
            rl.DrawTriangle(toVector2(points[0]), toVector2(points[i]), toVector2(points[i + 1]), colorToRl(color));
        }
    }
}

/// Draw a polygon outline from abi args.
pub fn drawPolygonLines(points: anytype, thickness: f32, color: Color) void {
    if (points.len < 2) return;
    const thick = positiveThickness(thickness) orelse return;

    if (points.len == 2) {
        drawSegment(points[0], points[1], thick, color);
        return;
    }

    for (points, 0..) |point, i| {
        const next = points[(i + 1) % points.len];
        drawSegment(point, next, thick, color);
    }
}

/// Draw text with a null-terminated string.
pub fn drawTextZ(text: [*:0]const u8, font: Font, pos: rl.Vector2, size: f32, spacing: f32, color: Color) void {
    rl.DrawTextEx(font, text, pos, size, spacing, colorToRl(color));
}

/// Draw a texture region into a destination rectangle.
pub fn drawTexture(texture: Texture, args: anytype) void {
    rl.DrawTexturePro(
        texture,
        rectFromArgs(args.source),
        rectFromArgs(args.dest),
        toVector2(args.origin),
        args.rotation,
        colorToRl(args.tint),
    );
}

/// Draw one texture once per borrowed instance, in list order.
///
/// The batching this buys is on the Roc side, not the GPU side: a per-sprite
/// `texture!` pays one hosted-effect crossing per sprite, and that crossing --
/// not `DrawTexturePro` -- is what caps instance counts. `DrawTexturePro` only
/// appends vertices to rlgl's active batch, which is flushed in bulk, so a
/// plain loop over the whole list already amortizes well.
///
/// The loop is deliberately shaped as "take the shared value once, take a
/// borrowed slice of per-instance fields, iterate": a future shape-instance
/// batch (rectangles, circles, or lines for plotting) can follow it by
/// swapping the shared texture for a shared style and the element accessor
/// for its own, with no other structure to reproduce.
pub fn drawTextureInstances(texture: Texture, instances: anytype) void {
    for (instances) |instance| drawTexture(texture, instance);
}

fn textureRegionUv(texture: Texture, x: f32, y: f32) rl.Vector2 {
    return .{
        .x = x / @as(f32, @floatFromInt(texture.width)),
        .y = y / @as(f32, @floatFromInt(texture.height)),
    };
}

test "textureRegionUv normalizes source pixels" {
    const texture = Texture{ .id = 1, .width = 64, .height = 32, .mipmaps = 1, .format = 1 };
    const uv = textureRegionUv(texture, 16, 24);
    try std.testing.expectEqual(@as(f32, 0.25), uv.x);
    try std.testing.expectEqual(@as(f32, 0.75), uv.y);
}

fn projectiveModelview(modelview: rl.Matrix) rl.Matrix {
    return .{
        .m0 = modelview.m0,
        .m1 = modelview.m1,
        .m2 = modelview.m2,
        .m3 = modelview.m3,
        .m4 = modelview.m4,
        .m5 = modelview.m5,
        .m6 = modelview.m6,
        .m7 = modelview.m7,
        .m8 = modelview.m12,
        .m9 = modelview.m13,
        .m10 = modelview.m14,
        .m11 = modelview.m15,
        .m12 = 0,
        .m13 = 0,
        .m14 = 0,
        .m15 = 0,
    };
}

fn textureQuadIsProjective(weights: [4]f32) bool {
    return weights[0] != weights[1] or weights[0] != weights[2] or weights[0] != weights[3];
}

test "projective modelview scales the complete transformed position by q" {
    const modelview = rl.Matrix{
        .m0 = 2,
        .m1 = 0,
        .m2 = 0,
        .m3 = 0,
        .m4 = 0,
        .m5 = 3,
        .m6 = 0,
        .m7 = 0,
        .m8 = 0,
        .m9 = 0,
        .m10 = 1,
        .m11 = 0,
        .m12 = 5,
        .m13 = -7,
        .m14 = 0,
        .m15 = 1,
    };
    const projective = projectiveModelview(modelview);
    const x: f32 = 11;
    const y: f32 = 13;
    const q: f32 = 0.4;

    const transformed_x = projective.m0 * (x * q) + projective.m4 * (y * q) + projective.m8 * q + projective.m12;
    const transformed_y = projective.m1 * (x * q) + projective.m5 * (y * q) + projective.m9 * q + projective.m13;
    const transformed_w = projective.m3 * (x * q) + projective.m7 * (y * q) + projective.m11 * q + projective.m15;

    try std.testing.expectApproxEqAbs(q * (2 * x + 5), transformed_x, 0.0001);
    try std.testing.expectApproxEqAbs(q * (3 * y - 7), transformed_y, 0.0001);
    try std.testing.expectApproxEqAbs(q, transformed_w, 0.0001);
}

test "equal quad weights retain the batched affine fast path" {
    try std.testing.expect(!textureQuadIsProjective(.{ 1, 1, 1, 1 }));
    try std.testing.expect(textureQuadIsProjective(.{ 1, 0.75, 0.5, 0.8 }));
}

/// Draw a texture source region across a validated planar projection.
pub fn drawTextureQuad(texture: Texture, args: anytype) void {
    const tint = colorToRl(args.tint);
    if (texture.width <= 0 or texture.height <= 0) return;
    const uv_top_left = textureRegionUv(texture, args.source.x, args.source.y);
    const uv_bottom_left = textureRegionUv(texture, args.source.x, args.source.y + args.source.height);
    const uv_bottom_right = textureRegionUv(texture, args.source.x + args.source.width, args.source.y + args.source.height);
    const uv_top_right = textureRegionUv(texture, args.source.x + args.source.width, args.source.y);

    const uvs = [_]rl.Vector2{ uv_top_left, uv_bottom_left, uv_bottom_right, uv_top_right };
    const vertices = [_]rl.Vector2{
        toVector2(args.top_left),
        toVector2(args.bottom_left),
        toVector2(args.bottom_right),
        toVector2(args.top_right),
    };
    const weights = [_]f32{
        args.q_top_left,
        args.q_bottom_left,
        args.q_bottom_right,
        args.q_top_right,
    };
    // Horizontal/vertical Tiled flips can reverse the destination winding.
    // Reverse vertex/UV pairs together so raylib's back-face culling still
    // accepts the quad without changing global rlgl state for every tile.
    const cross = (vertices[1].x - vertices[0].x) * (vertices[2].y - vertices[0].y) -
        (vertices[1].y - vertices[0].y) * (vertices[2].x - vertices[0].x);
    const order = if (cross > 0)
        [_]usize{ 3, 2, 1, 0 }
    else
        [_]usize{ 0, 1, 2, 3 };

    const projective = textureQuadIsProjective(weights);
    const saved_modelview = if (projective) rl.rlGetMatrixModelview() else undefined;
    if (projective) {
        // Earlier batched vertices must use the matrix active when they were
        // submitted. Flush this quad before restoring that matrix as well.
        rl.rlDrawRenderBatchActive();
        rl.rlSetMatrixModelview(projectiveModelview(saved_modelview));
    }

    rl.rlSetTexture(texture.id);
    rl.rlBegin(rl.RL_QUADS);
    rl.rlColor4ub(tint.r, tint.g, tint.b, tint.a);
    for (order) |i| {
        rl.rlTexCoord2f(uvs[i].x, uvs[i].y);
        if (projective) {
            const q = weights[i];
            rl.rlVertex3f(vertices[i].x * q, vertices[i].y * q, q);
        } else {
            rl.rlVertex2f(vertices[i].x, vertices[i].y);
        }
    }
    rl.rlEnd();
    if (projective) {
        rl.rlDrawRenderBatchActive();
        rl.rlSetMatrixModelview(saved_modelview);
    } else {
        rl.rlSetTexture(0);
    }
}

/// Measure text with a null-terminated string.
pub fn measureTextZ(text: [*:0]const u8, font: Font, size: f32, spacing: f32) rl.Vector2 {
    return rl.MeasureTextEx(font, text, size, spacing);
}

/// Draw a rectangle with vertical gradient from abi args.
pub fn drawRectangleGradientV(args: anytype) void {
    rl.DrawRectangleGradientV(
        @intFromFloat(args.x),
        @intFromFloat(args.y),
        @intFromFloat(args.width),
        @intFromFloat(args.height),
        colorToRl(args.color_top),
        colorToRl(args.color_bottom),
    );
}

/// Draw a rectangle with horizontal gradient from abi args.
pub fn drawRectangleGradientH(args: anytype) void {
    rl.DrawRectangleGradientH(
        @intFromFloat(args.x),
        @intFromFloat(args.y),
        @intFromFloat(args.width),
        @intFromFloat(args.height),
        colorToRl(args.color_left),
        colorToRl(args.color_right),
    );
}

/// Draw a circle with radial gradient from abi args.
pub fn drawCircleGradient(args: anytype) void {
    rl.DrawCircleGradient(
        toVector2(args.center),
        args.radius,
        colorToRl(args.color_inner),
        colorToRl(args.color_outer),
    );
}

/// Draw FPS counter at specified position.
pub fn drawFps(args: anytype) void {
    var buf: [32:0]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "FPS: {d}", .{rl.GetFPS()}) catch return;
    rl.DrawTextEx(defaultFont(), text.ptr, toVector2(args.pos), args.size, 1, colorToRl(args.color));
}

/// Begin drawing frame.
pub fn beginDrawing() void {
    rl.BeginDrawing();
}

/// Begin clipping subsequent draw calls to screen-space bounds.
pub fn beginScissor(x: f32, y: f32, width: f32, height: f32) void {
    rl.BeginScissorMode(
        @intFromFloat(x),
        @intFromFloat(y),
        @intFromFloat(width),
        @intFromFloat(height),
    );
}

/// End the active screen-space clipping region.
pub fn endScissor() void {
    rl.EndScissorMode();
}

/// Begin drawing in 2D camera mode.
///
/// raylib 6.0 carries the HiDPI content scale (render size / screen size) in
/// the modelview matrix: `BeginDrawing` and `EndMode2D` multiply it in, but
/// `BeginMode2D` resets the modelview to the camera alone (upstream #3746
/// dropped it when macOS still scaled through the viewport). On a Retina Mac
/// the camera section of a frame therefore lands at half size in the top-left
/// quarter of the window while everything outside the camera is correct. Apply
/// the same scale raylib applies elsewhere; it is the identity on ordinary
/// displays, and is skipped inside a render texture like raylib does.
pub fn beginMode2D(camera: anytype) void {
    const cam = cameraFromArgs(camera);
    rl.BeginMode2D(cam);
    if (rl.rlGetActiveFramebuffer() != 0) return;
    const screen_w: f32 = @floatFromInt(rl.GetScreenWidth());
    const screen_h: f32 = @floatFromInt(rl.GetScreenHeight());
    if (screen_w <= 0 or screen_h <= 0) return;
    const sx = @as(f32, @floatFromInt(rl.GetRenderWidth())) / screen_w;
    const sy = @as(f32, @floatFromInt(rl.GetRenderHeight())) / screen_h;
    if (sx == 1 and sy == 1) return;
    const scale = [16]f32{
        sx, 0,  0, 0,
        0,  sy, 0, 0,
        0,  0,  1, 0,
        0,  0,  0, 1,
    };
    // `rlMultMatrixf` pre-multiplies, so load the scale first and the camera
    // on top of it: points go through the camera, then the content scale.
    rl.rlLoadIdentity();
    rl.rlMultMatrixf(&scale);
    const m = rl.GetCameraMatrix2D(cam);
    const cam_mat = [16]f32{
        m.m0,  m.m1,  m.m2,  m.m3,
        m.m4,  m.m5,  m.m6,  m.m7,
        m.m8,  m.m9,  m.m10, m.m11,
        m.m12, m.m13, m.m14, m.m15,
    };
    rl.rlMultMatrixf(&cam_mat);
}

/// End drawing in 2D camera mode.
pub fn endMode2D() void {
    rl.EndMode2D();
}

/// Redirect subsequent draws to an offscreen framebuffer.
pub fn beginTextureMode(target: RenderTexture) void {
    rl.BeginTextureMode(target);
}

/// Restore drawing to the previous framebuffer.
pub fn endTextureMode() void {
    rl.EndTextureMode();
}

/// Apply a custom shader to subsequent draw calls.
pub fn beginShaderMode(shader: Shader) void {
    rl.BeginShaderMode(shader);
}

/// Restore raylib's default shader.
pub fn endShaderMode() void {
    rl.EndShaderMode();
}

/// Apply one of raylib's built-in blend equations.
pub fn beginBlendMode(mode: c_int) void {
    rl.BeginBlendMode(mode);
}

/// Restore normal alpha blending.
pub fn endBlendMode() void {
    rl.EndBlendMode();
}

/// End drawing frame.
pub fn endDrawing() void {
    rl.EndDrawing();
}

/// Clear the background with a color.
pub fn clearBackground(color: anytype) void {
    rl.ClearBackground(colorToRl(color));
}

/// Initialize a window.
pub fn initWindow(width: c_int, height: c_int, title: [*:0]const u8) void {
    rl.InitWindow(width, height, title);
}

/// Set flags that must be configured before InitWindow.
pub fn setConfigFlags(flags: c_uint) void {
    rl.SetConfigFlags(flags);
}

/// Build raylib window config flags from Roc app config booleans.
pub fn windowConfigFlags(resizable: bool, fullscreen: bool, vsync: bool, visible: bool) c_uint {
    var flags: c_uint = @as(c_uint, @intCast(rl.FLAG_WINDOW_HIGHDPI));
    if (resizable) flags |= @as(c_uint, @intCast(rl.FLAG_WINDOW_RESIZABLE));
    if (fullscreen) flags |= @as(c_uint, @intCast(rl.FLAG_FULLSCREEN_MODE));
    if (vsync) flags |= @as(c_uint, @intCast(rl.FLAG_VSYNC_HINT));
    // A hidden window still renders on the GPU, so captures work normally.
    // This is not the same as the `--host-headless` stub backend, which draws
    // nothing at all, and it still needs a display server (use xvfb-run on a
    // machine without one).
    if (!visible) flags |= @as(c_uint, @intCast(rl.FLAG_WINDOW_HIDDEN));
    return flags;
}

/// Close the window. The input callbacks chained on it go with it.
pub fn closeWindow() void {
    forgetInputEventCallbacks();
    rl.CloseWindow();
}

/// Check if window should close.
pub fn windowShouldClose() bool {
    return rl.WindowShouldClose();
}

/// Set target FPS.
pub fn setTargetFps(fps: c_int) void {
    rl.SetTargetFPS(fps);
}

/// Mouse cursor shapes exposed by raylib.
pub const MouseCursor = enum(c_int) {
    default = 0,
    arrow = 1,
    ibeam = 2,
    crosshair = 3,
    pointing_hand = 4,
    resize_ew = 5,
    resize_ns = 6,
    resize_nwse = 7,
    resize_nesw = 8,
    resize_all = 9,
    not_allowed = 10,
};

/// Set the OS cursor shape.
pub fn setMouseCursor(cursor: MouseCursor) void {
    rl.SetMouseCursor(@intFromEnum(cursor));
}

/// Show the OS cursor.
pub fn showCursor() void {
    rl.ShowCursor();
}

/// Hide the OS cursor.
pub fn hideCursor() void {
    rl.HideCursor();
}

/// Lock and hide the OS cursor.
pub fn disableCursor() void {
    rl.DisableCursor();
}

/// Unlock the OS cursor and make it visible.
pub fn enableCursor() void {
    rl.EnableCursor();
}

/// Suggest a window size to the native window manager.
///
/// The dimensions observed from the window afterward are authoritative.
pub fn suggestWindowSize(width: c_int, height: c_int) void {
    rl.SetWindowSize(width, height);
}

/// Suggest the smallest size to which the window manager should resize.
/// raylib maps 0 to GLFW_DONT_CARE, leaving that axis unconstrained. Requires
/// a live window, and only binds where a resizable-window backend honors it.
pub fn suggestWindowMinSize(width: c_int, height: c_int) void {
    rl.SetWindowMinSize(width, height);
}

/// Set the key that closes the window, or raylib's KEY_NULL (0) to disable it.
/// InitWindow resets this to KEY_ESCAPE, so this must be called after it.
pub fn setExitKey(key: c_int) void {
    rl.SetExitKey(key);
}

/// Suggest where the window's top-left corner sits, in virtual-desktop pixels.
///
/// The window manager may adjust or ignore the request; the position observed
/// from the window afterward is authoritative.
pub fn suggestWindowPosition(x: c_int, y: c_int) void {
    rl.SetWindowPosition(x, y);
}

/// Suggest that the window move to a monitor index.
///
/// raylib bounds-checks the index itself and logs a warning for one outside the
/// connected set, leaving the window where it is.
pub fn suggestWindowMonitor(monitor: c_int) void {
    rl.SetWindowMonitor(monitor);
}

/// The framebuffer-to-logical scale of the window, one factor per axis.
///
/// `1` without `FLAG_WINDOW_HIGHDPI` or on an ordinary display, and the
/// display's scale factor with it -- so the framebuffer this reports is the
/// resolution a capture reads back at.
pub fn getWindowScaleDpi() Vec2 {
    const scale = rl.GetWindowScaleDPI();
    return .{ .x = scale.x, .y = scale.y };
}

/// How many monitors the windowing backend can currently see.
pub fn getMonitorCount() c_int {
    return rl.GetMonitorCount();
}

/// Width of a monitor's current video mode, in pixels.
pub fn getMonitorWidth(monitor: c_int) c_int {
    return rl.GetMonitorWidth(monitor);
}

/// Height of a monitor's current video mode, in pixels.
pub fn getMonitorHeight(monitor: c_int) c_int {
    return rl.GetMonitorHeight(monitor);
}

/// A monitor's top-left corner in virtual-desktop coordinates.
pub fn getMonitorPosition(monitor: c_int) Vec2 {
    const position = rl.GetMonitorPosition(monitor);
    return .{ .x = position.x, .y = position.y };
}

/// Refresh rate of a monitor's current video mode, in hertz.
pub fn getMonitorRefreshRate(monitor: c_int) c_int {
    return rl.GetMonitorRefreshRate(monitor);
}

/// A monitor's human-readable name, owned by the windowing backend.
///
/// Never free it, and copy it before the next backend call: the pointer is null
/// for an index outside the connected set.
pub fn getMonitorName(monitor: c_int) ?[*:0]const u8 {
    const name = rl.GetMonitorName(monitor);
    if (name == null) return null;
    return @ptrCast(name);
}

/// Read UTF-8 text from the system clipboard.
///
/// The returned pointer is owned by the windowing backend: never free it, and
/// copy it before the next clipboard call invalidates it. Returns null when the
/// clipboard is empty or holds non-text content. Requires a live window.
pub fn getClipboardText() ?[*:0]const u8 {
    const text = rl.GetClipboardText();
    if (text == null) return null;
    return @ptrCast(text);
}

/// Replace the system clipboard contents. raylib copies the string, so the
/// caller keeps ownership. Requires a live window.
pub fn setClipboardText(text: [*:0]const u8) void {
    rl.SetClipboardText(text);
}

/// Get frame time (delta time) in seconds since the previous frame.
pub fn getFrameTime() f32 {
    return rl.GetFrameTime();
}

/// Get elapsed time in seconds since the window was initialized (monotonic).
pub fn getTime() f64 {
    return rl.GetTime();
}

/// Seed raylib's random number generator.
pub fn setRandomSeed(seed: u32) void {
    rl.SetRandomSeed(seed);
}

/// Get a random value in the range [min, max] (both endpoints included).
pub fn getRandomValue(min: c_int, max: c_int) c_int {
    return rl.GetRandomValue(min, max);
}

// --- Audio ---------------------------------------------------------------

const AUDIO_SAMPLE_RATE: u32 = 44100;
const MAX_GEN_SOUND_MS: i32 = 5000;
/// Scratch buffer for procedural generation (mono 16-bit).
var gen_sound_buf: [AUDIO_SAMPLE_RATE * @as(usize, @intCast(MAX_GEN_SOUND_MS)) / 1000]i16 = undefined;

/// Initialize the audio device (call once, after the window exists).
pub fn initAudioDevice() void {
    rl.InitAudioDevice();
}

/// Close the audio device after all host resource heaps have been drained.
pub fn closeAudioDevice() void {
    rl.CloseAudioDevice();
}

/// Unload a native sound when its host resource slot is released.
pub fn unloadSound(sound: Sound) void {
    rl.UnloadSound(sound);
}

/// Unload a native music stream when its host resource slot is released.
pub fn unloadMusic(music: Music) void {
    rl.UnloadMusicStream(music);
}

fn clampF32(value: f32, min: f32, max: f32) f32 {
    return if (value < min) min else if (value > max) max else value;
}

fn clampI32(value: i32, min: i32, max: i32) i32 {
    return if (value < min) min else if (value > max) max else value;
}

fn msToFrames(ms: i32) usize {
    const clamped = if (ms <= 0) 0 else ms;
    return @intCast(@divTrunc(@as(i64, AUDIO_SAMPLE_RATE) * clamped, 1000));
}

fn envelopeAt(frame: usize, frames: usize, attack: usize, decay: usize, sustain_in: f32, release: usize) f32 {
    if (frames == 0) return 0;

    const sustain = clampF32(sustain_in, 0.0, 1.0);
    const frame_f: f32 = @floatFromInt(frame);

    if (attack > 0 and frame < attack) {
        return frame_f / @as(f32, @floatFromInt(attack));
    }

    if (decay > 0 and frame < attack + decay) {
        const amount = (frame_f - @as(f32, @floatFromInt(attack))) / @as(f32, @floatFromInt(decay));
        return 1.0 + (sustain - 1.0) * clampF32(amount, 0.0, 1.0);
    }

    if (release > 0) {
        const release_start = if (release >= frames) 0 else frames - release;
        if (frame >= release_start) {
            const tail = frames - frame;
            return sustain * (@as(f32, @floatFromInt(tail)) / @as(f32, @floatFromInt(release)));
        }
    }

    return sustain;
}

fn waveformSample(waveform: u8, phase: f32, random_state: *u32) f32 {
    return switch (waveform) {
        1 => if (phase < 0.5) 1.0 else -1.0,
        2 => 1.0 - 4.0 * absF32(phase - 0.5),
        3 => phase * 2.0 - 1.0,
        4 => blk: {
            random_state.* = random_state.* *% 1664525 +% 1013904223;
            const raw: f32 = @floatFromInt(random_state.* >> 8);
            break :blk raw / 16777215.0 * 2.0 - 1.0;
        },
        else => std.math.sin(2.0 * std.math.pi * phase),
    };
}

/// Load a sound effect from encoded file bytes the host already read.
///
/// The wave is decoded, uploaded to the audio device, and released again:
/// `LoadSoundFromWave` copies the samples into its own buffer, so neither the
/// wave nor the encoded bytes have to outlive this call.
pub fn loadSoundFromMemory(file_type: [*:0]const u8, bytes: []const u8) ?Sound {
    const wave = rl.LoadWaveFromMemory(file_type, bytes.ptr, @intCast(bytes.len));
    if (!rl.IsWaveValid(wave)) return null;
    defer rl.UnloadWave(wave);
    const sound = rl.LoadSoundFromWave(wave);
    if (!rl.IsSoundValid(sound)) return null;
    return sound;
}

/// Generate a short procedural sound.
pub fn genSound(args: anytype) ?Sound {
    const dur_ms = clampI32(args.ms, 1, MAX_GEN_SOUND_MS);
    const frames = msToFrames(dur_ms);
    if (frames == 0 or frames > gen_sound_buf.len) return null;

    const attack = msToFrames(args.attack_ms);
    const decay = msToFrames(args.decay_ms);
    const release = msToFrames(args.release_ms);
    const volume = clampF32(args.volume, 0.0, 1.0);

    var phase: f32 = 0.0;
    var random_state: u32 = 0x9e3779b9 ^ @as(u32, @bitCast(args.freq_start));
    const sample_rate: f32 = @floatFromInt(AUDIO_SAMPLE_RATE);
    const frames_f: f32 = @floatFromInt(frames);

    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const amount = @as(f32, @floatFromInt(i)) / frames_f;
        const freq = @max(1.0, args.freq_start + (args.freq_end - args.freq_start) * amount);
        phase += freq / sample_rate;
        phase -= @floor(phase);

        const env = envelopeAt(i, frames, attack, decay, args.sustain, release);
        const sample = waveformSample(args.waveform, phase, &random_state) * env * volume;
        gen_sound_buf[i] = @intFromFloat(clampF32(sample, -1.0, 1.0) * 32767.0);
    }

    const wave = rl.Wave{
        .frameCount = @intCast(frames),
        .sampleRate = AUDIO_SAMPLE_RATE,
        .sampleSize = 16,
        .channels = 1,
        .data = @ptrCast(&gen_sound_buf),
    };

    const sound = rl.LoadSoundFromWave(wave);
    if (!rl.IsSoundValid(sound)) return null;
    return sound;
}

/// Generate a short sine tone.
pub fn genTone(freq: f32, ms: i32) ?Sound {
    return genSound(.{
        .waveform = @as(u8, 0),
        .freq_start = freq,
        .freq_end = freq,
        .ms = ms,
        .attack_ms = 5,
        .decay_ms = 12,
        .sustain = 0.8,
        .release_ms = 8,
        .volume = 0.55,
    });
}

/// Play a native sound.
pub fn playSound(sound: Sound) void {
    rl.PlaySound(sound);
}

/// Stop a native sound and rewind it.
pub fn stopSound(sound: Sound) void {
    rl.StopSound(sound);
}

/// Pause a native sound.
pub fn pauseSound(sound: Sound) void {
    rl.PauseSound(sound);
}

/// Resume a paused native sound.
pub fn resumeSound(sound: Sound) void {
    rl.ResumeSound(sound);
}

/// Check whether a native sound is currently playing.
pub fn isSoundPlaying(sound: Sound) bool {
    return rl.IsSoundPlaying(sound);
}

/// Set a native sound's volume.
pub fn setSoundVolume(sound: Sound, volume: f32) void {
    rl.SetSoundVolume(sound, clampF32(volume, 0.0, 1.0));
}

/// Set a native sound's pitch.
pub fn setSoundPitch(sound: Sound, pitch: f32) void {
    rl.SetSoundPitch(sound, clampF32(pitch, 0.05, 8.0));
}

/// Set a native sound's stereo pan.
pub fn setSoundPan(sound: Sound, pan: f32) void {
    rl.SetSoundPan(sound, clampF32(pan, -1.0, 1.0));
}

/// Load a music stream from encoded file bytes the host already read.
///
/// raylib's memory decoders keep a pointer into `bytes` and read from it as
/// the stream plays, so the caller owns those bytes for the stream's whole
/// life and must not free them until after `unloadMusic`.
pub fn loadMusicFromMemory(file_type: [*:0]const u8, bytes: []const u8) ?Music {
    var stream = rl.LoadMusicStreamFromMemory(file_type, bytes.ptr, @intCast(bytes.len));
    if (!rl.IsMusicValid(stream)) return null;
    stream.looping = true;
    return stream;
}

/// Advance one native music stream.
pub fn updateMusicStream(stream: *Music) void {
    rl.UpdateMusicStream(stream.*);
}

/// Start a native music stream.
pub fn playMusic(stream: Music) void {
    rl.PlayMusicStream(stream);
}

/// Stop a native music stream.
pub fn stopMusic(stream: Music) void {
    rl.StopMusicStream(stream);
}

/// Pause a native music stream.
pub fn pauseMusic(stream: Music) void {
    rl.PauseMusicStream(stream);
}

/// Resume a native music stream.
pub fn resumeMusic(stream: Music) void {
    rl.ResumeMusicStream(stream);
}

/// Set a native music stream's volume.
pub fn setMusicVolume(stream: Music, volume: f32) void {
    rl.SetMusicVolume(stream, clampF32(volume, 0.0, 1.0));
}

/// Set a native music stream's pitch.
pub fn setMusicPitch(stream: Music, pitch: f32) void {
    rl.SetMusicPitch(stream, clampF32(pitch, 0.05, 8.0));
}

/// Set a native music stream's stereo pan.
pub fn setMusicPan(stream: Music, pan: f32) void {
    rl.SetMusicPan(stream, clampF32(pan, -1.0, 1.0));
}

/// Enable or disable looping on a native music stream.
pub fn setMusicLooping(stream: *Music, looping: bool) void {
    stream.looping = looping;
}

/// Check whether a native music stream is currently playing.
pub fn isMusicPlaying(stream: Music) bool {
    return rl.IsMusicStreamPlaying(stream);
}

/// Seek a native music stream to a position in seconds.
pub fn seekMusic(stream: Music, seconds: f32) void {
    rl.SeekMusicStream(stream, @max(0, seconds));
}

/// Return a native music stream's duration in seconds.
pub fn musicLength(stream: Music) f32 {
    return rl.GetMusicTimeLength(stream);
}

/// Return a native music stream's current playback position in seconds.
pub fn musicTimePlayed(stream: Music) f32 {
    return rl.GetMusicTimePlayed(stream);
}

/// Set global audio output volume.
pub fn setMasterVolume(volume: f32) void {
    rl.SetMasterVolume(clampF32(volume, 0, 1));
}

/// Keyboard key enum for type-safe key handling.
pub const Key = enum(c_int) {
    space = rl.KEY_SPACE,
    q = rl.KEY_Q,
    f = rl.KEY_F,
    left = rl.KEY_LEFT,
    right = rl.KEY_RIGHT,
    up = rl.KEY_UP,
    down = rl.KEY_DOWN,
    home = rl.KEY_HOME,
    end = rl.KEY_END,
};

/// Check if a key was pressed (not held).
pub fn isKeyPressed(key: Key) bool {
    return rl.IsKeyPressed(@intFromEnum(key));
}

/// Check if a key is currently held down.
pub fn isKeyDown(key: Key) bool {
    return rl.IsKeyDown(@intFromEnum(key));
}

/// Mouse button enum for type-safe button handling.
pub const MouseButton = enum(c_int) {
    left = rl.MOUSE_BUTTON_LEFT,
    right = rl.MOUSE_BUTTON_RIGHT,
    middle = rl.MOUSE_BUTTON_MIDDLE,
    side = rl.MOUSE_BUTTON_SIDE,
    extra = rl.MOUSE_BUTTON_EXTRA,
    forward = rl.MOUSE_BUTTON_FORWARD,
    back = rl.MOUSE_BUTTON_BACK,
};

/// Simple 2D vector for mouse position.
pub const Vec2 = struct { x: f32, y: f32 };

/// Get mouse position.
pub fn getMousePosition() Vec2 {
    const pos = rl.GetMousePosition();
    return .{ .x = pos.x, .y = pos.y };
}

/// Get mouse movement since the previous frame.
pub fn getMouseDelta() Vec2 {
    const delta = rl.GetMouseDelta();
    return .{ .x = delta.x, .y = delta.y };
}

/// Check if a mouse button is down.
pub fn isMouseButtonDown(button: MouseButton) bool {
    return rl.IsMouseButtonDown(@intFromEnum(button));
}

/// Check if a mouse button was pressed.
pub fn isMouseButtonPressed(button: MouseButton) bool {
    return rl.IsMouseButtonPressed(@intFromEnum(button));
}

/// Check if a mouse button was released.
pub fn isMouseButtonReleased(button: MouseButton) bool {
    return rl.IsMouseButtonReleased(@intFromEnum(button));
}

/// Get mouse wheel movement.
pub fn getMouseWheelMove() f32 {
    return rl.GetMouseWheelMove();
}

/// Get horizontal and vertical mouse wheel movement.
pub fn getMouseWheelMoveV() Vec2 {
    const movement = rl.GetMouseWheelMoveV();
    return .{ .x = movement.x, .y = movement.y };
}

/// Get screen width.
pub fn getScreenWidth() c_int {
    return rl.GetScreenWidth();
}

/// Get screen height.
pub fn getScreenHeight() c_int {
    return rl.GetScreenHeight();
}

/// Whether the window currently has keyboard input focus.
pub fn isWindowFocused() bool {
    return rl.IsWindowFocused();
}

/// Whether the window is currently minimized.
pub fn isWindowMinimized() bool {
    return rl.IsWindowMinimized();
}

/// Get framebuffer width in pixels, which exceeds the screen width on HiDPI.
pub fn getRenderWidth() c_int {
    return rl.GetRenderWidth();
}

/// Get framebuffer height in pixels, which exceeds the screen height on HiDPI.
pub fn getRenderHeight() c_int {
    return rl.GetRenderHeight();
}

/// A CPU-side RGBA8 readback of the framebuffer, owned by raylib's allocator.
///
/// Every raylib allocation for a capture stays behind this type so the rest of
/// the host never has to reason about `UnloadImage` pairing.
pub const CaptureImage = struct {
    image: rl.Image,

    /// Tightly packed top-down RGBA8 pixels, four bytes each.
    pub fn pixels(self: CaptureImage) []u8 {
        const count = @as(usize, @intCast(self.image.width)) *
            @as(usize, @intCast(self.image.height)) * 4;
        const bytes: [*]u8 = @ptrCast(self.image.data);
        return bytes[0..count];
    }

    /// Width in pixels.
    pub fn width(self: CaptureImage) u32 {
        return @intCast(self.image.width);
    }

    /// Height in pixels.
    pub fn height(self: CaptureImage) u32 {
        return @intCast(self.image.height);
    }

    /// Rescale in place with bicubic filtering, reallocating the pixel buffer.
    pub fn resize(self: *CaptureImage, new_width: u32, new_height: u32) void {
        if (new_width == self.width() and new_height == self.height()) return;
        rl.ImageResize(&self.image, @intCast(new_width), @intCast(new_height));
    }

    /// Write this image as a PNG, returning false if the write failed.
    pub fn exportPng(self: CaptureImage, path: [*:0]const u8) bool {
        return rl.ExportImage(self.image, path);
    }

    /// Release the pixel buffer.
    pub fn deinit(self: CaptureImage) void {
        rl.UnloadImage(self.image);
    }
};

/// `GL_COLOR_BUFFER_BIT`, the only attachment a capture blit has to move.
///
/// `rlgl.h` exposes `RL_READ_FRAMEBUFFER` and `RL_DRAW_FRAMEBUFFER` but not the
/// blit masks, and the GL headers are raylib's own -- so the value is spelled
/// out here rather than reached for through a second OpenGL dependency.
const gl_color_buffer_bit: c_int = 0x00004000;

/// A reusable GPU pipeline that shrinks the framebuffer before it is read back.
///
/// `glReadPixels` cannot scale, so a `Half` or `Quarter` recording that reads
/// the framebuffer and resizes afterwards transfers, allocates, and filters 4x
/// or 16x more pixels than it keeps. This does the shrink on the GPU so the
/// readback is already the size of the finished frame, and reuses its render
/// targets for the whole recording instead of allocating per frame.
///
/// The frame is first blitted 1:1 into a render target, because the default
/// framebuffer is not a texture and cannot be sampled. raylib's blit is
/// hardcoded to `GL_NEAREST`, which at 1:1 is exact; the filtering all happens
/// in the halving steps that follow, where bilinear sampling averages 2x2
/// blocks. See `capture.planDownscale` for why the chain halves.
pub const CaptureDownscaler = struct {
    /// Render targets matching `capture.DownscalePlan.levels`, so `targets[0]`
    /// is framebuffer-sized and the last is the recording size.
    targets: [capture.max_downscale_levels]RenderTexture,
    count: usize,

    /// Build the render-target chain, or null if the GPU refused any of them.
    ///
    /// A partially built chain is torn down rather than returned, so a refusal
    /// never leaks the targets that did load.
    pub fn init(plan: capture.DownscalePlan) ?CaptureDownscaler {
        var self = CaptureDownscaler{
            .targets = undefined,
            .count = 0,
        };

        while (self.count < plan.count) {
            const extent = plan.levels[self.count];
            const target = rl.LoadRenderTexture(
                @intCast(extent.width),
                @intCast(extent.height),
            );
            if (!rl.IsRenderTextureValid(target)) {
                rl.UnloadRenderTexture(target);
                self.deinit();
                return null;
            }
            // Bilinear is what makes a halving step a 2x2 average instead of a
            // point sample, and clamping keeps the edge taps from wrapping
            // around to the opposite side of the frame.
            rl.SetTextureFilter(target.texture, rl.TEXTURE_FILTER_BILINEAR);
            rl.SetTextureWrap(target.texture, rl.TEXTURE_WRAP_CLAMP);
            self.targets[self.count] = target;
            self.count += 1;
        }
        return self;
    }

    /// Does this chain already produce exactly what `plan` asks for?
    ///
    /// Sizes are compared level by level rather than only end to end, so a
    /// window resize or a second recording at a different scale rebuilds
    /// instead of quietly encoding frames of the wrong dimensions.
    pub fn matches(self: CaptureDownscaler, plan: capture.DownscalePlan) bool {
        if (self.count != plan.count) return false;
        for (self.targets[0..self.count], plan.levels[0..plan.count]) |target, extent| {
            if (target.texture.width != @as(c_int, @intCast(extent.width))) return false;
            if (target.texture.height != @as(c_int, @intCast(extent.height))) return false;
        }
        return true;
    }

    /// Release every render target. Requires a live GL context.
    pub fn deinit(self: *CaptureDownscaler) void {
        for (self.targets[0..self.count]) |target| rl.UnloadRenderTexture(target);
        self.count = 0;
    }

    /// Shrink the current framebuffer through the chain and read the result.
    ///
    /// Carries the same ordering requirement as `captureFramebuffer`: the
    /// pending draw batch is flushed first, and this must run before
    /// `endDrawing` swaps the buffers away.
    pub fn readFrame(self: *CaptureDownscaler) ?CaptureImage {
        std.debug.assert(self.count >= 2);
        flushRenderBatch();

        // Restore whatever was bound rather than assuming the default
        // framebuffer, so a capture cannot silently redirect the app's drawing.
        const previous_framebuffer = rl.rlGetActiveFramebuffer();
        const source = self.targets[0];

        // Read from framebuffer 0 explicitly: the presented frame is the one
        // being recorded, whatever else may be bound.
        rl.rlBindFramebuffer(rl.RL_READ_FRAMEBUFFER, 0);
        rl.rlBindFramebuffer(rl.RL_DRAW_FRAMEBUFFER, source.id);
        rl.rlBlitFramebuffer(
            0,
            0,
            source.texture.width,
            source.texture.height,
            0,
            0,
            source.texture.width,
            source.texture.height,
            gl_color_buffer_bit,
        );
        rl.rlEnableFramebuffer(previous_framebuffer);

        // Copy the source colour through verbatim. The default framebuffer's
        // alpha is whatever the app's clear colour left there, and blending
        // against it would darken or erase the frame.
        rl.rlDisableColorBlend();
        var level: usize = 1;
        while (level < self.count) : (level += 1) {
            drawDownscaleLevel(self.targets[level - 1].texture, self.targets[level]);
        }
        rl.rlEnableColorBlend();

        // `rlReadScreenPixels` reads whatever framebuffer is bound and flips the
        // rows, exactly as it does for the default framebuffer -- which is why
        // every step above preserves the framebuffer's own row order.
        const last = self.targets[self.count - 1];
        rl.rlEnableFramebuffer(last.id);
        const data = rl.rlReadScreenPixels(last.texture.width, last.texture.height);
        rl.rlEnableFramebuffer(previous_framebuffer);
        if (data == null) return null;

        return .{ .image = .{
            .data = @ptrCast(data),
            .width = last.texture.width,
            .height = last.texture.height,
            .mipmaps = 1,
            .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
        } };
    }
};

/// Draw one downscale level into the next, filling it exactly.
///
/// The negative source height is raylib's render-target flip. It is not
/// cosmetic here: drawing a render texture upright would invert the row order,
/// so an odd-length chain would come out upside down and an even-length one
/// would not.
fn drawDownscaleLevel(from: Texture, to: RenderTexture) void {
    rl.BeginTextureMode(to);
    rl.DrawTexturePro(
        from,
        .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(from.width),
            .height = -@as(f32, @floatFromInt(from.height)),
        },
        .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(to.texture.width),
            .height = @floatFromInt(to.texture.height),
        },
        .{ .x = 0, .y = 0 },
        0,
        rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
    );
    // `EndTextureMode` submits the batch, so the level is complete before
    // the next input samples it.
    rl.EndTextureMode();
}

/// Submit raylib's batched geometry so the framebuffer reflects it.
///
/// raylib accumulates 2D draw calls in a vertex batch and only submits them on
/// a texture or shader switch, when the batch fills, or from `EndDrawing`. A
/// readback is plain `glReadPixels` and does no flushing of its own, so
/// without this a capture silently misses the tail of the frame.
pub fn flushRenderBatch() void {
    rl.rlDrawRenderBatchActive();
}

/// Read the current framebuffer into a CPU image.
///
/// This is raylib's thin wrapper over `rlReadScreenPixels`, not
/// `TakeScreenshot`: it skips the `basePath` prefixing and 512-byte truncation
/// that make `TakeScreenshot` unusable for a capture pipeline. The result is
/// already upright, and alpha is forced opaque by the readback itself.
///
/// Must be called before `endDrawing` swaps the buffers -- afterwards the back
/// buffer's contents are undefined. Flushes the pending batch first.
pub fn captureFramebuffer() ?CaptureImage {
    flushRenderBatch();
    const image = rl.LoadImageFromScreen();
    if (!rl.IsImageValid(image)) return null;
    return .{ .image = image };
}

/// Read an offscreen render target into a CPU image, upright and with alpha.
///
/// `LoadImageFromTexture` reads the colour attachment through `glGetTexImage`,
/// which keeps the alpha the app drew. `rlReadScreenPixels` -- what
/// `captureFramebuffer` and the downscaler use -- forces alpha opaque, which is
/// right for a window's frame and wrong for an offscreen composition that may
/// be exported with transparency.
///
/// A render target stores its rows bottom-up: the same inversion
/// `drawDownscaleLevel` compensates for with a negative source height. Flipped
/// here rather than left to the caller, so every consumer sees the row order
/// the rest of the capture path already assumes.
///
/// The pending batch is flushed first for the reason `captureFramebuffer`
/// gives: raylib may still be holding the draws that filled the target.
pub fn readRenderTexture(target: RenderTexture) ?CaptureImage {
    flushRenderBatch();
    var image = rl.LoadImageFromTexture(target.texture);
    if (!rl.IsImageValid(image)) return null;
    // `LoadRenderTexture` always allocates an RGBA8 attachment, so this
    // converts nothing today. It is here because `CaptureImage.pixels` computes
    // its length as four bytes per pixel, and a future attachment format would
    // otherwise be read as a buffer overrun rather than as a conversion.
    if (image.format != rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8) {
        rl.ImageFormat(&image, rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8);
        if (image.format != rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8) {
            rl.UnloadImage(image);
            return null;
        }
    }
    rl.ImageFlipVertical(&image);
    return .{ .image = image };
}

/// Draw a pointer glyph at a position, for compositing into a recording.
///
/// The operating system cursor is not part of the framebuffer, so a capture
/// never shows a pointer unless something draws one. This runs in the capture
/// hook rather than in the app's `render!`, so the glyph appears in the file
/// without the app having to know about it -- and without it appearing twice
/// alongside a real cursor on screen.
///
/// `pressed` draws a ring around the arrow so a click is visible in a silent
/// recording, where there is otherwise no cue that anything happened.
pub fn drawCaptureCursor(x: f32, y: f32, pressed: bool, scale: f32) void {
    const size = @max(scale, 0.1) * 18;
    const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = Color{ .r = 0, .g = 0, .b = 0, .a = 220 };

    // A classic arrow: tip at the hotspot, notch on the trailing edge.
    const points = [_]struct { x: f32, y: f32 }{
        .{ .x = x, .y = y },
        .{ .x = x, .y = y + size },
        .{ .x = x + size * 0.26, .y = y + size * 0.74 },
        .{ .x = x + size * 0.44, .y = y + size * 1.06 },
        .{ .x = x + size * 0.60, .y = y + size * 0.98 },
        .{ .x = x + size * 0.42, .y = y + size * 0.67 },
        .{ .x = x + size * 0.70, .y = y + size * 0.64 },
    };

    if (pressed) {
        drawCircleLines(.{
            .center = .{ .x = x, .y = y },
            .radius = size * 0.95,
            .thickness = @max(size * 0.10, 1),
            .color = white,
        });
    }

    drawPolygon(&points, white);
    drawPolygonLines(&points, @max(size * 0.09, 1), black);
}
