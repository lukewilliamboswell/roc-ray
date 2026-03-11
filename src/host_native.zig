///! Platform host for roc-ray using the raylib graphics library.
const std = @import("std");
const builtin = @import("builtin");
const builtins = @import("builtins");

// Import types (includes Roc ABI types and safe types)
const types = @import("types.zig");

// Import generated platform ABI (use for hosted function arg/ret types)
const abi = @import("roc_platform_abi.zig");

// Import FFI conversion utilities
const ffi = @import("roc_ffi.zig");

// Import backend
const raylib = @import("backend_raylib.zig");

// Import simulation recording/replay module
const sim = @import("sim.zig");

// Import replay UI overlay
const overlay = @import("overlay_native.zig");

// Type aliases for Roc ABI
const RocBox = types.RocBox;
const RocHostState = types.InputState.FFI;
const Try_BoxModel_I32 = types.Try_BoxModel_I32;
const RenderArgs = types.RenderArgs;
const RocOps = types.RocOps;
const HostedFn = types.HostedFn;
const roc__init_for_host = types.roc__init_for_host;
const roc__render_for_host = types.roc__render_for_host;

// Access raw raylib binding through backend (for cases not yet abstracted)
const rl = raylib.rl;

const TRACE_HOST = false;

/// Global flag to track if dbg or expect_failed was called.
/// If set, program exits with non-zero code to prevent accidental commits.
var debug_or_expect_called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Host environment for native builds.
const HostEnv = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    stdin_reader: std.fs.File.Reader,
    sim_state: ?*sim.SimState = null,

    pub fn allocator(self: *@This()) std.mem.Allocator {
        return self.gpa.allocator();
    }
};

/// Extract allocator from HostEnv for RocMemory callbacks.
fn getAllocatorFromEnv(env: *anyopaque) std.mem.Allocator {
    const host: *HostEnv = @ptrCast(@alignCast(env));
    return host.allocator();
}

/// OOM handler for native host - prints error and exits.
fn nativeOOM() noreturn {
    const stderr: std.fs.File = .stderr();
    stderr.writeAll("\x1b[31mHost error:\x1b[0m allocation failed, out of memory\n") catch {};
    std.process.exit(1);
}

/// Memory management callbacks using shared RocMemory implementation.
const NativeMemory = ffi.RocMemory(.{
    .getAllocator = &getAllocatorFromEnv,
    .onOOM = &nativeOOM,
});

/// Debug/expect/crash callbacks with flag tracking.
fn getDebugFlag() *std.atomic.Value(bool) {
    return &debug_or_expect_called;
}

const NativeCallbacks = ffi.RocCallbacks(getDebugFlag);


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

fn hostedDrawBeginFrame(ops: *types.RocOps, _: *anyopaque, _: *anyopaque) void {
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(.{ .BeginFrame = {} }) catch {};
        if (s.mode == .Test) return; // Skip actual draw in headless test mode
    }

    raylib.beginDrawing();
}

fn hostedDrawCircle(ops: *types.RocOps, _: *anyopaque, args: *const abi.DrawCircleArgs) void {
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    const circle = types.Circle{
        .center = .{ .x = args.center.x, .y = args.center.y },
        .radius = args.radius,
        .color = types.Color.fromU8(@intFromEnum(args.color)),
    };

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(sim.DrawCommand.circle(circle)) catch {};
        if (s.mode == .Test) return;
    }

    raylib.drawCircle(circle);
}

fn hostedDrawCircleGradient(ops: *types.RocOps, _: *anyopaque, args: *const abi.DrawCircle_gradientArgs) void {
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    const cg = types.CircleGradient{
        .center = .{ .x = args.center.x, .y = args.center.y },
        .radius = args.radius,
        .color_inner = types.Color.fromU8(@intFromEnum(args.color_inner)),
        .color_outer = types.Color.fromU8(@intFromEnum(args.color_outer)),
    };

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(sim.DrawCommand.circleGradient(cg)) catch {};
        if (s.mode == .Test) return;
    }

    raylib.drawCircleGradient(cg);
}

fn hostedDrawClear(ops: *types.RocOps, _: *anyopaque, args: *const abi.DrawClearArgs) void {
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    const color = types.Color.fromU8(@intFromEnum(args.arg0));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(sim.DrawCommand.clear(color)) catch {};
        if (s.mode == .Test) return;
    }

    raylib.clearBackground(color);
}

