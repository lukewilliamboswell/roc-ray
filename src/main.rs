use roc_std::{RocBox, RocList, RocResult, RocStr};
use roc_std_heap::ThreadSafeRefcountedResourceHeap;
use std::array;
use std::cell::{Cell, RefCell};
use std::ffi::{c_int, CString};
use std::time::SystemTime;

mod bindings;
mod glue;
mod roc;

thread_local! {
    static DRAW_FPS: Cell<Option<(i32, i32)>> = const { Cell::new(None) };
    static SHOULD_EXIT: Cell<bool> = const { Cell::new(false) };
    static PLATFORM_MODE: RefCell<PlatformMode> = const { RefCell::new(PlatformMode::None) };
}

/// use different error codes when the app exits
#[derive(Debug)]
enum ExitErrCode {
    ExitEffectNotPermitted = 1,
    ExitHeapFull = 2,
}

/// we check at runtime which mode the platform is in and if the effect is permitted
///
/// is an app author tries to call an effect that is not permitted in the current mode
/// the app will exit with an error code and provide a message to the user
///
/// this is used to keep the API very simple instead of having each effect return a result
/// or taking an argument which "locks" which effects are permitted.
///
/// if this is expensive for performance, we can only include this in dev builds and remove
/// it in release builds
#[derive(Debug, Clone, Copy, PartialEq)]
enum PlatformMode {
    None,
    TextureMode,
    TextureModeDraw2D,
    FramebufferMode,
    FramebufferModeDraw2D,
}

/// effects that are only permitted in certain modes
///
/// not all effects need to be listed here
enum PlatformEffect {
    BeginDrawingFramebuffer,
    EndDrawingFramebuffer,
    BeginMode2D,
    EndMode2D,
    BeginDrawingTexture,
    EndDrawingTexture,
    CreateCamera,
    UpdateCamera,
    LoadTexture,
    CreateRenderTexture,
    SetWindowSize,
    SetWindowTitle,
    SetTargetFPS,
    GetScreenSize,
    LoadSound,
    DrawCircle,
    DrawCircleGradient,
    DrawRectangleGradientV,
    DrawRectangleGradientH,
    DrawText,
    DrawRectangle,
    DrawLine,
    DrawTextureRectangle,
}

impl PlatformMode {
    /// only these modes are permitted to "draw" as raylib has a framebuffer and texture ready
    #[inline]
    fn is_draw_mode(&self) -> bool {
        use PlatformMode::*;
        matches!(
            self,
            FramebufferMode | FramebufferModeDraw2D | TextureMode | TextureModeDraw2D
        )
    }

    fn matches(&self, other: PlatformMode) -> bool {
        *self == other
    }

    #[inline]
    fn is_effect_permitted(&self, e: PlatformEffect) -> bool {
        use PlatformEffect::*;
        use PlatformMode::*;

        // we only need to track the "permitted" effects, everything else is "not permitted"
        match (self, e) {
            (None, CreateCamera)
            | (None, UpdateCamera)
            | (None, SetWindowSize)
            | (None, SetWindowTitle)
            | (None, SetTargetFPS)
            | (None, GetScreenSize)
            | (None, LoadSound)
            | (None, LoadTexture)
            | (None, CreateRenderTexture)
            | (None, BeginDrawingFramebuffer)
            | (None, BeginDrawingTexture)
            | (FramebufferMode, BeginMode2D)
            | (FramebufferMode, EndDrawingFramebuffer)
            | (FramebufferModeDraw2D, EndMode2D)
            | (TextureMode, EndDrawingTexture)
            | (TextureMode, BeginMode2D)
            | (TextureModeDraw2D, EndMode2D) => true,
            (mode, DrawCircle) if mode.is_draw_mode() => true,
            (mode, DrawCircleGradient) if mode.is_draw_mode() => true,
            (mode, DrawRectangleGradientV) if mode.is_draw_mode() => true,
            (mode, DrawRectangleGradientH) if mode.is_draw_mode() => true,
            (mode, DrawText) if mode.is_draw_mode() => true,
            (mode, DrawRectangle) if mode.is_draw_mode() => true,
            (mode, DrawLine) if mode.is_draw_mode() => true,
            (mode, DrawTextureRectangle) if mode.is_draw_mode() => true,
            (_, _) => false,
        }
    }

