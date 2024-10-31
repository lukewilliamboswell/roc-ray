#![allow(non_snake_case)]
use crate::config::ExitErrCode;
use crate::glue::{PeerMessage, PeerState, PlatformTime};
use crate::logger;
use roc_std::{RocList, RocRefcounted, RocResult, RocStr};
use roc_std_heap::ThreadSafeRefcountedResourceHeap;
use std::ffi::{c_int, CString};
use std::os::raw::c_void;
use std::sync::OnceLock;

mod music_heap;
pub use music_heap::*;

// note this is checked and deallocated in the roc_dealloc function
pub fn camera_heap() -> &'static ThreadSafeRefcountedResourceHeap<raylib::Camera2D> {
    static CAMERA_HEAP: OnceLock<ThreadSafeRefcountedResourceHeap<raylib::Camera2D>> =
        OnceLock::new();
    const DEFAULT_ROC_RAY_MAX_CAMERAS_HEAP_SIZE: usize = 100;
    let max_heap_size = std::env::var("ROC_RAY_MAX_CAMERAS_HEAP_SIZE")
        .map(|v| v.parse().unwrap_or(DEFAULT_ROC_RAY_MAX_CAMERAS_HEAP_SIZE))
        .unwrap_or(DEFAULT_ROC_RAY_MAX_CAMERAS_HEAP_SIZE);
    CAMERA_HEAP.get_or_init(|| {
        ThreadSafeRefcountedResourceHeap::new(max_heap_size)
            .expect("Failed to allocate mmap for heap references.")
    })
}

// note this is checked and deallocated in the roc_dealloc function
pub fn texture_heap() -> &'static ThreadSafeRefcountedResourceHeap<raylib::Texture> {
    static TEXTURE_HEAP: OnceLock<ThreadSafeRefcountedResourceHeap<raylib::Texture>> =
        OnceLock::new();
    const DEFAULT_ROC_RAY_MAX_TEXTURES_HEAP_SIZE: usize = 1000;
    let max_heap_size = std::env::var("ROC_RAY_MAX_TEXTURES_HEAP_SIZE")
        .map(|v| v.parse().unwrap_or(DEFAULT_ROC_RAY_MAX_TEXTURES_HEAP_SIZE))
        .unwrap_or(DEFAULT_ROC_RAY_MAX_TEXTURES_HEAP_SIZE);
    TEXTURE_HEAP.get_or_init(|| {
        ThreadSafeRefcountedResourceHeap::new(max_heap_size)
            .expect("Failed to allocate mmap for heap references.")
    })
}

// note this is checked and deallocated in the roc_dealloc function
pub fn sound_heap() -> &'static ThreadSafeRefcountedResourceHeap<raylib::Sound> {
    static SOUND_HEAP: OnceLock<ThreadSafeRefcountedResourceHeap<raylib::Sound>> = OnceLock::new();
    const DEFAULT_ROC_RAY_MAX_SOUNDS_HEAP_SIZE: usize = 1000;
    let max_heap_size = std::env::var("ROC_RAY_MAX_SOUNDS_HEAP_SIZE")
        .map(|v| v.parse().unwrap_or(DEFAULT_ROC_RAY_MAX_SOUNDS_HEAP_SIZE))
        .unwrap_or(DEFAULT_ROC_RAY_MAX_SOUNDS_HEAP_SIZE);
    SOUND_HEAP.get_or_init(|| {
        ThreadSafeRefcountedResourceHeap::new(max_heap_size)
            .expect("Failed to allocate mmap for heap references.")
    })
}

// note this is checked and deallocated in the roc_dealloc function
pub fn render_texture_heap() -> &'static ThreadSafeRefcountedResourceHeap<raylib::RenderTexture> {
    static RENDER_TEXTURE_HEAP: OnceLock<ThreadSafeRefcountedResourceHeap<raylib::RenderTexture>> =
        OnceLock::new();
    const DEFAULT_ROC_RAY_MAX_RENDER_TEXTURE_HEAP_SIZE: usize = 1000;
    let max_heap_size = std::env::var("ROC_RAY_MAX_RENDER_TEXTURE_HEAP_SIZE")
        .map(|v| {
            v.parse()
                .unwrap_or(DEFAULT_ROC_RAY_MAX_RENDER_TEXTURE_HEAP_SIZE)
        })
        .unwrap_or(DEFAULT_ROC_RAY_MAX_RENDER_TEXTURE_HEAP_SIZE);
    RENDER_TEXTURE_HEAP.get_or_init(|| {
        ThreadSafeRefcountedResourceHeap::new(max_heap_size)
            .expect("Failed to allocate mmap for heap references.")
    })
}

