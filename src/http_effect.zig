//! The `Http.send!` effect: one HTTP exchange on the app's zio runtime.
//!
//! `std.http.Client` is handed `rt.io()`, so every socket wait it does parks
//! the calling coroutine instead of blocking the thread. Inside `Task.spawn!`
//! that means the frame loop keeps drawing while the request is in flight;
//! inside `init!` there is no other task to run, so the frame thread waits.
//! Either way the code here reads as if it were synchronous, which is the
//! whole point of the coroutine scheme (COROUTINE_DESIGN_PROPOSAL.md, 5.3).
//!
//! `host_native.zig` owns the phase guard and the Roc entry point; this file
//! owns the exchange and the conversion between Roc values and Zig slices.
//! Nothing here touches raylib.
//!
//! ## Ownership
//!
//! `send` consumes the request record Roc hands it -- the ABI transfers owned
//! refcounted arguments to the hosted function -- and returns a response record
//! whose strings and lists Roc then owns. Everything in between lives in an
//! arena that is discarded before the Roc values are built, so a timeout or a
//! cancellation cannot leave a half-built Roc value behind.
//!
//! ## Limits
//!
//! The request carries both limits: `timeout_ms` bounds the whole exchange
//! through `zio.withTimeout`, and `max_response_bytes` bounds the decompressed
//! body through the reader's own limit. Zero disables either one. The body cap
//! is a refusal, not a truncation: a body over the cap fails the send, because
//! a truncated body decodes into wrong data rather than into an error.

const std = @import("std");
const zio = @import("zio");
const abi = @import("roc_platform_abi.zig");

/// The flattened request `Http` hands the host, as `roc glue` generated it.
pub const Request = abi.HttpHostSendArgs;

/// The flattened response the host hands back.
pub const Response = abi.HttpHostSend;

/// One header on the wire, in the order the peer sent or expects it.
pub const HeaderPair = abi.HttpHostSendHeaders;

/// The exchange completed; `status`, `headers` and `body` are meaningful.
pub const ERR_OK: u8 = 0;

/// The exchange did not finish inside `timeout_ms`.
pub const ERR_TIMEOUT: u8 = 1;

/// The connection could not be made or did not survive the exchange.
pub const ERR_NETWORK: u8 = 2;

/// A reply arrived but was not a well-formed HTTP response.
pub const ERR_BAD_BODY: u8 = 3;

/// Anything else; `err_message` describes it. `Http` maps this to `Other`.
pub const ERR_OTHER: u8 = 4;

/// Room for the redirect chain's URIs. RFC 9110 suggests at least 8000 bytes
/// for a request line, and a redirect target is one URI out of that budget.
const redirect_buffer_bytes: usize = 8192;

/// Working buffer between the socket and the decompressor.
const transfer_buffer_bytes: usize = 16 * 1024;

/// Bytes of the body echoed into the task trace. Enough to recognise a JSON
/// payload or an error page, short enough not to bury the other trace lines.
const trace_body_preview_bytes: usize = 200;

/// The six headers `std.http.Client` emits itself. An app that sets one of
/// these has to override the default rather than append a second copy, so they
/// are routed to `RequestOptions.headers` instead of `extra_headers`.
const standard_header_names = [_][]const u8{
    "host",
    "authorization",
    "user-agent",
    "connection",
    "accept-encoding",
    "content-type",
};

/// The runtime whose `io` the client drives, published while an app runs.
///
/// A hosted symbol is a bare C function with no context argument, so the
/// runtime reaches this effect the same way the task registry reaches its own:
/// through a variable the frame loop sets on the way in and clears on the way
/// out. Null outside a running app, which `send` reports rather than crashing.
var runtime: ?*zio.Runtime = null;

/// Whether `ROC_RAY_TRACE_TASKS` asked for per-request trace lines.
var trace: bool = false;

/// Publish the runtime this effect sends on. Called by the frame loop next to
/// the task registry's own `activate`.
pub fn activate(rt: *zio.Runtime, trace_requests: bool) void {
    runtime = rt;
    trace = trace_requests;
}

/// Withdraw the runtime. A send after this reports that the app is not running
/// rather than reaching a torn-down event loop.
pub fn deactivate() void {
    runtime = null;
}

