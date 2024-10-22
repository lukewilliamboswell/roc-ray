#![allow(non_snake_case)]
use roc_std::{RocBox, RocResult, RocStr};
use roc_std_heap::ThreadSafeRefcountedResourceHeap;
use std::mem::ManuallyDrop;
use std::os::raw::c_void;
use std::sync::OnceLock;

use crate::bindings;

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

#[derive(Debug)]
pub struct Model {
    model: RocBox<()>,
}
impl Model {
    unsafe fn init(model: RocBox<()>) -> Self {
        // Set the refcount to constant to ensure this never gets freed.
        // This also makes it thread-safe.
        let data_ptr: *mut usize = std::mem::transmute(model);
        let rc_ptr = data_ptr.offset(-1);
        let max_refcount = 0;
        *rc_ptr = max_refcount;
        Self {
            model: std::mem::transmute(data_ptr),
        }
    }
}

unsafe impl Send for Model {}
unsafe impl Sync for Model {}

#[derive(Clone, Default, Debug, PartialEq, PartialOrd)]
#[repr(C)]
pub struct PlatformState {
    pub frame_count: u64,
    pub keys: roc_std::RocList<u8>,
    pub mouse_buttons: roc_std::RocList<u8>,
    pub timestamp_millis: u64,
    pub mouse_pos_x: f32,
    pub mouse_pos_y: f32,
    pub mouse_wheel: f32,
}

impl roc_std::RocRefcounted for PlatformState {
    fn inc(&mut self) {
        self.keys.inc();
        self.mouse_buttons.inc();
    }
    fn dec(&mut self) {
        self.keys.dec();
        self.mouse_buttons.dec();
    }
    fn is_refcounted() -> bool {
        true
    }
}

pub fn call_roc_init() -> Model {
    extern "C" {
        #[link_name = "roc__init_1_exposed_size"]
        fn init_size() -> usize;

        #[allow(improper_ctypes)]
        #[link_name = "roc__init_1_exposed_generic"]
        fn init_caller(model: *mut RocResult<RocBox<()>, ()>, void_arg: ());
    }

    unsafe {
        // save stack space for return value
        let mut result: RocResult<RocBox<()>, ()> = RocResult::err(());
        debug_assert_eq!(std::mem::size_of_val(&result), init_size());

        init_caller(&mut result, ());

        match result.into() {
            Err(()) => {
                panic!("roc returned an error from init");
            }
            Ok(model) => Model::init(model),
        }
    }
}

pub fn call_roc_render(platform_state: PlatformState, model: &Model) -> Model {
    extern "C" {
        #[link_name = "roc__render_1_exposed_size"]
        fn render_size() -> usize;

        #[link_name = "roc__render_1_exposed_generic"]
        fn render_caller(
            model_out: *mut RocResult<RocBox<()>, ()>,
            model_in: *const RocBox<()>,
            platform_state: *const ManuallyDrop<PlatformState>,
        );
    }

    unsafe {
        // save stack space for return value
        let mut result: RocResult<RocBox<()>, ()> = RocResult::err(());
        debug_assert_eq!(std::mem::size_of_val(&result), render_size());

        render_caller(
            &mut result,
            &model.model,
            &ManuallyDrop::new(platform_state),
        );

        match result.into() {
            Err(()) => {
                panic!("roc returned an error from render");
            }
            Ok(model) => Model::init(model),
        }
    }
}
