use raylib::prelude::*;
use roc_std::{RocBox, RocList, RocResult, RocStr};
use roc_std_heap::ThreadSafeRefcountedResourceHeap;
use std::cell::Cell;
use std::ffi::{c_int, CString};
use std::time::SystemTime;

mod roc;

thread_local! {
    static DRAW_FPS: Cell<Option<(i32, i32)>> = Cell::new(None);
}

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

            raylib::ffi::ClearBackground(raylib::ffi::Color {
                r: 0,
                g: 0,
                b: 0,
                a: 255,
            });

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

            if let Some((x, y)) = DRAW_FPS.get() {
                raylib::ffi::DrawFPS(x, y);
            }

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
unsafe extern "C" fn roc_fx_log(msg: &RocStr, level: i32) -> RocResult<(), ()> {
    let text = CString::new(msg.as_str()).unwrap();
    if level >= 0 && level <= 7 {
        raylib::ffi::TraceLog(level, text.as_ptr())
    } else {
        panic!("Invalid log level from roc");
    }

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_setWindowSize(width: i32, height: i32) -> RocResult<(), ()> {
    raylib::ffi::SetWindowSize(width, height);
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_setWindowTitle(text: &RocStr) -> RocResult<(), ()> {
    let text = CString::new(text.as_str()).unwrap();
    raylib::ffi::SetWindowTitle(text.as_ptr());

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawCircle(
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
unsafe extern "C" fn roc_fx_drawCircleGradient(
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
unsafe extern "C" fn roc_fx_drawRectangleGradient(
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
unsafe extern "C" fn roc_fx_drawText(
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
unsafe extern "C" fn roc_fx_drawRectangle(
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

#[no_mangle]
unsafe extern "C" fn roc_fx_drawLine(
    start_x: f32,
    start_y: f32,
    end_x: f32,
    end_y: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) -> RocResult<(), ()> {
    let start = raylib::ffi::Vector2 {
        x: start_x,
        y: start_y,
    };
    let end = raylib::ffi::Vector2 { x: end_x, y: end_y };
    let color = raylib::ffi::Color { r, g, b, a };
    raylib::ffi::DrawLineV(start, end, color);
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
    let height = raylib::ffi::GetScreenHeight();
    let width = raylib::ffi::GetScreenWidth();
    RocResult::ok(ScreenSize {
        height,
        width,
        z: 0,
    })
}

#[no_mangle]
unsafe extern "C" fn roc_fx_drawGuiButton(
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    text: &RocStr,
) -> RocResult<i64, ()> {
    let text = CString::new(text.as_str()).unwrap();
    let id = raylib::ffi::GuiButton(
        raylib::ffi::Rectangle {
            x,
            y,
            width,
            height,
        },
        text.as_ptr(),
    );
    RocResult::ok(id as i64)
}

#[no_mangle]
unsafe extern "C" fn roc_fx_guiWindowBox(
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    text: &RocStr,
) -> RocResult<i64, ()> {
    let text = CString::new(text.as_str()).unwrap();
    let id = raylib::ffi::GuiWindowBox(
        raylib::ffi::Rectangle {
            x,
            y,
            width,
            height,
        },
        text.as_ptr(),
    );
    RocResult::ok(id as i64)
}

#[no_mangle]
unsafe extern "C" fn roc_fx_measureText(text: &RocStr, size: i32) -> RocResult<i64, ()> {
    let text = CString::new(text.as_str()).unwrap();
    let width = raylib::ffi::MeasureText(text.as_ptr(), size as c_int);
    RocResult::ok(width as i64)
}

#[no_mangle]
unsafe extern "C" fn roc_fx_setTargetFPS(rate: i32) -> RocResult<(), ()> {
    raylib::ffi::SetTargetFPS(rate as c_int);
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_setBackgroundColor(r: u8, g: u8, b: u8, a: u8) -> RocResult<(), ()> {
    let color = raylib::ffi::Color { r, g, b, a };
    raylib::ffi::ClearBackground(color);
    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_takeScreenshot(path: &RocStr) -> RocResult<(), ()> {
    let path = CString::new(path.as_str()).unwrap();
    raylib::ffi::TakeScreenshot(path.as_ptr());
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
    let camera = raylib::ffi::Camera2D {
        target: raylib::ffi::Vector2 {
            x: target_x,
            y: target_y,
        },
        offset: raylib::ffi::Vector2 {
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
    let camera: &mut raylib::ffi::Camera2D =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_camera);

    camera.target = raylib::ffi::Vector2 {
        x: target_x,
        y: target_y,
    };
    camera.offset = raylib::ffi::Vector2 {
        x: offset_x,
        y: offset_y,
    };
    camera.rotation = rotation;
    camera.zoom = zoom;

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_beginMode2D(boxed_camera: RocBox<()>) -> RocResult<(), ()> {
    let camera: &mut raylib::ffi::Camera2D =
        ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_camera);

    raylib::ffi::BeginMode2D(*camera);

    RocResult::ok(())
}

#[no_mangle]
unsafe extern "C" fn roc_fx_endMode2D(_boxed_camera: RocBox<()>) -> RocResult<(), ()> {
    raylib::ffi::EndMode2D();

    RocResult::ok(())
}

// fn update_keys_down() !void {
//     var key = rl.getKeyPressed();

//     // insert newly pressed keys
//     while (key != rl.KeyboardKey.key_null) {
//         try keys_down.put(key, true);
//         key = rl.getKeyPressed();
//     }

//     // check all keys that are marked "down" and update if they have been released
//     var iter = keys_down.iterator();
//     while (iter.next()) |kv| {
//         if (kv.value_ptr.*) {
//             const k = kv.key_ptr.*;
//             if (!rl.isKeyDown(k)) {
//                 try keys_down.put(k, false);
//             }
//         } else {
//             // key hasn't been pressed, ignore it
//         }
//     }
// }

// fn get_keys_down() RocList {

//     // store the keys pressed as we read from the queue... assume max 1000 queued
//     var key_queue: [1000]u64 = undefined;
//     var count: u64 = 0;

//     var iter = keys_down.iterator();
//     while (iter.next()) |kv| {
//         if (kv.value_ptr.*) {
//             key_queue[count] = @intCast(@intFromEnum(kv.key_ptr.*));
//             count = count + 1;
//         } else {
//             // key hasn't been pressed, ignore it
//         }
//     }

//     return RocList.fromSlice(u64, key_queue[0..count], false);
// }

// fn get_mouse_down() RocList {
//     var mouse_down: [6]u64 = undefined;
//     var count: u64 = 0;

//     if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_left)) {
//         mouse_down[count] = @intCast(@intFromEnum(rl.MouseButton.mouse_button_left));
//         count += 1;
//     }

//     if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_right)) {
//         mouse_down[count] = @intCast(@intFromEnum(rl.MouseButton.mouse_button_right));
//         count += 1;
//     }
//     if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_middle)) {
//         mouse_down[count] = @intCast(@intFromEnum(rl.MouseButton.mouse_button_middle));
//         count += 1;
//     }
//     if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_side)) {
//         mouse_down[count] = @intCast(@intFromEnum(rl.MouseButton.mouse_button_side));
//         count += 1;
//     }
//     if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_extra)) {
//         mouse_down[count] = @intCast(@intFromEnum(rl.MouseButton.mouse_button_extra));
//         count += 1;
//     }
//     if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_forward)) {
//         mouse_down[count] = @intCast(@intFromEnum(rl.MouseButton.mouse_button_forward));
//         count += 1;
//     }
//     if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_back)) {
//         mouse_down[count] = @intCast(@intFromEnum(rl.MouseButton.mouse_button_back));
//         count += 1;
//     }

//     return RocList.fromSlice(u64, mouse_down[0..count], false);
// }