/// How an exchange ended, before it is turned into Roc values.
///
/// `Canceled` is the app shutting down mid-request and `Timeout` is the
/// deadline expiring; `runWithDeadline` is what tells the two apart, since by
/// the time `std.http` reports a failure it has usually lost the distinction.
const ExchangeError = error{
    Canceled,
    Timeout,
    OutOfMemory,
    ResponseTooLarge,
    MalformedResponse,
    NetworkFailure,
    UnsupportedMethod,
    UnsupportedUri,
    BodyNotAllowed,
    InvalidHeader,
    TlsFailure,
};

/// One header, as plain Zig slices owned by the exchange arena.
const OutHeader = struct { name: []const u8, value: []const u8 };

/// Everything one exchange needs, and everything it produced.
///
/// `zio.withTimeout` takes a function and an argument tuple, so the inputs and
/// outputs travel together in one pointer rather than as a long parameter list.
const Exchange = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    method: std.http.Method,
    uri: std.Uri,
    /// Headers to append verbatim, already checked for wire-legal bytes.
    extra_headers: []const std.http.Header,
    /// Overrides for the headers `std.http.Client` would otherwise emit itself.
    standard_headers: std.http.Client.Request.Headers,
    /// Owned by the arena: `sendBodyComplete` writes through this buffer.
    body: []u8,
    /// Zero means no cap.
    max_response_bytes: u64,

    status: u16 = 0,
    headers: []OutHeader = &.{},
    response_body: []u8 = &.{},
};

/// Send one request and wait for the whole response.
///
/// Consumes `args`. The returned record's `err` is `ERR_OK` on success and one
/// of the other codes otherwise, in which case `err_message` describes the
/// failure and the other fields are empty.
pub fn send(roc_host: *abi.RocHost, allocator: std.mem.Allocator, args: Request) Response {
    defer args.decref(roc_host);

    const rt = runtime orelse return failure(
        roc_host,
        ERR_OTHER,
        "Http.send! is only available while the app is running",
    );

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var exchange = prepare(arena, rt.io(), args) catch |err| return describe(roc_host, err, args, 0);

    if (trace) std.log.info("[TASK] http {s} {s} parking", .{
        @tagName(exchange.method),
        args.uri.asSlice(),
    });

    const timeout: zio.Timeout = if (args.timeout_ms == 0) .none else .fromMilliseconds(args.timeout_ms);
    runWithDeadline(&exchange, timeout) catch |err| {
        if (trace) std.log.info("[TASK] http {s} failed: {s}", .{ @tagName(exchange.method), @errorName(err) });
        return describe(roc_host, err, args, exchange.max_response_bytes);
    };

    if (trace) {
        std.log.info("[TASK] http {d} resumed with {d} byte body from {s}", .{
            exchange.status,
            exchange.response_body.len,
            args.uri.asSlice(),
        });
        tracePreview(exchange.response_body);
    }

    return .{
        .err = ERR_OK,
        .err_message = abi.RocStr.empty(),
        .status = exchange.status,
        .headers = toRocHeaders(roc_host, exchange.headers),
        .body = abi.RocListWith(u8, false).fromSlice(exchange.response_body, roc_host),
    };
}

/// Turn the Roc request into the Zig values the exchange runs on.
///
/// Every slice this produces is copied into the arena, so the Roc strings the
/// caller owns can be released the moment `send` returns whatever happens.
fn prepare(arena: std.mem.Allocator, io: std.Io, args: Request) ExchangeError!Exchange {
    const method = try methodFromCode(args.method, args.method_ext.asSlice());
    const uri = std.Uri.parse(try arena.dupe(u8, args.uri.asSlice())) catch return error.UnsupportedUri;

    const body = try arena.dupe(u8, args.body.items());
    if (body.len != 0 and !method.requestHasBody()) return error.BodyNotAllowed;

    var standard: std.http.Client.Request.Headers = .{};
    var extra: std.ArrayList(std.http.Header) = .empty;
    for (args.headers.items()) |pair| {
        const name = try arena.dupe(u8, pair.name.asSlice());
        const value = try arena.dupe(u8, pair.value.asSlice());
        try checkHeaderBytes(name, value);
        if (try overrideStandardHeader(&standard, name, value)) continue;
        try extra.append(arena, .{ .name = name, .value = value });
    }

    return .{
        .arena = arena,
        .io = io,
        .method = method,
        .uri = uri,
        .extra_headers = extra.items,
        .standard_headers = standard,
        .body = body,
        .max_response_bytes = args.max_response_bytes,
    };
}

