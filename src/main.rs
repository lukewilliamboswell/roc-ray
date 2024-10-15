use raylib::prelude::*;
use roc_std::{RocList, RocResult, RocStr};
use std::borrow::BorrowMut;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime};

mod roc;

// We definitely should find a better solution to this!!!
static RL: OnceLock<Arc<Mutex<raylib::RaylibHandle>>> = OnceLock::new();

fn get_rl() -> &'static Arc<Mutex<raylib::RaylibHandle>> {
    RL.get().expect("raylib should have been initialised")
}

fn main() {
    let (rl, thread) = raylib::init().size(100, 100).title("Loading...").build();

    RL.set(Arc::new(Mutex::new(rl)))
        .expect("raylib should not have been initialised");

    let mut model = roc::call_roc_init();
    let mut frame_count = 0;
    let mut should_close = false;

    while !should_close {
        {
            let rl = get_rl().lock().unwrap();
            should_close = rl.window_should_close();
        }

        {
            let mut rl = get_rl().lock().unwrap();
            let mut d = rl.begin_drawing(&thread);

            d.clear_background(Color::WHITE);
            // d.draw_text("Hello, world!", 12, 12, 20, Color::BLACK);
        }

        let duration_since_epoch = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap();

        let timestamp = duration_since_epoch.as_millis() as u64; // we are casting to u64 and losing precision

        let rl = get_rl().lock().unwrap();
        let mouse_pos_x = rl.get_mouse_x().as_f32();
        let mouse_pos_y = rl.get_mouse_y().as_f32();

        let platform_state = roc::PlatformState {
            timestamp_millis: timestamp,
            frame_count,
            keys_down: RocList::empty(),
            mouse_down: RocList::empty(),
            mouse_pos_x,
            mouse_pos_y,
        };

        model = roc::call_roc_render(platform_state, &model);

        // if (show_fps) {
        //     rl.drawFPS(show_fps_pos_x, show_fps_pos_y);
        // }

        frame_count += 1;
    }
}

#[no_mangle]
pub extern "C" fn roc_fx_exit() -> RocResult<(), ()> {
    todo!("roc_fx_exit");
}

#[no_mangle]
pub extern "C" fn roc_fx_log(msg: &RocStr, level: u8) -> RocResult<(), ()> {
    let rl = get_rl().lock().unwrap();
    match level {
        0 => rl.trace_log(raylib::consts::TraceLogLevel::LOG_ALL, msg.as_str()),
        1 => rl.trace_log(raylib::consts::TraceLogLevel::LOG_TRACE, msg.as_str()),
        2 => rl.trace_log(raylib::consts::TraceLogLevel::LOG_DEBUG, msg.as_str()),
        3 => rl.trace_log(raylib::consts::TraceLogLevel::LOG_INFO, msg.as_str()),
        4 => rl.trace_log(raylib::consts::TraceLogLevel::LOG_WARNING, msg.as_str()),
        5 => rl.trace_log(raylib::consts::TraceLogLevel::LOG_ERROR, msg.as_str()),
        6 => rl.trace_log(raylib::consts::TraceLogLevel::LOG_FATAL, msg.as_str()),
        7 => rl.trace_log(raylib::consts::TraceLogLevel::LOG_NONE, msg.as_str()),
        _ => panic!("Invalid log level from roc"),
    }

    RocResult::ok(())
}

#[no_mangle]
pub extern "C" fn roc_fx_setWindowSize(width: i32, height: i32) -> RocResult<(), ()> {
    let mut rl = get_rl().lock().unwrap();
    rl.set_window_size(width, height);
    RocResult::ok(())
}

#[no_mangle]
pub extern "C" fn roc_fx_setWindowTitle(text: &RocStr) -> RocResult<(), ()> {
    // let mut rl = get_rl().lock().unwrap();
    // rl.set_window_title(test.as_str());
    eprintln!("TODO -- this needs to run in the same thread that started raylib...");
    RocResult::ok(())
}

#[no_mangle]
pub extern "C" fn roc_fx_drawCircle(
    centerX: f32,
    centerY: f32,
    radius: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) -> RocResult<(), ()> {
    eprintln!("TODO roc_fx_drawCircle");
    // let mut rl = get_rl().lock().unwrap();
    // rl.begin_drawing(test.as_str());
    RocResult::ok(())
}

#[no_mangle]
pub extern "C" fn roc_fx_drawCircleGradient(
    centerX: f32,
    centerY: f32,
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
    eprintln!("TODO roc_fx_drawCircleGradient");
    // let mut rl = get_rl().lock().unwrap();
    // rl.begin_drawing(test.as_str());
    RocResult::ok(())
}

#[no_mangle]
pub extern "C" fn roc_fx_drawRectangleGradient(
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
    eprintln!("TODO roc_fx_drawRectangleGradient");
    // let mut rl = get_rl().lock().unwrap();
    // rl.begin_drawing(test.as_str());
    RocResult::ok(())
}

#[no_mangle]
pub extern "C" fn roc_fx_drawText(
    x: f32,
    y: f32,
    size: i32,
    text: &RocStr,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) -> RocResult<(), ()> {
    eprintln!("TODO roc_fx_drawText");
    // let mut rl = get_rl().lock().unwrap();
    // rl.begin_drawing(test.as_str());
    RocResult::ok(())
}

#[no_mangle]
pub extern "C" fn roc_fx_drawRectangle(
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) -> RocResult<(), ()> {
    eprintln!("TODO roc_fx_drawRectangle");
    // let mut rl = get_rl().lock().unwrap();
    // rl.begin_drawing(test.as_str());
    RocResult::ok(())
}
