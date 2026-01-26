///! Platform host for roc-ray - a Roc platform for raylib graphics.
///! This file is for NATIVE builds only. Web/WASM builds use host_web.zig.
const std = @import("std");
const builtin = @import("builtin");
const builtins = @import("builtins");

// Import shared Roc ABI types
const roc_types = @import("roc_types.zig");

// Import simulation recording/replay module
const sim = @import("sim.zig");
const RocStr = roc_types.RocStr;
const RocList = roc_types.RocList;
const RocBox = roc_types.RocBox;
const RocVector2 = roc_types.RocVector2;
const RocPlatformState = roc_types.RocPlatformState;
const RocRectangle = roc_types.RocRectangle;
const RocCircle = roc_types.RocCircle;
const RocLine = roc_types.RocLine;
const RocText = roc_types.RocText;
const Try_BoxModel_I64 = roc_types.Try_BoxModel_I64;
const RenderArgs = roc_types.RenderArgs;
const RocOps = roc_types.RocOps;
const HostedFn = roc_types.HostedFn;
const Color = roc_types.Color;
const roc__init_for_host = roc_types.roc__init_for_host;
const roc__render_for_host = roc_types.roc__render_for_host;

// Direct C interop with raylib
const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("rlgl.h");
});

const TRACE_ALLOCATIONS = false;
const TRACE_HOST = false;

/// Global flag to track if dbg or expect_failed was called.
/// If set, program exits with non-zero code to prevent accidental commits.
var debug_or_expect_called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Host environment for native builds
const HostEnv = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    stdin_reader: std.fs.File.Reader,
    sim_state: ?*sim.SimState = null,

    pub fn allocator(self: *@This()) std.mem.Allocator {
        return self.gpa.allocator();
    }
};

/// Roc allocation function with size-tracking metadata
fn rocAllocFn(roc_alloc: *builtins.host_abi.RocAlloc, env: *anyopaque) callconv(.c) void {
    const host: *HostEnv = @ptrCast(@alignCast(env));
    const allocator = host.allocator();

    const min_alignment: usize = @max(roc_alloc.alignment, @alignOf(usize));
    const align_enum = std.mem.Alignment.fromByteUnits(min_alignment);

    // Calculate additional bytes needed to store the size
    const size_storage_bytes = @max(roc_alloc.alignment, @alignOf(usize));
    const total_size = roc_alloc.length + size_storage_bytes;

    // Allocate memory including space for size metadata
    const result = allocator.rawAlloc(total_size, align_enum, @returnAddress());

    const base_ptr = result orelse {
        const stderr: std.fs.File = .stderr();
        stderr.writeAll("\x1b[31mHost error:\x1b[0m allocation failed, out of memory\n") catch {};
        std.process.exit(1);
    };

    // Store the total size (including metadata) right before the user data
    const size_ptr: *usize = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes - @sizeOf(usize));
    size_ptr.* = total_size;

    // Return pointer to the user data (after the size metadata)
    roc_alloc.answer = @ptrFromInt(@intFromPtr(base_ptr) + size_storage_bytes);

    if (TRACE_ALLOCATIONS) {
        std.log.debug("[ALLOC] ptr=0x{x} size={d} align={d}", .{ @intFromPtr(roc_alloc.answer), roc_alloc.length, roc_alloc.alignment });
    }
}

/// Roc deallocation function with size-tracking metadata
fn rocDeallocFn(roc_dealloc: *builtins.host_abi.RocDealloc, env: *anyopaque) callconv(.c) void {
    if (TRACE_ALLOCATIONS) {
        std.log.debug("[DEALLOC] ptr=0x{x} align={d}", .{ @intFromPtr(roc_dealloc.ptr), roc_dealloc.alignment });
    }

    const host: *HostEnv = @ptrCast(@alignCast(env));
    const allocator = host.allocator();

    // Calculate where the size metadata is stored
    const size_storage_bytes = @max(roc_dealloc.alignment, @alignOf(usize));
    const size_ptr: *const usize = @ptrFromInt(@intFromPtr(roc_dealloc.ptr) - @sizeOf(usize));

    // Read the total size from metadata
    const total_size = size_ptr.*;

    // Calculate the base pointer (start of actual allocation)
    const base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(roc_dealloc.ptr) - size_storage_bytes);

    // Calculate alignment
    const min_alignment: usize = @max(roc_dealloc.alignment, @alignOf(usize));
    const align_enum = std.mem.Alignment.fromByteUnits(min_alignment);

    // Free the memory (including the size metadata)
    const slice = @as([*]u8, @ptrCast(base_ptr))[0..total_size];
    allocator.rawFree(slice, align_enum, @returnAddress());
}

