use config::ExitErrCode;
use platform_mode::PlatformEffect;
use roc_std::{RocBox, RocList, RocResult, RocStr};
use roc_std_heap::ThreadSafeRefcountedResourceHeap;
use std::ffi::{CString, c_int, c_void};

#[cfg(target_family = "wasm")]
extern crate console_error_panic_hook;

mod config;
mod glue;
mod logger;
mod platform_mode;
mod roc;
mod worker;

#[cfg(target_arch = "wasm32")]
thread_local!(static MAIN_LOOP_CALLBACK: std::cell::RefCell<Option<Box<dyn FnMut()>>> = std::cell::RefCell::new(None));

#[cfg(target_arch = "wasm32")]
pub fn set_main_loop_callback<F: 'static>(callback: F)
where
    F: FnMut(),
{
    MAIN_LOOP_CALLBACK.with(|log| {
        *log.borrow_mut() = Some(Box::new(callback));
    });

    unsafe {
        emscripten_set_main_loop(wrapper::<F>, 0, 1);
    }

    extern "C" fn wrapper<F>()
    where
        F: FnMut(),
    {
        MAIN_LOOP_CALLBACK.with(|z| {
            if let Some(ref mut callback) = *z.borrow_mut() {
                callback();
            }
        });
    }
}

#[cfg(target_family = "wasm")]
extern "C" {
    fn emscripten_set_main_loop(loop_fn: extern "C" fn(), fps: i32, sim_infinite_loop: i32);
}

#[cfg(target_family = "wasm")]
#[no_mangle]
pub extern "C" fn on_resize(width: i32, height: i32) {
    unsafe {
        raylib::SetWindowSize(width, height);
    }
}

fn main() {
    #[cfg(target_arch = "wasm32")]
    std::panic::set_hook(Box::new(console_error_panic_hook::hook));

    let mut app = roc::App::init();

    // MANUALLY CHANGE PLATFORM MODE
    _ = platform_mode::update(PlatformEffect::EndInitWindow);

    #[cfg(not(target_arch = "wasm32"))]
    let maybe_rt_handle = setup_networking(config::with(|c| c.network_web_rtc_url.clone()));

    #[cfg(target_family = "wasm")]
    unsafe {
        set_main_loop_callback(move || {
            if let Some(msg_code) = config::with(|c| c.should_exit_msg_code.clone()) {
                draw_fatal_error(msg_code);
            } else {
                app.render();
            }
        });
    }

    #[cfg(not(target_family = "wasm"))]
    unsafe {
        while !raylib::WindowShouldClose() && !config::with(|c| c.should_exit) {
            if let Some(msg_code) = config::with(|c| c.should_exit_msg_code.clone()) {
                draw_fatal_error(msg_code);
            } else {
                app.render();
            }
        }
    }

    #[cfg(not(target_arch = "wasm32"))]
    {
        // Send shutdown message before closing the window
        worker::send_message(worker::MainToWorkerMsg::Shutdown);

        if let Some((rt, handle)) = maybe_rt_handle {
            // Wait for the worker to finish
            rt.block_on(handle).unwrap();
        }
    }

    // Now close the window
    unsafe {
        raylib::CloseAudioDevice();
        raylib::CloseWindow();
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn setup_networking(
    room_url: Option<String>,
) -> Option<(tokio::runtime::Runtime, tokio::task::JoinHandle<()>)> {
    let rt = tokio::runtime::Runtime::new().unwrap();
    worker::init(&rt, room_url).map(|handle| (rt, handle))
}

unsafe fn draw_fatal_error(msg_code: (String, ExitErrCode)) {
    raylib::BeginDrawing();

    raylib::ClearBackground(raylib::Color {
        r: 255,
        g: 210,
        b: 210,
        a: 255,
    });

    raylib::DrawCircle(
        raylib::GetMouseX(),
        raylib::GetMouseY(),
        5.0,
        raylib::Color {
            r: 50,
            g: 50,
            b: 50,
            a: 255,
        },
    );

    let error_msg = CString::new("FATAL ERROR:").unwrap();

    let error_msg_width = raylib::MeasureText(error_msg.as_ptr(), 20);

    raylib::DrawText(
        error_msg.as_ptr(),
        10,
        10,
        20,
        raylib::Color {
            r: 255,
            g: 0,
            b: 0,
            a: 255,
        },
    );

    let code_str = CString::new(format!("{:?}", msg_code.1)).unwrap();
    raylib::DrawText(
        code_str.as_ptr(),
        error_msg_width + 20,
        10,
        20,
        raylib::Color {
            r: 0,
            g: 0,
            b: 0,
            a: 255,
        },
    );

    let error_msg = CString::new(msg_code.0).unwrap();
    raylib::DrawText(
        error_msg.as_ptr(),
        10,
        40,
        10,
        raylib::Color {
            r: 0,
            g: 0,
            b: 0,
            a: 255,
        },
    );

    raylib::EndDrawing();
}

/// display a fatal error message
fn display_fatal_error_message(msg: String, code: ExitErrCode) {
    config::update(|c| {
        c.should_exit_msg_code = Some((msg.clone(), code));
    });

    logger::log(msg.as_str());
}

#[no_mangle]
extern "C" fn roc_fx_exit() {
    config::update(|c| c.should_exit = true);
}

#[no_mangle]
extern "C" fn roc_fx_init_window(title: &RocStr, width: f32, height: f32) {
    config::update(|c| {
        c.title = CString::new(title.to_string()).unwrap();
        c.width = width as i32;
        c.height = height as i32;
    });

    if let Err(msg) = platform_mode::update(PlatformEffect::InitWindow) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    // CREATE THE RAYLIB WINDOW
    let title = config::with(|c| c.title.as_ptr());
    let width = config::with(|c| c.width);
    let height = config::with(|c| c.height);

    unsafe {
        raylib::InitWindow(width, height, title);

        // wait for the window to be ready (blocking)
        if !raylib::IsWindowReady() {
            panic!("Attempting to create window failed!");
        }

        raylib::SetTraceLogLevel(config::with(|c| c.trace_log_level.into()));
        raylib::SetTargetFPS(config::with(|c| c.fps_target));

        raylib::InitAudioDevice();
    }
}

#[no_mangle]
extern "C" fn roc_fx_begin_drawing(clear_color: glue::RocColor) {
    if let Err(msg) = platform_mode::update(PlatformEffect::BeginDrawingFramebuffer) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        raylib::BeginDrawing();
        raylib::ClearBackground(clear_color.into());
    }
}

#[no_mangle]
extern "C" fn roc_fx_end_drawing() {
    if let Err(msg) = platform_mode::update(PlatformEffect::EndDrawingFramebuffer) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        raylib::EndDrawing();
    }
}

