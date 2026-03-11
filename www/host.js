/**
 * host.js - Zero-allocation JavaScript runtime for Roc WASM platform
 *
 * Reads command buffer from WASM memory and renders to Canvas 2D.
 * All TypedArray views are created once at init and reused every frame.
 */

// =============================================================================
// Constants - must match values in platform/host_web.zig
// =============================================================================

// Command type codes
export const CMD_RECT = 1;
export const CMD_CIRCLE = 2;
export const CMD_LINE = 3;
export const CMD_TEXT = 4;
export const CMD_CIRCLE_GRADIENT = 5;
export const CMD_RECT_GRADIENT_V = 6;
export const CMD_RECT_GRADIENT_H = 7;

// Buffer capacities
export const MAX_COMMANDS = 2048;
export const MAX_RECTS = 1024;
export const MAX_CIRCLES = 512;
export const MAX_LINES = 512;
export const MAX_TEXTS = 256;
export const MAX_STRING_BYTES = 8192;
export const MAX_CIRCLE_GRADIENTS = 256;
export const MAX_RECT_GRADIENTS = 256;

// Color palette (matches Roc's Color type - alphabetically sorted)
export const COLORS = [
    '#000000', // 0: Black
    '#0000ff', // 1: Blue
    '#505050', // 2: DarkGray
    '#808080', // 3: Gray
    '#00ff00', // 4: Green
    '#c0c0c0', // 5: LightGray
    '#ffa500', // 6: Orange
    '#ffc0cb', // 7: Pink
    '#800080', // 8: Purple
    '#f5f5f5', // 9: RayWhite
    '#ff0000', // 10: Red
    '#ffffff', // 11: White
    '#ffff00', // 12: Yellow
];

// =============================================================================
// Helper Functions (shared with test runner)
// =============================================================================

/**
 * Get all buffer offsets from WASM exports
 * @param {WebAssembly.Exports} wasm - WASM instance exports
 * @returns {Object} Offsets object
 */
export function getOffsets(wasm) {
    return {
        has_clear: wasm._get_offset_has_clear(),
        clear_color: wasm._get_offset_clear_color(),
        cmd_stream: wasm._get_offset_cmd_stream(),
        cmd_count: wasm._get_offset_cmd_count(),
        rect_count: wasm._get_offset_rect_count(),
        rect_x: wasm._get_offset_rect_x(),
        rect_y: wasm._get_offset_rect_y(),
        rect_w: wasm._get_offset_rect_w(),
        rect_h: wasm._get_offset_rect_h(),
        rect_color: wasm._get_offset_rect_color(),
        circle_count: wasm._get_offset_circle_count(),
        circle_x: wasm._get_offset_circle_x(),
        circle_y: wasm._get_offset_circle_y(),
        circle_radius: wasm._get_offset_circle_radius(),
        circle_color: wasm._get_offset_circle_color(),
        line_count: wasm._get_offset_line_count(),
        line_x1: wasm._get_offset_line_x1(),
        line_y1: wasm._get_offset_line_y1(),
        line_x2: wasm._get_offset_line_x2(),
        line_y2: wasm._get_offset_line_y2(),
        line_color: wasm._get_offset_line_color(),
        text_count: wasm._get_offset_text_count(),
        text_x: wasm._get_offset_text_x(),
        text_y: wasm._get_offset_text_y(),
        text_size: wasm._get_offset_text_size(),
        text_color: wasm._get_offset_text_color(),
        text_str_offset: wasm._get_offset_text_str_offset(),
        text_str_len: wasm._get_offset_text_str_len(),
        string_buffer: wasm._get_offset_string_buffer(),
        string_buffer_len: wasm._get_offset_string_buffer_len(),
        // Circle gradients
        circle_gradient_count: wasm._get_offset_circle_gradient_count(),
        circle_gradient_x: wasm._get_offset_circle_gradient_x(),
        circle_gradient_y: wasm._get_offset_circle_gradient_y(),
        circle_gradient_radius: wasm._get_offset_circle_gradient_radius(),
        circle_gradient_inner: wasm._get_offset_circle_gradient_inner(),
        circle_gradient_outer: wasm._get_offset_circle_gradient_outer(),
        // Rectangle gradients V
        rect_gradient_v_count: wasm._get_offset_rect_gradient_v_count(),
        rect_gradient_v_x: wasm._get_offset_rect_gradient_v_x(),
        rect_gradient_v_y: wasm._get_offset_rect_gradient_v_y(),
        rect_gradient_v_w: wasm._get_offset_rect_gradient_v_w(),
        rect_gradient_v_h: wasm._get_offset_rect_gradient_v_h(),
        rect_gradient_v_top: wasm._get_offset_rect_gradient_v_top(),
        rect_gradient_v_bottom: wasm._get_offset_rect_gradient_v_bottom(),
        // Rectangle gradients H
        rect_gradient_h_count: wasm._get_offset_rect_gradient_h_count(),
        rect_gradient_h_x: wasm._get_offset_rect_gradient_h_x(),
        rect_gradient_h_y: wasm._get_offset_rect_gradient_h_y(),
        rect_gradient_h_w: wasm._get_offset_rect_gradient_h_w(),
        rect_gradient_h_h: wasm._get_offset_rect_gradient_h_h(),
        rect_gradient_h_left: wasm._get_offset_rect_gradient_h_left(),
        rect_gradient_h_right: wasm._get_offset_rect_gradient_h_right(),
    };
}

