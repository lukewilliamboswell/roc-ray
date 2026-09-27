//! The permission policy an application declared in its startup `Config`.
//!
//! An application's reach beyond its own resources -- network origins and
//! peers, directories, executables, environment variables, the clipboard -- is
//! whatever its source declares with `Permission.*`, and nothing else. There is
//! no launch flag that widens it. The host reads the declarations once, after
//! the config callback and before `init!`, validates every one into the fixed
//! table here, and then answers each hosted effect with `admit*`.
//!
//! An admission has three answers, and they mean different things:
//!
//! - `allow`: the declared scope covers the target.
//! - `out_of_scope`: the facility is declared, but not for this target. The
//!   target -- a URL, a path, a peer, a variable name -- may be runtime data,
//!   so this is a runtime outcome the effect reports as `PermissionDenied`.
//! - `undeclared`: the source never declared the facility at all. That is
//!   fixed by the source, so it is a programmer error, and the caller fails
//!   the application with `fix` naming the declaration to add.
//!
//! The policy is written once on the frame thread before any task or worker
//! starts and is only read afterwards, so workers that check a redirect may
//! read it without synchronization.
//!
//! Nothing here touches the filesystem or the network: every check is
//! lexical, over the declared text. That is what makes the table testable in
//! isolation and safe to consult from any thread.

const std = @import("std");

/// The most declarations one application may make. Exceeding it fails
/// startup rather than dropping a declaration, because a dropped declaration
/// would turn into a crash far from its cause.
pub const capacity: usize = 64;

/// Bytes available for the text of every declaration together.
pub const text_capacity: usize = 16 * 1024;

/// The longest application identifier accepted.
pub const app_id_max_bytes: usize = 128;

/// Declaration kinds. Mirrored in `platform/Permission.roc`; the numbers are
/// the transport encoding and must not be reused.
pub const Kind = enum(u8) {
    http_origin = 1,
    http_any = 2,
    udp_bind = 3,
    udp_peer = 4,
    udp_any = 5,
    command = 6,
    command_any = 7,
    env_var = 8,
    env_any = 9,
    clipboard_read = 10,
    clipboard_write = 11,
    working_directory = 12,
    directory = 13,
    files_anywhere = 14,
    _,
};

/// Whether a directory declaration permits writes. Mirrored in
/// `platform/Permission.roc`.
pub const Mode = enum(u8) {
    read_only = 0,
    read_write = 1,
    _,
};

/// A facility as the gate asks about it. Several kinds serve one facility --
/// an origin and `http_any` both answer for `http` -- which is why
/// "undeclared" is a question about facilities, not kinds.
pub const Facility = enum {
    http,
    udp,
    command,
    env,
    clipboard_read,
    clipboard_write,
    files,
};

/// How a policy answers one effect; see the module comment.
pub const Admission = enum { allow, out_of_scope, undeclared };

/// Why a declaration was refused at startup; `describe` phrases each one.
pub const ValidationError = error{
    TooManyDeclarations,
    DeclarationTextTooLong,
    UnknownKind,
    UnknownMode,
    InvalidOrigin,
    InvalidPort,
    InvalidPeer,
    InvalidCommand,
    InvalidEnvName,
    InvalidDirectory,
    InvalidAppId,
};

/// One validated declaration. Slices point into the policy's own text buffer.
const Entry = struct {
    kind: Kind,
    mode: Mode = .read_only,
    port: u16 = 0,
    /// Origin scheme (`http` or `https`), lowercased.
    scheme: []const u8 = "",
    /// Origin host, lowercased; a command, variable name, or directory.
    text: []const u8 = "",
    /// A UDP peer's IPv4 address in host order.
    ip: u32 = 0,
};