#[no_mangle]
extern "C" fn roc_fx_sleep_millis(millis: u64) {
    if let Err(msg) = platform_mode::update(PlatformEffect::SleepMillis) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    #[cfg(not(target_family = "wasm"))]
    std::thread::sleep(std::time::Duration::from_millis(millis));

    #[cfg(target_family = "wasm")]
    {
        extern "C" {
            // https://emscripten.org/docs/api_reference/emscripten.h.html?highlight=sleep#c.emscripten_sleep
            fn emscripten_sleep(ms: c_int);
        }
        unsafe {
            emscripten_sleep(millis as c_int);
        }
    }
}

#[no_mangle]
extern "C" fn roc_fx_random_i32(min: i32, max: i32) -> i32 {
    if let Err(msg) = platform_mode::update(PlatformEffect::RandomValue) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe { raylib::GetRandomValue(min, max) }
}

#[no_mangle]
extern "C" fn roc_fx_draw_text(
    text: &RocStr,
    pos: &glue::RocVector2,
    size: f32,
    spacing: f32,
    color: glue::RocColor,
) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawText) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let text = CString::new(text.as_bytes()).unwrap();

    unsafe {
        let default = raylib::GetFontDefault();
        raylib::DrawTextEx(
            default,
            text.as_ptr(),
            pos.into(),
            size,
            spacing,
            color.into(),
        );
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_text_font(
    boxed_font: RocBox<()>,
    text: &RocStr,
    pos: &glue::RocVector2,
    size: f32,
    spacing: f32,
    color: glue::RocColor,
) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawText) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let text = CString::new(text.as_bytes()).unwrap();

    let font: &mut raylib::Font = ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_font);

    unsafe {
        raylib::DrawTextEx(
            *font,
            text.as_ptr(),
            pos.into(),
            size,
            spacing,
            color.into(),
        );
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_rectangle(rect: &glue::RocRectangle, color: glue::RocColor) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawRectangle) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        raylib::DrawRectangleRec(rect.into(), color.into());
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_rectangle_pro(rect: &glue::RocRectangle, origin: &glue::RocVector2, rotation: f32, color: glue::RocColor) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawRectangle) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        raylib::DrawRectanglePro(rect.into(), origin.into(), rotation, color.into());
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_line(
    start: &glue::RocVector2,
    end: &glue::RocVector2,
    color: glue::RocColor,
) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawLine) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        raylib::DrawLineV(start.into(), end.into(), color.into());
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_line_ex(
    start: &glue::RocVector2,
    end: &glue::RocVector2,
    thickness: f32,
    color: glue::RocColor,
) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawLine) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        raylib::DrawLineEx(start.into(), end.into(), thickness, color.into());
    }
}


#[no_mangle]
extern "C" fn roc_fx_draw_circle(center: &glue::RocVector2, radius: f32, color: glue::RocColor) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawCircle) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        raylib::DrawCircleV(center.into(), radius, color.into());
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_circle_gradient(
    center: &glue::RocVector2,
    radius: f32,
    inner: glue::RocColor,
    outer: glue::RocColor,
) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawCircleGradient) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let (x, y) = center.to_components_c_int();

    unsafe {
        raylib::DrawCircleGradient(x, y, radius, inner.into(), outer.into());
    }
}