/// Run the exchange under a deadline, reporting `error.Timeout` when the
/// deadline is what ended it.
///
/// `zio.withTimeout` would be the scoped form of this, but it only recognises
/// its own timer when the wrapped call returns `error.Canceled`, and
/// `std.http`'s error sets do not carry one: a cancelled socket read surfaces
/// as `error.ReadFailed` several layers up, and the exchange then reports a
/// network failure for what was really a timeout. Arming `AutoCancel` by hand
/// lets the timer itself, rather than the error value, decide.
///
/// `check` also consumes the cancellation. Without that the task stays
/// cancelled and the *next* effect the app runs inside the same
/// `Task.spawn!` -- a retry, a sleep -- fails for no visible reason.
fn runWithDeadline(exchange: *Exchange, timeout: zio.Timeout) ExchangeError!void {
    var auto: zio.AutoCancel = .init;
    auto.set(timeout);
    const outcome = run(exchange);
    auto.clear();
    const timed_out = auto.check(error.Canceled);
    _ = outcome catch |err| return if (timed_out) error.Timeout else err;
}

/// Run the exchange to completion, filling in `exchange`'s output fields.
///
/// A fresh `std.http.Client` per send: it is the client that owns the
/// connection pool and the TLS trust store, and one that outlived the send
/// would have to be torn down from outside any coroutine, where its `io` calls
/// are not valid. The cost is a handshake per request, and on HTTPS a rescan
/// of the system certificate store; see docs/http.md.
fn run(exchange: *Exchange) ExchangeError!void {
    var client: std.http.Client = .{ .allocator = exchange.arena, .io = exchange.io };
    defer client.deinit();

    var request = client.request(exchange.method, exchange.uri, .{
        // The client dies with this send, so there is nothing to pool into.
        .keep_alive = false,
        .headers = exchange.standard_headers,
        .extra_headers = exchange.extra_headers,
    }) catch |err| return translate(err);
    defer request.deinit();

    if (exchange.method.requestHasBody()) {
        request.sendBodyComplete(exchange.body) catch |err| return translate(err);
    } else {
        request.sendBodiless() catch |err| return translate(err);
    }

    const redirect_buffer = try exchange.arena.alloc(u8, redirect_buffer_bytes);
    var response = request.receiveHead(redirect_buffer) catch |err| return translate(err);
    exchange.status = @intFromEnum(response.head.status);

    // `readerDecompressing` invalidates the head's string pointers, so the
    // headers have to be copied out of it first.
    exchange.headers = try copyHeaders(exchange.arena, response.head);

    const transfer_buffer = try exchange.arena.alloc(u8, transfer_buffer_bytes);
    const decompress = try exchange.arena.create(std.http.Decompress);
    const decompress_buffer = try exchange.arena.alloc(u8, std.compress.flate.max_window_len);
    const reader = response.readerDecompressing(transfer_buffer, decompress, decompress_buffer);

    // `allocRemaining` fails once the limit is *reached*, so a body of exactly
    // `max_response_bytes` has to be allowed one byte of headroom to succeed.
    const limit: std.Io.Limit = if (exchange.max_response_bytes == 0)
        .unlimited
    else
        .limited(@intCast(@min(exchange.max_response_bytes +| 1, std.math.maxInt(usize))));

    exchange.response_body = reader.allocRemaining(exchange.arena, limit) catch |err| switch (err) {
        error.StreamTooLong => return error.ResponseTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => return translate(response.bodyErr() orelse error.ReadFailed),
    };
}

/// Copy the response's headers out of the head buffer before it is invalidated.
fn copyHeaders(arena: std.mem.Allocator, head: std.http.Client.Response.Head) ExchangeError![]OutHeader {
    var out: std.ArrayList(OutHeader) = .empty;
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        try out.append(arena, .{
            .name = try arena.dupe(u8, header.name),
            .value = try arena.dupe(u8, header.value),
        });
    }
    return out.items;
}

/// Map basic-cli's numeric method codes onto the methods this host can send.
///
/// `std.http.Method` is a closed enum of the nine RFC methods, so `QUERY` and
/// any `Unknown(ext)` method cannot be put on the wire from here and are
/// reported rather than silently rewritten.
fn methodFromCode(code: u8, ext: []const u8) ExchangeError!std.http.Method {
    _ = ext;
    return switch (code) {
        0 => .CONNECT,
        1 => .DELETE,
        3 => .GET,
        4 => .HEAD,
        5 => .OPTIONS,
        6 => .PATCH,
        7 => .POST,
        8 => .PUT,
        9 => .TRACE,
        else => error.UnsupportedMethod,
    };
}

