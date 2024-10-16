#[cfg(target_arch = "aarch64")]
#[cfg(target_os = "macos")]
mod aarch64_apple_darwin;

#[cfg(target_arch = "aarch64")]
#[cfg(target_os = "macos")]
pub use aarch64_apple_darwin::*;

#[cfg(target_arch = "x86_64")]
#[cfg(target_os = "linux")]
mod x86_64_unknown_linux_gnu;

#[cfg(target_arch = "x86_64")]
#[cfg(target_os = "linux")]
pub use x86_64_unknown_linux_gnu::*;