// RLAPI void DrawCircleLinesV(Vector2 center, float radius, Color color);                                  // Draw circle outline (Vector version)
#[no_mangle]
extern "C" fn roc_fx_draw_circle_lines(center: &glue::RocVector2, radius: f32, color: glue::RocColor) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawCircleGradient) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        raylib::DrawCircleLinesV(center.into(), radius, color.into());
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_rectangle_gradient_v(
    rect: &glue::RocRectangle,
    top: glue::RocColor,
    bottom: glue::RocColor,
) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawRectangleGradientV) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let (x, y, w, h) = rect.to_components_c_int();

    unsafe {
        raylib::DrawRectangleGradientV(x, y, w, h, top.into(), bottom.into());
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_rectangle_gradient_h(
    rect: &glue::RocRectangle,
    left: glue::RocColor,
    right: glue::RocColor,
) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawRectangleGradientH) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let (x, y, w, h) = rect.to_components_c_int();

    unsafe {
        raylib::DrawRectangleGradientH(x, y, w, h, left.into(), right.into());
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_ellipse(
    center: &glue::RocVector2,
    h: f32,
    v: f32,
    color: glue::RocColor,
) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawRectangleGradientH) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }
    let (x, y) = center.to_components_c_int();
    unsafe {
        raylib::DrawEllipse(x, y, h, v, color.into());
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_ellipse_lines(
    center: &glue::RocVector2,
    h: f32,
    v: f32,
    color: glue::RocColor,
) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawRectangleGradientH) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }
    let (x, y) = center.to_components_c_int();
    unsafe {
        raylib::DrawEllipseLines(x, y, h, v, color.into());
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_ring(
    center: &glue::RocVector2,
    inner: f32,
    outer: f32,
    start_angle: f32,
    end_angle: f32,
    segments: i32,
    color: glue::RocColor,
) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawRectangleGradientH) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }
    unsafe {
        raylib::DrawRing(center.into(), inner, outer, start_angle, end_angle, segments, color.into());
    }
}


#[no_mangle]
extern "C" fn roc_fx_get_screen_size() -> glue::ScreenSize {
    if let Err(msg) = platform_mode::update(PlatformEffect::GetScreenSize) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        let height = raylib::GetScreenHeight();
        let width = raylib::GetScreenWidth();
        glue::ScreenSize {
            height,
            width,
            z: 0,
        }
    }
}

#[no_mangle]
extern "C" fn roc_fx_get_screen_to_world_2d (point: &glue::RocVector2, boxed_camera: RocBox<()>) -> glue::RocVector2 {
    if let Err(msg) = platform_mode::update(PlatformEffect::GetScreenSize) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }
    unsafe {
        let camera: &mut raylib::Camera2D =
            ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_camera);
        raylib::GetScreenToWorld2D(point.into(), *camera).into()
    }
}

#[no_mangle]
extern "C" fn roc_fx_measure_text(text: &RocStr, size: f32, spacing: f32) -> glue::RocVector2 {
    if let Err(msg) = platform_mode::update(PlatformEffect::MeasureText) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let text = CString::new(text.as_str()).unwrap();

    unsafe {
        let default = raylib::GetFontDefault();
        raylib::MeasureTextEx(default, text.as_ptr(), size, spacing).into()
    }
}

#[no_mangle]
extern "C" fn roc_fx_measure_text_font(
    boxed_font: RocBox<()>,
    text: &RocStr,
    size: f32,
    spacing: f32,
) -> glue::RocVector2 {
    if let Err(msg) = platform_mode::update(PlatformEffect::MeasureText) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let text = CString::new(text.as_str()).unwrap();
    let font: &mut raylib::Font = ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_font);

    unsafe { raylib::MeasureTextEx(*font, text.as_ptr(), size, spacing).into() }
}

#[no_mangle]
extern "C" fn roc_fx_set_target_fps(rate: i32) {
    if let Err(msg) = platform_mode::update(PlatformEffect::SetTargetFPS) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    config::update(|c| {
        c.fps_target_dirty = true;
        c.fps_target = rate as c_int
    });
}

#[no_mangle]
extern "C" fn roc_fx_take_screenshot(path: &RocStr) {
    if let Err(msg) = platform_mode::update(PlatformEffect::TakeScreenshot) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let path = CString::new(path.as_str()).unwrap();

    unsafe {
        raylib::TakeScreenshot(path.as_ptr());
    }
}

#[no_mangle]
extern "C" fn roc_fx_set_draw_fps(show: bool, pos: &glue::RocVector2) {
    if let Err(msg) = platform_mode::update(PlatformEffect::SetDrawFPS) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    config::update(|c| {
        c.fps_show = show;
        c.fps_position = pos.to_components_c_int();
    });
}

