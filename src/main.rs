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

#[derive(Debug)]
enum PlatformMode {
    None,
    // TextureMode,
    // TextureMode2D,
    FramebufferMode,
    FramebufferMode2D,
}

enum PlatformEffect {
    BeginDrawingFramebuffer,
    EndDrawingFramebuffer,
    BeginMode2D,
    EndMode2D,
    CreateCamera,
    UpdateCamera,
    LoadTexture,
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
    #[inline]
    fn is_draw_mode(&self) -> bool {
        matches!(
            self,
            PlatformMode::FramebufferMode | PlatformMode::FramebufferMode2D
        )
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
            | (None, BeginDrawingFramebuffer)
            | (FramebufferMode, BeginMode2D)
            | (FramebufferMode, EndDrawingFramebuffer)
            | (FramebufferMode2D, EndMode2D) => true,
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
            FramebufferMode2D => "FramebufferMode2D",
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

fn main() {
    unsafe {
        let c_title = CString::new("Loading...").unwrap();

        bindings::InitWindow(100, 50, c_title.as_ptr());
        if !bindings::IsWindowReady() {
            panic!("Attempting to create window failed!");
        }

        bindings::InitAudioDevice();

        let mut model = roc::call_roc_init();

        let mut frame_count = 0;

        while !bindings::WindowShouldClose() && !SHOULD_EXIT.get() {
            let duration_since_epoch = SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap();

            let timestamp = duration_since_epoch.as_millis() as u64; // we are casting to u64 and losing precision

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

fn exit_with_msg(msg: String) {
    let c_msg = CString::new(msg).unwrap();
    unsafe {
        bindings::TraceLog(bindings::TraceLogLevel_LOG_FATAL as i32, c_msg.as_ptr());
    }
    std::process::exit(99);
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

#[no_mangle]
unsafe extern "C" fn roc_fx_setWindowSize(width: i32, height: i32) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::SetWindowSize) {
        let mode = platform_mode_str();
        exit_with_msg(format!("Cannot set the window size while in {mode}"));
    }

    bindings::SetWindowSize(width, height);
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_setWindowTitle(text: &RocStr) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::SetWindowTitle) {
        let mode = platform_mode_str();
        exit_with_msg(format!("Cannot set the window title while in {mode}"));
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
        exit_with_msg(format!("Cannot draw a circle while in {mode}"));
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
        exit_with_msg(format!(
            "Cannot draw a circle with gradient while in {mode}"
        ));
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
        exit_with_msg(format!(
            "Cannot draw a rectangle with verticle gradient while in {mode}"
        ));
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
        exit_with_msg(format!(
            "Cannot draw a rectangle with verticle gradient while in {mode}"
        ));
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
        exit_with_msg(format!("Cannot draw text while in {mode}"));
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
        exit_with_msg(format!("Cannot draw rectangle while in {mode}"));
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
        exit_with_msg(format!("Cannot draw line while in {mode}"));
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
        exit_with_msg(format!("Cannot get screen size while in {mode}"));
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
        exit_with_msg(format!("Cannot set target FPS while in {mode}"));
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
        exit_with_msg(format!("Cannot create a camera while in {mode}"));
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
        // TODO: handle this std::io::Error and give it back to roc
        Err(_err) => panic!("Failed to create camera, out of memory."),
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
        exit_with_msg(format!("Cannot update camera while in {mode}"));
    }

    let camera: &mut bindings::Camera2D =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_camera);

    camera.target = target.into();
    camera.offset = offset.into();
    camera.rotation = rotation;
    camera.zoom = zoom;

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_beginDrawing(clear_color: glue::RocColor) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::BeginDrawingFramebuffer) {
        let mode = platform_mode_str();
        exit_with_msg(format!("Cannot begin drawing while in {mode}"));
    }

    update_platform_mode(PlatformMode::FramebufferMode);

    bindings::BeginDrawing();
    bindings::ClearBackground(clear_color.into());

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_endDrawing() -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::EndDrawingFramebuffer) {
        let mode = platform_mode_str();
        exit_with_msg(format!("Cannot end drawing while in {mode}"));
    }

    update_platform_mode(PlatformMode::None);

    bindings::EndMode2D();

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_beginMode2D(boxed_camera: RocBox<()>) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::BeginMode2D) {
        let mode = platform_mode_str();
        exit_with_msg(format!("Cannot being drawing in 2D while in {mode}"));
    }

    update_platform_mode(PlatformMode::FramebufferMode2D);

    let camera: &mut bindings::Camera2D =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_camera);

    bindings::BeginMode2D(*camera);

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_endMode2D(_boxed_camera: RocBox<()>) -> RocResult<(), ()> {
    if !is_effect_permitted(PlatformEffect::EndMode2D) {
        let mode = platform_mode_str();
        exit_with_msg(format!("Cannot being drawing in 2D while in {mode}"));
    }

    update_platform_mode(PlatformMode::FramebufferMode);

    bindings::EndMode2D();

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
unsafe extern "C" fn roc_fx_loadSound(path: &RocStr) -> RocResult<RocBox<()>, RocStr> {
    if !is_effect_permitted(PlatformEffect::LoadSound) {
        let mode = platform_mode_str();
        exit_with_msg(format!("Cannot load a sound while in {mode}"));
    }

    let path = CString::new(path.as_str()).unwrap();

    let sound = bindings::LoadSound(path.as_ptr());

    let heap = roc::sound_heap();

    let alloc_result = heap.alloc_for(sound);
    match alloc_result {
        Ok(roc_box) => RocResult::ok(roc_box),
        // TODO: handle this std::io::Error and give it back to roc
        Err(err) => RocResult::err(format!("{}", err).as_str().into()),
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
unsafe extern "C" fn roc_fx_loadTexture(file_path: &RocStr) -> RocResult<RocBox<()>, RocStr> {
    if !is_effect_permitted(PlatformEffect::LoadTexture) {
        let mode = platform_mode_str();
        exit_with_msg(format!("Cannot load a texture while in {mode}"));
    }

    // should have a valid utf8 string from roc, no need to check for null bytes
    let file_path = CString::new(file_path.as_str()).unwrap();
    let texture: bindings::Texture = bindings::LoadTexture(file_path.as_ptr());

    let heap = roc::texture_heap();

    let alloc_result = heap.alloc_for(texture);
    match alloc_result {
        Ok(roc_box) => RocResult::ok(roc_box),
        // TODO: handle this std::io::Error and give it back to roc
        Err(err) => RocResult::err(format!("{}", err).as_str().into()),
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
        exit_with_msg(format!("Cannot draw a texture rectangle while in {mode}"));
    }

    let texture: &mut bindings::Texture =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_texture);

    bindings::DrawTextureRec(*texture, source.into(), position.into(), color.into());

    RocResult::ok(())
}