/// The validated declarations of one application lifetime.
pub const Policy = struct {
    entries: [capacity]Entry = undefined,
    len: usize = 0,
    text: [text_capacity]u8 = undefined,
    text_len: usize = 0,
    app_id_buffer: [app_id_max_bytes]u8 = undefined,
    app_id_len: usize = 0,

    /// The declared application identifier, or null when none was declared.
    pub fn appId(self: *const Policy) ?[]const u8 {
        if (self.app_id_len == 0) return null;
        return self.app_id_buffer[0..self.app_id_len];
    }

    /// Record the application identifier. Empty means none; anything else must
    /// be a reverse-DNS style name that is safe as one path component.
    pub fn setAppId(self: *Policy, id: []const u8) ValidationError!void {
        if (id.len == 0) {
            self.app_id_len = 0;
            return;
        }
        if (!isValidAppId(id)) return error.InvalidAppId;
        @memcpy(self.app_id_buffer[0..id.len], id);
        self.app_id_len = id.len;
    }

    /// Validate one transported declaration and add it to the table.
    pub fn add(self: *Policy, kind_code: u8, mode_code: u8, port: u16, text: []const u8) ValidationError!void {
        if (self.len == capacity) return error.TooManyDeclarations;
        const kind: Kind = @enumFromInt(kind_code);
        const mode: Mode = switch (@as(Mode, @enumFromInt(mode_code))) {
            .read_only, .read_write => |m| m,
            _ => return error.UnknownMode,
        };
        var entry: Entry = .{ .kind = kind, .mode = mode, .port = port };
        switch (kind) {
            .http_any, .udp_any, .command_any, .env_any, .clipboard_read, .clipboard_write => {},
            .working_directory, .files_anywhere => {},
            .http_origin => {
                const origin = parseOrigin(text) orelse return error.InvalidOrigin;
                entry.scheme = if (origin.https) "https" else "http";
                entry.port = origin.port;
                entry.text = try self.lowerCopy(origin.host);
            },
            .udp_bind => if (port == 0) return error.InvalidPort,
            .udp_peer => {
                if (port == 0) return error.InvalidPort;
                entry.ip = parseIp4(text) orelse return error.InvalidPeer;
            },
            .command => {
                if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidCommand;
                entry.text = try self.copy(text);
            },
            .env_var => {
                if (!isValidEnvName(text)) return error.InvalidEnvName;
                entry.text = try self.copy(text);
            },
            .directory => {
                if (!isSafeDeclaredDirectory(text)) return error.InvalidDirectory;
                entry.text = try self.copy(trimTrailingSeparators(text));
            },
            _ => return error.UnknownKind,
        }
        self.entries[self.len] = entry;
        self.len += 1;
    }

    fn copy(self: *Policy, bytes: []const u8) ValidationError![]const u8 {
        if (bytes.len > text_capacity - self.text_len) return error.DeclarationTextTooLong;
        const out = self.text[self.text_len..][0..bytes.len];
        @memcpy(out, bytes);
        self.text_len += bytes.len;
        return out;
    }

    fn lowerCopy(self: *Policy, bytes: []const u8) ValidationError![]const u8 {
        const out = try self.copy(bytes);
        const writable = self.text[self.text_len - out.len .. self.text_len];
        for (writable) |*byte| byte.* = std.ascii.toLower(byte.*);
        return writable;
    }

    /// Whether the app declared the facility at all, in any scope.
    pub fn declares(self: *const Policy, facility: Facility) bool {
        for (self.entries[0..self.len]) |entry| {
            if (facilityOf(entry.kind) == facility) return true;
        }
        return false;
    }

    /// Admit an HTTP request, or a redirect hop, to `uri`.
    pub fn admitHttp(self: *const Policy, uri: std.Uri) Admission {
        if (!self.declares(.http)) return .undeclared;
        const https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
        if (!https and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return .out_of_scope;
        const component = uri.host orelse return .out_of_scope;
        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = component.toRaw(&host_buffer) catch return .out_of_scope;
        const port = uri.port orelse @as(u16, if (https) 443 else 80);
        for (self.entries[0..self.len]) |entry| switch (entry.kind) {
            .http_any => return .allow,
            .http_origin => {
                if (!std.mem.eql(u8, entry.scheme, if (https) "https" else "http")) continue;
                if (entry.port != port) continue;
                if (std.ascii.eqlIgnoreCase(entry.text, host)) return .allow;
            },
            else => {},
        };
        return .out_of_scope;
    }

    /// Admit binding a UDP socket to a local port. Port `0` asks the system
    /// for an ephemeral port; any UDP declaration permits that.
    pub fn admitUdpBind(self: *const Policy, port: u16) Admission {
        if (!self.declares(.udp)) return .undeclared;
        for (self.entries[0..self.len]) |entry| switch (entry.kind) {
            .udp_any => return .allow,
            .udp_bind => if (entry.port == port) return .allow,
            .udp_peer => if (port == 0) return .allow,
            else => {},
        };
        return .out_of_scope;
    }

    /// Admit sending a datagram to an IPv4 peer.
    pub fn admitUdpPeer(self: *const Policy, ip: u32, port: u16) Admission {
        if (!self.declares(.udp)) return .undeclared;
        for (self.entries[0..self.len]) |entry| switch (entry.kind) {
            .udp_any => return .allow,
            .udp_peer => if (entry.ip == ip and entry.port == port) return .allow,
            else => {},
        };
        return .out_of_scope;
    }

    /// Admit running `program` exactly as the application named it. The check
    /// precedes any `PATH` lookup, so declaring `git` permits `git` and not
    /// `/tmp/git`.
    pub fn admitCommand(self: *const Policy, program: []const u8) Admission {
        if (!self.declares(.command)) return .undeclared;
        for (self.entries[0..self.len]) |entry| switch (entry.kind) {
            .command_any => return .allow,
            .command => if (std.mem.eql(u8, entry.text, program)) return .allow,
            else => {},
        };
        return .out_of_scope;
    }

    /// Admit reading one environment variable.
    pub fn admitEnv(self: *const Policy, name: []const u8) Admission {
        if (!self.declares(.env)) return .undeclared;
        for (self.entries[0..self.len]) |entry| switch (entry.kind) {
            .env_any => return .allow,
            .env_var => if (std.mem.eql(u8, entry.text, name)) return .allow,
            else => {},
        };
        return .out_of_scope;
    }

    /// Admit a clipboard read or write.
    pub fn admitClipboard(self: *const Policy, write: bool) Admission {
        return if (self.declares(if (write) .clipboard_write else .clipboard_read)) .allow else .undeclared;
    }

    /// Admit a filesystem path as the application wrote it, for reading or
    /// writing.
    ///
    /// The check is lexical. A relative path is covered by
    /// `working_directory` or by a relative `directory` it lies beneath; an
    /// absolute path by an absolute `directory` it lies beneath. A path with a
    /// `..` component is covered only by `files_anywhere`, because lexically
    /// it can name anything.
    pub fn admitPath(self: *const Policy, path: []const u8, write: bool) Admission {
        if (!self.declares(.files)) return .undeclared;
        const absolute = isAbsolute(path);
        const has_parent = hasParentComponent(path);
        for (self.entries[0..self.len]) |entry| {
            if (write and entry.mode != .read_write) continue;
            switch (entry.kind) {
                .files_anywhere => return .allow,
                .working_directory => if (!absolute and !has_parent) return .allow,
                .directory => {
                    if (has_parent) continue;
                    if (isAbsolute(entry.text) != absolute) continue;
                    if (isBeneath(entry.text, path)) return .allow;
                },
                else => {},
            }
        }
        return .out_of_scope;
    }

    /// Whether the working directory is declared readable (in any mode).
    pub fn admitWorkingDirectory(self: *const Policy, write: bool) Admission {
        if (!self.declares(.files)) return .undeclared;
        for (self.entries[0..self.len]) |entry| {
            if (write and entry.mode != .read_write) continue;
            switch (entry.kind) {
                .files_anywhere, .working_directory => return .allow,
                else => {},
            }
        }
        return .out_of_scope;
    }
};

fn facilityOf(kind: Kind) ?Facility {
    return switch (kind) {
        .http_origin, .http_any => .http,
        .udp_bind, .udp_peer, .udp_any => .udp,
        .command, .command_any => .command,
        .env_var, .env_any => .env,
        .clipboard_read => .clipboard_read,
        .clipboard_write => .clipboard_write,
        .working_directory, .directory, .files_anywhere => .files,
        _ => null,
    };
}

/// The declaration that would permit a facility, phrased for the message an
/// undeclared use fails with.
pub fn fix(facility: Facility) []const u8 {
    return switch (facility) {
        .http => "Declare the origin it talks to: App.default.with_permission(Permission.http_origin(\"https://example.com\")).",
        .udp => "Declare the port it binds and the peers it sends to: App.default.with_permission(Permission.udp_bind(port)) and .with_permission(Permission.udp_peer(\"127.0.0.1\", port)).",
        .command => "Declare the executable it runs: App.default.with_permission(Permission.command(\"name\")).",
        .env => "Declare the variable it reads: App.default.with_permission(Permission.env_var(\"NAME\")).",
        .clipboard_read => "Declare clipboard reads: App.default.with_permission(Permission.clipboard_read).",
        .clipboard_write => "Declare clipboard writes: App.default.with_permission(Permission.clipboard_write).",
        .files => "Declare the directory it uses: App.default.with_permission(Permission.working_directory(ReadOnly)) or Permission.directory(\"path\", ReadWrite).",
    };
}

/// Describe a validation failure for the startup message that names it.
pub fn describe(err: ValidationError) []const u8 {
    return switch (err) {
        error.TooManyDeclarations => "more permission declarations than the host holds",
        error.DeclarationTextTooLong => "permission declarations are longer in total than the host holds",
        error.UnknownKind => "an unrecognised permission kind",
        error.UnknownMode => "an unrecognised directory mode",
        error.InvalidOrigin => "an HTTP origin must be scheme://host[:port] with an http or https scheme and no path, query, or credentials",
        error.InvalidPort => "a UDP port must be between 1 and 65535",
        error.InvalidPeer => "a UDP peer must be a dotted-quad IPv4 address",
        error.InvalidCommand => "a command must be a non-empty executable name",
        error.InvalidEnvName => "an environment variable name must be non-empty and contain no '=' or NUL",
        error.InvalidDirectory => "a directory must be non-empty, contain no '..' component or NUL, and not be the filesystem root",
        error.InvalidAppId => "an app id must be 1-128 ASCII letters, digits, '.', '-', or '_', not starting with '.' or '-', and not containing '..'",
    };
}

const Origin = struct { https: bool, host: []const u8, port: u16 };

fn parseOrigin(text: []const u8) ?Origin {
    const uri = std.Uri.parse(text) catch return null;
    const https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!https and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return null;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |p| p,
    };
    if (path.len != 0 and !std.mem.eql(u8, path, "/")) return null;
    const host = switch (uri.host orelse return null) {
        .raw, .percent_encoded => |h| h,
    };
    if (host.len == 0 or host.len > std.Io.net.HostName.max_len) return null;
    if (std.mem.indexOfScalar(u8, host, '%') != null) return null;
    return .{ .https = https, .host = host, .port = uri.port orelse @as(u16, if (https) 443 else 80) };
}