#[no_mangle]
extern "C" fn roc_fx_get_camera_matrix_2d(_boxed_camera: RocBox<()>) -> glue::RocMatrix {
    let camera: &mut raylib::Camera2D =
        ThreadSafeRefcountedResourceHeap::box_to_resource(_boxed_camera);

    let matrix = unsafe { raylib::GetCameraMatrix2D(*camera) };

    return matrix.into();
}

#[no_mangle]
extern "C" fn roc_fx_create_camera(
    target: &glue::RocVector2,
    offset: &glue::RocVector2,
    rotation: f32,
    zoom: f32,
) -> RocResult<RocBox<()>, RocStr> {
    if let Err(msg) = platform_mode::update(PlatformEffect::CreateCamera) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let camera = raylib::Camera2D {
        target: target.into(),
        offset: offset.into(),
        rotation,
        zoom,
    };

    let heap = roc::camera_heap();

    let alloc_result = heap.alloc_for(camera);
    match alloc_result {
        Ok(roc_box) => RocResult::ok(roc_box),
        Err(_) => RocResult::err("Unable to load camera, out of memory in the camera heap. Consider using ROC_RAY_MAX_CAMERAS_HEAP_SIZE env var to increase the heap size.".into()),
    }
}

#[no_mangle]
extern "C" fn roc_fx_create_render_texture(
    size: &glue::RocVector2,
) -> RocResult<RocBox<()>, RocStr> {
    if let Err(msg) = platform_mode::update(PlatformEffect::CreateRenderTexture) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let (width, height) = size.to_components_c_int();

    let render_texture = unsafe { raylib::LoadRenderTexture(width, height) };

    let heap = roc::render_texture_heap();

    let alloc_result = heap.alloc_for(render_texture);
    match alloc_result {
        Ok(roc_box) => RocResult::ok(roc_box),
        Err(_) => RocResult::err("Unable to load render texture, out of memory in the render texture heap. Consider using ROC_RAY_MAX_RENDER_TEXTURE_HEAP_SIZE env var to increase the heap size.".into()),
    }
}

#[no_mangle]
extern "C" fn roc_fx_update_camera(
    boxed_camera: RocBox<()>,
    target: &glue::RocVector2,
    offset: &glue::RocVector2,
    rotation: f32,
    zoom: f32,
) {
    if let Err(msg) = platform_mode::update(PlatformEffect::UpdateCamera) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let camera: &mut raylib::Camera2D =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_camera);

    camera.target = target.into();
    camera.offset = offset.into();
    camera.rotation = rotation;
    camera.zoom = zoom;
}

#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_begin_mode_2d(boxed_camera: RocBox<()>) {
    if let Err(msg) = platform_mode::update(PlatformEffect::BeginMode2D) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        let camera: &mut raylib::Camera2D =
            ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_camera);

        raylib::BeginMode2D(*camera);
    }
}

#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_begin_shader_mode(boxed_shader: RocBox<()>) {

    unsafe {
        let shader: &mut raylib::Shader =
            ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_shader);

        raylib::BeginShaderMode(*shader);
    }
}

#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_get_shader_location(boxed_shader: RocBox<()>, uniform_name: &RocStr) -> RocResult<i32, RocStr> {
    let uniform = CString::new(uniform_name.to_string().as_str()).unwrap();

    let location = unsafe {
        let shader: &mut raylib::Shader =
            ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_shader);
        let location = raylib::GetShaderLocation(*shader, uniform.as_ptr());
        if location < 0 {
            return RocResult::err(
            format!("Uniform location for '{}' not found", uniform_name.to_string())
                .as_str()
                .into(),
            )
        } else {
            return RocResult::ok(location);
        }
    };
}

#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_set_shader_value(boxed_shader: RocBox<()>, loc_index: i32, value: f32) {
    let f = &value as *const f32 as *const c_void;
    return unsafe {
        let shader: &mut raylib::Shader =
            ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_shader);
        raylib::SetShaderValue(*shader, loc_index, f, raylib::ShaderUniformDataType_SHADER_UNIFORM_FLOAT.try_into().unwrap());
    }
}
#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_set_shader_value_int(boxed_shader: RocBox<()>, loc_index: i32, value: i32) {
    let f = &value as *const i32 as *const c_void;
    return unsafe {
        let shader: &mut raylib::Shader =
            ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_shader);
        raylib::SetShaderValue(*shader, loc_index, f, raylib::ShaderUniformDataType_SHADER_UNIFORM_INT.try_into().unwrap());
    }
}
#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_set_shader_value_vec2(boxed_shader: RocBox<()>, loc_index: i32, value: &glue::RocVector2) {
    let shader: &mut raylib::Shader = ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_shader);
    let value_ : raylib::Vector2 = value.into();
    let ptr_ = &value_ as *const raylib::Vector2 as *const c_void;
    return unsafe {
        raylib::SetShaderValue(*shader, loc_index, ptr_, raylib::ShaderUniformDataType_SHADER_UNIFORM_VEC2.try_into().unwrap());
    }
}