// note this is checked and deallocated in the roc_dealloc function
pub fn font_heap() -> &'static ThreadSafeRefcountedResourceHeap<raylib::Font> {
    static FONT_HEAP: OnceLock<ThreadSafeRefcountedResourceHeap<raylib::Font>> = OnceLock::new();
    const DEFAULT_ROC_RAY_MAX_FONT_HEAP_SIZE: usize = 10;
    let max_heap_size = std::env::var("ROC_RAY_MAX_FONT_HEAP_SIZE")
        .map(|v| v.parse().unwrap_or(DEFAULT_ROC_RAY_MAX_FONT_HEAP_SIZE))
        .unwrap_or(DEFAULT_ROC_RAY_MAX_FONT_HEAP_SIZE);
    FONT_HEAP.get_or_init(|| {
        ThreadSafeRefcountedResourceHeap::new(max_heap_size)
            .expect("Failed to allocate mmap for heap references.")
    })
}

#[no_mangle]
pub unsafe extern "C" fn roc_alloc(size: usize, _alignment: u32) -> *mut c_void {
    libc::malloc(size)
}

#[no_mangle]
pub unsafe extern "C" fn roc_dealloc(c_ptr: *mut c_void, _alignment: u32) {
    let camera_heap = camera_heap();
    if camera_heap.in_range(c_ptr) {
        camera_heap.dealloc(c_ptr);
        return;
    }

    let texture_heap = texture_heap();
    if texture_heap.in_range(c_ptr) {
        texture_heap.dealloc(c_ptr);
        return;
    }

    let sound_heap = sound_heap();
    if sound_heap.in_range(c_ptr) {
        sound_heap.dealloc(c_ptr);
        return;
    }

    let music_heap = music_heap();
    if music_heap.in_range(c_ptr) {
        music_heap.dealloc(c_ptr);
        return;
    }

    let render_texture_heap = render_texture_heap();
    if render_texture_heap.in_range(c_ptr) {
        render_texture_heap.dealloc(c_ptr);
        return;
    }

    let font_heap = font_heap();
    if font_heap.in_range(c_ptr) {
        font_heap.dealloc(c_ptr);
        return;
    }

    libc::free(c_ptr);
}

#[no_mangle]
pub unsafe extern "C" fn roc_realloc(
    c_ptr: *mut c_void,
    new_size: usize,
    _old_size: usize,
    _alignment: u32,
) -> *mut c_void {
    libc::realloc(c_ptr, new_size)
}

#[no_mangle]
pub unsafe extern "C" fn roc_panic(msg: &RocStr, _tag_id: u32) {
    logger::log(format!("Roc crashed with: {}", msg.as_str()).as_str());
}

#[no_mangle]
pub unsafe extern "C" fn roc_dbg(loc: &RocStr, msg: &RocStr) {
    eprintln!("[{}] {}", loc, msg);
}

#[no_mangle]
pub unsafe extern "C" fn roc_memset(dst: *mut c_void, c: i32, n: usize) -> *mut c_void {
    libc::memset(dst, c, n)
}

#[cfg(unix)]
#[no_mangle]
pub unsafe extern "C" fn roc_mmap(
    addr: *mut libc::c_void,
    len: libc::size_t,
    prot: libc::c_int,
    flags: libc::c_int,
    fd: libc::c_int,
    offset: libc::off_t,
) -> *mut libc::c_void {
    libc::mmap(addr, len, prot, flags, fd, offset)
}

#[cfg(unix)]
#[no_mangle]
pub unsafe extern "C" fn roc_shm_open(
    name: *const libc::c_char,
    oflag: libc::c_int,
    mode: libc::mode_t,
) -> libc::c_int {
    libc::shm_open(name, oflag, mode as libc::c_uint)
}

#[cfg(unix)]
#[no_mangle]
pub unsafe extern "C" fn roc_getppid() -> libc::pid_t {
    libc::getppid()
}

pub struct App {
    model: *const (),
    frame_count: u64,
    timestamps: PlatformTime,
    peers: PeerState,
    messages: RocList<PeerMessage>,
}

impl App {
    pub fn init() -> App {
        #[link(name = "app")]
        extern "C" {
            #[link_name = "roc__initForHost_1_exposed"]
            fn init_caller(arg_not_used: i32) -> RocResult<*const (), RocStr>;
        }

        unsafe {
            let mut timestamps = PlatformTime::default();

            timestamps.init_start = now();

            let result = init_caller(0);

            let model = match result.into() {
                Ok(model) => model,
                Err(msg) => {
                    let msg = msg.to_string();
                    logger::log(msg.as_str());
                    crate::config::update(|c| {
                        c.should_exit_msg_code = Some((msg, ExitErrCode::ErrFromRocInit))
                    });

                    // we return a null pointer to signal to the caller that the model is invalid
                    // this is ok, the loop will display the error message instead of using this model
                    &() as *const ()
                }
            };

            timestamps.init_end = now();

            App {
                model,
                timestamps,
                frame_count: 0,
                peers: PeerState::default(),
                messages: RocList::empty(),
            }
        }
    }