    #[inline]
    fn as_str(&self) -> &'static str {
        use PlatformMode::*;
        match self {
            None => "None",
            FramebufferMode => "FramebufferMode",
            FramebufferModeDraw2D => "FramebufferModeDraw2D",
            TextureMode => "TextureMode",
            TextureModeDraw2D => "TextureModeDraw2D",
        }
    }
}

fn is_effect_permitted(e: PlatformEffect) -> bool {
    PLATFORM_MODE.with(|mode| mode.borrow().is_effect_permitted(e))
}

fn platform_mode_str() -> &'static str {
    PLATFORM_MODE.with(|m| m.borrow().as_str())
}

fn update_platform_mode(mode: PlatformMode) {
    PLATFORM_MODE.with(|m| *m.borrow_mut() = mode);
}

/// check if in framebuffer or texture mode before moving to the next mode
fn update_platform_mode_draw_2d() {
    PLATFORM_MODE.with(|m| {
        use PlatformMode::*;
        let mut mode = m.borrow_mut();
        if mode.matches(FramebufferMode) {
            *mode = FramebufferModeDraw2D;
        } else if mode.matches(FramebufferModeDraw2D) {
            *mode = FramebufferMode;
        } else if mode.matches(TextureMode) {
            *mode = TextureModeDraw2D;
        } else if mode.matches(TextureModeDraw2D) {
            *mode = TextureMode;
        } else {
            panic!("unreachable, invalid mode should have been caught by is_effect_permitted")
        }
    });
}

fn main() {
    unsafe {
        let c_title = CString::new("Loading...").unwrap();

        bindings::InitWindow(100, 50, c_title.as_ptr());
        if !bindings::IsWindowReady() {
            panic!("Attempting to create window failed!");
        }

        let mut frame_count = 0;

        #[cfg(feature = "trace-debug")]
        bindings::SetTraceLogLevel(bindings::TraceLogLevel_LOG_DEBUG as i32);

        bindings::InitAudioDevice();

        let mut model = roc::call_roc_init();

        while !bindings::WindowShouldClose() && !SHOULD_EXIT.get() {
            let duration_since_epoch = SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap();

            let timestamp = duration_since_epoch.as_millis() as u64; // we are casting to u64 and losing precision

            #[cfg(feature = "trace-debug")]
            trace_log(&format!(
                "------ RENDER frame: {}, millis: {} ------",
                frame_count, timestamp
            ));

            let platform_state = roc::PlatformState {
                frame_count,
                keys: get_keys_states(),
                mouse_buttons: get_mouse_button_states(),
                timestamp_millis: timestamp,
                mouse_pos_x: bindings::GetMouseX() as f32,
                mouse_pos_y: bindings::GetMouseY() as f32,
                mouse_wheel: bindings::GetMouseWheelMove(),
            };

            model = roc::call_roc_render(platform_state, &model);

            if let Some((x, y)) = DRAW_FPS.get() {
                bindings::DrawFPS(x, y);
            }

            frame_count += 1;

            bindings::EndDrawing();
        }
    }
}

/// exit the program with a message and a code, close the window
fn exit_with_msg(msg: String, code: ExitErrCode) -> ! {
    let c_msg = CString::new(msg).unwrap();
    unsafe {
        bindings::TraceLog(bindings::TraceLogLevel_LOG_FATAL as i32, c_msg.as_ptr());
        bindings::CloseWindow();
    }
    std::process::exit(code as i32);
}

