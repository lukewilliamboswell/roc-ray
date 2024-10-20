#![allow(non_snake_case)]
use roc_std::{RocBox, RocResult, RocStr};
use roc_std_heap::ThreadSafeRefcountedResourceHeap;
use std::alloc::Layout;
use std::mem::{ManuallyDrop, MaybeUninit};
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
        #[link_name = "roc__forHost_1_exposed_generic"]
        fn load_init_captures(init_captures: *mut u8);

        #[link_name = "roc__forHost_1_exposed_size"]
        fn exposed_size() -> usize;

        #[link_name = "roc__forHost_0_caller"]
        fn init_caller(
            inputs: *const u8,
            init_captures: *const u8,
            model: *mut RocResult<RocBox<()>, ()>,
        );

        #[link_name = "roc__forHost_0_size"]
        fn init_captures_size() -> usize;

        #[link_name = "roc__forHost_1_size"]
        fn respond_captures_size() -> usize;

        #[link_name = "roc__forHost_0_result_size"]
        fn init_result_size() -> usize;
    }

    unsafe {
        let respond_captures_size = respond_captures_size();
        if respond_captures_size != 0 {
            panic!("This platform does not allow for the respond function to have captures, but respond has {} bytes of captures. Ensure respond is a top level function and not a lambda.", respond_captures_size);
        }
        // allocate memory for captures
        let captures_size = init_captures_size();
        let captures_layout = Layout::array::<u8>(captures_size).unwrap();
        let captures_ptr = std::alloc::alloc(captures_layout);

        // initialise roc
        debug_assert_eq!(captures_size, exposed_size());
        load_init_captures(captures_ptr);

        // save stack space for return value
        let mut result: RocResult<RocBox<()>, ()> = RocResult::err(());
        debug_assert_eq!(std::mem::size_of_val(&result), init_result_size());

        // call init to get the model RocBox<()>
        init_caller(
            // This inputs pointer will never get dereferenced
            MaybeUninit::uninit().as_ptr(),
            captures_ptr,
            &mut result,
        );

        // deallocate captures
        std::alloc::dealloc(captures_ptr, captures_layout);

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
        #[link_name = "roc__forHost_1_caller"]
        fn render_fn_caller(
            model: *const RocBox<()>,
            inputs: *const ManuallyDrop<PlatformState>,
            captures: *const u8,
            output: *mut u8,
        );

        #[link_name = "roc__forHost_1_result_size"]
        fn render_fn_result_size() -> usize;

        #[link_name = "roc__forHost_2_caller"]
        fn render_task_caller(
            inputs: *const u8,
            captures: *const u8,
            model: *mut RocResult<RocBox<()>, ()>,
        );

        #[link_name = "roc__forHost_2_size"]
        fn render_task_size() -> usize;

        #[link_name = "roc__forHost_2_result_size"]
        fn render_task_result_size() -> usize;
    }

    unsafe {
        // allocated memory for return value
        let intermediate_result_size = render_fn_result_size();
        let intermediate_result_layout = Layout::array::<u8>(intermediate_result_size).unwrap();
        let intermediate_result_ptr = std::alloc::alloc(intermediate_result_layout);

        // call the respond function to get the Task
        debug_assert_eq!(intermediate_result_size, render_task_size());
        render_fn_caller(
            &model.model,
            &ManuallyDrop::new(platform_state),
            // In init, we ensured that respond never has captures.
            MaybeUninit::uninit().as_ptr(),
            intermediate_result_ptr,
        );

        // save stack space for return value
        let mut result: RocResult<RocBox<()>, ()> = RocResult::err(());
        debug_assert_eq!(std::mem::size_of_val(&result), render_task_result_size());

        // call the Task
        render_task_caller(
            // This inputs pointer will never get dereferenced
            MaybeUninit::uninit().as_ptr(),
            intermediate_result_ptr,
            &mut result,
        );

        // deallocate captures
        std::alloc::dealloc(intermediate_result_ptr, intermediate_result_layout);

        match result.into() {
            Err(()) => {
                panic!("roc returned an error from init");
            }
            Ok(model) => Model::init(model),
        }
    }
}
