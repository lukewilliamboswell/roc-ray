use config::ExitErrCode;
// use glue::PeerMessage;
// use matchbox_socket::{PeerId, PeerState};
use platform_mode::PlatformEffect;
use roc_std::{RocList, RocStr};
use std::ffi::{c_int, CString};

#[cfg(target_family = "wasm")]
extern crate console_error_panic_hook;

extern crate raylib;

mod config;
mod glue;
mod logger;
mod platform_mode;
mod platform_time;
mod roc;

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
    }

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
        while !raylib::WindowShouldClose() {
            if let Some(msg_code) = config::with(|c| c.should_exit_msg_code.clone()) {
                draw_fatal_error(msg_code);
            } else {
                app.render();
            }
        }
    }
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

/// The draw loop will display a fatal error message
fn display_fatal_error_message(msg: String, code: ExitErrCode) {
    config::update(|c| {
        c.should_exit_msg_code = Some((msg.clone(), code));
    });

    logger::log(msg.as_str());
}

#[allow(unused_variables)]
fn trace_log(msg: &str) {
    unsafe {
        let level = raylib::TraceLogLevel_LOG_DEBUG;
        let text = CString::new(msg).unwrap();
        raylib::TraceLog(level as i32, text.as_ptr());
    }
}

#[no_mangle]
extern "C" fn roc_fx_exit() {
    config::update(|c| c.should_exit = true);
}

#[no_mangle]
extern "C" fn roc_fx_initWindow(title: &RocStr, width: f32, height: f32) {
    config::update(|c| {
        c.title = CString::new(title.to_string()).unwrap();
        c.width = width as i32;
        c.height = height as i32;
    });

    if let Err(msg) = platform_mode::update(PlatformEffect::InitWindow) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }
}

#[no_mangle]
extern "C" fn roc_fx_beginDrawing(clear_color: glue::RocColor) {
    if let Err(msg) = platform_mode::update(PlatformEffect::BeginDrawingFramebuffer) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        raylib::BeginDrawing();
        raylib::ClearBackground(clear_color.into());
    }
}

#[no_mangle]
extern "C" fn roc_fx_endDrawing() {
    if let Err(msg) = platform_mode::update(PlatformEffect::EndDrawingFramebuffer) {
        display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    }

    unsafe {
        raylib::EndDrawing();
    }
}

#[no_mangle]
extern "C" fn roc_fx_drawText(
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
fn get_mouse_button_states() -> RocList<u8> {
    let mouse_buttons: [u8; 7] = std::array::from_fn(|i| {
        unsafe {
            if raylib::IsMouseButtonPressed(i as c_int) {
                0
            } else if raylib::IsMouseButtonReleased(i as c_int) {
                1
            } else if raylib::IsMouseButtonDown(i as c_int) {
                2
            } else {
                // Up
                3
            }
        }
    });

    RocList::from_slice(&mouse_buttons)
}

fn get_keys_states() -> RocList<u8> {
    let keys: [u8; 350] = std::array::from_fn(|i| {
        unsafe {
            if raylib::IsKeyPressed(i as c_int) {
                0
            } else if raylib::IsKeyReleased(i as c_int) {
                1
            } else if raylib::IsKeyDown(i as c_int) {
                2
            } else if raylib::IsKeyUp(i as c_int) {
                3
            } else {
                // PressedRepeat
                4
            }
        }
    });

    RocList::from_slice(&keys)
}