/// Parse a dotted-quad IPv4 literal into host order, refusing leading zeros.
pub fn parseIp4(text: []const u8) ?u32 {
    var octets: [4]u8 = undefined;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, text, '.');
    while (parts.next()) |part| {
        if (count == 4) return null;
        if (part.len == 0 or part.len > 3) return null;
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
    return (@as(u32, octets[0]) << 24) | (@as(u32, octets[1]) << 16) | (@as(u32, octets[2]) << 8) | octets[3];
}

fn isValidEnvName(name: []const u8) bool {
    if (name.len == 0) return false;
    return std.mem.indexOfAny(u8, name, "=\x00") == null;
}

fn isValidAppId(id: []const u8) bool {
    if (id.len == 0 or id.len > app_id_max_bytes) return false;
    if (id[0] == '.' or id[0] == '-') return false;
    if (std.mem.indexOf(u8, id, "..") != null) return false;
    for (id) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        if (byte == '.' or byte == '-' or byte == '_') continue;
        return false;
    }
    return true;
}

fn isSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn isAbsolute(path: []const u8) bool {
    if (path.len == 0) return false;
    if (isSeparator(path[0])) return true;
    // A Windows drive path, `C:\...` or `C:/...`.
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and isSeparator(path[2]);
}

fn hasParentComponent(path: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and isSeparator(path[end - 1])) end -= 1;
    return path[0..end];
}