#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_set_shader_value_matrix(boxed_shader: RocBox<()>, loc_index: i32,
     m0: f32,  m4: f32,  m8: f32,  m12: f32,
     m1: f32,  m5: f32,  m9: f32,  m13: f32,
     m2: f32,  m6: f32,  m10: f32,  m14: f32,
     m3: f32,  m7: f32,  m11: f32,  m15: f32,
) {
    let mat4 = raylib::Matrix {
            m0 : m0, m4 : m4, m8 : m8, m12 : m8,
            m1 : m1, m5 : m5, m9 : m9, m13 : m13,
            m2 : m2, m6 : m6, m10 : m10, m14 : m14,
            m3 : m3, m7 : m7, m11 : m11, m15 : m15,
        };
    return unsafe {
        let shader: &mut raylib::Shader =
            ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_shader);
        raylib::SetShaderValueMatrix(*shader, loc_index, mat4);
    }
}
#[no_mangle]
extern "C" fn roc_fx_end_mode_2d(_boxed_camera: RocBox<()>) {
    if let Err(msg) = platform_mode::update(PlatformEffect::EndMode2D) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        raylib::EndMode2D();
    }
}

#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_begin_texture(boxed_render_texture: RocBox<()>, clear_color: glue::RocColor) {
    if let Err(msg) = platform_mode::update(PlatformEffect::BeginDrawingTexture) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        let render_texture: &mut raylib::RenderTexture =
            ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_render_texture);

        raylib::BeginTextureMode(*render_texture);
        raylib::ClearBackground(clear_color.into());
    }
}

#[no_mangle]
extern "C" fn roc_fx_end_texture(_boxed_render_texture: RocBox<()>) {
    if let Err(msg) = platform_mode::update(PlatformEffect::EndDrawingTexture) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        raylib::EndTextureMode();
    }
}

#[no_mangle]
extern "C" fn roc_fx_end_shader_mode() {
    unsafe {
        raylib::EndShaderMode();
    }
}

#[no_mangle]
extern "C" fn roc_fx_load_sound(path: &RocStr) -> RocResult<RocBox<()>, RocStr> {
    if let Err(msg) = platform_mode::update(PlatformEffect::LoadSound) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    // Check the file exists, so we can give a more helpful error message
    let file_path = std::path::Path::new(path.as_str());
    if !file_path.exists() {
        return RocResult::err(
            format!("Sound file not found: {}", file_path.display())
                .as_str()
                .into(),
        );
    }

    let path = CString::new(path.as_str()).unwrap();
    let sound = unsafe { raylib::LoadSound(path.as_ptr()) };

    let heap = roc::sound_heap();

    let alloc_result = heap.alloc_for(sound);
    match alloc_result {
        Ok(roc_box) => RocResult::ok(roc_box),
        Err(_) => RocResult::err("Unable to load sound, out of memory in the sound heap. Consider using ROC_RAY_MAX_SOUNDS_HEAP_SIZE env var to increase the heap size.".into())
    }
}

#[no_mangle]
extern "C" fn roc_fx_play_sound(boxed_sound: RocBox<()>) {
    if let Err(msg) = platform_mode::update(PlatformEffect::PlaySound) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let sound: &mut raylib::Sound = ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_sound);

    unsafe {
        raylib::PlaySound(*sound);
    }
}

#[no_mangle]
extern "C" fn roc_fx_load_music_stream(path: &RocStr) -> RocResult<roc::LoadedMusic, RocStr> {
    if let Err(msg) = platform_mode::update(PlatformEffect::LoadMusicStream) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let file_path = std::path::Path::new(path.as_str());
    if !file_path.exists() {
        return RocResult::err(
            format!("Music file not found: {}", file_path.display())
                .as_str()
                .into(),
        );
    }

    let path = CString::new(path.as_str()).unwrap();

    let music = unsafe { raylib::LoadMusicStream(path.as_ptr()) };

    let alloc_result = roc::alloc_music_stream(music);
    match alloc_result {
        Ok(loaded_music) => RocResult::ok(loaded_music),
        Err(_) => RocResult::err("Unable to load music stream, out of memory in the music heap. Consider using ROC_RAY_MAX_MUSIC_STREAMS_HEAP_SIZE env var to increase the heap size.".into()),
    }
}

#[no_mangle]
extern "C" fn roc_fx_play_music_stream(boxed_music: RocBox<()>) {
    if let Err(msg) = platform_mode::update(PlatformEffect::PlayMusicStream) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let music: &mut raylib::Music = ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_music);

    unsafe {
        raylib::PlayMusicStream(*music);
    }
}

#[no_mangle]
extern "C" fn roc_fx_stop_music_stream(boxed_music: RocBox<()>) {
    if let Err(msg) = platform_mode::update(PlatformEffect::PlayMusicStream) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let music: &mut raylib::Music = ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_music);

    unsafe {
        raylib::StopMusicStream(*music);
    }
}

