#[cfg(target_arch = "aarch64")]
#[cfg(target_os = "macos")]
mod aarch64_apple_darwin;

#[cfg(target_arch = "aarch64")]
#[cfg(target_os = "macos")]
pub use aarch64_apple_darwin::*;