/**
 * Create TypedArray views into WASM command buffer
 * @param {ArrayBuffer} buffer - WASM memory buffer
 * @param {number} basePtr - Command buffer pointer
 * @param {Object} offsets - Offsets from getOffsets()
 * @returns {Object} TypedArray views
 */
export function createBufferViews(buffer, basePtr, offsets) {
    return {
        cmdStream: new Uint16Array(buffer, basePtr + offsets.cmd_stream, MAX_COMMANDS),
        // Rectangles
        rectX: new Float32Array(buffer, basePtr + offsets.rect_x, MAX_RECTS),
        rectY: new Float32Array(buffer, basePtr + offsets.rect_y, MAX_RECTS),
        rectW: new Float32Array(buffer, basePtr + offsets.rect_w, MAX_RECTS),
        rectH: new Float32Array(buffer, basePtr + offsets.rect_h, MAX_RECTS),
        rectColor: new Uint8Array(buffer, basePtr + offsets.rect_color, MAX_RECTS),
        // Circles
        circleX: new Float32Array(buffer, basePtr + offsets.circle_x, MAX_CIRCLES),
        circleY: new Float32Array(buffer, basePtr + offsets.circle_y, MAX_CIRCLES),
        circleRadius: new Float32Array(buffer, basePtr + offsets.circle_radius, MAX_CIRCLES),
        circleColor: new Uint8Array(buffer, basePtr + offsets.circle_color, MAX_CIRCLES),
        // Lines
        lineX1: new Float32Array(buffer, basePtr + offsets.line_x1, MAX_LINES),
        lineY1: new Float32Array(buffer, basePtr + offsets.line_y1, MAX_LINES),
        lineX2: new Float32Array(buffer, basePtr + offsets.line_x2, MAX_LINES),
        lineY2: new Float32Array(buffer, basePtr + offsets.line_y2, MAX_LINES),
        lineColor: new Uint8Array(buffer, basePtr + offsets.line_color, MAX_LINES),
        // Text
        textX: new Float32Array(buffer, basePtr + offsets.text_x, MAX_TEXTS),
        textY: new Float32Array(buffer, basePtr + offsets.text_y, MAX_TEXTS),
        textSize: new Int32Array(buffer, basePtr + offsets.text_size, MAX_TEXTS),
        textColor: new Uint8Array(buffer, basePtr + offsets.text_color, MAX_TEXTS),
        textStrOffset: new Uint16Array(buffer, basePtr + offsets.text_str_offset, MAX_TEXTS),
        textStrLen: new Uint16Array(buffer, basePtr + offsets.text_str_len, MAX_TEXTS),
        stringBuffer: new Uint8Array(buffer, basePtr + offsets.string_buffer, MAX_STRING_BYTES),
        // Circle gradients
        circleGradientX: new Float32Array(buffer, basePtr + offsets.circle_gradient_x, MAX_CIRCLE_GRADIENTS),
        circleGradientY: new Float32Array(buffer, basePtr + offsets.circle_gradient_y, MAX_CIRCLE_GRADIENTS),
        circleGradientRadius: new Float32Array(buffer, basePtr + offsets.circle_gradient_radius, MAX_CIRCLE_GRADIENTS),
        circleGradientInner: new Uint8Array(buffer, basePtr + offsets.circle_gradient_inner, MAX_CIRCLE_GRADIENTS),
        circleGradientOuter: new Uint8Array(buffer, basePtr + offsets.circle_gradient_outer, MAX_CIRCLE_GRADIENTS),
        // Rectangle gradients V
        rectGradientVX: new Float32Array(buffer, basePtr + offsets.rect_gradient_v_x, MAX_RECT_GRADIENTS),
        rectGradientVY: new Float32Array(buffer, basePtr + offsets.rect_gradient_v_y, MAX_RECT_GRADIENTS),
        rectGradientVW: new Float32Array(buffer, basePtr + offsets.rect_gradient_v_w, MAX_RECT_GRADIENTS),
        rectGradientVH: new Float32Array(buffer, basePtr + offsets.rect_gradient_v_h, MAX_RECT_GRADIENTS),
        rectGradientVTop: new Uint8Array(buffer, basePtr + offsets.rect_gradient_v_top, MAX_RECT_GRADIENTS),
        rectGradientVBottom: new Uint8Array(buffer, basePtr + offsets.rect_gradient_v_bottom, MAX_RECT_GRADIENTS),
        // Rectangle gradients H
        rectGradientHX: new Float32Array(buffer, basePtr + offsets.rect_gradient_h_x, MAX_RECT_GRADIENTS),
        rectGradientHY: new Float32Array(buffer, basePtr + offsets.rect_gradient_h_y, MAX_RECT_GRADIENTS),
        rectGradientHW: new Float32Array(buffer, basePtr + offsets.rect_gradient_h_w, MAX_RECT_GRADIENTS),
        rectGradientHH: new Float32Array(buffer, basePtr + offsets.rect_gradient_h_h, MAX_RECT_GRADIENTS),
        rectGradientHLeft: new Uint8Array(buffer, basePtr + offsets.rect_gradient_h_left, MAX_RECT_GRADIENTS),
        rectGradientHRight: new Uint8Array(buffer, basePtr + offsets.rect_gradient_h_right, MAX_RECT_GRADIENTS),
    };
}

