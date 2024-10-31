use config::ExitErrCode;
use glue::PeerMessage;
use matchbox_socket::{PeerId, PeerState};
use platform_mode::PlatformEffect;
use raylib::GetFontDefault;
use roc::LoadedMusic;
use roc_std::{RocBox, RocList, RocStr};
use roc_std_heap::ThreadSafeRefcountedResourceHeap;
use std::array;
use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_int, CString};
use std::time::SystemTime;
use worker::MainToWorkerMsg;

mod bindings;
mod config;
mod glue;
mod platform_mode;
mod platform_time;
mod roc;
mod worker;

extern "C" fn draw_loop() {
    // let model = get_model();

    unsafe {
        let mut frame_count = 0;

        let worker_handle = setup_networking(config::with(|c| c.network_web_rtc_url.clone()));

        let mut peers: HashMap<PeerId, PeerState> = HashMap::new();

        unsafe {
            'render_loop: while !raylib::WindowShouldClose() && !(config::with(|c| c.should_exit)) {
                let mut messages: RocList<PeerMessage> = RocList::with_capacity(100);

                // Try to receive any pending (non-blocking)
                let queued_network_messages = worker::get_messages();

                for msg in queued_network_messages {
                    use worker::WorkerToMainMsg::*;
                    match msg {
                        PeerConnected(peer) => {
                            peers.insert(peer, PeerState::Connected);
                        }
                        PeerDisconnected(peer) => {
                            peers.insert(peer, PeerState::Disconnected);
                        }
                        MessageReceived(id, bytes) => {
                            messages.append(glue::PeerMessage {
                                id: id.into(),
                                bytes: RocList::from_slice(bytes.as_slice()),
                            });
                        }
                        ConnectionFailed => {
                            config::update(|c| {
                                c.should_exit_msg_code = Some((
                                    format!(
                                        "Unable to connect to signaling server at {:?}. Exiting...",
                                        c.network_web_rtc_url
                                    ),
                                    ExitErrCode::ExitWebRTCConnectionError,
                                ));
                                c.should_exit = true;
                            });
                            break 'render_loop;
                        }
                        Disconnected => {
                            // TODO give roc an error somehow, allow for reconnecting to a different server??
                            config::update(|c| {
                                c.should_exit_msg_code = Some((
                                    format!(
                                        "Disconnected from signaling server at {:?}. Exiting...",
                                        c.network_web_rtc_url
                                    ),
                                    ExitErrCode::ExitWebRTCConnectionDisconnected,
                                ));
                                c.should_exit = true;
                            });
                            break 'render_loop;
                        }
                    }
                }

                let duration_since_epoch = SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .unwrap();

                if config::with(|c| c.fps_target_dirty) {
                    raylib::SetTargetFPS(config::with(|c| c.fps_target));

                    config::update(|c| c.fps_target_dirty = false);
                }

                let timestamp = duration_since_epoch.as_millis() as u64; // we are casting to u64 and losing precision

                // note this is called before we build the PlatformState
                platform_time::render_start();

                let platform_state = glue::PlatformState {
                    frame_count,
                    peers: (&peers).into(),
                    keys: get_keys_states(),
                    messages,
                    timestamp: platform_time::get_platform_time(),
                    mouse_buttons: get_mouse_button_states(),
                    timestamp_millis: timestamp,
                    mouse_pos_x: raylib::GetMouseX() as f32,
                    mouse_pos_y: raylib::GetMouseY() as f32,
                    mouse_wheel: raylib::GetMouseWheelMove(),
                };

                platform_time::render_end();

                if config::with(|c| c.fps_show) {
                    config::with(|c| raylib::DrawFPS(c.fps_position.0, c.fps_position.1));
                }

                frame_count += 1;

                roc::update_music_streams();
            }

            // Send shutdown message before closing the window
            worker::send_message(worker::MainToWorkerMsg::Shutdown);

            // Now close the window
            raylib::CloseWindow();
        }

        if let Some((msg, code)) = config::with(|c| c.should_exit_msg_code.clone()) {
            display_fatal_error_message(msg, code);
        }
    }
}

// fn main() {
//     // CALL INTO ROC FOR INITALIZATION
//     platform_time::init_start();
//     let mut model = roc::call_roc_init();
//     platform_time::init_end();