/// Refuse header bytes that would be a protocol violation on the wire.
///
/// `std.http.Client` asserts these in safety builds, which would abort the
/// process on an app's typo; checking here turns that into an error the app
/// can print.
fn checkHeaderBytes(name: []const u8, value: []const u8) ExchangeError!void {
    if (name.len == 0) return error.InvalidHeader;
    if (std.mem.indexOfScalar(u8, name, ':') != null) return error.InvalidHeader;
    for ([_][]const u8{ name, value }) |field| {
        if (std.mem.indexOfAny(u8, field, "\r\n") != null) return error.InvalidHeader;
    }
}

/// Route a header the client emits itself into its override slot.
///
/// Returns true when the header was consumed as an override, so the caller
/// does not also append it and produce two copies on the wire.
fn overrideStandardHeader(
    headers: *std.http.Client.Request.Headers,
    name: []const u8,
    value: []const u8,
) ExchangeError!bool {
    inline for (standard_header_names, 0..) |candidate, index| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) {
            const slot = switch (index) {
                0 => &headers.host,
                1 => &headers.authorization,
                2 => &headers.user_agent,
                3 => &headers.connection,
                4 => &headers.accept_encoding,
                5 => &headers.content_type,
                else => unreachable,
            };
            slot.* = .{ .override = value };
            return true;
        }
    }
    return false;
}

/// Fold one of `std.http`'s many error sets into this file's.
///
/// `error.Canceled` passes through unchanged: `zio.withTimeout` needs to see it
/// to know that its own timer, rather than a shutdown, ended the exchange.
fn translate(err: anyerror) ExchangeError {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedUriScheme,
        error.UriMissingHost,
        error.UriHostTooLong,
        => error.UnsupportedUri,
        error.CertificateBundleLoadFailure,
        error.TlsInitializationFailed,
        => error.TlsFailure,
        error.HttpChunkInvalid,
        error.HttpHeadersInvalid,
        error.HttpHeadersOversize,
        error.HttpConnectionHeaderUnsupported,
        error.HttpContentEncodingUnsupported,
        error.HttpHeaderContinuationsUnsupported,
        error.HttpTransferEncodingUnsupported,
        error.HttpRedirectLocationMissing,
        error.HttpRedirectLocationOversize,
        error.HttpRedirectLocationInvalid,
        error.TooManyHttpRedirects,
        error.RedirectRequiresResend,
        error.InvalidContentLength,
        error.CompressionUnsupported,
        error.DecompressionFailure,
        => error.MalformedResponse,
        else => error.NetworkFailure,
    };
}

/// Turn an exchange failure into the response record, with a message the app
/// can print. Nothing is allocated in the arena at this point, so the message
/// is built straight into a Roc string.
fn describe(roc_host: *abi.RocHost, err: anyerror, args: Request, max_response_bytes: u64) Response {
    var buffer: [256]u8 = undefined;
    return switch (err) {
        error.Timeout => failure(roc_host, ERR_TIMEOUT, "the request did not finish in time"),
        error.Canceled => failure(roc_host, ERR_NETWORK, "the request was cancelled while the app shut down"),
        error.MalformedResponse => failure(roc_host, ERR_BAD_BODY, "the reply was not a well-formed HTTP response"),
        error.NetworkFailure => failure(
            roc_host,
            ERR_NETWORK,
            std.fmt.bufPrint(&buffer, "could not complete the request to {s}", .{args.uri.asSlice()}) catch
                "could not complete the request",
        ),
        error.ResponseTooLarge => failure(
            roc_host,
            ERR_OTHER,
            std.fmt.bufPrint(
                &buffer,
                "the response body is larger than max_response_bytes ({d})",
                .{max_response_bytes},
            ) catch "the response body is larger than max_response_bytes",
        ),
        error.UnsupportedUri => failure(roc_host, ERR_OTHER, "the host could not use this URI"),
        error.UnsupportedMethod => failure(
            roc_host,
            ERR_OTHER,
            "this host can only send the nine standard HTTP methods, not QUERY or an extension method",
        ),
        error.BodyNotAllowed => failure(roc_host, ERR_OTHER, "this HTTP method cannot carry a request body"),
        error.InvalidHeader => failure(roc_host, ERR_OTHER, "a request header name or value is not legal on the wire"),
        error.TlsFailure => failure(roc_host, ERR_OTHER, "the system certificate store could not be loaded for TLS"),
        error.OutOfMemory => failure(roc_host, ERR_OTHER, "out of memory while sending the request"),
        else => failure(
            roc_host,
            ERR_OTHER,
            std.fmt.bufPrint(&buffer, "{s}", .{@errorName(err)}) catch "the request failed",
        ),
    };
}

