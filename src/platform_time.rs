use std::cell::RefCell;
use std::time::SystemTime;

use crate::glue::PlatformTime;

thread_local! {
    static PLATFORM_TIME: RefCell<crate::glue::PlatformTime> = const { RefCell::new(PlatformTime{
        init_end: 0,
        init_start: 0,
        last_render_end: 0,
        last_render_start: 0,
        render_start: 0,
    }) };
}

pub fn get_platform_time() -> PlatformTime {
    PLATFORM_TIME.with_borrow(|time| time.clone())
}

pub fn init_start() {
    PLATFORM_TIME.with_borrow_mut(|time| {
        time.init_start = now();
    })
}

pub fn init_end() {
    PLATFORM_TIME.with_borrow_mut(|time| {
        time.init_end = now();
    })
}

pub fn render_start() {
    PLATFORM_TIME.with_borrow_mut(|time| {
        time.render_start = now();
    })
}

pub fn render_end() {
    PLATFORM_TIME.with_borrow_mut(|time| {
        time.last_render_end = now();
        time.last_render_start = time.render_start;
    })
}

// note we cast to u64 and lose some precision
fn now() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}