//     // MANUALLY TRANSITION TO RENDER MODE
//     platform_mode::update(PlatformEffect::EndInitWindow).unwrap();

//     let mut frame_count = 0;

//     let worker_handle = setup_networking(config::with(|c| c.network_web_rtc_url.clone()));

//     let mut peers: HashMap<PeerId, PeerState> = HashMap::new();

//     unsafe {
//         'render_loop: while !raylib::WindowShouldClose() && !(config::with(|c| c.should_exit)) {
//             let mut messages: RocList<PeerMessage> = RocList::with_capacity(100);

//             // Try to receive any pending (non-blocking)
//             let queued_network_messages = worker::get_messages();

//             for msg in queued_network_messages {
//                 use worker::WorkerToMainMsg::*;
//                 match msg {
//                     PeerConnected(peer) => {
//                         peers.insert(peer, PeerState::Connected);
//                     }
//                     PeerDisconnected(peer) => {
//                         peers.insert(peer, PeerState::Disconnected);
//                     }
//                     MessageReceived(id, bytes) => {
//                         messages.append(glue::PeerMessage {
//                             id: id.into(),
//                             bytes: RocList::from_slice(bytes.as_slice()),
//                         });
//                     }
//                     ConnectionFailed => {
//                         config::update(|c| {
//                             c.should_exit_msg_code = Some((
//                                 format!(
//                                     "Unable to connect to signaling server at {:?}. Exiting...",
//                                     c.network_web_rtc_url
//                                 ),
//                                 ExitErrCode::ExitWebRTCConnectionError,
//                             ));
//                             c.should_exit = true;
//                         });
//                         break 'render_loop;
//                     }
//                     Disconnected => {
//                         // TODO give roc an error somehow, allow for reconnecting to a different server??
//                         config::update(|c| {
//                             c.should_exit_msg_code = Some((
//                                 format!(
//                                     "Disconnected from signaling server at {:?}. Exiting...",
//                                     c.network_web_rtc_url
//                                 ),
//                                 ExitErrCode::ExitWebRTCConnectionDisconnected,
//                             ));
//                             c.should_exit = true;
//                         });
//                         break 'render_loop;
//                     }
//                 }
//             }

//             let duration_since_epoch = SystemTime::now()
//                 .duration_since(SystemTime::UNIX_EPOCH)
//                 .unwrap();

//             if config::with(|c| c.fps_target_dirty) {
//                 raylib::SetTargetFPS(config::with(|c| c.fps_target));
//                 config::update(|c| c.fps_target_dirty = false);
//             }

//             let timestamp = duration_since_epoch.as_millis() as u64; // we are casting to u64 and losing precision

//             trace_log(&format!(
//                 "RENDER frame: {}, millis: {} ------",
//                 frame_count, timestamp
//             ));

//             // note this is called before we build the PlatformState
//             platform_time::render_start();

//             let platform_state = glue::PlatformState {
//                 frame_count,
//                 peers: (&peers).into(),
//                 keys: get_keys_states(),
//                 messages,
//                 timestamp: platform_time::get_platform_time(),
//                 mouse_buttons: get_mouse_button_states(),
//                 timestamp_millis: timestamp,
//                 mouse_pos_x: raylib::GetMouseX() as f32,
//                 mouse_pos_y: raylib::GetMouseY() as f32,
//                 mouse_wheel: raylib::GetMouseWheelMove(),
//             };

//             model = roc::call_roc_render(platform_state, model);

//             platform_time::render_end();

//             if config::with(|c| c.fps_show) {
//                 config::with(|c| raylib::DrawFPS(c.fps_position.0, c.fps_position.1));
//             }

//             frame_count += 1;

//             raylib::EndDrawing();

//             roc::update_music_streams();
//         }

//         // Send shutdown message before closing the window
//         worker::send_message(worker::MainToWorkerMsg::Shutdown);

//         // Now close the window
//         raylib::CloseWindow();
//     }

//     if let Some((msg, code)) = config::with(|c| c.should_exit_msg_code.clone()) {
//         display_fatal_error_message(msg, code);
//     }
// }

#[cfg(not(target_arch = "wasm32"))]
fn setup_networking(room_url: Option<String>) -> Option<tokio::task::JoinHandle<()>> {
    let rt = tokio::runtime::Runtime::new().unwrap();
    worker::init(&rt, room_url)
}

