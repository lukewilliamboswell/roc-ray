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