/// Roc reallocation function with size-tracking metadata
fn rocReallocFn(roc_realloc: *builtins.host_abi.RocRealloc, env: *anyopaque) callconv(.c) void {
    const host: *HostEnv = @ptrCast(@alignCast(env));
    const allocator = host.allocator();

    // Calculate alignment
    const min_alignment: usize = @max(roc_realloc.alignment, @alignOf(usize));
    const align_enum = std.mem.Alignment.fromByteUnits(min_alignment);

    // Calculate where the size metadata is stored for the old allocation
    const size_storage_bytes = min_alignment;
    const old_size_ptr: *const usize = @ptrFromInt(@intFromPtr(roc_realloc.answer) - @sizeOf(usize));

    // Read the old total size from metadata
    const old_total_size = old_size_ptr.*;

    // Calculate the old base pointer (start of actual allocation)
    const old_base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(roc_realloc.answer) - size_storage_bytes);

    // Calculate new total size needed
    const new_total_size = roc_realloc.new_length + size_storage_bytes;

    // Allocate new memory with proper alignment
    const new_base_ptr = allocator.rawAlloc(new_total_size, align_enum, @returnAddress()) orelse {
        const stderr: std.fs.File = .stderr();
        stderr.writeAll("\x1b[31mHost error:\x1b[0m reallocation failed, out of memory\n") catch {};
        std.process.exit(1);
    };

    // Copy old data to new allocation (excluding metadata, just user data)
    const old_user_data_size = old_total_size - size_storage_bytes;
    const copy_size = @min(old_user_data_size, roc_realloc.new_length);
    const new_user_ptr: [*]u8 = @ptrFromInt(@intFromPtr(new_base_ptr) + size_storage_bytes);
    const old_user_ptr: [*]const u8 = @ptrCast(roc_realloc.answer);
    @memcpy(new_user_ptr, old_user_ptr[0..copy_size]);

    // Free old allocation
    const old_slice = old_base_ptr[0..old_total_size];
    allocator.rawFree(old_slice, align_enum, @returnAddress());

    // Store the new total size in the metadata
    const new_size_ptr: *usize = @ptrFromInt(@intFromPtr(new_base_ptr) + size_storage_bytes - @sizeOf(usize));
    new_size_ptr.* = new_total_size;

    // Return pointer to the user data (after the size metadata)
    roc_realloc.answer = new_user_ptr;

    if (TRACE_ALLOCATIONS) {
        std.log.debug("[REALLOC] old=0x{x} new=0x{x} new_size={d}", .{ @intFromPtr(roc_realloc.answer), @intFromPtr(new_user_ptr), roc_realloc.new_length });
    }
}

/// Roc debug function
fn rocDbgFn(roc_dbg: *const builtins.host_abi.RocDbg, env: *anyopaque) callconv(.c) void {
    _ = env;
    debug_or_expect_called.store(true, .release);
    const message = roc_dbg.utf8_bytes[0..roc_dbg.len];
    const stderr: std.fs.File = .stderr();
    stderr.writeAll("\x1b[33mdbg:\x1b[0m ") catch {};
    stderr.writeAll(message) catch {};
    stderr.writeAll("\n") catch {};
}

/// Roc expect failed function
fn rocExpectFailedFn(roc_expect: *const builtins.host_abi.RocExpectFailed, env: *anyopaque) callconv(.c) void {
    _ = env;
    debug_or_expect_called.store(true, .release);
    const source_bytes = roc_expect.utf8_bytes[0..roc_expect.len];
    const trimmed = std.mem.trim(u8, source_bytes, " \t\n\r");
    const stderr: std.fs.File = .stderr();
    stderr.writeAll("\x1b[33mexpect failed:\x1b[0m ") catch {};
    stderr.writeAll(trimmed) catch {};
    stderr.writeAll("\n") catch {};
}

/// Roc crashed function
fn rocCrashedFn(roc_crashed: *const builtins.host_abi.RocCrashed, env: *anyopaque) callconv(.c) noreturn {
    _ = env;
    const message = roc_crashed.utf8_bytes[0..roc_crashed.len];
    const stderr: std.fs.File = .stderr();
    var buf: [256]u8 = undefined;
    var w = stderr.writer(&buf);
    w.interface.print("\n\x1b[31mRoc crashed:\x1b[0m {s}\n", .{message}) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}

/// Decrement the reference count of a RocBox
/// If the refcount reaches zero, the memory is freed
fn decrefRocBox(box: RocBox, roc_ops: *RocOps) void {
    const ptr: ?[*]u8 = @ptrCast(box);
    // Box alignment is pointer-width, elements are not refcounted at this level
    builtins.utils.decrefDataPtrC(ptr, @alignOf(usize), false, roc_ops);
}