#[cfg(target_arch = "wasm32")]
fn setup_networking(room_url: Option<String>) -> Option<()> {
    worker::init(None, room_url)
}

#[no_mangle]
extern "C" fn roc_fx_log(msg: &RocStr, level: i32) {
    // if let Err(msg) = platform_mode::update(PlatformEffect::LogMsg) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let text = CString::new(msg.as_str()).unwrap();
    // if level >= 0 && level <= 7 {
    //     unsafe { raylib::TraceLog(level, text.as_ptr()) }
    // } else {
    //     panic!("Invalid log level from roc");
    // }
}

#[no_mangle]
extern "C" fn roc_fx_setTargetFPS(rate: i32) {
    // if let Err(msg) = platform_mode::update(PlatformEffect::SetTargetFPS) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    config::update(|c| {
        c.fps_target_dirty = true;
        c.fps_target = rate as c_int
    });
}

#[no_mangle]
extern "C" fn roc_fx_takeScreenshot(path: &RocStr) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::TakeScreenshot) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let path = CString::new(path.as_str()).unwrap();

    // unsafe {
    //     raylib::TakeScreenshot(path.as_ptr());
    // }
}

#[no_mangle]
extern "C" fn roc_fx_setDrawFPS(show: bool, pos: &glue::RocVector2) {
    // if let Err(msg) = platform_mode::update(PlatformEffect::SetDrawFPS) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    config::update(|c| {
        c.fps_show = show;
        c.fps_position = pos.to_components_c_int();
    });
}

#[no_mangle]
extern "C" fn roc_fx_createCamera(
    target: &glue::RocVector2,
    offset: &glue::RocVector2,
    rotation: f32,
    zoom: f32,
) -> RocBox<()> {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::CreateCamera) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let camera = raylib::Camera2D {
    //     target: target.into(),
    //     offset: offset.into(),
    //     rotation,
    //     zoom,
    // };

    // let heap = roc::camera_heap();

    // let alloc_result = heap.alloc_for(camera);
    // match alloc_result {
    //     Ok(roc_box) => roc_box,
    //     Err(_) => {
    //         display_fatal_error_message("Unable to load camera, out of memory in the camera heap. Consider using ROC_RAY_MAX_CAMERAS_HEAP_SIZE env var to increase the heap size.".into(), ExitErrCode::ExitHeapFull);
    //     }
    // }
}

#[no_mangle]
extern "C" fn roc_fx_createRenderTexture(size: &glue::RocVector2) -> RocBox<()> {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::CreateRenderTexture) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let (width, height) = size.to_components_c_int();

    // let render_texture = unsafe { raylib::LoadRenderTexture(width, height) };

    // let heap = roc::render_texture_heap();

    // let alloc_result = heap.alloc_for(render_texture);
    // match alloc_result {
    //     Ok(roc_box) => roc_box,
    //     Err(_) => {
    //         display_fatal_error_message("Unable to load render texture, out of memory in the render texture heap. Consider using ROC_RAY_MAX_RENDER_TEXTURE_HEAP_SIZE env var to increase the heap size.".into(), ExitErrCode::ExitHeapFull);
    //     }
    // }
}

#[no_mangle]
extern "C" fn roc_fx_updateCamera(
    boxed_camera: RocBox<()>,
    target: &glue::RocVector2,
    offset: &glue::RocVector2,
    rotation: f32,
    zoom: f32,
) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::UpdateCamera) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let camera: &mut raylib::Camera2D =
    //     ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_camera);

    // camera.target = target.into();
    // camera.offset = offset.into();
    // camera.rotation = rotation;
    // camera.zoom = zoom;
}

#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_beginMode2D(boxed_camera: RocBox<()>) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::BeginMode2D) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // unsafe {
    //     trace_log("BeginMode2D");

    //     let camera: &mut raylib::Camera2D =
    //         ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_camera);

    //     raylib::BeginMode2D(*camera);
    // }
}

#[no_mangle]
extern "C" fn roc_fx_endMode2D(_boxed_camera: RocBox<()>) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::EndMode2D) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // unsafe {
    //     trace_log("EndMode2D");
    //     raylib::EndMode2D();
    // }
}