/// An empty response carrying only a code and a message.
fn failure(roc_host: *abi.RocHost, code: u8, message: []const u8) Response {
    return .{
        .err = code,
        .err_message = abi.RocStr.fromSlice(message, roc_host),
        .status = 0,
        .headers = abi.RocList(HeaderPair).empty(),
        .body = abi.RocListWith(u8, false).empty(),
    };
}

/// Copy the response's headers into a Roc list Roc then owns.
fn toRocHeaders(roc_host: *abi.RocHost, headers: []const OutHeader) abi.RocList(HeaderPair) {
    if (headers.len == 0) return abi.RocList(HeaderPair).empty();
    const list = abi.RocList(HeaderPair).allocate(headers.len, roc_host);
    const elements = list.elements_ptr.?;
    for (headers, 0..) |header, index| {
        elements[index] = .{
            .name = abi.RocStr.fromSlice(header.name, roc_host),
            .value = abi.RocStr.fromSlice(header.value, roc_host),
        };
    }
    return list;
}

/// Echo the start of the body into the trace, with control bytes escaped.
///
/// This is what makes an HTTP trace readable: without it a failing fetch shows
/// only a byte count, and the difference between an API's JSON and its error
/// page is invisible. `scripts/all_tests.py` also reads this line to check that
/// the body a local server served is the body the host received.
fn tracePreview(body: []const u8) void {
    const shown = body[0..@min(body.len, trace_body_preview_bytes)];
    var buffer: [trace_body_preview_bytes * 2]u8 = undefined;
    var written: usize = 0;
    for (shown) |byte| {
        if (std.ascii.isPrint(byte)) {
            buffer[written] = byte;
            written += 1;
        } else {
            if (written + 1 >= buffer.len) break;
            buffer[written] = ' ';
            written += 1;
        }
    }
    std.log.info("[TASK] http body: {s}{s}", .{
        buffer[0..written],
        if (body.len > shown.len) "..." else "",
    });
}

test "a method code outside the nine standard methods is refused" {
    try std.testing.expectEqual(std.http.Method.GET, try methodFromCode(3, ""));
    try std.testing.expectEqual(std.http.Method.POST, try methodFromCode(7, ""));
    // 2 is basic-cli's code for QUERY and for every Unknown(ext) method.
    try std.testing.expectError(error.UnsupportedMethod, methodFromCode(2, "QUERY"));
}

test "header bytes that would break the wire format are refused" {
    try checkHeaderBytes("Accept", "application/json");
    try std.testing.expectError(error.InvalidHeader, checkHeaderBytes("", "x"));
    try std.testing.expectError(error.InvalidHeader, checkHeaderBytes("Bad:Name", "x"));
    try std.testing.expectError(error.InvalidHeader, checkHeaderBytes("X", "a\r\nInjected: y"));
}

test "a header the client emits itself becomes an override" {
    var headers: std.http.Client.Request.Headers = .{};
    try std.testing.expect(try overrideStandardHeader(&headers, "User-Agent", "roc-ray"));
    try std.testing.expectEqualStrings("roc-ray", headers.user_agent.override);
    try std.testing.expect(!try overrideStandardHeader(&headers, "Accept", "application/json"));
}

test "std's error sets fold onto the transport codes Http maps" {
    try std.testing.expectEqual(error.Canceled, translate(error.Canceled));
    try std.testing.expectEqual(error.MalformedResponse, translate(error.HttpHeadersInvalid));
    try std.testing.expectEqual(error.UnsupportedUri, translate(error.UnsupportedUriScheme));
    try std.testing.expectEqual(error.TlsFailure, translate(error.CertificateBundleLoadFailure));
    try std.testing.expectEqual(error.NetworkFailure, translate(error.ConnectionRefused));
}
