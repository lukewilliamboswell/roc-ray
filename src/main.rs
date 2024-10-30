use config::ExitErrCode;
use roc_std::{RocBox, RocStr};
use std::cell::RefCell;
use std::ffi::{c_int, CString};

#[cfg(target_family = "wasm")]
extern crate console_error_panic_hook;

extern crate raylib;

mod config;
mod glue;
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

    // https://emscripten.org/docs/api_reference/emscripten.h.html#c.emscripten_force_exit
    fn emscripten_force_exit(status: c_int);
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
        if let Some(msg_code) = config::with(|c| c.should_exit_msg_code.clone()) {
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

            let error_msg = CString::new(msg_code.0).unwrap();
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
        } else {
            raylib::BeginDrawing();

            raylib::ClearBackground(raylib::Color {
                r: 100,
                g: 255,
                b: 100,
                a: 255,
            });

            let mouse_x = raylib::GetMouseX();
            let mouse_y = raylib::GetMouseY();
            let blue = raylib::Color {
                r: 0,
                g: 0,
                b: 255,
                a: 255,
            };

            raylib::DrawCircle(mouse_x, mouse_y, 10.0, blue);

            let text = CString::new("It's working").unwrap();
            raylib::DrawText(
                text.as_ptr(),
                10,
                10,
                20,
                raylib::Color {
                    r: 255,
                    g: 255,
                    b: 255,
                    a: 255,
                },
            );

            let platform_state = glue::PlatformState::default();

            let model = get_model();
            let model = roc::call_roc_render(platform_state, model);
            set_model(model);

            raylib::EndDrawing();
        }
    }
}

fn game_loop() {
    #[cfg(target_family = "wasm")]
    unsafe {
        emscripten_set_main_loop(draw_loop, 0, 0);
    }

    #[cfg(target_family = "unix")]
    unsafe {
        while !raylib::WindowShouldClose() {
            draw_loop();
        }
    }

    #[cfg(target_family = "windows")]
    unsafe {
        while !raylib::WindowShouldClose() {
            draw_loop();
        }
    }
}

fn main() {
    #[cfg(target_arch = "wasm32")]
    console_error_panic_hook::set_once();

    unsafe {
        let text = CString::new("Cross platform Raylib!").unwrap();
        raylib::SetConfigFlags(raylib::ConfigFlags_FLAG_WINDOW_RESIZABLE);
        raylib::InitWindow(640, 480, text.as_ptr());
        raylib::SetTargetFPS(120);
    }

    let model = roc::call_roc_init();
    set_model(model);

    game_loop();
}

/// exit the program with a message and a code, close the window
fn display_fatal_error_message(msg: String, code: ExitErrCode) {
    config::update(|c| {
        c.should_exit_msg_code = Some((msg, code));
    });
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
    //     exit_with_msg(msg, ExitErrCode::ExitEffectNotPermitted);
    // }

    display_fatal_error_message(
        "ASDFASDASDF".to_string(),
        ExitErrCode::ExitEffectNotPermitted,
    );

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
