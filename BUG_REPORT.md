# Roc Glue Generator Bug Report

Platform: roc-ray (`platform/main.roc`)
Glue command: `roc glue ../roc/src/glue/src/ZigGlue.roc ./src/ ./platform/main.roc`
Output: `src/roc_platform_abi.zig`

---

## Bug 1: Entrypoint arg type truncated (init!/render! host state arg)

**Status: OPEN**

**Location:** `roc__init_for_host`, `roc__render_for_host` entrypoints

**Generated:**
```zig
pub extern fn roc__init_for_host(
    ops: *RocOps,
    ret_ptr: *Try,
    arg_ptr: ?*const __AnonStruct107,  // { mouse_wheel: f32 } — only 1 of 8 fields!
) callconv(.c) void;

pub const Render_for_hostArgs = extern struct {
    arg0: **anyopaque,
    arg1: __AnonStruct114,  // { mouse_wheel: f32 } — same truncation
};
pub extern fn roc__render_for_host(
    ops: *RocOps,
    ret_ptr: *Try,
    arg_ptr: ?*const Render_for_hostArgs,
) callconv(.c) void;
```

**Expected for init:** The arg should be the full `HostStateFromHost` struct:
```zig
extern struct {
    frame_count: u64,
    keys: Keys,        // RocListWith(u8, false) wrapped in Keys nominal type
    mouse_wheel: f32,
    mouse_x: f32,
    mouse_y: f32,
    mouse_left: bool,
    mouse_middle: bool,
    mouse_right: bool,
}
```

**Expected for render:** `Render_for_hostArgs.arg0` should be `*anyopaque` (a `Box(Model)` is already a pointer; a field holding it should be a single pointer, not `**anyopaque`). And `arg1` should be the full `HostStateFromHost`, not `{ mouse_wheel: f32 }`.

**Root cause:** The glue generator resolves `HostStateFromHost` (a Roc type alias for the host record) incompletely — only one field survives whatever filtering is applied. Additionally, `Box(Model)` may be incorrectly emitted as `**anyopaque` instead of `*anyopaque`.

**Impact:** Cannot use the generated entrypoint declarations. `types.zig` keeps hand-rolled `roc__init_for_host` and `roc__render_for_host`.

---

## Bug 2: `Try` payload type wrong for `Try(Box(Model), I32)`

**Status: OPEN**

**Location:** `abi.Try` used as return type for init/render entrypoints

**Generated:**
```zig
pub const Try = extern struct {
    payload: extern union { err: *anyopaque, ok: RocStr },  // ok is RocStr (24 bytes)
    tag: TryTag,
};
// Size: 32 bytes
```

**Expected for `Try(Box(Model), I32)`:**
```zig
// ok: *anyopaque (8 bytes, Box is a heap pointer)
// err: i32 (4 bytes)
extern struct {
    payload: extern union { ok: *anyopaque, err: i32 },
    discriminant: u8,
    _padding: [7]u8,
}
// Size: 16 bytes
```

**Root cause:** The glue generator emits a single `Try` type using the largest Ok payload seen (`Str` = 24 bytes), rather than per-instantiation types. This is wrong for `Try(Box(Model), I32)`.

**Impact:** Cannot use `abi.Try` for init/render return values. `types.zig` keeps hand-rolled `Try_BoxModel_I32`.

---

## Bug 3: `Try` size wrong for `Try({}, [NotSupported, ..])`

**Status: OPEN**

**Location:** `hostedSetScreenSize` return type — `Try({}, [NotSupported, ..])`

**Generated `abi.Try`:** 32 bytes (ok payload = RocStr)

**Actual Roc layout for `Try({}, [NotSupported, ..])`:** 8 bytes total:
```zig
extern struct {
    payload: u8,       // 0 = NotSupported error tag
    discriminant: u8,  // 0 = Err, 1 = Ok
    _padding: [6]u8,
}
```

**Root cause:** Same single-`Try` issue as Bug 2. Using `abi.Try` here would write 32 bytes where Roc only reads 8, corrupting the stack.

**Impact:** Cannot use `abi.Try` for `set_screen_size!` return. `types.zig` keeps hand-rolled `Try_Unit_NotSupported`.

---

## Bug 4: `DrawTextArgs` field ordering wrong on wasm32

**Status: OPEN**

**Location:** `abi.DrawTextArgs`

**Generated (64-bit field ordering):**
```zig
pub const DrawTextArgs = extern struct {
    text: RocStr,       // align 8 → first on 64-bit
    pos: __AnonStruct54,
    size: i32,
    color: Color,
};
```

**Expected on wasm32 (32-bit pointer layout):**
```zig
// On wasm32, RocStr has pointer align = 4, same as f32.
// Field ordering changes to alphabetical: pos, size, text, color
extern struct {
    pos: Vector2,
    size: i32,
    text: RocStr,   // 12 bytes on 32-bit
    color: u8,
}
```

**Root cause:** The generated file is 64-bit only. `DrawTextArgs` layout is correct for native but wrong for wasm32.

**Impact:** Cannot use `abi.DrawTextArgs` in `host_wasm.zig`. Kept using `types.Text.FFI` which has a compile-time conditional for the correct layout.

---

## Bug 5: Invalid Zig identifier in generated struct field ✅ RESOLVED

**Resolution:** The field is now emitted as `@"render!": *anyopaque` using Zig's escaped identifier syntax. The file compiles cleanly.

---

## Bug 6: Generated code fails project lint rules ✅ RESOLVED

**Resolution:**

### 6a: Separator comment style violation ✅
`// ====` separator comments no longer appear in the regenerated file.

### 6b: Dead code `small_str_max_length` ✅
The unused `small_str_max_length` constant has been removed from `RocStr`.

---

## Summary

| Generated type | Usable? | Status |
|---|---|---|
| `abi.DrawCircleArgs` | Yes (64-bit) | — |
| `abi.DrawClearArgs` | Yes | — |
| `abi.DrawLineArgs` | Yes (64-bit) | — |
| `abi.DrawRectangleArgs` | Yes (64-bit) | — |
| `abi.DrawRectangle_gradient_hArgs` | Yes (64-bit) | — |
| `abi.DrawRectangle_gradient_vArgs` | Yes (64-bit) | — |
| `abi.DrawTextArgs` | No (wasm32 wrong) | Bug 4 open |
| `abi.DrawCircle_gradientArgs` | Yes (64-bit) | — |
| `abi.HostExitArgs` | Yes | — |
| `abi.HostRead_envArgs` | Yes | — |
| `abi.HostSet_screen_sizeArgs` | Yes | — |
| `abi.HostSet_target_fpsArgs` | Yes | — |
| `abi.HostGet_screen_sizeRetRecord` | Yes | — |
| `abi.Try` | No (wrong size/type) | Bugs 2 & 3 open |
| `roc__init_for_host` entrypoint | No (truncated arg) | Bug 1 open |
| `roc__render_for_host` entrypoint | No (truncated arg + `**anyopaque`) | Bug 1 open |
| `__AnonStruct88.@"render!"` | Yes (escaped ident) | Bug 5 resolved ✅ |
| Lint compliance | Yes | Bug 6 resolved ✅ |
| `abi.DefaultAllocators` | Yes (new) | — |
| `abi.DefaultHandlers` | Yes (new) | — |
| `abi.makeRocOps` | Yes (new) | — |
