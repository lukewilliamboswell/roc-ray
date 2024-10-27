#![allow(non_snake_case)]
use crate::glue::PlatformState;
use roc_std::{RocBox, RocStr};
use roc_std_heap::ThreadSafeRefcountedResourceHeap;
use std::mem::ManuallyDrop;
use std::os::raw::c_void;
use std::sync::OnceLock;

use crate::bindings;

mod music_heap;
pub use music_heap::*;

// note this is checked and deallocated in the roc_dealloc function
pub fn camera_heap() -> &'static ThreadSafeRefcountedResourceHeap<bindings::Camera2D> {
    static CAMERA_HEAP: OnceLock<ThreadSafeRefcountedResourceHeap<bindings::Camera2D>> =
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
pub fn texture_heap() -> &'static ThreadSafeRefcountedResourceHeap<bindings::Texture> {
    static TEXTURE_HEAP: OnceLock<ThreadSafeRefcountedResourceHeap<bindings::Texture>> =
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
pub fn sound_heap() -> &'static ThreadSafeRefcountedResourceHeap<bindings::Sound> {
    static SOUND_HEAP: OnceLock<ThreadSafeRefcountedResourceHeap<bindings::Sound>> =
        OnceLock::new();
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
pub fn render_texture_heap() -> &'static ThreadSafeRefcountedResourceHeap<bindings::RenderTexture> {
    static RENDER_TEXTURE_HEAP: OnceLock<
        ThreadSafeRefcountedResourceHeap<bindings::RenderTexture>,
    > = OnceLock::new();
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
    panic!("Roc crashed with: {}", msg.as_str());
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

pub fn call_roc_init() -> RocBox<()> {
    extern "C" {
        #[link_name = "roc__initForHost_1_exposed_size"]
        fn init_size() -> usize;

        #[link_name = "roc__initForHost_1_exposed"]
        fn init_caller(arg_not_used: i32) -> RocBox<()>;
    }

    unsafe {
        let model: RocBox<()> = init_caller(0);

        debug_assert_eq!(std::mem::size_of_val(&model), init_size());

        model
    }
}

pub fn call_roc_render(platform_state: PlatformState, model: RocBox<()>) -> RocBox<()> {
    extern "C" {
        #[link_name = "roc__renderForHost_1_exposed_size"]
        fn render_size() -> usize;

        #[link_name = "roc__renderForHost_1_exposed"]
        fn render_caller(
            model_in: RocBox<()>,
            platform_state: *const ManuallyDrop<PlatformState>,
        ) -> RocBox<()>;

    }

    unsafe {
        let model = render_caller(model, &ManuallyDrop::new(platform_state));

        debug_assert_eq!(std::mem::size_of_val(&model), render_size());

        model
    }
}