// =============================================================================
// Runtime State (browser only)
// =============================================================================

let memory = null;
let wasm = null;
let ctx = null;
let canvas = null;

// Input state
let mouseX = 0;
let mouseY = 0;
let mouseButtons = 0;
let mouseWheel = 0;

// Command buffer pointer and offsets
let cmdBufferPtr = 0;
let OFFSETS = {};

// Cached buffer views
let views = null;

// Text decoder (reused)
const decoder = new TextDecoder();

// Track current buffer to detect memory growth
let currentBuffer = null;

// =============================================================================
// WASM Imports
// =============================================================================

function js_console_log(ptr, len) {
    const msg = new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
    console.log('[roc]', msg);
}

function js_throw_error(ptr, len) {
    const msg = new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
    console.error('[roc_panic]', msg);
    throw new Error('[roc_panic] ' + msg);
}

// =============================================================================
// Browser Runtime
// =============================================================================

/**
 * Initialize the WASM module and canvas
 * @param {string} wasmPath - Path to the .wasm file
 * @param {string} canvasId - ID of the canvas element
 */
export async function init(wasmPath = 'app.wasm', canvasId = 'canvas') {
    canvas = document.getElementById(canvasId);
    if (!canvas) {
        throw new Error(`Canvas element '${canvasId}' not found`);
    }
    ctx = canvas.getContext('2d');

    setupMouseTracking();
    setupKeyboardTracking();

    console.log(`[host.js] Loading ${wasmPath}...`);

    const imports = {
        env: {
            js_console_log,
            js_throw_error,
        }
    };

    try {
        const response = await fetch(wasmPath);
        if (!response.ok) {
            throw new Error(`Failed to fetch ${wasmPath}: ${response.status}`);
        }
        const { instance } = await WebAssembly.instantiateStreaming(response, imports);
        wasm = instance.exports;
        memory = wasm.memory;

        console.log('[host.js] WASM loaded successfully');
        console.log('[host.js] Memory size:', memory.buffer.byteLength, 'bytes');
    } catch (e) {
        console.error('[host.js] Failed to load WASM:', e);
        throw e;
    }

    cmdBufferPtr = wasm._get_cmd_buffer_ptr();
    OFFSETS = getOffsets(wasm);
    console.log('[host.js] Buffer offsets loaded');

    console.log('[host.js] Initializing app...');
    try {
        wasm._init();
        console.log('[host.js] _init completed successfully');
    } catch (e) {
        console.error('[host.js] _init failed:', e);
        throw e;
    }

    views = createBufferViews(memory.buffer, cmdBufferPtr, OFFSETS);
    console.log('[host.js] Buffer views created');

    console.log('[host.js] Starting render loop');
    requestAnimationFrame(frame);
}