// OS-specific entry point handling (not exported during tests)
comptime {
    if (!builtin.is_test) {
        // Export main for all platforms (including WASM/emscripten)
        @export(&main, .{ .name = "main" });

        // Windows MinGW/MSVCRT compatibility: export __main stub
        if (builtin.os.tag == .windows) {
            @export(&__main, .{ .name = "__main" });
        }
    }
}

// Windows MinGW/MSVCRT compatibility stub
// The C runtime on Windows calls __main from main for constructor initialization
fn __main() callconv(.c) void {}

// C compatible main for runtime
fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return platform_main(@intCast(argc), argv);
}

/// Convert Roc Color tag union discriminant to raylib Color
/// Tags sorted alphabetically: Black=0, Blue=1, DarkGray=2, Gray=3, Green=4,
/// LightGray=5, Orange=6, Pink=7, Purple=8, RayWhite=9, Red=10, White=11, Yellow=12
fn rocColorToRaylib(discriminant: u8) rl.Color {
    return switch (discriminant) {
        0 => rl.BLACK,
        1 => rl.BLUE,
        2 => rl.DARKGRAY,
        3 => rl.GRAY,
        4 => rl.GREEN,
        5 => rl.LIGHTGRAY,
        6 => rl.ORANGE,
        7 => rl.PINK,
        8 => rl.PURPLE,
        9 => rl.RAYWHITE,
        10 => rl.RED,
        11 => rl.WHITE,
        12 => rl.YELLOW,
        else => rl.MAGENTA, // Error fallback
    };
}

/// Hosted function: Draw.begin_frame! (index 0 alphabetically)
fn hostedDrawBeginFrame(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    _ = args_ptr;
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(.{ .BeginFrame = {} }) catch {};
        if (s.mode == .Test) return; // Skip actual draw in headless test mode
    }

    rl.BeginDrawing();
}

/// Hosted function: Draw.circle! (index 1 alphabetically)
fn hostedDrawCircle(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    const circle: *const RocCircle = @ptrCast(@alignCast(args_ptr));
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(.{ .Circle = .{
            .center_x = circle.center.x,
            .center_y = circle.center.y,
            .radius = circle.radius,
            .color = circle.color,
        } }) catch {};
        if (s.mode == .Test) return;
    }

    rl.DrawCircle(
        @intFromFloat(circle.center.x),
        @intFromFloat(circle.center.y),
        circle.radius,
        rocColorToRaylib(circle.color),
    );
}

/// Hosted function: Draw.clear! (index 2 alphabetically)
fn hostedDrawClear(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    const color_discriminant: *const u8 = @ptrCast(args_ptr);
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(.{ .Clear = color_discriminant.* }) catch {};
        if (s.mode == .Test) return;
    }

    rl.ClearBackground(rocColorToRaylib(color_discriminant.*));
}

/// Hosted function: Draw.end_frame! (index 3 alphabetically)
fn hostedDrawEndFrame(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    _ = args_ptr;
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(.{ .EndFrame = {} }) catch {};
        if (s.mode == .Test) return;
    }

    rl.EndDrawing();
}

/// Hosted function: Draw.line! (index 4 alphabetically)
fn hostedDrawLine(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    const line: *const RocLine = @ptrCast(@alignCast(args_ptr));
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(.{ .Line = .{
            .start_x = line.start.x,
            .start_y = line.start.y,
            .end_x = line.end.x,
            .end_y = line.end.y,
            .color = line.color,
        } }) catch {};
        if (s.mode == .Test) return;
    }

    rl.DrawLine(
        @intFromFloat(line.start.x),
        @intFromFloat(line.start.y),
        @intFromFloat(line.end.x),
        @intFromFloat(line.end.y),
        rocColorToRaylib(line.color),
    );
}

/// Hosted function: Draw.rectangle! (index 5 alphabetically)
fn hostedDrawRectangle(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    const rect: *const RocRectangle = @ptrCast(@alignCast(args_ptr));
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(.{ .Rectangle = .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
            .color = rect.color,
        } }) catch {};
        if (s.mode == .Test) return;
    }

    rl.DrawRectangle(
        @intFromFloat(rect.x),
        @intFromFloat(rect.y),
        @intFromFloat(rect.width),
        @intFromFloat(rect.height),
        rocColorToRaylib(rect.color),
    );
}

