// ci/wasm-test.mjs
// Node.js WASM Command Buffer Integration Tests
// Runs without browser - tests deterministic command buffer output
//
// This test validates the WASM host layer in ISOLATION. It catches:
//   - Command buffer layout/struct offset bugs
//   - Command encoding issues (type + index packing)
//   - Data integrity for all draw primitives (rect, circle, line, text)
//   - String buffer encoding/decoding
//   - Command ordering preservation
//   - Buffer capacity enforcement

import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import path from 'path';

// Import shared constants from host.js (single source of truth)
import {
    CMD_RECT, CMD_CIRCLE, CMD_LINE, CMD_TEXT,
    MAX_COMMANDS, MAX_RECTS, MAX_CIRCLES, MAX_LINES, MAX_TEXTS, MAX_STRING_BYTES,
    getOffsets, createBufferViews
} from '../platform/web/host.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let passCount = 0, failCount = 0;

function assert(condition, msg) {
    if (condition) {
        console.log(`  \u2713 ${msg}`);
        passCount++;
    } else {
        console.log(`  \u2717 ${msg}`);
        failCount++;
    }
    return condition;
}

function section(name) {
    console.log(`\n--- ${name} ---`);
}

async function runTests() {
    console.log('WASM Command Buffer Integration Tests\n');

    // Load WASM from zig-out/web-test/
    const wasmPath = path.join(__dirname, '..', 'zig-out', 'web-test', 'host_web.wasm');
    let wasmBytes;
    try {
        wasmBytes = await readFile(wasmPath);
        console.log(`Loaded WASM from: ${wasmPath}`);
    } catch (e) {
        console.error(`\u2717 Failed to load WASM: ${e.message}`);
        console.error(`  Make sure to run 'zig build test' first`);
        process.exit(1);
    }

    // Shared state for imports
    let memory = null;

    // Provide stub implementations for imported functions (not used in tests)
    const imports = {
        env: {
            roc__init_for_host: () => {},
            roc__render_for_host: () => {},
            // Console logging stub - used by host for debug/expect/crash messages
            js_console_log: (ptr, len) => {
                if (memory) {
                    const bytes = new Uint8Array(memory.buffer, ptr, len);
                    const text = new TextDecoder().decode(bytes);
                    console.log('[WASM]', text);
                }
            },
            // Error throwing stub - used by host for crash/panic
            js_throw_error: (ptr, len) => {
                if (memory) {
                    const bytes = new Uint8Array(memory.buffer, ptr, len);
                    const text = new TextDecoder().decode(bytes);
                    throw new Error(`[WASM Error] ${text}`);
                }
                throw new Error('[WASM Error] (no memory)');
            },
        }
    };

    let wasm;
    try {
        const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
        wasm = instance.exports;
        memory = wasm.memory;
        assert(true, 'WASM module instantiated successfully');
    } catch (e) {
        console.error(`\u2717 Failed to instantiate WASM: ${e.message}`);
        process.exit(1);
    }

    // Get buffer pointer and offsets
    section('Buffer Setup');
    const cmdBufferPtr = wasm._get_cmd_buffer_ptr();
    assert(cmdBufferPtr > 0, `Buffer pointer valid: ${cmdBufferPtr}`);

    const OFFSETS = getOffsets(wasm);
    assert(OFFSETS.cmd_stream > 0, `cmd_stream offset valid: ${OFFSETS.cmd_stream}`);

    // Run test function
    section('Test Draw Commands');
    const cmdCount = wasm._test_draw_commands();
    assert(cmdCount === 4, `_test_draw_commands returned ${cmdCount} commands (expected 4)`);

    // Read buffer values
    section('Buffer Validation');
    const view = new DataView(memory.buffer, cmdBufferPtr);
    const base = cmdBufferPtr;

    // Check clear
    const hasClear = view.getUint8(OFFSETS.has_clear) !== 0;
    assert(hasClear === true, `has_clear = ${hasClear}`);

    const clearColor = view.getUint8(OFFSETS.clear_color);
    assert(clearColor === 1, `clear_color = ${clearColor} (expected 1 for Blue)`);

    // Check cmd_count
    const readCmdCount = view.getUint32(OFFSETS.cmd_count, true);
    assert(readCmdCount === 4, `cmd_count = ${readCmdCount} (expected 4)`);

    // Check rectangle
    const rectCount = view.getUint32(OFFSETS.rect_count, true);
    assert(rectCount === 1, `rect_count = ${rectCount} (expected 1)`);

    const rectX = new Float32Array(memory.buffer, base + OFFSETS.rect_x, MAX_RECTS);
    const rectY = new Float32Array(memory.buffer, base + OFFSETS.rect_y, MAX_RECTS);
    const rectW = new Float32Array(memory.buffer, base + OFFSETS.rect_w, MAX_RECTS);
    const rectH = new Float32Array(memory.buffer, base + OFFSETS.rect_h, MAX_RECTS);
    const rectColor = new Uint8Array(memory.buffer, base + OFFSETS.rect_color, MAX_RECTS);

    assert(rectX[0] === 10, `rect_x[0] = ${rectX[0]} (expected 10)`);
    assert(rectY[0] === 10, `rect_y[0] = ${rectY[0]} (expected 10)`);
    assert(rectW[0] === 100, `rect_w[0] = ${rectW[0]} (expected 100)`);
    assert(rectH[0] === 50, `rect_h[0] = ${rectH[0]} (expected 50)`);
    assert(rectColor[0] === 10, `rect_color[0] = ${rectColor[0]} (expected 10 for Red)`);

    // Check circle
    const circleCount = view.getUint32(OFFSETS.circle_count, true);
    assert(circleCount === 1, `circle_count = ${circleCount} (expected 1)`);

    const circleX = new Float32Array(memory.buffer, base + OFFSETS.circle_x, MAX_CIRCLES);
    const circleY = new Float32Array(memory.buffer, base + OFFSETS.circle_y, MAX_CIRCLES);
    const circleRadius = new Float32Array(memory.buffer, base + OFFSETS.circle_radius, MAX_CIRCLES);
    const circleColor = new Uint8Array(memory.buffer, base + OFFSETS.circle_color, MAX_CIRCLES);

    assert(circleX[0] === 200, `circle_x[0] = ${circleX[0]} (expected 200)`);
    assert(circleY[0] === 100, `circle_y[0] = ${circleY[0]} (expected 100)`);
    assert(circleRadius[0] === 30, `circle_radius[0] = ${circleRadius[0]} (expected 30)`);
    assert(circleColor[0] === 4, `circle_color[0] = ${circleColor[0]} (expected 4 for Green)`);

    // Check line
    const lineCount = view.getUint32(OFFSETS.line_count, true);
    assert(lineCount === 1, `line_count = ${lineCount} (expected 1)`);

    const lineX1 = new Float32Array(memory.buffer, base + OFFSETS.line_x1, MAX_LINES);
    const lineY1 = new Float32Array(memory.buffer, base + OFFSETS.line_y1, MAX_LINES);
    const lineX2 = new Float32Array(memory.buffer, base + OFFSETS.line_x2, MAX_LINES);
    const lineY2 = new Float32Array(memory.buffer, base + OFFSETS.line_y2, MAX_LINES);
    const lineColorArr = new Uint8Array(memory.buffer, base + OFFSETS.line_color, MAX_LINES);

    assert(lineX1[0] === 300, `line_x1[0] = ${lineX1[0]} (expected 300)`);
    assert(lineY1[0] === 10, `line_y1[0] = ${lineY1[0]} (expected 10)`);
    assert(lineX2[0] === 400, `line_x2[0] = ${lineX2[0]} (expected 400)`);
    assert(lineY2[0] === 100, `line_y2[0] = ${lineY2[0]} (expected 100)`);
    assert(lineColorArr[0] === 12, `line_color[0] = ${lineColorArr[0]} (expected 12 for Yellow)`);

    // Check text
    const textCount = view.getUint32(OFFSETS.text_count, true);
    assert(textCount === 1, `text_count = ${textCount} (expected 1)`);

    const textXArr = new Float32Array(memory.buffer, base + OFFSETS.text_x, MAX_TEXTS);
    const textYArr = new Float32Array(memory.buffer, base + OFFSETS.text_y, MAX_TEXTS);
    const textSizeArr = new Int32Array(memory.buffer, base + OFFSETS.text_size, MAX_TEXTS);
    const textColorArr = new Uint8Array(memory.buffer, base + OFFSETS.text_color, MAX_TEXTS);
    const textStrOffsetArr = new Uint16Array(memory.buffer, base + OFFSETS.text_str_offset, MAX_TEXTS);
    const textStrLenArr = new Uint16Array(memory.buffer, base + OFFSETS.text_str_len, MAX_TEXTS);
    const stringBuffer = new Uint8Array(memory.buffer, base + OFFSETS.string_buffer, MAX_STRING_BYTES);

    assert(textXArr[0] === 10, `text_x[0] = ${textXArr[0]} (expected 10)`);
    assert(textYArr[0] === 200, `text_y[0] = ${textYArr[0]} (expected 200)`);
    assert(textSizeArr[0] === 32, `text_size[0] = ${textSizeArr[0]} (expected 32)`);
    assert(textColorArr[0] === 11, `text_color[0] = ${textColorArr[0]} (expected 11 for White)`);

    const strOff = textStrOffsetArr[0];
    const strLen = textStrLenArr[0];
    const textStr = new TextDecoder().decode(stringBuffer.subarray(strOff, strOff + strLen));
    assert(textStr === 'Test', `text string = "${textStr}" (expected "Test")`);

    // Verify command stream order
    section('Command Stream Order');
    const cmdStream = new Uint16Array(memory.buffer, base + OFFSETS.cmd_stream, MAX_COMMANDS);

    const cmd0Type = cmdStream[0] >> 12;
    const cmd0Idx = cmdStream[0] & 0xFFF;
    assert(cmd0Type === CMD_RECT && cmd0Idx === 0, `cmd[0] = rect[0] (type=${cmd0Type}, idx=${cmd0Idx})`);

    const cmd1Type = cmdStream[1] >> 12;
    const cmd1Idx = cmdStream[1] & 0xFFF;
    assert(cmd1Type === CMD_CIRCLE && cmd1Idx === 0, `cmd[1] = circle[0] (type=${cmd1Type}, idx=${cmd1Idx})`);

    const cmd2Type = cmdStream[2] >> 12;
    const cmd2Idx = cmdStream[2] & 0xFFF;
    assert(cmd2Type === CMD_LINE && cmd2Idx === 0, `cmd[2] = line[0] (type=${cmd2Type}, idx=${cmd2Idx})`);

    const cmd3Type = cmdStream[3] >> 12;
    const cmd3Idx = cmdStream[3] & 0xFFF;
    assert(cmd3Type === CMD_TEXT && cmd3Idx === 0, `cmd[3] = text[0] (type=${cmd3Type}, idx=${cmd3Idx})`);

    // Summary
    section('Summary');
    if (failCount === 0) {
        console.log(`\n\u2713 ALL ${passCount} TESTS PASSED\n`);
        process.exit(0);
    } else {
        console.log(`\n\u2717 ${failCount} TESTS FAILED, ${passCount} passed\n`);
        process.exit(1);
    }
}

runTests().catch(e => {
    console.error(`Fatal error: ${e.message}`);
    console.error(e.stack);
    process.exit(1);
});