#[no_mangle]
extern "C" fn roc_fx_pause_music_stream(boxed_music: RocBox<()>) {
    if let Err(msg) = platform_mode::update(PlatformEffect::PlayMusicStream) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let music: &mut raylib::Music = ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_music);

    unsafe {
        raylib::PauseMusicStream(*music);
    }
}

#[no_mangle]
extern "C" fn roc_fx_resume_music_stream(boxed_music: RocBox<()>) {
    if let Err(msg) = platform_mode::update(PlatformEffect::PlayMusicStream) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let music: &mut raylib::Music = ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_music);

    unsafe {
        raylib::ResumeMusicStream(*music);
    }
}

// NOTE: the RocStr in this error type is to work around a compiler bug
#[no_mangle]
extern "C" fn roc_fx_get_music_time_played(boxed_music: RocBox<()>) -> f32 {
    if let Err(msg) = platform_mode::update(PlatformEffect::PlayMusicStream) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let music: &mut raylib::Music = ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_music);

    unsafe { raylib::GetMusicTimePlayed(*music) }
}

#[no_mangle]
extern "C" fn roc_fx_load_texture(path: &RocStr) -> RocResult<RocBox<()>, RocStr> {
    if let Err(msg) = platform_mode::update(PlatformEffect::LoadTexture) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let file_path = std::path::Path::new(path.as_str());
    if !file_path.exists() {
        return RocResult::err(
            format!("Texture file not found: {}", file_path.display())
                .as_str()
                .into(),
        );
    }

    // Check file extension
    if let Some(extension) = file_path.extension() {
        // https://github.com/raysan5/raylib/blob/master/FAQ.md#what-file-formats-are-supported-by-raylib
        // Image/Textures: PNG, BMP, TGA, JPG, GIF, QOI, PSD, DDS, HDR, KTX, ASTC, PKM, PVR
        let valid_extensions = [
            "png", "bmp", "tga", "jpg", "gif", "qoi", "psd", "dds", "hdr", "ktx", "astc", "pkm",
            "pvr",
        ];
        if !valid_extensions.contains(&extension.to_str().unwrap_or("").to_lowercase().as_str()) {
            return RocResult::err(
                format!(
                    "Unsupported texture format: {}. Supported formats: {:?}",
                    extension.to_str().unwrap_or("unknown"),
                    valid_extensions
                )
                .as_str()
                .into(),
            );
        }
    } else {
        return RocResult::err("Texture file must have an extension".into());
    }

    let path = match CString::new(path.as_str()) {
        Ok(s) => s,
        Err(_) => return RocResult::err("Invalid characters in texture path".into()),
    };

    let texture: raylib::Texture = unsafe { raylib::LoadTexture(path.as_ptr()) };

    // Validate texture loading success
    if texture.id == 0 || texture.width == 0 || texture.height == 0 {
        return RocResult::err(
            format!(
                "Failed to load texture: {}. Verify the file is a valid image.",
                file_path.display()
            )
            .as_str()
            .into(),
        );
    }

    let heap = roc::texture_heap();

    let alloc_result = heap.alloc_for(texture);
    match alloc_result {
        Ok(roc_box) => RocResult::ok(roc_box),
        Err(_) => RocResult::err("Unable to load texture, out of memory in the texture heap. Consider using ROC_RAY_MAX_TEXTURES_HEAP_SIZE env var to increase the heap size.".into()),
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_texture_rec(
    boxed_texture: RocBox<()>,
    source: &glue::RocRectangle,
    position: &glue::RocVector2,
    color: glue::RocColor,
) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawTextureRectangle) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let texture: &mut raylib::Texture =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_texture);

    unsafe {
        raylib::DrawTextureRec(*texture, source.into(), position.into(), color.into());
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_texture_pro(
    boxed_texture: RocBox<()>,
    source: &glue::RocRectangle,
    dest: &glue::RocRectangle,
    position: &glue::RocVector2,
    rotation: f32,
    color: glue::RocColor,
) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawTextureRectangle) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let texture: &mut raylib::Texture =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_texture);

    unsafe {
        raylib::DrawTexturePro(
            *texture,
            source.into(),
            dest.into(),
            position.into(),
            rotation,
            color.into()
        );
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_render_texture_rec(
    boxed_texture: RocBox<()>,
    source: &glue::RocRectangle,
    position: &glue::RocVector2,
    color: glue::RocColor,
) {
    if let Err(msg) = platform_mode::update(PlatformEffect::DrawTextureRectangle) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let texture: &mut raylib::RenderTexture =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_texture);

    unsafe {
        raylib::DrawTextureRec(
            texture.texture,
            source.into(),
            position.into(),
            color.into(),
        );
    }
}
#[no_mangle]
extern "C" fn roc_fx_draw_render_texture_pro(
    boxed_texture: RocBox<()>,
    source: &glue::RocRectangle,
    dest: &glue::RocRectangle,
    origin: &glue::RocVector2,
    rotation: f32,
    color: glue::RocColor,
) {
    let texture: &mut raylib::RenderTexture =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_texture);

    unsafe {
        raylib::DrawTexturePro(
            texture.texture,
            source.into(),
            dest.into(),
            origin.into(),
            rotation,
            color.into(),
        );
    }
}