#[no_mangle]
pub extern "C" fn roc_fx_exit() -> RocResult<(), ()> {
    SHOULD_EXIT.set(true);
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_log(msg: &RocStr, level: i32) -> RocResult<(), ()> {
    let text = CString::new(msg.as_str()).unwrap();
    if level >= 0 && level <= 7 {
        bindings::TraceLog(level, text.as_ptr())
    } else {
        panic!("Invalid log level from roc");
    }

    RocResult::ok(())
}

#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_setWindowSize(width: i32, height: i32) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::SetWindowSize) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot set the window size while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    #[cfg(not(test))]
    unsafe {
        bindings::SetWindowSize(width, height);
    }

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_setWindowTitle(text: &RocStr) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::SetWindowTitle) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot set the window title while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    let text = CString::new(text.as_str()).unwrap();
    bindings::SetWindowTitle(text.as_ptr());

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawCircle(
    center: &glue::RocVector2,
    radius: f32,
    color: glue::RocColor,
) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::DrawCircle) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot draw a circle while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }
    bindings::DrawCircleV(center.into(), radius, color.into());
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawCircleGradient(
    center: &glue::RocVector2,
    radius: f32,
    inner: glue::RocColor,
    outer: glue::RocColor,
) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::DrawCircleGradient) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot draw a circle with gradient while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    let (x, y) = center.to_components_c_int();
    bindings::DrawCircleGradient(x, y, radius, inner.into(), outer.into());
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawRectangleGradientV(
    rect: &glue::RocRectangle,
    top: glue::RocColor,
    bottom: glue::RocColor,
) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::DrawRectangleGradientV) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot draw a rectangle with verticle gradient while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    let (x, y, w, h) = rect.to_components_c_int();
    bindings::DrawRectangleGradientV(x, y, w, h, top.into(), bottom.into());
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawRectangleGradientH(
    rect: &glue::RocRectangle,
    top: glue::RocColor,
    bottom: glue::RocColor,
) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::DrawRectangleGradientH) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot draw a rectangle with verticle gradient while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    let (x, y, w, h) = rect.to_components_c_int();
    bindings::DrawRectangleGradientV(x, y, w, h, top.into(), bottom.into());
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawText(
    pos: &glue::RocVector2,
    size: i32,
    text: &RocStr,
    color: glue::RocColor,
) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::DrawText) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot draw text while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    let text = CString::new(text.as_bytes()).unwrap();
    let (x, y) = pos.to_components_c_int();
    bindings::DrawText(text.as_ptr(), x, y, size as c_int, color.into());
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawRectangle(
    rect: &glue::RocRectangle,
    color: glue::RocColor,
) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::DrawRectangle) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot draw rectangle while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    bindings::DrawRectangleRec(rect.into(), color.into());
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawLine(
    start: &glue::RocVector2,
    end: &glue::RocVector2,
    color: glue::RocColor,
) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::DrawLine) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot draw line while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    bindings::DrawLineV(start.into(), end.into(), color.into());
    RocResult::ok(())
}

#[repr(C)]
struct ScreenSize {
    z: i64,
    height: i32,
    width: i32,
}

#[no_mangle]
unsafe extern "C" fn roc_fx_getScreenSize() -> RocResult<ScreenSize, ()> {
    if !is_effect_permitted(PlatformEffect::GetScreenSize) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot get screen size while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    let height = bindings::GetScreenHeight();
    let width = bindings::GetScreenWidth();
    RocResult::ok(ScreenSize {
        height,
        width,
        z: 0,
    })
}

#[no_mangle]
unsafe extern "C" fn roc_fx_measureText(text: &RocStr, size: i32) -> RocResult<i64, ()> {
    // permitted in any mode
    let text = CString::new(text.as_str()).unwrap();
    let width = bindings::MeasureText(text.as_ptr(), size as c_int);
    RocResult::ok(width as i64)
}

