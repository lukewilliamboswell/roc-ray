use std::cell::RefCell;
use std::ffi::{c_int, CString};

thread_local! {
    // DEFAULT VALUES
    static CONFIG: RefCell<Config> = RefCell::new(Config {
        title: CString::new("Loading roc-ray app...").unwrap(),
        width: 200,
        height: 50,
        should_exit: false,
        fps_show: false,
        fps_target: 60,
        fps_target_dirty: false,
        fps_position: (10, 10),
        trace_log_level: TraceLevel::Info,
    });
}

pub fn with<F, R>(f: F) -> R
where
    F: FnOnce(&Config) -> R,
{
    CONFIG.with(|config| f(&*config.borrow()))
}

pub fn update<F>(f: F)
where
    F: FnOnce(&mut Config),
{
    CONFIG.with(|config| f(&mut *config.borrow_mut()));
}

#[derive(Debug, Clone, Copy)]
pub enum TraceLevel {
    None,
    Error,
    Warn,
    Info,
    Debug,
    Trace,
    All,
}

impl From<TraceLevel> for c_int {
    fn from(value: TraceLevel) -> Self {
        match value {
            TraceLevel::None => crate::bindings::TraceLogLevel_LOG_NONE as c_int,
            TraceLevel::Error => crate::bindings::TraceLogLevel_LOG_ERROR as c_int,
            TraceLevel::Warn => crate::bindings::TraceLogLevel_LOG_WARNING as c_int,
            TraceLevel::Info => crate::bindings::TraceLogLevel_LOG_INFO as c_int,
            TraceLevel::Debug => crate::bindings::TraceLogLevel_LOG_DEBUG as c_int,
            TraceLevel::Trace => crate::bindings::TraceLogLevel_LOG_TRACE as c_int,
            TraceLevel::All => crate::bindings::TraceLogLevel_LOG_ALL as c_int,
        }
    }
}

#[derive(Debug)]
pub struct Config {
    pub title: CString,
    pub width: c_int,
    pub height: c_int,
    pub should_exit: bool,
    pub fps_show: bool,
    pub fps_target: c_int,
    pub fps_target_dirty: bool,
    pub fps_position: (c_int, c_int),
    pub trace_log_level: TraceLevel,
}