#[no_mangle]
extern "C" fn roc_fx_draw_poly(
    center: &glue::RocVector2,
    sides: i32,
    radius: f32,
    rotation: f32,
    color: glue::RocColor,
) {
    unsafe {
        raylib::DrawPoly(
            center.into(),
            sides,
            radius,
            rotation,
            color.into(),
        );
    }
}

#[no_mangle]
extern "C" fn roc_fx_set_render_texture_filter(
    boxed_texture: RocBox<()>,
    filter_mode: i32,
) {
    let texture: &mut raylib::RenderTexture =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_texture);
    unsafe {
        raylib::SetTextureFilter(texture.texture, filter_mode);
    }

}

#[no_mangle]
extern "C" fn roc_fx_load_file_to_str(path: &RocStr) -> RocResult<RocStr, RocStr> {
    if let Err(msg) = platform_mode::update(PlatformEffect::LoadFileToStr) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let path = path.as_str();
    let Ok(contents) = std::fs::read_to_string(path) else {
        return RocResult::err(format!("File not found: {}", path).as_str().into());
    };

    let contents = contents.replace("\r\n", "\n");
    let contents = unsafe { RocStr::from_slice_unchecked(contents.as_bytes()) };

    RocResult::ok(contents)
}

#[no_mangle]
extern "C" fn roc_fx_send_to_peer(bytes: &RocList<u8>, peer: &glue::PeerUUID) {
    if let Err(msg) = platform_mode::update(PlatformEffect::SendMsgToPeer) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let data = bytes.as_slice().to_vec();

    worker::send_message(worker::MainToWorkerMsg::SendMessage(peer.into(), data));
}

#[no_mangle]
extern "C" fn roc_fx_configure_web_rtc(url: &RocStr) {
    if let Err(msg) = platform_mode::update(PlatformEffect::ConfigureNetwork) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    #[cfg(target_arch = "wasm32")]
    display_fatal_error_message(
        "TODO : Implement WebRTC networking for web targets".to_string(),
        ExitErrCode::NotYetImplemented,
    );

    config::update(|c| c.network_web_rtc_url = Some(url.to_string()));
}

#[no_mangle]
extern "C" fn roc_fx_load_font(path: &RocStr) -> RocResult<RocBox<()>, RocStr> {
    if let Err(msg) = platform_mode::update(PlatformEffect::LoadFont) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    if !std::path::Path::new(path.as_str()).exists() {
        return RocResult::err(format!("Font file not found at {}", path).as_str().into());
    }

    let path = CString::new(path.to_string().as_str()).unwrap();

    let font = unsafe { raylib::LoadFont(path.as_ptr()) };

    let heap = roc::font_heap();

    let alloc_result = heap.alloc_for(font);

    match alloc_result {
            Ok(roc_box) => RocResult::ok(roc_box),
            Err(_) => {
                RocResult::err("Unable to load font, out of memory in the font heap. Consider using ROC_RAY_MAX_FONT_HEAP_SIZE env var to increase the heap size.".into())
            }
        }
}

#[no_mangle]
extern "C" fn roc_fx_load_shader(vertex_shader: &RocStr, fragment_shader: &RocStr) -> RocResult<RocBox<()>, RocStr> {
    if let Err(msg) = platform_mode::update(PlatformEffect::LoadFont) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    let v_shader_path = CString::new(vertex_shader.to_string().as_str()).unwrap();
    let f_shader_path = CString::new(fragment_shader.to_string().as_str()).unwrap();
    let shader = unsafe { raylib::LoadShader(v_shader_path.as_ptr(), f_shader_path.as_ptr()) };

    let heap = roc::shader_heap();
    let alloc_result = heap.alloc_for(shader);

    match alloc_result {
            Ok(roc_box) => RocResult::ok(roc_box),
            Err(err) => {
                RocResult::err("Unable to load shader, out of memory in the shader heap. Consider using ROC_RAY_MAX_SHADER_HEAP_SIZE env var to increase the heap size.".into())
            }
        }
}

// TODO remove the Level or start using it again...
#[no_mangle]
extern "C" fn roc_fx_log(msg: &RocStr, _level: i32) {
    if let Err(msg) = platform_mode::update(PlatformEffect::LogMsg) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    logger::log(msg.to_string().as_str());
}