fn hostedDrawEndFrame(ops: *types.RocOps, _: *anyopaque, _: *anyopaque) void {
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(.{ .EndFrame = {} }) catch {};
        if (s.mode == .Test) return;
    }

    // Show FPS counter in debug builds
    if (builtin.mode == .Debug) {
        raylib.drawFps(10, 10);
    }

    raylib.endDrawing();
}

fn hostedDrawLine(ops: *types.RocOps, _: *anyopaque, args: *const abi.DrawLineArgs) void {
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    const line = types.Line{
        .start = .{ .x = args.start.x, .y = args.start.y },
        .end = .{ .x = args.end.x, .y = args.end.y },
        .color = types.Color.fromU8(@intFromEnum(args.color)),
    };

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(sim.DrawCommand.line(line)) catch {};
        if (s.mode == .Test) return;
    }

    raylib.drawLine(line);
}

fn hostedDrawRectangle(ops: *types.RocOps, _: *anyopaque, args: *const abi.DrawRectangleArgs) void {
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    const rect = types.Rectangle{
        .x = args.x,
        .y = args.y,
        .width = args.width,
        .height = args.height,
        .color = types.Color.fromU8(@intFromEnum(args.color)),
    };

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(sim.DrawCommand.rectangle(rect)) catch {};
        if (s.mode == .Test) return;
    }

    raylib.drawRectangle(rect);
}

fn hostedDrawRectangleGradientH(ops: *types.RocOps, _: *anyopaque, args: *const abi.DrawRectangle_gradient_hArgs) void {
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    const rg = types.RectangleGradientH{
        .x = args.x,
        .y = args.y,
        .width = args.width,
        .height = args.height,
        .color_left = types.Color.fromU8(@intFromEnum(args.color_left)),
        .color_right = types.Color.fromU8(@intFromEnum(args.color_right)),
    };

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(sim.DrawCommand.rectangleGradientH(rg)) catch {};
        if (s.mode == .Test) return;
    }

    raylib.drawRectangleGradientH(rg);
}

fn hostedDrawRectangleGradientV(ops: *types.RocOps, _: *anyopaque, args: *const abi.DrawRectangle_gradient_vArgs) void {
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    const rg = types.RectangleGradientV{
        .x = args.x,
        .y = args.y,
        .width = args.width,
        .height = args.height,
        .color_top = types.Color.fromU8(@intFromEnum(args.color_top)),
        .color_bottom = types.Color.fromU8(@intFromEnum(args.color_bottom)),
    };

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(sim.DrawCommand.rectangleGradientV(rg)) catch {};
        if (s.mode == .Test) return;
    }

    raylib.drawRectangleGradientV(rg);
}

fn hostedDrawText(ops: *types.RocOps, _: *anyopaque, args: *const abi.DrawTextArgs) void {
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    const text_slice = args.text.asSlice();

    // Record output if simulation active
    if (host.sim_state) |s| {
        // Use dedicated text recording that handles Test mode properly
        s.recordTextOutput(text_slice, args.pos.x, args.pos.y, args.size, @intFromEnum(args.color)) catch {};
        if (s.mode == .Test) return;
    }

    // raylib expects null-terminated string, use stack buffer for small strings
    var buf: [256:0]u8 = undefined;
    if (text_slice.len < buf.len) {
        @memcpy(buf[0..text_slice.len], text_slice);
        buf[text_slice.len] = 0;
        raylib.drawTextZ(buf[0..text_slice.len :0], @intFromFloat(args.pos.x), @intFromFloat(args.pos.y), args.size, types.Color.fromU8(@intFromEnum(args.color)));
    }
}

/// Global flag for deferred exit request (exit after current frame completes)
var exit_requested: ?i64 = null;

fn hostedReadEnvWindows(_: *RocOps, result: *types.Try_Str_NotFound, _: *const abi.HostRead_envArgs) void {
    // Windows doesn't link libc, so env var reading is not yet supported
    // TODO: Use native Windows API (GetEnvironmentVariableW) in the future
    result.* = types.Try_Str_NotFound.notFound();
}

fn hostedReadEnvPosix(ops: *RocOps, result: *types.Try_Str_NotFound, args: *const abi.HostRead_envArgs) void {
    const key = args.arg1.asSlice();

    // On POSIX systems, use std.posix.getenv (works after environ initialization)
    const value = std.posix.getenv(key);

    if (value) |v| {
        // Create RocStr from the value
        result.* = types.Try_Str_NotFound.ok(types.RocStr.fromSlice(v, ops));
    } else {
        result.* = types.Try_Str_NotFound.notFound();
    }
}

