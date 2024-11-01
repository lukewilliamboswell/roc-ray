#[cfg(target_family = "wasm")]
extern "C" {
    fn emscripten_console_log(msg: *const i8);
}

pub fn log(msg: &str) {
    #[cfg(target_family = "wasm")]
    unsafe {
        let cstring = std::ffi::CString::new(msg).unwrap();
        emscripten_console_log(cstring.as_ptr());
    }

    #[cfg(not(target_family = "wasm"))]
    println!("{}", msg)
}