#[no_mangle]
unsafe extern "C" fn roc_fx_setTargetFPS(rate: i32) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::SetTargetFPS) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot set target FPS while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }
    bindings::SetTargetFPS(rate as c_int);
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_takeScreenshot(path: &RocStr) -> RocResult<(), ()> {
    // permitted in any mode
    let path = CString::new(path.as_str()).unwrap();
    bindings::TakeScreenshot(path.as_ptr());
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_setDrawFPS(show: bool, pos_x: i32, pos_y: i32) -> RocResult<(), ()> {
    // permitted in any mode
    if show {
        DRAW_FPS.set(Some((pos_x, pos_y)));
    } else {
        DRAW_FPS.set(None);
    }

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_createCamera(
    target: &glue::RocVector2,
    offset: &glue::RocVector2,
    rotation: f32,
    zoom: f32,
) -> RocResult<RocBox<()>, ()> {
    if !is_effect_permitted(PlatformEffect::CreateCamera) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot create a camera while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    let camera = bindings::Camera2D {
        target: target.into(),
        offset: offset.into(),
        rotation,
        zoom,
    };

    let heap = roc::camera_heap();

    let alloc_result = heap.alloc_for(camera);
    match alloc_result {
        Ok(roc_box) => RocResult::ok(roc_box),
        Err(_) => {
            exit_with_msg("Unable to load camera, out of memory in the camera heap. Consider using ROC_RAY_MAX_CAMERAS_HEAP_SIZE env var to increase the heap size.".into(), ExitErrCode::ExitHeapFull);
        }
    }
}

#[no_mangle]
unsafe extern "C" fn roc_fx_createRenderTexture(
    size: &glue::RocVector2,
) -> RocResult<RocBox<()>, ()> {
    if !is_effect_permitted(PlatformEffect::CreateRenderTexture) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot create a render texture while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    let (width, height) = size.to_components_c_int();

    let render_texture: bindings::RenderTexture = bindings::LoadRenderTexture(width, height);

    let heap = roc::render_texture_heap();

    let alloc_result = heap.alloc_for(render_texture);
    match alloc_result {
        Ok(roc_box) => RocResult::ok(roc_box),
        Err(_) => {
            exit_with_msg("Unable to load render texture, out of memory in the render texture heap. Consider using ROC_RAY_MAX_RENDER_TEXTURE_HEAP_SIZE env var to increase the heap size.".into(), ExitErrCode::ExitHeapFull);
        }
    }
}

#[no_mangle]
unsafe extern "C" fn roc_fx_updateCamera(
    boxed_camera: RocBox<()>,
    target: &glue::RocVector2,
    offset: &glue::RocVector2,
    rotation: f32,
    zoom: f32,
) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::UpdateCamera) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot update camera while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    let camera: &mut bindings::Camera2D =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_camera);

    camera.target = target.into();
    camera.offset = offset.into();
    camera.rotation = rotation;
    camera.zoom = zoom;

    RocResult::ok(())
}

#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_beginDrawing(clear_color: glue::RocColor) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::BeginDrawingFramebuffer) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot begin drawing while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    update_platform_mode(PlatformMode::FramebufferMode);

    #[cfg(not(test))]
    unsafe {
        #[cfg(feature = "trace-debug")]
        trace_log("BeginDrawing");

        bindings::BeginDrawing();
        bindings::ClearBackground(clear_color.into());
    }

    RocResult::ok(())
}

#[no_mangle]
extern "C" fn roc_fx_endDrawing() -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::EndDrawingFramebuffer) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot end drawing while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    update_platform_mode(PlatformMode::None);

    #[cfg(not(test))]
    unsafe {
        #[cfg(feature = "trace-debug")]
        trace_log("EndDrawing");

        bindings::EndMode2D();
    }

    RocResult::ok(())
}

#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_beginMode2D(boxed_camera: RocBox<()>) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::BeginMode2D) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot begin drawing in 2D while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    update_platform_mode_draw_2d();

    #[cfg(not(test))]
    unsafe {
        #[cfg(feature = "trace-debug")]
        trace_log("BeginMode2D");

        let camera: &mut bindings::Camera2D =
            ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_camera);

        bindings::BeginMode2D(*camera);
    }

    RocResult::ok(())
}

#[no_mangle]
extern "C" fn roc_fx_endMode2D(_boxed_camera: RocBox<()>) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::EndMode2D) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot begin drawing in 2D while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    update_platform_mode_draw_2d();

    #[cfg(not(test))]
    unsafe {
        #[cfg(feature = "trace-debug")]
        trace_log("EndMode2D");

        bindings::EndMode2D();
    }

    RocResult::ok(())
}