fn hostedExit(_: *types.RocOps, _: *anyopaque, args: *const abi.HostExitArgs) void {
    exit_requested = @as(i64, args.arg0);
}

fn hostedGetScreenSize(_: *types.RocOps, result: *abi.HostGet_screen_sizeRetRecord, _: *anyopaque) void {
    result.* = .{ .height = raylib.getScreenHeight(), .width = raylib.getScreenWidth() };
}

fn hostedSetScreenSize(_: *types.RocOps, result: *abi.Try(void, *anyopaque), args: *const abi.HostSet_screen_sizeArgs) void {
    raylib.setWindowSize(@intFromFloat(args.width), @intFromFloat(args.height));
    result.tag = .Ok;
}

fn hostedSetTargetFps(_: *types.RocOps, _: *anyopaque, args: *const abi.HostSet_target_fpsArgs) void {
    raylib.setTargetFps(args.arg0);
}

/// Array of hosted function pointers, sorted alphabetically by fully-qualified name.
/// All functions use wrapHostedFn for type-safe pointer casting.
const hosted_function_ptrs = [_]HostedFn{
    ffi.wrapHostedFn(hostedDrawBeginFrame), // Draw.begin_frame! (0)
    ffi.wrapHostedFn(hostedDrawCircle), // Draw.circle! (1)
    ffi.wrapHostedFn(hostedDrawCircleGradient), // Draw.circle_gradient! (2)
    ffi.wrapHostedFn(hostedDrawClear), // Draw.clear! (3)
    ffi.wrapHostedFn(hostedDrawEndFrame), // Draw.end_frame! (4)
    ffi.wrapHostedFn(hostedDrawLine), // Draw.line! (5)
    ffi.wrapHostedFn(hostedDrawRectangle), // Draw.rectangle! (6)
    ffi.wrapHostedFn(hostedDrawRectangleGradientH), // Draw.rectangle_gradient_h! (7)
    ffi.wrapHostedFn(hostedDrawRectangleGradientV), // Draw.rectangle_gradient_v! (8)
    ffi.wrapHostedFn(hostedDrawText), // Draw.text! (9)
    ffi.wrapHostedFn(hostedExit), // Host.exit! (10)
    ffi.wrapHostedFn(hostedGetScreenSize), // Host.get_screen_size! (11)
    if (builtin.os.tag == .windows) ffi.wrapHostedFn(hostedReadEnvWindows) else ffi.wrapHostedFn(hostedReadEnvPosix), // Host.read_env! (12)
    ffi.wrapHostedFn(hostedSetScreenSize), // Host.set_screen_size! (13)
    ffi.wrapHostedFn(hostedSetTargetFps), // Host.set_target_fps! (14)
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
    // Initialize std.os.environ on Linux.
    // Roc links with -nostdlib, so glibc's __libc_start_main (which normally
    // initializes environ) doesn't run. We manually extract envp from the stack
    // where the kernel placed it: [argc, argv..., NULL, envp..., NULL, auxv...]
    if (comptime builtin.os.tag == .linux) {
        const envp_ptr: [*][*:0]u8 = @ptrCast(argv + argc + 1);
        var envp_len: usize = 0;
        while (@intFromPtr(envp_ptr[envp_len]) != 0) : (envp_len += 1) {}
        std.os.environ = envp_ptr[0..envp_len];
    }

    var stdin_buffer: [4096]u8 = undefined;
    var host_env: HostEnv = .{
        .gpa = std.heap.GeneralPurposeAllocator(.{}){},
        .stdin_reader = std.fs.File.stdin().reader(&stdin_buffer),
    };
    defer {
        const leak_status = host_env.gpa.deinit();
        if (leak_status == .leak) {
            std.log.warn("Memory leak detected", .{});
        }
    }

    // Initialize simulation state from environment variables
    var sim_state = sim.initFromEnv(host_env.allocator()) catch |err| {
        std.debug.print("Failed to initialize simulation: {}\n", .{err});
        return 1;
    };
    host_env.sim_state = &sim_state;

    // Determine if we're in headless mode (Test) or replay-only mode (Replay)
    const headless = sim_state.mode == .Test;
    const replay_only = sim_state.mode == .Replay;

    // Create the RocOps struct
    var roc_ops = RocOps{
        .env = @as(*anyopaque, @ptrCast(&host_env)),
        .roc_alloc = NativeMemory.alloc,
        .roc_dealloc = NativeMemory.dealloc,
        .roc_realloc = NativeMemory.realloc,
        .roc_dbg = NativeCallbacks.dbg,
        .roc_expect_failed = NativeCallbacks.expectFailed,
        .roc_crashed = NativeCallbacks.crashed,
        .hosted_fns = .{
            .count = hosted_function_ptrs.len,
            .fns = @constCast(&hosted_function_ptrs),
        },
    };

    // Keyboard state manager (handles RocList allocation and refcounting)
    // We incref before each pass to Roc, and Roc decrefs when it drops the old Host.
    var keys = types.Keys.init(&roc_ops);
    defer keys.decref();

    // argc/argv used above for environ initialization on Linux

    // Initialize raylib window (skip in headless test mode)
    const screen_width = 800;
    const screen_height = 600;
    if (!headless) {
        raylib.initWindow(screen_width, screen_height, "Roc + Raylib");
        raylib.setTargetFps(60);
    }
    defer if (!headless) raylib.closeWindow();

    // Timing for headless test mode
    var timer = std.time.Timer.start() catch null;
    var init_time_ns: u64 = 0;
    var render_time_ns: u64 = 0;

    // In replay-only mode, skip Roc initialization - we just play back recorded outputs
    var boxed_model: RocBox = null;
    if (!replay_only) {
        if (TRACE_HOST) {
            std.log.debug("[HOST] Calling roc__init_for_host...", .{});
        }

        var init_result: Try_BoxModel_I32 = undefined;
        // Create initial host state for init (frame 0, no input)
        keys.incref(); // Prevent Roc from freeing our list
        var init_state = types.InputState.FFI{
            .frame_count = 0,
            .keys = keys.list,
            .mouse_wheel = 0,
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_left = false,
            .mouse_right = false,
            .mouse_middle = false,
        };
        roc__init_for_host(&roc_ops, &init_result, @ptrCast(&init_state));

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
            // In test mode, report init failure properly
            if (headless) {
                std.fs.File.stderr().writeAll("[FAIL] init! returned error\n") catch {};
            }
            // Clean up sim state before exiting (other cleanup via defer)
            sim_state.deinit();
            // Ensure non-zero exit code (use 1 if err_code is 0 due to Roc wildcard match bug)
            const exit_code: c_int = if (err_code == 0) 1 else @intCast(err_code);
            return exit_code;
        }

        boxed_model = init_result.getModel();
    }

    if (!headless) {
        raylib.setTargetFps(240);
    }

    // Main render loop
    var exit_code: i32 = 0;
    var frame_count: u64 = 0;

    // Replay control state (using overlay module)
    var overlay_state = overlay.OverlayState{};

    while (true) {
        // Handle replay controls (only in visual replay mode)
        if (replay_only) {
            const action = overlay.handleInput(&overlay_state);
            if (action.quit) break;
            if (action.step_back) sim_state.stepBack();
            if (action.step_forward) sim_state.stepForward();
            if (action.jump_to_start) sim_state.jumpToStart();
            if (action.jump_to_end) sim_state.jumpToEnd();
        }

        // Check exit conditions
        if (!headless and raylib.windowShouldClose()) break;
        if (sim_state.mode == .Replay or sim_state.mode == .Test) {
            if (!sim_state.hasMoreFrames()) break;
        }

        // Build platform state for this frame
        var platform_state: RocHostState = undefined;

        if (sim_state.mode == .Replay or sim_state.mode == .Test) {
            // Use recorded inputs - copy keys from recorded state to the persistent list
            if (sim_state.currentFrame()) |frame| {
                const input_state = frame.inputs.toInputState();
                keys.update(&input_state.keys);
                keys.incref(); // Prevent Roc from freeing our list
                platform_state = .{
                    .frame_count = input_state.frame_count,
                    .keys = keys.list,
                    .mouse_wheel = input_state.mouse_wheel,
                    .mouse_x = input_state.mouse_x,
                    .mouse_y = input_state.mouse_y,
                    .mouse_left = input_state.mouse_left,
                    .mouse_middle = input_state.mouse_middle,
                    .mouse_right = input_state.mouse_right,
                };
            } else {
                break;
            }
        } else {
            // Capture real inputs from raylib
            raylib.updateKeyboardState();
            keys.update(raylib.getKeyState());
            keys.incref(); // Prevent Roc from freeing our list
            const mouse_pos = raylib.getMousePosition();
            platform_state = RocHostState{
                .frame_count = frame_count,
                .keys = keys.list,
                .mouse_left = raylib.isMouseButtonDown(.left),
                .mouse_middle = raylib.isMouseButtonDown(.middle),
                .mouse_right = raylib.isMouseButtonDown(.right),
                .mouse_wheel = raylib.getMouseWheelMove(),
                .mouse_x = mouse_pos.x,
                .mouse_y = mouse_pos.y,
            };
        }

        // Start frame recording (if in record mode)
        if (sim_state.mode == .Record) {
            sim_state.beginFrame(platform_state.toInputState()) catch {};
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
                        .BeginFrame => raylib.beginDrawing(),
                        .Clear => |c| raylib.clearBackground(types.Color.fromU8(c)),
                        .Circle => |c| raylib.drawCircle(c.toCircle()),
                        .CircleGradient => |cg| raylib.drawCircleGradient(cg.toCircleGradient()),
                        .Rectangle => |r| raylib.drawRectangle(r.toRectangle()),
                        .RectangleGradientH => |rg| raylib.drawRectangleGradientH(rg.toRectangleGradientH()),
                        .RectangleGradientV => |rg| raylib.drawRectangleGradientV(rg.toRectangleGradientV()),
                        .Line => |l| raylib.drawLine(l.toLine()),
                        .Text => |t| {
                            const text_content = sim_state.getText(t.text_offset, t.text_len);
                            var buf: [256:0]u8 = undefined;
                            if (text_content.len < buf.len) {
                                @memcpy(buf[0..text_content.len], text_content);
                                buf[text_content.len] = 0;
                                raylib.drawTextZ(buf[0..text_content.len :0], @intFromFloat(t.pos_x), @intFromFloat(t.pos_y), t.size, types.Color.fromU8(t.color));
                            }
                        },
                        .EndFrame => {
                            // Draw replay UI overlay before ending the frame
                            if (overlay_state.paused) {
                                overlay_state.update(raylib.getFrameTime());

                                if (overlay.isShowingInputs()) {
                                    overlay.drawInputsOverlay(
                                        &overlay_state,
                                        frame.inputs.toInputState(),
                                        screen_width,
                                        screen_height,
                                    );
                                } else {
                                    overlay.drawPausedOverlay(
                                        &overlay_state,
                                        sim_state.getFrameIndex(),
                                        sim_state.getTotalFrames(),
                                        screen_width,
                                        screen_height,
                                    );
                                }
                            }

                            raylib.endDrawing();
                        },
                    }
                }
            }
        } else {
            // Call Roc render with the platform state
            var render_args = RenderArgs{
                .model = boxed_model,
                .state = platform_state,
            };
            var render_result: Try_BoxModel_I32 = undefined;

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

            // Check for exit request (deferred exit after frame completes)
            if (exit_requested) |code| {
                exit_code = @intCast(code);
                break;
            }
        }

        // End frame in simulation
        if (replay_only) {
            // In replay mode, advance frame only when playing (not paused)
            if (!overlay_state.paused) {
                overlay_state.frame_accumulator += raylib.getFrameTime() * overlay_state.currentSpeed() * 60.0;
                if (overlay_state.frame_accumulator >= 1.0) {
                    sim_state.endFrame();
                    overlay_state.frame_accumulator -= 1.0;
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
        const msg = std.fmt.bufPrint(&buf, "[TIMING] init={d}ms render={d}ms total={d}ms ({d} frames, {d}us/frame)\n", .{
            init_time_ns / 1_000_000,
            render_time_ns / 1_000_000,
            total_time_ns / 1_000_000,
            frame_count,
            if (frame_count > 0) render_time_ns / frame_count / 1000 else 0,
        }) catch "[TIMING] error\n";
        stderr.writeAll(msg) catch {};
    }

    // Finish simulation (write file or report test results)
    sim_state.finish() catch |err| switch (err) {
        error.TestFailed => exit_code = 1,
        else => {},
    };

    // Clean up simulation state before leak check
    sim_state.deinit();

    // Clean up final model (always clean up if we have one, regardless of exit code)
    if (boxed_model) |model| {
        if (TRACE_HOST) {
            std.log.debug("[HOST] Decrementing refcount for final model box=0x{x}", .{@intFromPtr(model)});
        }
        builtins.utils.decrefDataPtrC(@ptrCast(model), @alignOf(usize), false, &roc_ops);
    }

    // If dbg or expect_failed was called, ensure non-zero exit code
    // to prevent accidental commits with debug statements or failing tests
    const was_debug_called = debug_or_expect_called.load(.acquire);
    if (was_debug_called and exit_code == 0) {
        return 1;
    }

    return exit_code;
}
