use std::cell::RefCell;
use std::ffi::{c_int, CString};

#[derive(Debug)]
pub struct Config {
    pub title: CString,
    pub width: c_int,
    pub height: c_int,
    pub should_exit: bool,
    pub should_exit_msg_code: Option<(String, ExitErrCode)>,
    pub fps_show: bool,
    pub fps_target: c_int,
    pub fps_target_dirty: bool,
    pub fps_position: (c_int, c_int),
    pub trace_log_level: TraceLevel,
    pub network_web_rtc_url: Option<String>,
}

thread_local! {
    // DEFAULT VALUES
    static CONFIG: RefCell<Config> = RefCell::new(Config {
        title: CString::new("Loading roc-ray app...").unwrap(),
        width: 200,
        height: 50,
        should_exit: false,
        should_exit_msg_code: None,
        fps_show: false,
        fps_target: 60,
        fps_target_dirty: false,
        fps_position: (10, 10),
        trace_log_level: TraceLevel::Info,
        network_web_rtc_url: None,
    });
}

pub fn with<F, R>(f: F) -> R
where
    F: FnOnce(&Config) -> R,
{
    CONFIG.with(|config| f(&config.borrow()))
}

pub fn update<F>(f: F)
where
    F: FnOnce(&mut Config),
{
    CONFIG.with(|config| f(&mut config.borrow_mut()));
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
            TraceLevel::None => raylib::TraceLogLevel_LOG_NONE as c_int,
            TraceLevel::Error => raylib::TraceLogLevel_LOG_ERROR as c_int,
            TraceLevel::Warn => raylib::TraceLogLevel_LOG_WARNING as c_int,
            TraceLevel::Info => raylib::TraceLogLevel_LOG_INFO as c_int,
            TraceLevel::Debug => raylib::TraceLogLevel_LOG_DEBUG as c_int,
            TraceLevel::Trace => raylib::TraceLogLevel_LOG_TRACE as c_int,
            TraceLevel::All => raylib::TraceLogLevel_LOG_ALL as c_int,
        }
    }
}

/// use different error codes when the app exits
#[allow(dead_code)]
#[derive(Clone, Copy, Debug)]
pub enum ExitErrCode {
    EffectNotPermitted = 1,
    NotYetImplemented = 2, // only used when things are TODO otherwise dead code
    WebRTCConnectionError = 3,
    WebRTCConnectionDisconnected = 4,
    ErrFromRocInit = 5,
    ErrFromRocRender = 6,
}