#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_beginTexture(
    boxed_render_texture: RocBox<()>,
    clear_color: glue::RocColor,
) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::BeginDrawingTexture) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot begin drawing to a render texture while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    update_platform_mode(PlatformMode::TextureMode);

    #[cfg(not(test))]
    unsafe {
        #[cfg(feature = "trace-debug")]
        trace_log("BeginTexture");

        let render_texture: &mut bindings::RenderTexture =
            ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_render_texture);

        bindings::BeginTextureMode(*render_texture);
        bindings::ClearBackground(clear_color.into());
    }

    RocResult::ok(())
}

#[no_mangle]
extern "C" fn roc_fx_endTexture(_boxed_render_texture: RocBox<()>) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::EndDrawingTexture) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot end drawing to a render texture while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    update_platform_mode(PlatformMode::None);

    #[cfg(not(test))]
    unsafe {
        #[cfg(feature = "trace-debug")]
        trace_log("EndTexture");

        bindings::EndTextureMode();
    }

    RocResult::ok(())
}

unsafe fn get_mouse_button_states() -> RocList<u8> {
    let mouse_buttons: [u8; 7] = array::from_fn(|i| {
        if bindings::IsMouseButtonPressed(i as c_int) {
            0
        } else if bindings::IsMouseButtonReleased(i as c_int) {
            1
        } else if bindings::IsMouseButtonDown(i as c_int) {
            2
        } else {
            // Up
            3
        }
    });

    RocList::from_slice(&mouse_buttons)
}

unsafe fn get_keys_states() -> RocList<u8> {
    let keys: [u8; 350] = array::from_fn(|i| {
        if bindings::IsKeyPressed(i as c_int) {
            0
        } else if bindings::IsKeyReleased(i as c_int) {
            1
        } else if bindings::IsKeyDown(i as c_int) {
            2
        } else if bindings::IsKeyUp(i as c_int) {
            3
        } else {
            // PressedRepeat
            4
        }
    });

    RocList::from_slice(&keys)
}

#[no_mangle]
unsafe extern "C" fn roc_fx_loadSound(path: &RocStr) -> RocResult<RocBox<()>, ()> {
    if !is_effect_permitted(PlatformEffect::LoadSound) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot load a sound while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    let path = CString::new(path.as_str()).unwrap();

    let sound = bindings::LoadSound(path.as_ptr());

    let heap = roc::sound_heap();

    let alloc_result = heap.alloc_for(sound);
    match alloc_result {
        Ok(roc_box) => RocResult::ok(roc_box),
        Err(_) => {
            exit_with_msg("Unable to load sound, out of memory in the sound heap. Consider using ROC_RAY_MAX_SOUNDS_HEAP_SIZE env var to increase the heap size.".into(), ExitErrCode::ExitHeapFull);
        }
    }
}

#[no_mangle]
unsafe extern "C" fn roc_fx_playSound(boxed_sound: RocBox<()>) -> RocResult<(), ()> {
    // permitted in any mode
    let sound: &mut bindings::Sound =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_sound);

    bindings::PlaySound(*sound);

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_loadTexture(file_path: &RocStr) -> RocResult<RocBox<()>, ()> {
    if !is_effect_permitted(PlatformEffect::LoadTexture) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot load a texture while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    // should have a valid utf8 string from roc, no need to check for null bytes
    let file_path = CString::new(file_path.as_str()).unwrap();
    let texture: bindings::Texture = bindings::LoadTexture(file_path.as_ptr());

    let heap = roc::texture_heap();

    let alloc_result = heap.alloc_for(texture);
    match alloc_result {
        Ok(roc_box) => RocResult::ok(roc_box),
        Err(_) => {
            exit_with_msg("Unable to load texture, out of memory in the texture heap. Consider using ROC_RAY_MAX_TEXTURES_HEAP_SIZE env var to increase the heap size.".into(), ExitErrCode::ExitHeapFull);
        }
    }
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawTextureRec(
    boxed_texture: RocBox<()>,
    source: &glue::RocRectangle,
    position: &glue::RocVector2,
    color: glue::RocColor,
) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::DrawTextureRectangle) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot draw a texture rectangle while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    let texture: &mut bindings::Texture =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_texture);

    bindings::DrawTextureRec(*texture, source.into(), position.into(), color.into());

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawRenderTextureRec(
    boxed_texture: RocBox<()>,
    source: &glue::RocRectangle,
    position: &glue::RocVector2,
    color: glue::RocColor,
) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::DrawTextureRectangle) {
        let mode = platform_mode_str();
        exit_with_msg(
            format!("Cannot draw a texture rectangle while in {mode}"),
            ExitErrCode::ExitEffectNotPermitted,
        );
    }

    let texture: &mut bindings::RenderTexture =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_texture);

    bindings::DrawTextureRec(
        texture.texture,
        source.into(),
        position.into(),
        color.into(),
    );

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_loadFileToStr(path: &RocStr) -> RocResult<RocStr, ()> {
    let path = path.as_str();
    let Ok(contents) = std::fs::read_to_string(path) else {
        panic!("file not found: {path}");
    };

    let contents = contents.replace("\r\n", "\n");
    let contents = RocStr::from_slice_unchecked(contents.as_bytes());

    RocResult::ok(contents)
}

