///! Platform host for roc-ray using the raylib graphics library.
const std = @import("std");
const builtin = @import("builtin");
const builtins = @import("builtins");

// Import types (includes Roc ABI types and safe types)
const types = @import("types.zig");

// Import FFI conversion utilities
const ffi = @import("roc_ffi.zig");

// Import backend
const raylib = @import("backend/raylib.zig");

// Import simulation recording/replay module
const sim = @import("sim.zig");

// Import replay UI overlay
const overlay = @import("overlay_native.zig");

// Type aliases for Roc ABI
const RocBox = types.RocBox;
const RocPlatformState = types.InputState.FFI;
const RocText = types.Text.FFI;
const Try_BoxModel_I64 = types.Try_BoxModel_I64;
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

/// Memory management callbacks using shared RocMemory implementation.
const NativeMemory = ffi.RocMemory(getAllocatorFromEnv);

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
fn hostedDrawBeginFrame(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    _ = args_ptr;
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(.{ .BeginFrame = {} }) catch {};
        if (s.mode == .Test) return; // Skip actual draw in headless test mode
    }

    raylib.beginDrawing();
}

fn hostedDrawCircle(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    const circle = ffi.circleFromRoc(args_ptr);
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(sim.DrawCommand.circle(circle)) catch {};
        if (s.mode == .Test) return;
    }

    raylib.drawCircle(circle);
}

fn hostedDrawCircleGradient(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    const cg = ffi.circleGradientFromRoc(args_ptr);
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(sim.DrawCommand.circleGradient(cg)) catch {};
        if (s.mode == .Test) return;
    }

    raylib.drawCircleGradient(cg);
}

fn hostedDrawClear(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    const color_discriminant: *const u8 = @ptrCast(args_ptr);
    const color = types.Color.fromU8Safe(color_discriminant.*);
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(sim.DrawCommand.clear(color)) catch {};
        if (s.mode == .Test) return;
    }

    raylib.clearBackground(color);
}

fn hostedDrawEndFrame(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    _ = args_ptr;
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(.{ .EndFrame = {} }) catch {};
        if (s.mode == .Test) return;
    }

    raylib.endDrawing();
}

fn hostedDrawLine(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    const line = ffi.lineFromRoc(args_ptr);
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(sim.DrawCommand.line(line)) catch {};
        if (s.mode == .Test) return;
    }

    raylib.drawLine(line);
}

fn hostedDrawRectangle(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    const rect = ffi.rectangleFromRoc(args_ptr);
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(sim.DrawCommand.rectangle(rect)) catch {};
        if (s.mode == .Test) return;
    }

    raylib.drawRectangle(rect);
}

fn hostedDrawRectangleGradientH(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    const rg = ffi.rectangleGradientHFromRoc(args_ptr);
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(sim.DrawCommand.rectangleGradientH(rg)) catch {};
        if (s.mode == .Test) return;
    }

    raylib.drawRectangleGradientH(rg);
}

fn hostedDrawRectangleGradientV(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ret_ptr;
    const rg = ffi.rectangleGradientVFromRoc(args_ptr);
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));

    // Record output if simulation active
    if (host.sim_state) |s| {
        s.recordOutput(sim.DrawCommand.rectangleGradientV(rg)) catch {};
        if (s.mode == .Test) return;
    }

    raylib.drawRectangleGradientV(rg);
}

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
        raylib.drawTextRaw(buf[0..text_slice.len :0], @intFromFloat(txt.pos.x), @intFromFloat(txt.pos.y), txt.size, raylib.colorToRl(types.Color.fromU8Safe(txt.color)));
    }
}

/// Array of hosted function pointers, sorted alphabetically by fully-qualified name
const hosted_function_ptrs = [_]HostedFn{
    hostedDrawBeginFrame, // Draw.begin_frame! (0)
    hostedDrawCircle, // Draw.circle! (1)
    hostedDrawCircleGradient, // Draw.circle_gradient! (2)
    hostedDrawClear, // Draw.clear! (3)
    hostedDrawEndFrame, // Draw.end_frame! (4)
    hostedDrawLine, // Draw.line! (5)
    hostedDrawRectangle, // Draw.rectangle! (6)
    hostedDrawRectangleGradientH, // Draw.rectangle_gradient_h! (7)
    hostedDrawRectangleGradientV, // Draw.rectangle_gradient_v! (8)
    hostedDrawText, // Draw.text! (9)
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
    var sim_state = sim.SimState.init(host_env.allocator());
    // Skip env var reading for now - causes segfault in Roc-built binary
    // var sim_state = sim.initFromEnv(host_env.allocator()) catch |err| {
    //     const stderr: std.fs.File = .stderr();
    //     var buf: [256]u8 = undefined;
    //     const msg = std.fmt.bufPrint(&buf, "Failed to initialize simulation: {}\n", .{err}) catch "Failed to initialize simulation\n";
    //     stderr.writeAll(msg) catch {};
    //     return 1;
    // };
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
        raylib.initWindow(screen_width, screen_height, "Roc + Raylib");
        raylib.setTargetFps(60);
    }
    defer if (!headless) raylib.closeWindow();

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
        var platform_state: RocPlatformState = undefined;

        if (sim_state.mode == .Replay or sim_state.mode == .Test) {
            // Use recorded inputs
            if (sim_state.currentFrame()) |frame| {
                platform_state = frame.inputs.toInputState().toFfi();
            } else {
                break;
            }
        } else {
            // Capture real inputs from raylib
            const mouse_pos = raylib.getMousePosition();
            platform_state = RocPlatformState{
                .frame_count = frame_count,
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
                        .Clear => |c| raylib.clearBackgroundRaw(raylib.colorToRl(types.Color.fromU8Safe(c))),
                        .Circle => |c| raylib.drawCircleRaw(
                            @intFromFloat(c.center.x),
                            @intFromFloat(c.center.y),
                            c.radius,
                            raylib.colorToRl(types.Color.fromU8Safe(c.color)),
                        ),
                        .CircleGradient => |cg| raylib.drawCircleGradient(cg.toCircleGradient()),
                        .Rectangle => |r| raylib.drawRectangleRaw(
                            @intFromFloat(r.x),
                            @intFromFloat(r.y),
                            @intFromFloat(r.width),
                            @intFromFloat(r.height),
                            raylib.colorToRl(types.Color.fromU8Safe(r.color)),
                        ),
                        .RectangleGradientH => |rg| raylib.drawRectangleGradientH(rg.toRectangleGradientH()),
                        .RectangleGradientV => |rg| raylib.drawRectangleGradientV(rg.toRectangleGradientV()),
                        .Line => |l| raylib.drawLineRaw(
                            @intFromFloat(l.start.x),
                            @intFromFloat(l.start.y),
                            @intFromFloat(l.end.x),
                            @intFromFloat(l.end.y),
                            raylib.colorToRl(types.Color.fromU8Safe(l.color)),
                        ),
                        .Text => |t| {
                            const text_content = sim_state.getText(t.text_offset, t.text_len);
                            var buf: [256:0]u8 = undefined;
                            if (text_content.len < buf.len) {
                                @memcpy(buf[0..text_content.len], text_content);
                                buf[text_content.len] = 0;
                                raylib.drawTextRaw(buf[0..text_content.len :0], @intFromFloat(t.pos_x), @intFromFloat(t.pos_y), t.size, raylib.colorToRl(types.Color.fromU8Safe(t.color)));
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