#[allow(unused_variables)]
#[no_mangle]
extern "C" fn roc_fx_beginTexture(boxed_render_texture: RocBox<()>, clear_color: glue::RocColor) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::BeginDrawingTexture) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // unsafe {
    //     trace_log("BeginTexture");
    //     let render_texture: &mut raylib::RenderTexture =
    //         ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_render_texture);

    //     raylib::BeginTextureMode(*render_texture);
    //     raylib::ClearBackground(clear_color.into());
    // }
}

#[no_mangle]
extern "C" fn roc_fx_endTexture(_boxed_render_texture: RocBox<()>) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::EndDrawingTexture) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // unsafe {
    //     trace_log("EndTexture");
    //     raylib::EndTextureMode();
    // }
}

fn get_mouse_button_states() -> RocList<u8> {
    let mouse_buttons: [u8; 7] = array::from_fn(|i| {
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
    let keys: [u8; 350] = array::from_fn(|i| {
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

#[no_mangle]
extern "C" fn roc_fx_loadSound(path: &RocStr) -> RocBox<()> {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::LoadSound) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let path = CString::new(path.as_str()).unwrap();

    // let sound = unsafe {
    //     trace_log("LoadSound");
    //     raylib::LoadSound(path.as_ptr())
    // };

    // let heap = roc::sound_heap();

    // let alloc_result = heap.alloc_for(sound);
    // match alloc_result {
    //     Ok(roc_box) => roc_box,
    //     Err(_) => {
    //         display_fatal_error_message("Unable to load sound, out of memory in the sound heap. Consider using ROC_RAY_MAX_SOUNDS_HEAP_SIZE env var to increase the heap size.".into(), ExitErrCode::ExitHeapFull);
    //     }
    // }
}

#[no_mangle]
extern "C" fn roc_fx_playSound(boxed_sound: RocBox<()>) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::PlaySound) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let sound: &mut raylib::Sound =
    //     ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_sound);

    // unsafe {
    //     raylib::PlaySound(*sound);
    // }
}

#[no_mangle]
extern "C" fn roc_fx_loadMusicStream(path: &RocStr) -> LoadedMusic {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::LoadMusicStream) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let path = CString::new(path.as_str()).unwrap();

    // let music = unsafe {
    //     trace_log("LoadMusicStream");
    //     raylib::LoadMusicStream(path.as_ptr())
    // };

    // let alloc_result = roc::alloc_music_stream(music);
    // match alloc_result {
    //     Ok(loaded_music) => loaded_music,
    //     Err(_) => {
    //         display_fatal_error_message("Unable to load music stream, out of memory in the music heap. Consider using ROC_RAY_MAX_MUSIC_STREAMS_HEAP_SIZE env var to increase the heap size.".into(), ExitErrCode::ExitHeapFull);
    //     }
    // }
}

#[no_mangle]
extern "C" fn roc_fx_playMusicStream(boxed_music: RocBox<()>) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::PlayMusicStream) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let music: &mut raylib::Music =
    //     ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_music);

    // unsafe {
    //     raylib::PlayMusicStream(*music);
    // }
}

#[no_mangle]
extern "C" fn roc_fx_stopMusicStream(boxed_music: RocBox<()>) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::PlayMusicStream) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let music: &mut raylib::Music =
    //     ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_music);

    // unsafe {
    //     raylib::StopMusicStream(*music);
    // }
}

#[no_mangle]
extern "C" fn roc_fx_pauseMusicStream(boxed_music: RocBox<()>) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::PlayMusicStream) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let music: &mut raylib::Music =
    //     ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_music);

    // unsafe {
    //     raylib::PauseMusicStream(*music);
    // }
}

#[no_mangle]
extern "C" fn roc_fx_resumeMusicStream(boxed_music: RocBox<()>) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::PlayMusicStream) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let music: &mut raylib::Music =
    //     ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_music);

    // unsafe {
    //     raylib::ResumeMusicStream(*music);
    // }
}

// NOTE: the RocStr in this error type is to work around a compiler bug
#[no_mangle]
extern "C" fn roc_fx_getMusicTimePlayed(boxed_music: RocBox<()>) -> f32 {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::PlayMusicStream) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let music: &mut raylib::Music =
    //     ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_music);

    // let time_played = unsafe { raylib::GetMusicTimePlayed(*music) };

    // time_played
}