/// Hosted function: Draw.text! (index 6 alphabetically)
fn hostedDrawText(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    const txt: *const RocText = @ptrCast(@alignCast(args_ptr));
    const text_slice = txt.text.asSlice();
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        // Use dedicated text recording that handles Test mode properly
        s.recordTextOutput(text_slice, txt.pos.x, txt.pos.y, txt.size, txt.color) catch {};
        if (s.mode == .Test) return;
    }

    // raylib expects null-terminated string, use stack buffer for small strings
    var buf: [256:0]u8 = undefined;
    if (text_slice.len < buf.len) {
        @memcpy(buf[0..text_slice.len], text_slice);
        buf[text_slice.len] = 0;
        rl.DrawText(buf[0..text_slice.len :0], @intFromFloat(txt.pos.x), @intFromFloat(txt.pos.y), txt.size, rocColorToRaylib(txt.color));
    }
}

/// Array of hosted function pointers, sorted alphabetically by fully-qualified name
/// Order: Draw.begin_frame!, Draw.circle!, Draw.clear!, Draw.end_frame!, Draw.line!, Draw.rectangle!, Draw.text!
const hosted_function_ptrs = [_]HostedFn{
    hostedDrawBeginFrame, // Draw.begin_frame! (0)
    hostedDrawCircle, // Draw.circle! (1)
    hostedDrawClear, // Draw.clear! (2)
    hostedDrawEndFrame, // Draw.end_frame! (3)
    hostedDrawLine, // Draw.line! (4)
    hostedDrawRectangle, // Draw.rectangle! (5)
    hostedDrawText, // Draw.text! (6)
};

/// Force-include all rlgl/GL functions that raylib might use at runtime.
/// This prevents emscripten from dead-code-eliminating GL functions that
/// are only called through certain raylib code paths.
/// The function is never actually called - just referenced at comptime.
fn forceIncludeGLFunctions() void {
    // Framebuffer functions (glBindFramebuffer, glGenFramebuffers, glDeleteFramebuffers, etc.)
    _ = rl.rlLoadFramebuffer;
    _ = rl.rlUnloadFramebuffer;
    _ = rl.rlFramebufferAttach;
    _ = rl.rlFramebufferComplete;
    _ = rl.rlEnableFramebuffer;
    _ = rl.rlDisableFramebuffer;

    // Renderbuffer functions (glBindRenderbuffer, glGenRenderbuffers, glRenderbufferStorage)
    _ = rl.rlLoadTextureDepth;

    // Blending functions (glBlendEquation, glBlendEquationSeparate, glBlendFuncSeparate)
    _ = rl.rlSetBlendMode;
    _ = rl.rlSetBlendFactors;
    _ = rl.rlSetBlendFactorsSeparate;
    _ = rl.rlEnableColorBlend;
    _ = rl.rlDisableColorBlend;

    // Texture functions (glTexParameterf, glTexSubImage2D, glGenerateMipmap)
    _ = rl.rlLoadTexture;
    _ = rl.rlLoadTextureCubemap;
    _ = rl.rlUnloadTexture;
    _ = rl.rlUpdateTexture;
    _ = rl.rlGenTextureMipmaps;
    _ = rl.rlReadTexturePixels;
    _ = rl.rlSetTexture;
    _ = rl.rlActiveTextureSlot;
    _ = rl.rlEnableTexture;
    _ = rl.rlDisableTexture;
    _ = rl.rlEnableTextureCubemap;
    _ = rl.rlDisableTextureCubemap;
    _ = rl.rlTextureParameters;

    // Shader uniform functions (glUniform1fv, glUniform2fv, glUniform3fv, glUniform4fv, etc.)
    _ = rl.rlSetUniform;
    _ = rl.rlSetUniformMatrix;
    _ = rl.rlSetUniformSampler;
    _ = rl.rlLoadShaderCode;
    _ = rl.rlLoadShaderProgram;
    _ = rl.rlUnloadShaderProgram;
    _ = rl.rlEnableShader;
    _ = rl.rlDisableShader;
    _ = rl.rlSetShader;
    _ = rl.rlGetLocationUniform;
    _ = rl.rlGetLocationAttrib;

    // Vertex attribute functions (glVertexAttrib1fv, glVertexAttrib2fv, etc.)
    _ = rl.rlSetVertexAttribute;
    _ = rl.rlSetVertexAttributeDefault;
    _ = rl.rlSetVertexAttributeDivisor;
    _ = rl.rlEnableVertexAttribute;
    _ = rl.rlDisableVertexAttribute;
    _ = rl.rlLoadVertexArray;
    _ = rl.rlLoadVertexBuffer;
    _ = rl.rlLoadVertexBufferElement;
    _ = rl.rlUnloadVertexArray;
    _ = rl.rlUnloadVertexBuffer;
    _ = rl.rlEnableVertexArray;
    _ = rl.rlDisableVertexArray;
    _ = rl.rlEnableVertexBuffer;
    _ = rl.rlDisableVertexBuffer;
    _ = rl.rlEnableVertexBufferElement;
    _ = rl.rlDisableVertexBufferElement;

    // Depth/stencil functions (glDepthMask)
    _ = rl.rlEnableDepthTest;
    _ = rl.rlDisableDepthTest;
    _ = rl.rlEnableDepthMask;
    _ = rl.rlDisableDepthMask;

    // Scissor functions (glScissor)
    _ = rl.rlEnableScissorTest;
    _ = rl.rlDisableScissorTest;
    _ = rl.rlScissor;

    // Line width (glLineWidth)
    _ = rl.rlSetLineWidth;
    _ = rl.rlGetLineWidth;

    // Error checking (glGetError)
    _ = rl.rlGetGlTextureFormats;
    _ = rl.rlGetVersion;

    // Render batch (uses various GL functions internally)
    _ = rl.rlLoadRenderBatch;
    _ = rl.rlUnloadRenderBatch;
    _ = rl.rlDrawRenderBatch;
    _ = rl.rlSetRenderBatchActive;
    _ = rl.rlDrawRenderBatchActive;
    _ = rl.rlCheckRenderBatchLimit;

    // Matrix functions
    _ = rl.rlSetMatrixProjection;
    _ = rl.rlSetMatrixModelview;
    _ = rl.rlGetMatrixModelview;
    _ = rl.rlGetMatrixProjection;
    _ = rl.rlGetMatrixTransform;
    _ = rl.rlGetMatrixProjectionStereo;
    _ = rl.rlGetMatrixViewOffsetStereo;

    // Drawing primitives (to ensure basic GL calls are included)
    _ = rl.rlLoadDrawCube;
    _ = rl.rlLoadDrawQuad;
}