//#[no_mangle]
//extern "C" fn roc_fx_update_texture(boxed_texture: RocBox<()>, pixel_ptr: *const u8, byte_len: usize,) {
//    if pixel_ptr.is_null() || byte_len == 0 {
//        return;
//    }
//    unsafe {
//        let texture: &mut raylib::Texture = ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_texture);
//    //let font: &mut raylib::Font = ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_font);
//        let void_ptr = pixel_ptr as *const std::ffi::c_void;
//        raylib::UpdateTexture(*texture, void_ptr);
//    }
//}

// #[repr(C)]
// pub enum RocPixelFormat {
//     UncompressedGrayScale =1,
//     UncompressedGrayAlpha = 2,
//     UncompressedR5G6B5 = 3,
//     UncompressedR8G8B8 = 4,
//     UncompressedR8G8B8A8 = 5,
// }

#[no_mangle]
extern "C" fn roc_fx_texture_format(boxed_texture: RocBox<()>) -> u32 {
    let tex: &raylib::Texture = ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_texture);
    tex.format as u32
}

#[no_mangle]
extern "C" fn roc_fx_draw_triangle_fan(points: &RocList<glue::RocVector2>, color: glue::RocColor) {
    let tmp: Vec<raylib::Vector2> =
        points.iter().map(|p| p.into()).collect();
    unsafe {
        raylib::DrawTriangleFan(
            tmp.as_ptr() as *const raylib::Vector2,
            points.len() as i32,
            color.into(),
        );
    }
}

#[no_mangle]
extern "C" fn roc_fx_begin_blend_mode(mode: i32) {
    unsafe {
        raylib::BeginBlendMode(mode);
    }
}
#[no_mangle]
extern "C" fn roc_fx_end_blend_mode() {
    unsafe {
        raylib::EndBlendMode();
    }
}

#[no_mangle]
extern "C" fn roc_fx_gen_image_color(width: i32, height: i32, color: glue::RocColor) -> RocResult<RocBox<()>, RocStr> {
    let image = unsafe {
        raylib::GenImageColor(width.into(), height.into(), color.into())
    };

    if image.height != height || image.width != width {
        return RocResult::err(
            "failed to generate image".into()
        )
    }

    let heap = roc::image_heap();
    let alloc_result = heap.alloc_for(image);

    match alloc_result {
        Ok(roc_box) => RocResult::ok(roc_box),
        Err(err) =>
            RocResult::err(
                format!(
                    "Unble to generate image heap: {}", err.to_string()
                )
                .as_str().into()
        )
    }
}

#[no_mangle]
extern "C" fn roc_fx_gen_image_perlin_noise(width: i32, height: i32, offset_x: i32, offset_y: i32, scale: f32) -> RocResult<RocBox<()>, RocStr> {
    let image = unsafe {
        raylib::GenImagePerlinNoise(width.into(), height.into(), offset_x.into(), offset_y.into(), scale.into())
    };

    if image.height != height || image.width != width {
        return RocResult::err(
            "failed to generate image, invalid height and/or width do not match".into()
        )
    }

    let heap = roc::image_heap();
    let alloc_result = heap.alloc_for(image);

    match alloc_result {
        Ok(roc_box) => RocResult::ok(roc_box),
        Err(err) =>
            RocResult::err(
            format!(
                "Failed to generate image heap for Perlin Noise: {}", err.to_string()
            ).as_str().into()
        )
    }
}

#[no_mangle]
extern "C" fn roc_fx_load_texture_from_image(boxed_image: RocBox<()>) -> RocResult<RocBox<()>, RocStr> {
    if let Err(msg) = platform_mode::update(PlatformEffect::LoadTexture) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }
    let image: &mut raylib::Image =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_image);

    let texture: raylib::Texture = unsafe { raylib::LoadTextureFromImage(*image) };
    // Validate texture loading success
    if texture.id == 0 || texture.width == 0 || texture.height == 0 {
        return RocResult::err(
            format!(
                "Failed to load texture. Verify the image is valid.",
            )
            .as_str()
            .into(),
        );
    }
    let heap = roc::texture_heap();
    let alloc_result = heap.alloc_for(texture);
    match alloc_result {
        Ok(roc_box) => RocResult::ok(roc_box),
        Err(_) => RocResult::err("Unable to load texture, out of memory in the texture heap. Consider using ROC_RAY_MAX_TEXTURES_HEAP_SIZE env var to increase the heap size.".into()),
    }
}

#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_update_texture_from_image(
    boxed_texture: RocBox<()>,
    boxed_image: RocBox<()>,
) {
    let texture: &raylib::Texture2D =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_texture);

    let image: &raylib::Image =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_image);

    unsafe {
        raylib::UpdateTexture(
            *texture,
            image.data,
        );
    }
}

#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_set_shader_value_texture(
    boxed_shader: RocBox<()>,
    loc_index: i32,
    boxed_texture: RocBox<()>,
) {
    let shader: &mut raylib::Shader =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_shader);

    let texture: &raylib::Texture2D =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_texture);

    unsafe {
        raylib::SetShaderValueTexture(*shader, loc_index, *texture);
    }
}