function setupMouseTracking() {
    canvas.addEventListener('mousemove', (e) => {
        const rect = canvas.getBoundingClientRect();
        mouseX = e.clientX - rect.left;
        mouseY = e.clientY - rect.top;
    });

    canvas.addEventListener('mousedown', (e) => {
        mouseButtons |= (1 << e.button);
        e.preventDefault();
    });

    canvas.addEventListener('mouseup', (e) => {
        mouseButtons &= ~(1 << e.button);
    });

    canvas.addEventListener('mouseleave', () => {
        mouseButtons = 0;
    });

    canvas.addEventListener('wheel', (e) => {
        mouseWheel = e.deltaY;
        e.preventDefault();
    }, { passive: false });

    canvas.addEventListener('contextmenu', (e) => e.preventDefault());
    canvas.style.userSelect = 'none';
}

// Map browser KeyboardEvent.code to raylib key codes
// Based on raylib's KEY_* constants
const KEY_CODE_MAP = {
    'Space': 32,
    'Quote': 39,
    'Comma': 44,
    'Minus': 45,
    'Period': 46,
    'Slash': 47,
    'Digit0': 48, 'Digit1': 49, 'Digit2': 50, 'Digit3': 51, 'Digit4': 52,
    'Digit5': 53, 'Digit6': 54, 'Digit7': 55, 'Digit8': 56, 'Digit9': 57,
    'Semicolon': 59,
    'Equal': 61,
    'KeyA': 65, 'KeyB': 66, 'KeyC': 67, 'KeyD': 68, 'KeyE': 69,
    'KeyF': 70, 'KeyG': 71, 'KeyH': 72, 'KeyI': 73, 'KeyJ': 74,
    'KeyK': 75, 'KeyL': 76, 'KeyM': 77, 'KeyN': 78, 'KeyO': 79,
    'KeyP': 80, 'KeyQ': 81, 'KeyR': 82, 'KeyS': 83, 'KeyT': 84,
    'KeyU': 85, 'KeyV': 86, 'KeyW': 87, 'KeyX': 88, 'KeyY': 89, 'KeyZ': 90,
    'BracketLeft': 91,
    'Backslash': 92,
    'BracketRight': 93,
    'Backquote': 96,
    'Escape': 256,
    'Enter': 257,
    'Tab': 258,
    'Backspace': 259,
    'Insert': 260,
    'Delete': 261,
    'ArrowRight': 262,
    'ArrowLeft': 263,
    'ArrowDown': 264,
    'ArrowUp': 265,
    'PageUp': 266,
    'PageDown': 267,
    'Home': 268,
    'End': 269,
    'CapsLock': 280,
    'ScrollLock': 281,
    'NumLock': 282,
    'PrintScreen': 283,
    'Pause': 284,
    'F1': 290, 'F2': 291, 'F3': 292, 'F4': 293, 'F5': 294, 'F6': 295,
    'F7': 296, 'F8': 297, 'F9': 298, 'F10': 299, 'F11': 300, 'F12': 301,
    'ShiftLeft': 340,
    'ControlLeft': 341,
    'AltLeft': 342,
    'MetaLeft': 343,
    'ShiftRight': 344,
    'ControlRight': 345,
    'AltRight': 346,
    'MetaRight': 347,
    'Numpad0': 320, 'Numpad1': 321, 'Numpad2': 322, 'Numpad3': 323, 'Numpad4': 324,
    'Numpad5': 325, 'Numpad6': 326, 'Numpad7': 327, 'Numpad8': 328, 'Numpad9': 329,
    'NumpadDecimal': 330,
    'NumpadDivide': 331,
    'NumpadMultiply': 332,
    'NumpadSubtract': 333,
    'NumpadAdd': 334,
    'NumpadEnter': 335,
    'NumpadEqual': 336,
    'ContextMenu': 348,
};