// Force the compiler to include the GL/GLFW function references by exporting
// This prevents dead-code elimination during both Zig and emscripten compilation
export fn __force_gl_exports() void {
    forceIncludeGLFunctions();
}

/// Platform host entrypoint
fn platform_main(argc: usize, argv: [*][*:0]u8) c_int {
    var stdin_buffer: [4096]u8 = undefined;
    var host_env: HostEnv = .{
        .gpa = std.heap.GeneralPurposeAllocator(.{}){},
        .stdin_reader = std.fs.File.stdin().reader(&stdin_buffer),
    };

    // Initialize simulation state from environment variables
    var sim_state = sim.initFromEnv(host_env.allocator()) catch |err| {
        const stderr: std.fs.File = .stderr();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Failed to initialize simulation: {}\n", .{err}) catch "Failed to initialize simulation\n";
        stderr.writeAll(msg) catch {};
        return 1;
    };
    host_env.sim_state = &sim_state;

    // Determine if we're in headless mode (Test) or replay-only mode (Replay)
    const headless = sim_state.mode == .Test;
    const replay_only = sim_state.mode == .Replay;

    // Create the RocOps struct
    var roc_ops = RocOps{
        .env = @as(*anyopaque, @ptrCast(&host_env)),
        .roc_alloc = rocAllocFn,
        .roc_dealloc = rocDeallocFn,
        .roc_realloc = rocReallocFn,
        .roc_dbg = rocDbgFn,
        .roc_expect_failed = rocExpectFailedFn,
        .roc_crashed = rocCrashedFn,
        .hosted_fns = .{
            .count = hosted_function_ptrs.len,
            .fns = @constCast(&hosted_function_ptrs),
        },
    };

    // TODO: Build List(Str) from argc/argv when platform supports passing args to init
    _ = argc;
    _ = argv;

    // Initialize raylib window (skip in headless test mode)
    const screen_width = 800;
    const screen_height = 600;
    if (!headless) {
        rl.InitWindow(screen_width, screen_height, "Roc + Raylib");
        rl.SetTargetFPS(60);
    }
    defer if (!headless) rl.CloseWindow();

    // Timing for headless test mode
    var timer = std.time.Timer.start() catch null;
    var init_time_ns: u64 = 0;
    var render_time_ns: u64 = 0;

    // In replay-only mode, skip Roc initialization - we just play back recorded outputs
    var boxed_model: ?RocBox = null;
    if (!replay_only) {
        if (TRACE_HOST) {
            std.log.debug("[HOST] Calling roc__init_for_host...", .{});
        }

        var init_result: Try_BoxModel_I64 = undefined;
        var unit: struct {} = .{};
        roc__init_for_host(&roc_ops, &init_result, @ptrCast(&unit));

        if (timer) |*t| init_time_ns = t.lap();

        if (TRACE_HOST) {
            std.log.debug("[HOST] init returned, discriminant={d}", .{init_result.discriminant});
        }

        // Check if init failed
        if (init_result.isErr()) {
            const err_code = init_result.getErrCode();
            if (TRACE_HOST) {
                std.log.debug("[HOST] init returned Err({d})", .{err_code});
            }
            return @intCast(err_code);
        }

        boxed_model = init_result.getModel();
        if (TRACE_HOST) {
            std.log.debug("[HOST] init returned Ok, model box=0x{x}", .{@intFromPtr(boxed_model.?)});
        }
    }

    if (!headless) {
        rl.SetTargetFPS(240);
    }

    // Main render loop
    var exit_code: i32 = 0;
    var frame_count: u64 = 0;

    // Replay control state
    var replay_paused: bool = true; // Start paused
    const speed_presets = [_]f32{ 0.1, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0 };
    var speed_index: usize = 4; // Start at 1.0x (index 4)
    var frame_accumulator: f32 = 0.0; // For sub-frame timing at different speeds
    var blink_timer: f32 = 0.0; // For blinking "PAUSED" text

    while (true) {
        // Handle replay controls (only in visual replay mode)
        if (replay_only) {
            // Q to quit
            if (rl.IsKeyPressed(rl.KEY_Q)) break;

            // Space to toggle pause
            if (rl.IsKeyPressed(rl.KEY_SPACE)) {
                replay_paused = !replay_paused;
                frame_accumulator = 0.0;
            }

            // Arrow keys for stepping (only when paused)
            if (replay_paused) {
                if (rl.IsKeyPressed(rl.KEY_LEFT)) sim_state.stepBack();
                if (rl.IsKeyPressed(rl.KEY_RIGHT)) sim_state.stepForward();
            }

            // Home/End to jump
            if (rl.IsKeyPressed(rl.KEY_HOME)) sim_state.jumpToStart();
            if (rl.IsKeyPressed(rl.KEY_END)) sim_state.jumpToEnd();

            // Up/Down for speed control
            if (rl.IsKeyPressed(rl.KEY_UP) and speed_index + 1 < speed_presets.len) speed_index += 1;
            if (rl.IsKeyPressed(rl.KEY_DOWN) and speed_index > 0) speed_index -= 1;
        }

        // Check exit conditions
        if (!headless and rl.WindowShouldClose()) break;
        if (sim_state.mode == .Replay or sim_state.mode == .Test) {
            if (!sim_state.hasMoreFrames()) break;
        }

        // Build platform state for this frame
        var platform_state: RocPlatformState = undefined;

        if (sim_state.mode == .Replay or sim_state.mode == .Test) {
            // Use recorded inputs
            if (sim_state.currentFrame()) |frame| {
                platform_state = frame.inputs.toRocState();
            } else {
                break;
            }
        } else {
            // Capture real inputs from raylib
            const mouse_pos = rl.GetMousePosition();
            platform_state = RocPlatformState{
                .frame_count = frame_count,
                .mouse_left = rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT),
                .mouse_middle = rl.IsMouseButtonDown(rl.MOUSE_BUTTON_MIDDLE),
                .mouse_right = rl.IsMouseButtonDown(rl.MOUSE_BUTTON_RIGHT),
                .mouse_wheel = rl.GetMouseWheelMove(),
                .mouse_x = mouse_pos.x,
                .mouse_y = mouse_pos.y,
            };
        }

        // Start frame recording (if in record mode)
        if (sim_state.mode == .Record) {
            sim_state.beginFrame(sim.InputState.fromRocState(platform_state)) catch {};
        }

        if (TRACE_HOST and frame_count % 60 == 0) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[HOST] frame={d} mouse=({d:.1}, {d:.1}) left={}\n", .{
                frame_count,
                platform_state.mouse_x,
                platform_state.mouse_y,
                platform_state.mouse_left,
            }) catch "[HOST] print error\n";
            const dbg_stderr: std.fs.File = .stderr();
            dbg_stderr.writeAll(msg) catch {};
        }

        if (replay_only) {
            // In replay mode, play back recorded draw commands directly
            if (sim_state.currentFrame()) |frame| {
                for (frame.outputs.items) |cmd| {
                    switch (cmd) {
                        .BeginFrame => rl.BeginDrawing(),
                        .Clear => |c| rl.ClearBackground(rocColorToRaylib(c)),
                        .Circle => |c| rl.DrawCircle(
                            @intFromFloat(c.center_x),
                            @intFromFloat(c.center_y),
                            c.radius,
                            rocColorToRaylib(c.color),
                        ),
                        .Rectangle => |r| rl.DrawRectangle(
                            @intFromFloat(r.x),
                            @intFromFloat(r.y),
                            @intFromFloat(r.width),
                            @intFromFloat(r.height),
                            rocColorToRaylib(r.color),
                        ),
                        .Line => |l| rl.DrawLine(
                            @intFromFloat(l.start_x),
                            @intFromFloat(l.start_y),
                            @intFromFloat(l.end_x),
                            @intFromFloat(l.end_y),
                            rocColorToRaylib(l.color),
                        ),
                        .Text => |t| {
                            const text_content = sim_state.getText(t.text_offset, t.text_len);
                            var buf: [256:0]u8 = undefined;
                            if (text_content.len < buf.len) {
                                @memcpy(buf[0..text_content.len], text_content);
                                buf[text_content.len] = 0;
                                rl.DrawText(buf[0..text_content.len :0], @intFromFloat(t.pos_x), @intFromFloat(t.pos_y), t.size, rocColorToRaylib(t.color));
                            }
                        },
                        .EndFrame => {
                            // Draw replay UI overlay before ending the frame
                            if (replay_paused) {
                                blink_timer += rl.GetFrameTime();
                                // Alternate between white and dark gray every 0.5s
                                const color = if (@mod(blink_timer, 1.0) < 0.5)
                                    rl.WHITE
                                else
                                    rl.Color{ .r = 40, .g = 40, .b = 40, .a = 255 };

                                const info_font: c_int = 30;

                                if (rl.IsKeyDown(rl.KEY_F)) {
                                    // Show input state while F is held
                                    const inputs = frame.inputs;
                                    const base_y = @divTrunc(screen_height, 2) - 80;

                                    // Title
                                    const title = "INPUTS";
                                    const title_font: c_int = 60;
                                    const title_width = rl.MeasureText(title, title_font);
                                    rl.DrawText(title, @divTrunc(screen_width - title_width, 2), base_y, title_font, color);

                                    // Mouse position
                                    var line1_buf: [64:0]u8 = undefined;
                                    const line1 = std.fmt.bufPrint(&line1_buf, "Mouse: ({d:.1}, {d:.1})", .{ inputs.mouse_x, inputs.mouse_y }) catch "Mouse: ?";
                                    line1_buf[line1.len] = 0;
                                    const line1_width = rl.MeasureText(line1_buf[0..line1.len :0], info_font);
                                    rl.DrawText(line1_buf[0..line1.len :0], @divTrunc(screen_width - line1_width, 2), base_y + title_font + 15, info_font, color);

                                    // Mouse buttons
                                    var line2_buf: [64:0]u8 = undefined;
                                    const left_str: []const u8 = if (inputs.mouse_left != 0) "LEFT" else "left";
                                    const mid_str: []const u8 = if (inputs.mouse_middle != 0) "MID" else "mid";
                                    const right_str: []const u8 = if (inputs.mouse_right != 0) "RIGHT" else "right";
                                    const line2 = std.fmt.bufPrint(&line2_buf, "Buttons: [{s}] [{s}] [{s}]", .{ left_str, mid_str, right_str }) catch "Buttons: ?";
                                    line2_buf[line2.len] = 0;
                                    const line2_width = rl.MeasureText(line2_buf[0..line2.len :0], info_font);
                                    rl.DrawText(line2_buf[0..line2.len :0], @divTrunc(screen_width - line2_width, 2), base_y + title_font + 50, info_font, color);

                                    // Mouse wheel
                                    var line3_buf: [64:0]u8 = undefined;
                                    const line3 = std.fmt.bufPrint(&line3_buf, "Wheel: {d:.2}", .{inputs.mouse_wheel}) catch "Wheel: ?";
                                    line3_buf[line3.len] = 0;
                                    const line3_width = rl.MeasureText(line3_buf[0..line3.len :0], info_font);
                                    rl.DrawText(line3_buf[0..line3.len :0], @divTrunc(screen_width - line3_width, 2), base_y + title_font + 85, info_font, color);
                                } else {
                                    // Normal paused display
                                    // "PAUSED" text centered
                                    const paused_text = "PAUSED";
                                    const paused_font: c_int = 80;
                                    const paused_width = rl.MeasureText(paused_text, paused_font);
                                    const paused_x = @divTrunc(screen_width - paused_width, 2);
                                    const paused_y = @divTrunc(screen_height, 2) - 60;
                                    rl.DrawText(paused_text, paused_x, paused_y, paused_font, color);

                                    // Frame/Speed status centered below PAUSED
                                    var status_buf: [128:0]u8 = undefined;
                                    const status_slice = std.fmt.bufPrint(&status_buf, "Frame: {d}/{d}  Speed: {d:.2}x", .{
                                        sim_state.getFrameIndex() + 1,
                                        sim_state.getTotalFrames(),
                                        speed_presets[speed_index],
                                    }) catch "Frame: ?/?";
                                    status_buf[status_slice.len] = 0;
                                    const status_width = rl.MeasureText(status_buf[0..status_slice.len :0], info_font);
                                    const status_x = @divTrunc(screen_width - status_width, 2);
                                    const status_y = paused_y + paused_font + 10;
                                    rl.DrawText(status_buf[0..status_slice.len :0], status_x, status_y, info_font, color);

                                    // Hint to press F
                                    const hint_text = "PRESS F FOR INPUTS";
                                    const hint_font: c_int = 20;
                                    const hint_width = rl.MeasureText(hint_text, hint_font);
                                    const hint_x = @divTrunc(screen_width - hint_width, 2);
                                    const hint_y = status_y + info_font + 20;
                                    rl.DrawText(hint_text, hint_x, hint_y, hint_font, color);
                                }
                            }

                            rl.EndDrawing();
                        },
                    }
                }
            }
        } else {
            // Call Roc render with the platform state
            var render_args = RenderArgs{
                .model = boxed_model.?,
                .state = platform_state,
            };
            var render_result: Try_BoxModel_I64 = undefined;

            const render_start = if (timer) |*t| t.lap() else 0;
            _ = render_start;
            roc__render_for_host(&roc_ops, &render_result, &render_args);
            if (timer) |*t| render_time_ns += t.lap();

            // Check render result
            if (render_result.isErr()) {
                exit_code = @intCast(render_result.getErrCode());
                if (TRACE_HOST) {
                    std.log.debug("[HOST] render returned Err({d})", .{exit_code});
                }
                break;
            }

            // Update boxed_model for next iteration
            boxed_model = render_result.getModel();
        }

        // End frame in simulation
        if (replay_only) {
            // In replay mode, advance frame only when playing (not paused)
            if (!replay_paused) {
                frame_accumulator += rl.GetFrameTime() * speed_presets[speed_index] * 60.0;
                if (frame_accumulator >= 1.0) {
                    sim_state.endFrame();
                    frame_accumulator -= 1.0;
                }
            }
            // Note: frame_count not used in replay mode
        } else {
            sim_state.endFrame();
            frame_count += 1;
        }
    }

    // Print timing stats for headless test mode
    if (headless) {
        const total_time_ns = if (timer) |*t| t.read() else 0;
        const stderr: std.fs.File = .stderr();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[timing] init={d}ms render={d}ms total={d}ms ({d} frames, {d}us/frame)\n", .{
            init_time_ns / 1_000_000,
            render_time_ns / 1_000_000,
            total_time_ns / 1_000_000,
            frame_count,
            if (frame_count > 0) render_time_ns / frame_count / 1000 else 0,
        }) catch "[timing] error\n";
        stderr.writeAll(msg) catch {};
    }

    // Finish simulation (write file or report test results)
    sim_state.finish() catch |err| {
        if (err == error.TestFailed) {
            exit_code = 1;
        }
    };

    // Clean up simulation state before leak check
    sim_state.deinit();

    // Clean up final model (always clean up if we have one, regardless of exit code)
    if (boxed_model) |model| {
        if (TRACE_HOST) {
            std.log.debug("[HOST] Decrementing refcount for final model box=0x{x}", .{@intFromPtr(model)});
        }
        decrefRocBox(model, &roc_ops);
    }

    // Check for memory leaks before returning
    const leak_status = host_env.gpa.deinit();
    if (leak_status == .leak) {
        std.log.warn("Memory leak detected", .{});
    }

    // If dbg or expect_failed was called, ensure non-zero exit code
    // to prevent accidental commits with debug statements or failing tests
    const was_debug_called = debug_or_expect_called.load(.acquire);
    if (was_debug_called and exit_code == 0) {
        return 1;
    }

    return exit_code;
}

/// Build a RocList of RocStr from argc/argv
fn buildStrArgsList(argc: usize, argv: [*][*:0]u8, roc_ops: *RocOps) RocList {
    if (argc == 0) {
        return RocList.empty();
    }

    // Allocate list with proper refcount header using RocList.allocateExact
    const args_list = RocList.allocateExact(
        @alignOf(RocStr),
        argc,
        @sizeOf(RocStr),
        true, // elements are refcounted (RocStr)
        roc_ops,
    );

    const args_ptr: [*]RocStr = @ptrCast(@alignCast(args_list.bytes));

    // Build each argument string
    for (0..argc) |i| {
        const arg_cstr = argv[i];
        const arg_len = std.mem.len(arg_cstr);

        // RocStr.init takes a const pointer to read FROM and allocates internally
        args_ptr[i] = RocStr.init(arg_cstr, arg_len, roc_ops);
    }

    return args_list;
}