fn isSafeDeclaredDirectory(path: []const u8) bool {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (hasParentComponent(path)) return false;
    // The filesystem root is `files_anywhere`, which says so.
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    const first = parts.next() orelse return false;
    if (isAbsolute(path) and first.len == 2 and first[1] == ':' and parts.peek() == null) return false;
    return true;
}

/// Whether `path` names `root` or something beneath it, comparing components
/// so `/data` does not cover `/database`. `.` components are ignored.
fn isBeneath(root: []const u8, path: []const u8) bool {
    var root_parts = std.mem.tokenizeAny(u8, root, "/\\");
    var path_parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (nextComponent(&root_parts)) |root_part| {
        const path_part = nextComponent(&path_parts) orelse return false;
        if (!std.mem.eql(u8, root_part, path_part)) return false;
    }
    return true;
}

fn nextComponent(parts: *std.mem.TokenIterator(u8, .any)) ?[]const u8 {
    while (parts.next()) |part| {
        if (!std.mem.eql(u8, part, ".")) return part;
    }
    return null;
}

fn testPolicy(declarations: []const struct { Kind, Mode, u16, []const u8 }) !Policy {
    var policy: Policy = .{};
    for (declarations) |d| try policy.add(@intFromEnum(d[0]), @intFromEnum(d[1]), d[2], d[3]);
    return policy;
}