#[no_mangle]
extern "C" fn roc_fx_loadTexture(file_path: &RocStr) -> RocBox<()> {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::LoadTexture) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // // should have a valid utf8 string from roc, no need to check for null bytes
    // let file_path = CString::new(file_path.as_str()).unwrap();

    // let texture: raylib::Texture = unsafe { raylib::LoadTexture(file_path.as_ptr()) };

    // let heap = roc::texture_heap();

    // let alloc_result = heap.alloc_for(texture);
    // match alloc_result {
    //     Ok(roc_box) => roc_box,
    //     Err(_) => {
    //         display_fatal_error_message("Unable to load texture, out of memory in the texture heap. Consider using ROC_RAY_MAX_TEXTURES_HEAP_SIZE env var to increase the heap size.".into(), ExitErrCode::ExitHeapFull);
    //     }
    // }
}

#[no_mangle]
extern "C" fn roc_fx_drawTextureRec(
    boxed_texture: RocBox<()>,
    source: &glue::RocRectangle,
    position: &glue::RocVector2,
    color: glue::RocColor,
) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::DrawTextureRectangle) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let texture: &mut raylib::Texture =
    //     ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_texture);

    // unsafe {
    //     raylib::DrawTextureRec(*texture, source.into(), position.into(), color.into());
    // }
}

#[no_mangle]
extern "C" fn roc_fx_drawRenderTextureRec(
    boxed_texture: RocBox<()>,
    source: &glue::RocRectangle,
    position: &glue::RocVector2,
    color: glue::RocColor,
) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::DrawTextureRectangle) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let texture: &mut raylib::RenderTexture =
    //     ThreadSafeRefcountedResourceHeap::box_to_resource(boxed_texture);

    // unsafe {
    //     raylib::DrawTextureRec(
    //         texture.texture,
    //         source.into(),
    //         position.into(),
    //         color.into(),
    //     );
    // }
}

#[no_mangle]
extern "C" fn roc_fx_loadFileToStr(path: &RocStr) -> RocStr {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::LoadFileToStr) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let path = path.as_str();
    // let Ok(contents) = std::fs::read_to_string(path) else {
    //     panic!("file not found: {path}");
    // };

    // let contents = contents.replace("\r\n", "\n");
    // let contents = unsafe { RocStr::from_slice_unchecked(contents.as_bytes()) };

    // contents
}

#[no_mangle]
extern "C" fn roc_fx_sendToPeer(bytes: &RocList<u8>, peer: &glue::PeerUUID) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::SendMsgToPeer) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let data = bytes.as_slice().to_vec();

    // worker::send_message(MainToWorkerMsg::SendMessage(peer.into(), data));
}

#[no_mangle]
extern "C" fn roc_fx_configureWebRTC(url: &RocStr) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::ConfigureNetwork) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // config::update(|c| c.network_web_rtc_url = Some(url.to_string()));
}

#[no_mangle]
extern "C" fn roc_fx_sleepMillis(millis: u64) {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::SleepMillis) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // std::thread::sleep(std::time::Duration::from_millis(millis));
}

#[no_mangle]
extern "C" fn roc_fx_randomI32(min: i32, max: i32) -> i32 {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::RandomValue) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // unsafe { raylib::GetRandomValue(min, max) }
}

#[no_mangle]
extern "C" fn roc_fx_loadFont(path: &RocStr) -> RocBox<()> {
    todo!()
    // if let Err(msg) = platform_mode::update(PlatformEffect::LoadFont) {
    //     display_fatal_error_message(msg, ExitErrCode::EffectNotPermitted);
    // }

    // let path = CString::new(path.as_str()).unwrap();

    // let sound = unsafe {
    //     trace_log("LoadFont");
    //     raylib::LoadFont(path.as_ptr())
    // };

    // let heap = roc::font_heap();

    // let alloc_result = heap.alloc_for(sound);
    // match alloc_result {
    //     Ok(roc_box) => roc_box,
    //     Err(_) => {
    //         display_fatal_error_message("Unable to load font, out of memory in the font heap. Consider using ROC_RAY_MAX_FONT_HEAP_SIZE env var to increase the heap size.".into(), ExitErrCode::ExitHeapFull);
    //     }
    // }
}