function setupKeyboardTracking() {
    // Track keyboard events globally (not just on canvas)
    window.addEventListener('keydown', (e) => {
        const keyCode = KEY_CODE_MAP[e.code];
        if (keyCode !== undefined && wasm && wasm._set_key_down) {
            wasm._set_key_down(keyCode);
        }
        // Prevent default for arrow keys, space, etc. to avoid page scrolling
        if (['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Space'].includes(e.code)) {
            e.preventDefault();
        }
    });

    window.addEventListener('keyup', (e) => {
        const keyCode = KEY_CODE_MAP[e.code];
        if (keyCode !== undefined && wasm && wasm._set_key_up) {
            wasm._set_key_up(keyCode);
        }
    });

    // Clear all keys when window loses focus (to avoid stuck keys)
    window.addEventListener('blur', () => {
        for (const keyCode of Object.values(KEY_CODE_MAP)) {
            if (wasm && wasm._set_key_up) {
                wasm._set_key_up(keyCode);
            }
        }
    });
}

function refreshBufferViews() {
    if (memory.buffer !== currentBuffer) {
        views = createBufferViews(memory.buffer, cmdBufferPtr, OFFSETS);
        currentBuffer = memory.buffer;
    }
}

function frame(timestamp) {
    wasm._frame(mouseX, mouseY, mouseButtons, mouseWheel);
    mouseWheel = 0;

    refreshBufferViews();
    render();

    requestAnimationFrame(frame);
}

// =============================================================================
// Memory Telemetry
// =============================================================================

/**
 * Get current memory allocation statistics from the WASM module.
 * Useful for detecting memory leaks - if liveAllocations grows over time,
 * there's likely a leak.
 *
 * @returns {Object} Memory statistics
 */
export function getMemoryStats() {
    if (!wasm) return null;

    const allocCount = Number(wasm._get_alloc_count());
    const deallocCount = Number(wasm._get_dealloc_count());
    const reallocCount = Number(wasm._get_realloc_count());
    const bytesAllocated = Number(wasm._get_bytes_allocated());
    const bytesFreed = Number(wasm._get_bytes_freed());

    return {
        allocCount,
        deallocCount,
        reallocCount,
        bytesAllocated,
        bytesFreed,
        liveAllocations: allocCount - deallocCount,
        liveBytes: bytesAllocated - bytesFreed,
        wasmMemoryBytes: memory ? memory.buffer.byteLength : 0,
    };
}

/**
 * Log memory statistics to console (convenience function)
 */
export function logMemoryStats() {
    const stats = getMemoryStats();
    if (!stats) {
        console.log('[memory] WASM not initialized');
        return;
    }
    console.log(`[memory] Live: ${stats.liveAllocations} allocations, ${stats.liveBytes} bytes`);
    console.log(`[memory] Total: ${stats.allocCount} allocs, ${stats.deallocCount} deallocs, ${stats.reallocCount} reallocs`);
    console.log(`[memory] Bytes: ${stats.bytesAllocated} allocated, ${stats.bytesFreed} freed`);
    console.log(`[memory] WASM memory: ${stats.wasmMemoryBytes} bytes`);
}

/**
 * Reset memory telemetry counters (useful for per-session tracking)
 */
export function resetMemoryStats() {
    if (wasm && wasm._reset_memory_telemetry) {
        wasm._reset_memory_telemetry();
    }
}

// =============================================================================
// Rendering
// =============================================================================

