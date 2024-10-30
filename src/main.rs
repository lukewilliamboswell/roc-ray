use config::ExitErrCode;
// use platform_mode::PlatformEffect;
use roc_std::{RocBox, RocStr};
use std::cell::RefCell;
use std::ffi::CString;

#[cfg(target_family = "wasm")]
extern crate console_error_panic_hook;

extern crate raylib;

mod config;
mod glue;
mod platform_mode;
mod platform_time;
mod roc;

thread_local! {
    static MODEL: RefCell<Option<RocBox<()>>> = RefCell::new(None);
}

fn get_model() -> RocBox<()> {
    MODEL.with(|option_model| {
        option_model
            .borrow()
            .as_ref()
            .map(|model| model.clone())
            .expect("Model not initialized")
    })
}

fn set_model(model: RocBox<()>) {
    MODEL.with(|option_model| {
        *option_model.borrow_mut() = Some(model);
    });
}

#[cfg(target_family = "wasm")]
extern "C" {

    // https://emscripten.org/docs/api_reference/emscripten.h.html#c.emscripten_set_main_loop
    fn emscripten_set_main_loop(loop_fn: extern "C" fn(), fps: i32, sim_infinite_loop: i32);

}

#[cfg(target_family = "wasm")]
#[no_mangle]
pub extern "C" fn on_resize(width: i32, height: i32) {
    unsafe {
        raylib::SetWindowSize(width, height);
    }
}

extern "C" fn draw_loop() {
    unsafe {
        // if let Some(msg_code) = config::with(|c| c.should_exit_msg_code.clone()) {
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

        let error_msg = CString::new("ASDFASDFASDF").unwrap();
        // let error_msg = CString::new(msg_code.0).unwrap();
        raylib::DrawText(
            error_msg.as_ptr(),
            10,
            30,
            20,
            raylib::Color {
                r: 0,
                g: 0,
                b: 0,
                a: 255,
            },
        );

        raylib::EndDrawing();
        // } else {
        //     // if config::with(|c| c.fps_target_dirty) {
        //     //     raylib::SetTargetFPS(config::with(|c| c.fps_target));

        //     //     config::update(|c| c.fps_target_dirty = false);
        //     // }

        //     let platform_state = glue::PlatformState::default();

        //     let model = get_model();
        //     let model = roc::call_roc_render(platform_state, model);
        //     set_model(model);
        // }
    }
}

fn render_loop() {
    #[cfg(target_family = "wasm")]
    unsafe {
        emscripten_set_main_loop(draw_loop, 0, 0);
    }

    #[cfg(target_family = "unix")]
    unsafe {
        while !raylib::WindowShouldClose() && !(config::with(|c| c.should_exit)) {
            draw_loop();
        }
    }

    #[cfg(target_family = "windows")]
    unsafe {
        while !raylib::WindowShouldClose() && !(config::with(|c| c.should_exit)) {
            draw_loop();
        }
    }
}

fn main() {
    #[cfg(target_arch = "wasm32")]
    console_error_panic_hook::set_once();

    // CALL INTO ROC FOR INITALIZATION
    // platform_time::init_start();
    let model = roc::call_roc_init();
    set_model(model);
    // platform_time::init_end();

    // MANUALLY TRANSITION TO RENDER MODE
    // platform_mode::update(PlatformEffect::EndInitWindow).unwrap();

    // // Set initial window state
    // unsafe {
    //     raylib::SetConfigFlags(raylib::ConfigFlags_FLAG_WINDOW_RESIZABLE as u32);
    // }

    render_loop();

    // unsafe {
    //     raylib::CloseWindow();
    // }
}

/// The draw loop will display a fatal error message
fn display_fatal_error_message(msg: String, code: ExitErrCode) {
    config::update(|c| {
        c.should_exit_msg_code = Some((msg.clone(), code));
    });

    // unsafe {
    //     let level = raylib::TraceLogLevel_LOG_FATAL;
    //     let text = CString::new(msg).unwrap();
    //     raylib::TraceLog(level as i32, text.as_ptr());
    // }
}

#[allow(unused_variables)]
fn trace_log(msg: &str) {
    // unsafe {
    //     let level = raylib::TraceLogLevel_LOG_DEBUG;
    //     let text = CString::new(msg).unwrap();
    //     raylib::TraceLog(level as i32, text.as_ptr());
    // }
}

// #[no_mangle]
// extern "C" fn roc_fx_exit() {
//     config::update(|c| c.should_exit = true);
// }

#[no_mangle]
extern "C" fn roc_fx_initWindow(title: &RocStr, width: f32, height: f32) {
    config::update(|c| {
        c.title = CString::new(title.to_string()).unwrap();
        c.width = width as i32;
        c.height = height as i32;
    });

    // trace_log("InitWindow");

    // dbg!(&title, &width, &height);

    // if let Err(msg) = platform_mode::update(PlatformEffect::InitWindow) {
    //     display_fatal_error_message(msg, ExitErrCode::ExitEffectNotPermitted);
    // }

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
}

#[no_mangle]
extern "C" fn roc_fx_beginDrawing(clear_color: glue::RocColor) {
    // if let Err(msg) = platform_mode::update(PlatformEffect::BeginDrawingFramebuffer) {
    //     display_fatal_error_message(msg, ExitErrCode::ExitEffectNotPermitted);
    // }

    unsafe {
        // trace_log("BeginDrawing");
        raylib::BeginDrawing();
        raylib::ClearBackground(clear_color.into());
    }
}

#[no_mangle]
extern "C" fn roc_fx_endDrawing() {
    // if let Err(msg) = platform_mode::update(PlatformEffect::EndDrawingFramebuffer) {
    //     display_fatal_error_message(msg, ExitErrCode::ExitEffectNotPermitted);
    // }

    unsafe {
        // trace_log("EndDrawing");
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
    // if let Err(msg) = platform_mode::update(PlatformEffect::DrawText) {
    //     display_fatal_error_message(msg, ExitErrCode::ExitEffectNotPermitted);
    // }

    // trace_log("DrawText");

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