test "an empty policy reports every facility undeclared" {
    const policy: Policy = .{};
    try std.testing.expectEqual(Admission.undeclared, policy.admitHttp(try std.Uri.parse("https://example.com/")));
    try std.testing.expectEqual(Admission.undeclared, policy.admitUdpBind(4000));
    try std.testing.expectEqual(Admission.undeclared, policy.admitUdpPeer(0x7f000001, 4000));
    try std.testing.expectEqual(Admission.undeclared, policy.admitCommand("git"));
    try std.testing.expectEqual(Admission.undeclared, policy.admitEnv("HOME"));
    try std.testing.expectEqual(Admission.undeclared, policy.admitClipboard(false));
    try std.testing.expectEqual(Admission.undeclared, policy.admitClipboard(true));
    try std.testing.expectEqual(Admission.undeclared, policy.admitPath("save.json", false));
    try std.testing.expectEqual(Admission.undeclared, policy.admitWorkingDirectory(false));
}

test "http origins match scheme, host, and port exactly" {
    const policy = try testPolicy(&.{.{ .http_origin, .read_only, 0, "https://API.Example.com" }});
    try std.testing.expectEqual(Admission.allow, policy.admitHttp(try std.Uri.parse("https://api.example.com/v1?q=1")));
    try std.testing.expectEqual(Admission.allow, policy.admitHttp(try std.Uri.parse("https://api.example.com:443/")));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitHttp(try std.Uri.parse("http://api.example.com/")));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitHttp(try std.Uri.parse("https://api.example.com:8443/")));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitHttp(try std.Uri.parse("https://evil.example.com/")));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitHttp(try std.Uri.parse("https://api.example.com.evil.net/")));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitHttp(try std.Uri.parse("ftp://api.example.com/")));
}

test "http_any admits any http or https target and nothing else" {
    const policy = try testPolicy(&.{.{ .http_any, .read_only, 0, "" }});
    try std.testing.expectEqual(Admission.allow, policy.admitHttp(try std.Uri.parse("http://127.0.0.1:8080/x")));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitHttp(try std.Uri.parse("file:///etc/passwd")));
}

test "origins with a path, query, or credentials are refused at startup" {
    var policy: Policy = .{};
    const bad = [_][]const u8{ "https://example.com/api", "https://u:p@example.com", "https://example.com?x", "example.com", "ftp://example.com", "https://" };
    for (bad) |origin| {
        try std.testing.expectError(error.InvalidOrigin, policy.add(@intFromEnum(Kind.http_origin), 0, 0, origin));
    }
    try policy.add(@intFromEnum(Kind.http_origin), 0, 0, "http://localhost:8080/");
    try std.testing.expectEqual(Admission.allow, policy.admitHttp(try std.Uri.parse("http://localhost:8080/path")));
}

test "udp binds and peers are scoped separately" {
    const policy = try testPolicy(&.{
        .{ .udp_bind, .read_only, 40000, "" },
        .{ .udp_peer, .read_only, 40001, "127.0.0.1" },
    });
    try std.testing.expectEqual(Admission.allow, policy.admitUdpBind(40000));
    try std.testing.expectEqual(Admission.allow, policy.admitUdpBind(0));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitUdpBind(40002));
    try std.testing.expectEqual(Admission.allow, policy.admitUdpPeer(0x7f000001, 40001));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitUdpPeer(0x7f000001, 40000));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitUdpPeer(0x0a000001, 40001));
}

test "an ephemeral bind needs a peer or udp_any, not just any udp declaration" {
    const binds_only = try testPolicy(&.{.{ .udp_bind, .read_only, 40000, "" }});
    try std.testing.expectEqual(Admission.out_of_scope, binds_only.admitUdpBind(0));
    const any = try testPolicy(&.{.{ .udp_any, .read_only, 0, "" }});
    try std.testing.expectEqual(Admission.allow, any.admitUdpBind(0));
    try std.testing.expectEqual(Admission.allow, any.admitUdpPeer(0x08080808, 53));
}

test "udp declarations are validated" {
    var policy: Policy = .{};
    try std.testing.expectError(error.InvalidPort, policy.add(@intFromEnum(Kind.udp_bind), 0, 0, ""));
    try std.testing.expectError(error.InvalidPeer, policy.add(@intFromEnum(Kind.udp_peer), 0, 9, "localhost"));
    try std.testing.expectError(error.InvalidPeer, policy.add(@intFromEnum(Kind.udp_peer), 0, 9, "010.0.0.1"));
}