function render() {
    const view = new DataView(memory.buffer, cmdBufferPtr);

    const hasClear = view.getUint8(OFFSETS.has_clear) !== 0;
    if (hasClear) {
        const clearColorIdx = view.getUint8(OFFSETS.clear_color);
        ctx.fillStyle = COLORS[clearColorIdx] || '#000000';
        ctx.fillRect(0, 0, canvas.width, canvas.height);
    }

    const cmdCount = view.getUint32(OFFSETS.cmd_count, true);

    for (let c = 0; c < cmdCount; c++) {
        const cmd = views.cmdStream[c];
        const type = cmd >> 12;
        const idx = cmd & 0xFFF;

        switch (type) {
            case CMD_RECT:
                ctx.fillStyle = COLORS[views.rectColor[idx]] || '#000000';
                ctx.fillRect(views.rectX[idx], views.rectY[idx], views.rectW[idx], views.rectH[idx]);
                break;

            case CMD_CIRCLE:
                ctx.fillStyle = COLORS[views.circleColor[idx]] || '#000000';
                ctx.beginPath();
                ctx.arc(views.circleX[idx], views.circleY[idx], views.circleRadius[idx], 0, Math.PI * 2);
                ctx.fill();
                break;

            case CMD_LINE:
                ctx.strokeStyle = COLORS[views.lineColor[idx]] || '#000000';
                ctx.lineWidth = 1;
                ctx.beginPath();
                ctx.moveTo(views.lineX1[idx], views.lineY1[idx]);
                ctx.lineTo(views.lineX2[idx], views.lineY2[idx]);
                ctx.stroke();
                break;

            case CMD_TEXT:
                ctx.fillStyle = COLORS[views.textColor[idx]] || '#000000';
                ctx.font = `${views.textSize[idx]}px sans-serif`;
                ctx.textBaseline = 'top'; // Match raylib's top-left text positioning
                const strOff = views.textStrOffset[idx];
                const strLen = views.textStrLen[idx];
                const str = decoder.decode(views.stringBuffer.subarray(strOff, strOff + strLen));
                ctx.fillText(str, views.textX[idx], views.textY[idx]);
                break;

            case CMD_CIRCLE_GRADIENT: {
                const cx = views.circleGradientX[idx];
                const cy = views.circleGradientY[idx];
                const r = views.circleGradientRadius[idx];
                const innerColor = COLORS[views.circleGradientInner[idx]] || '#ffffff';
                const outerColor = COLORS[views.circleGradientOuter[idx]] || '#000000';
                const gradient = ctx.createRadialGradient(cx, cy, 0, cx, cy, r);
                gradient.addColorStop(0, innerColor);
                gradient.addColorStop(1, outerColor);
                ctx.fillStyle = gradient;
                ctx.beginPath();
                ctx.arc(cx, cy, r, 0, Math.PI * 2);
                ctx.fill();
                break;
            }

            case CMD_RECT_GRADIENT_V: {
                const rx = views.rectGradientVX[idx];
                const ry = views.rectGradientVY[idx];
                const rw = views.rectGradientVW[idx];
                const rh = views.rectGradientVH[idx];
                const topColor = COLORS[views.rectGradientVTop[idx]] || '#ffffff';
                const bottomColor = COLORS[views.rectGradientVBottom[idx]] || '#000000';
                const gradient = ctx.createLinearGradient(rx, ry, rx, ry + rh);
                gradient.addColorStop(0, topColor);
                gradient.addColorStop(1, bottomColor);
                ctx.fillStyle = gradient;
                ctx.fillRect(rx, ry, rw, rh);
                break;
            }

            case CMD_RECT_GRADIENT_H: {
                const rx = views.rectGradientHX[idx];
                const ry = views.rectGradientHY[idx];
                const rw = views.rectGradientHW[idx];
                const rh = views.rectGradientHH[idx];
                const leftColor = COLORS[views.rectGradientHLeft[idx]] || '#ffffff';
                const rightColor = COLORS[views.rectGradientHRight[idx]] || '#000000';
                const gradient = ctx.createLinearGradient(rx, ry, rx + rw, ry);
                gradient.addColorStop(0, leftColor);
                gradient.addColorStop(1, rightColor);
                ctx.fillStyle = gradient;
                ctx.fillRect(rx, ry, rw, rh);
                break;
            }
        }
    }
}