#[cfg(feature = "trace-debug")]
unsafe fn trace_log(msg: &str) {
    let level = bindings::TraceLogLevel_LOG_DEBUG;
    let text = CString::new(msg).unwrap();
    bindings::TraceLog(level as i32, text.as_ptr());
}

#[cfg(test)]
mod test_platform_mode_transitions {
    use super::*;

    fn set_platform_mode(mode: PlatformMode) {
        PLATFORM_MODE.with(|m| *m.borrow_mut() = mode);
    }

    fn get_platform_mode() -> PlatformMode {
        PLATFORM_MODE.with(|m| m.borrow().clone())
    }

    #[test]
    fn test_initial_mode() {
        assert_eq!(get_platform_mode(), PlatformMode::None);
    }

    #[test]
    fn test_begin_drawing_framebuffer() {
        set_platform_mode(PlatformMode::None);
        roc_fx_beginDrawing(glue::RocColor::WHITE);
        assert_eq!(get_platform_mode(), PlatformMode::FramebufferMode);
    }

    #[test]
    fn test_end_drawing_framebuffer() {
        set_platform_mode(PlatformMode::FramebufferMode);
        roc_fx_endDrawing();
        assert_eq!(get_platform_mode(), PlatformMode::None);
    }

    #[test]
    fn test_begin_texture() {
        set_platform_mode(PlatformMode::None);
        roc_fx_beginTexture(RocBox::new(()), glue::RocColor::WHITE);
        assert_eq!(get_platform_mode(), PlatformMode::TextureMode);
    }

    #[test]
    fn test_end_texture() {
        set_platform_mode(PlatformMode::TextureMode);
        roc_fx_endTexture(RocBox::new(()));
        assert_eq!(get_platform_mode(), PlatformMode::None);
    }

    #[test]
    fn test_begin_mode_2d_from_framebuffer() {
        set_platform_mode(PlatformMode::FramebufferMode);
        roc_fx_beginMode2D(RocBox::new(()));
        assert_eq!(get_platform_mode(), PlatformMode::FramebufferModeDraw2D);
    }

    #[test]
    fn test_end_mode_2d_to_framebuffer() {
        set_platform_mode(PlatformMode::FramebufferModeDraw2D);
        roc_fx_endMode2D(RocBox::new(()));
        assert_eq!(get_platform_mode(), PlatformMode::FramebufferMode);
    }

    #[test]
    fn test_begin_mode_2d_from_texture() {
        set_platform_mode(PlatformMode::TextureMode);
        roc_fx_beginMode2D(RocBox::new(()));
        assert_eq!(get_platform_mode(), PlatformMode::TextureModeDraw2D);
    }

    #[test]
    fn test_end_mode_2d_to_texture() {
        set_platform_mode(PlatformMode::TextureModeDraw2D);
        roc_fx_endMode2D(RocBox::new(()));
        assert_eq!(get_platform_mode(), PlatformMode::TextureMode);
    }
}