test "commands and environment variables match exactly" {
    const policy = try testPolicy(&.{
        .{ .command, .read_only, 0, "git" },
        .{ .env_var, .read_only, 0, "GITHUB_TOKEN" },
    });
    try std.testing.expectEqual(Admission.allow, policy.admitCommand("git"));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitCommand("/tmp/git"));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitCommand("sh"));
    try std.testing.expectEqual(Admission.allow, policy.admitEnv("GITHUB_TOKEN"));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitEnv("HOME"));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitEnv("github_token"));
}

test "clipboard reads and writes are declared independently" {
    const read_only = try testPolicy(&.{.{ .clipboard_read, .read_only, 0, "" }});
    try std.testing.expectEqual(Admission.allow, read_only.admitClipboard(false));
    try std.testing.expectEqual(Admission.undeclared, read_only.admitClipboard(true));
}

test "the working directory covers relative paths without parent components" {
    const policy = try testPolicy(&.{.{ .working_directory, .read_only, 0, "" }});
    try std.testing.expectEqual(Admission.allow, policy.admitPath("assets/logo.png", false));
    try std.testing.expectEqual(Admission.allow, policy.admitWorkingDirectory(false));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitPath("assets/logo.png", true));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitWorkingDirectory(true));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitPath("../secret", false));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitPath("assets/../../secret", false));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitPath("/etc/passwd", false));
}

test "directories cover what lies beneath them by component" {
    const policy = try testPolicy(&.{
        .{ .directory, .read_write, 0, "/srv/data/" },
        .{ .directory, .read_only, 0, "saves" },
    });
    try std.testing.expectEqual(Admission.allow, policy.admitPath("/srv/data/a.txt", true));
    try std.testing.expectEqual(Admission.allow, policy.admitPath("/srv/data", false));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitPath("/srv/database/a.txt", false));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitPath("/srv/data/../etc", false));
    try std.testing.expectEqual(Admission.allow, policy.admitPath("./saves/slot1.json", false));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitPath("saves/slot1.json", true));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitPath("other/slot1.json", false));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitWorkingDirectory(false));
}

test "files_anywhere covers every path in its mode" {
    const policy = try testPolicy(&.{.{ .files_anywhere, .read_only, 0, "" }});
    try std.testing.expectEqual(Admission.allow, policy.admitPath("../x", false));
    try std.testing.expectEqual(Admission.allow, policy.admitPath("/etc/hosts", false));
    try std.testing.expectEqual(Admission.out_of_scope, policy.admitPath("/tmp/x", true));
}

test "directory declarations are validated" {
    var policy: Policy = .{};
    for ([_][]const u8{ "", "../up", "a/../b", "/", "C:\\" }) |dir| {
        try std.testing.expectError(error.InvalidDirectory, policy.add(@intFromEnum(Kind.directory), 0, 0, dir));
    }
    try std.testing.expectError(error.UnknownMode, policy.add(@intFromEnum(Kind.directory), 7, 0, "ok"));
    try std.testing.expectError(error.UnknownKind, policy.add(200, 0, 0, ""));
}

test "the table is bounded" {
    var policy: Policy = .{};
    for (0..capacity) |_| try policy.add(@intFromEnum(Kind.clipboard_read), 0, 0, "");
    try std.testing.expectError(error.TooManyDeclarations, policy.add(@intFromEnum(Kind.clipboard_read), 0, 0, ""));
    var long: Policy = .{};
    const big = [_]u8{'a'} ** 4096;
    for (0..4) |_| try long.add(@intFromEnum(Kind.command), 0, 0, &big);
    try std.testing.expectError(error.DeclarationTextTooLong, long.add(@intFromEnum(Kind.command), 0, 0, "x"));
}

test "app ids are one safe path component" {
    var policy: Policy = .{};
    try policy.setAppId("dev.roc-ray.sqlite_scores");
    try std.testing.expectEqualStrings("dev.roc-ray.sqlite_scores", policy.appId().?);
    for ([_][]const u8{ ".hidden", "-x", "a/b", "a..b", "a b", "a\\b" }) |id| {
        try std.testing.expectError(error.InvalidAppId, policy.setAppId(id));
    }
    try policy.setAppId("");
    try std.testing.expect(policy.appId() == null);
}
