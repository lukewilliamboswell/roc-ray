use raylib::prelude::*;
use roc_std::{RocList, RocResult, RocStr};
use std::ffi::{c_int, CString};
use std::time::SystemTime;

mod roc;

fn main() {
    unsafe {
        let c_title = CString::new("Loading...").unwrap();
        raylib::ffi::InitWindow(100, 50, c_title.as_ptr());
        if !raylib::ffi::IsWindowReady() {
            panic!("Attempting to create window failed!");
        }

        let mut model = roc::call_roc_init();
        let mut frame_count = 0;

        while !raylib::ffi::WindowShouldClose() {
            raylib::ffi::BeginDrawing();

            let duration_since_epoch = SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap();

            let timestamp = duration_since_epoch.as_millis() as u64; // we are casting to u64 and losing precision

            let platform_state = roc::PlatformState {
                timestamp_millis: timestamp,
                frame_count,
                keys_down: RocList::empty(),
                mouse_down: RocList::empty(),
                mouse_pos_x: (raylib::ffi::GetMouseX() as i32).as_f32(),
                mouse_pos_y: (raylib::ffi::GetMouseY() as i32).as_f32(),
            };

            model = roc::call_roc_render(platform_state, &model);

            // TODO will need to model this differently for roc to use...
            // if (show_fps) {
            //     rl.drawFPS(show_fps_pos_x, show_fps_pos_y);
            // }

            frame_count += 1;

            raylib::ffi::EndDrawing();
        }
    }
}

#[no_mangle]
pub extern "C" fn roc_fx_exit() -> RocResult<(), ()> {
    todo!("roc_fx_exit");
}

#[no_mangle]
pub unsafe extern "C" fn roc_fx_log(msg: &RocStr, level: i32) -> RocResult<(), ()> {
    let text = CString::new(msg.as_str()).unwrap();
    if level >= 0 && level <= 7 {
        raylib::ffi::TraceLog(level, text.as_ptr())
    } else {
        panic!("Invalid log level from roc");
    }

    RocResult::ok(())
}

#[no_mangle]
pub unsafe extern "C" fn roc_fx_setWindowSize(width: i32, height: i32) -> RocResult<(), ()> {
    raylib::ffi::SetWindowSize(width, height);
    RocResult::ok(())
}

#[no_mangle]
pub unsafe extern "C" fn roc_fx_setWindowTitle(text: &RocStr) -> RocResult<(), ()> {
    let text = CString::new(text.as_str()).unwrap();
    raylib::ffi::SetWindowTitle(text.as_ptr());

    RocResult::ok(())
}

#[no_mangle]
pub unsafe extern "C" fn roc_fx_drawCircle(
    center_x: f32,
    center_y: f32,
    radius: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) -> RocResult<(), ()> {
    let center = raylib::ffi::Vector2 {
        x: center_x,
        y: center_y,
    };
    let color = raylib::ffi::Color { r, g, b, a };
    raylib::ffi::DrawCircleV(center, radius, color);

    RocResult::ok(())
}

#[no_mangle]
pub unsafe extern "C" fn roc_fx_drawCircleGradient(
    center_x: f32,
    center_y: f32,
    radius: f32,
    r1: u8,
    g1: u8,
    b1: u8,
    a1: u8,
    r2: u8,
    g2: u8,
    b2: u8,
    a2: u8,
) -> RocResult<(), ()> {
    let color1 = raylib::ffi::Color {
        r: r1,
        g: g1,
        b: b1,
        a: a1,
    };
    let color2 = raylib::ffi::Color {
        r: r2,
        g: g2,
        b: b2,
        a: a2,
    };
    raylib::ffi::DrawCircleGradient(center_x as c_int, center_y as c_int, radius, color1, color2);
    RocResult::ok(())
}

#[no_mangle]
pub unsafe extern "C" fn roc_fx_drawRectangleGradient(
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    r1: u8,
    g1: u8,
    b1: u8,
    a1: u8,
    r2: u8,
    g2: u8,
    b2: u8,
    a2: u8,
) -> RocResult<(), ()> {
    let color1 = raylib::ffi::Color {
        r: r1,
        g: g1,
        b: b1,
        a: a1,
    };
    let color2 = raylib::ffi::Color {
        r: r2,
        g: g2,
        b: b2,
        a: a2,
    };
    raylib::ffi::DrawRectangleGradientV(
        x as c_int,
        y as c_int,
        width as c_int,
        height as c_int,
        color1,
        color2,
    );
    RocResult::ok(())
}

#[no_mangle]
pub unsafe extern "C" fn roc_fx_drawText(
    x: f32,
    y: f32,
    size: i32,
    text: &RocStr,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) -> RocResult<(), ()> {
    let text = CString::new(text.as_str()).unwrap();
    let color = raylib::ffi::Color { r, g, b, a };
    raylib::ffi::DrawText(text.as_ptr(), x as c_int, y as c_int, size as c_int, color);
    RocResult::ok(())
}

#[no_mangle]
pub unsafe extern "C" fn roc_fx_drawRectangle(
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) -> RocResult<(), ()> {
    let position = raylib::ffi::Vector2 { x, y };
    let size = raylib::ffi::Vector2 {
        x: width,
        y: height,
    };
    let color = raylib::ffi::Color { r, g, b, a };
    raylib::ffi::DrawRectangleV(position, size, color);
    RocResult::ok(())
}