    pub fn render(&mut self) {
        #[link(name = "app")]
        extern "C" {

            // NOTE -- we could definitely go back to PlatformState now... I changed to this and broke everything out becuase I was getting a segfault, but now I know it's because I wan't handling the refcounting correctly... PlatformState would be fine as we can just call a single `.inc()` on it to prevent a double free.
            //
            // But this is probably ok for now...and potentially more performant even
            //
            // The main advantage of PlatformState is having it all in one thing and using roc glue to (re)generate it whenever it change... but this is probably not too bad to maintain also.

            #[link_name = "roc__renderForHost_1_exposed"]
            fn render_caller(
                model_in: *const (),
                frame_count: u64,
                keys: &RocList<u8>,
                mouse_buttons: &RocList<u8>,
                timestamps: &PlatformTime,
                mousePosX: f32,
                mousePosY: f32,
                mouseWheel: f32,
                peers: &PeerState,
                messages: &RocList<PeerMessage>,
            ) -> RocResult<*const (), RocStr>;

            // API COPIED FROM src/main.rs
            // renderForHost! : Box Model, U64, List U8, List U8, Effect.PlatformTime, F32, F32, F32, Effect.PeerState, List Effect.PeerMessage  => Box Model
            // renderForHost! = \boxedModel, frameCount, keys, mouseButtons, timestamp, mousePosX, mousePosY, mouseWheel, peers, messages ->

            // LLVM IR GENERTATED USING $ roc build --no-link --emit-llvm-ir examples/basic-shapes.roc
            // define ptr @roc__renderForHost_1_exposed(ptr %0, i64 %1, ptr %2, ptr %3, ptr %4, float %5, float %6, float %7, ptr %8, ptr %9) !dbg !777 {
            // entry:
            //   %load_arg = load %list.RocList, ptr %2, align 8, !dbg !778
            //   %load_arg1 = load %list.RocList, ptr %3, align 8, !dbg !778
            //   %load_arg2 = load %list.RocList, ptr %9, align 8, !dbg !778
            //   %call = call fastcc ptr @"_renderForHost!_1bb73f6fafaa3656a8bf5796e2e6e6bdbd058375237d0b9be5834c8c9f54"(ptr %0, i64 %1, %list.RocList %load_arg, %list.RocList %load_arg1, ptr %4, float %5, float %6, float %7, ptr %8, %list.RocList %load_arg2), !dbg !778
            //   ret ptr %call, !dbg !778
            // }

        }

        unsafe {
            // Increment frame count
            self.frame_count += 1;

            // Update timestamps
            self.timestamps.last_render_start = self.timestamps.render_start;
            self.timestamps.render_start = now();

            // Note we increment the refcount of the keys and mouse buttons
            // so they aren't deallocated before the end of this function
            // otherwise we'd have a double free
            let mut mouse_buttons = get_mouse_button_states();
            mouse_buttons.inc();

            let mut key_states = get_keys_states();
            key_states.inc();

            // Refcount things we dont' want Roc to dealloc...
            self.peers.inc();
            self.messages.inc();

            let mouse_x = raylib::GetMouseX() as f32;
            let mouse_y = raylib::GetMouseY() as f32;
            let mouse_wheel = raylib::GetMouseWheelMove() as f32;

            let result = render_caller(
                self.model,
                self.frame_count,
                &key_states,
                &mouse_buttons,
                &self.timestamps,
                mouse_x,
                mouse_y,
                mouse_wheel,
                &self.peers,
                &self.messages,
            );

            let new_model = match result.into() {
                Ok(model) => model,
                Err(msg) => {
                    let msg = msg.to_string();
                    logger::log(msg.as_str());
                    crate::config::update(|c| {
                        c.should_exit_msg_code = Some((msg, ExitErrCode::ErrFromRocRender))
                    });

                    // we return a null pointer to signal to the caller that the model is invalid
                    // this is ok, the immediate next loop will display the error message and not use this model
                    &() as *const ()
                }
            };

            self.model = new_model;

            if crate::config::with(|c| c.fps_show) {
                crate::config::with(|c| raylib::DrawFPS(c.fps_position.0, c.fps_position.1));
            }

            update_music_streams();

            self.timestamps.last_render_end = now();
        }
    }
}

fn now() -> u64 {
    #[cfg(not(target_family = "wasm"))]
    {
        use std::time::SystemTime;

        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64
    }

    #[cfg(target_family = "wasm")]
    {
        // implemented in src/web.js
        extern "C" {
            fn date_now() -> f64;
        }
        unsafe { date_now() as u64 }
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
