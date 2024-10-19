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
    static CLEAR_COLOR: RefCell<glue::RocColor> = const { RefCell::new(glue::RocColor::BLACK) };
    static DRAW_FPS: Cell<Option<(i32, i32)>> = const { Cell::new(None) };
    static SHOULD_EXIT: Cell<bool> = const { Cell::new(false) };
    static SOUNDS: RefCell<Vec<bindings::Sound>> = const { RefCell::new(vec![]) }
}

fn main() {
    unsafe {
        let c_title = CString::new("Loading...").unwrap();

        bindings::InitWindow(100, 50, c_title.as_ptr());
        if !bindings::IsWindowReady() {
            panic!("Attempting to create window failed!");
        }

        bindings::InitAudioDevice();

        // // This plays a sound correctly:
        // {
        //     let path = RocStr::from("resources/sound.wav");
        //     let sound_id = load_sound_internal(path);
        //     roc_fx_playSound(sound_id);
        //     // I HOPE this is only necessary because our program is exiting immediately
        //     std::thread::sleep(std::time::Duration::from_secs(1));
        // }

        let mut model = roc::call_roc_init();
        println!("we never get to this message after init");

        let mut frame_count = 0;

        while !bindings::WindowShouldClose() && !SHOULD_EXIT.get() {
            bindings::BeginDrawing();

            CLEAR_COLOR.with(|cc| {
                let (r, g, b, a) = cc.borrow().to_rgba();
                bindings::ClearBackground(bindings::Color { r, g, b, a });
            });

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
    bindings::SetWindowSize(width, height);
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_setWindowTitle(text: &RocStr) -> RocResult<(), ()> {
    let text = CString::new(text.as_str()).unwrap();
    bindings::SetWindowTitle(text.as_ptr());

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawCircle(
    center_x: f32,
    center_y: f32,
    radius: f32,
    color: glue::RocColor,
) -> RocResult<(), ()> {
    let center = bindings::Vector2 {
        x: center_x,
        y: center_y,
    };
    bindings::DrawCircleV(center, radius, color.into());

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawCircleGradient(
    center_x: f32,
    center_y: f32,
    radius: f32,
    inner: glue::RocColor,
    outer: glue::RocColor,
) -> RocResult<(), ()> {
    bindings::DrawCircleGradient(
        center_x as c_int,
        center_y as c_int,
        radius,
        inner.into(),
        outer.into(),
    );
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawRectangleGradient(
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    top: glue::RocColor,
    bottom: glue::RocColor,
) -> RocResult<(), ()> {
    bindings::DrawRectangleGradientV(
        x as c_int,
        y as c_int,
        width as c_int,
        height as c_int,
        top.into(),
        bottom.into(),
    );
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawText(
    x: f32,
    y: f32,
    size: i32,
    text: &RocStr,
    color: glue::RocColor,
) -> RocResult<(), ()> {
    let text = CString::new(text.as_str()).unwrap();
    bindings::DrawText(
        text.as_ptr(),
        x as c_int,
        y as c_int,
        size as c_int,
        color.into(),
    );
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawRectangle(
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    color: glue::RocColor,
) -> RocResult<(), ()> {
    let position = bindings::Vector2 { x, y };
    let size = bindings::Vector2 {
        x: width,
        y: height,
    };
    bindings::DrawRectangleV(position, size, color.into());
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawLine(
    start_x: f32,
    start_y: f32,
    end_x: f32,
    end_y: f32,
    color: glue::RocColor,
) -> RocResult<(), ()> {
    let start = bindings::Vector2 {
        x: start_x,
        y: start_y,
    };
    let end = bindings::Vector2 { x: end_x, y: end_y };
    bindings::DrawLineV(start, end, color.into());
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
    let text = CString::new(text.as_str()).unwrap();
    let width = bindings::MeasureText(text.as_ptr(), size as c_int);
    RocResult::ok(width as i64)
}

#[no_mangle]
unsafe extern "C" fn roc_fx_setTargetFPS(rate: i32) -> RocResult<(), ()> {
    bindings::SetTargetFPS(rate as c_int);
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_setBackgroundColor(color: glue::RocColor) -> RocResult<(), ()> {
    CLEAR_COLOR.with(|cc| {
        let mut clear_color = cc.borrow_mut();
        *clear_color = color;
    });
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_takeScreenshot(path: &RocStr) -> RocResult<(), ()> {
    let path = CString::new(path.as_str()).unwrap();
    bindings::TakeScreenshot(path.as_ptr());
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_setDrawFPS(show: bool, pos_x: i32, pos_y: i32) -> RocResult<(), ()> {
    if show {
        DRAW_FPS.set(Some((pos_x, pos_y)));
    } else {
        DRAW_FPS.set(None);
    }

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_createCamera(
    target_x: f32,
    target_y: f32,
    offset_x: f32,
    offset_y: f32,
    rotation: f32,
    zoom: f32,
) -> RocResult<RocBox<()>, ()> {
    let camera = bindings::Camera2D {
        target: bindings::Vector2 {
            x: target_x,
            y: target_y,
        },
        offset: bindings::Vector2 {
            x: offset_x,
            y: offset_y,
        },
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
    target_x: f32,
    target_y: f32,
    offset_x: f32,
    offset_y: f32,
    rotation: f32,
    zoom: f32,
) -> RocResult<(), ()> {
    let camera: &mut bindings::Camera2D =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_camera);

    camera.target = bindings::Vector2 {
        x: target_x,
        y: target_y,
    };
    camera.offset = bindings::Vector2 {
        x: offset_x,
        y: offset_y,
    };
    camera.rotation = rotation;
    camera.zoom = zoom;

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_beginMode2D(boxed_camera: RocBox<()>) -> RocResult<(), ()> {
    let camera: &mut bindings::Camera2D =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_camera);

    bindings::BeginMode2D(*camera);

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_endMode2D(_boxed_camera: RocBox<()>) -> RocResult<(), ()> {
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
unsafe extern "C" fn roc_fx_loadSound(path: RocStr) -> RocResult<u32, ()> {
    println!("in roc_fx_loadSound");
    dbg!(&path);

    let sound_id = load_sound_internal(path);
    dbg!(sound_id);

    RocResult::ok(sound_id)
}

#[no_mangle]
unsafe extern "C" fn load_sound_internal(path: RocStr) -> u32 {
    let path = CString::new(path.to_string()).unwrap();
    dbg!(&path);

    let sound = bindings::LoadSound(path.into_raw());

    let sound_id = SOUNDS.with_borrow_mut(|sounds| {
        sounds.push(sound);
        sounds.len() - 1
    });

    sound_id as u32
}

#[no_mangle]
unsafe extern "C" fn roc_fx_playSound(sound_id: u32) -> RocResult<(), ()> {
    SOUNDS.with_borrow(|sounds| bindings::PlaySound(sounds[sound_id as usize]));
    RocResult::ok(())
}
