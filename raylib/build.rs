use std::path::PathBuf;

fn main() {
    // Get the roc ray supported target
    let arch = build_target::target_arch().unwrap();
    let os = build_target::target_os().unwrap();
    let target = RocRaySupportedTarget::from_arch_os(arch, os);

    match target {
        RocRaySupportedTarget::Linux => {
            println!(
                "cargo:rustc-link-search=native={}",
                manifest_dir().join("raylib-5.0_linux_amd64").display()
            )
        }
        RocRaySupportedTarget::Windows => {
            println!(
                "cargo:rustc-link-search=native={}",
                manifest_dir().join("raylib-5.0_win64_msvc16").display()
            )
        }
        RocRaySupportedTarget::Web => {
            println!(
                "cargo:rustc-link-search=native={}",
                manifest_dir().join("raylib-5.0_webassembly").display()
            )
        }
        RocRaySupportedTarget::MacOS => {
            println!(
                "cargo:rustc-link-search=native={}",
                manifest_dir().join("raylib-5.0_macos").display()
            )
        }
    }

    println!("cargo:rustc-link-lib=static=raylib");
}

#[derive(Debug)]
enum RocRaySupportedTarget {
    MacOS,
    Linux,
    Windows,
    Web,
}

impl RocRaySupportedTarget {
    fn from_arch_os(arch: build_target::Arch, os: build_target::Os) -> RocRaySupportedTarget {
        if matches!(arch, build_target::Arch::WASM32) {
            RocRaySupportedTarget::Web
        } else if matches!(os, build_target::Os::MacOs) {
            RocRaySupportedTarget::MacOS
        } else if matches!(os, build_target::Os::Linux) {
            RocRaySupportedTarget::Linux
        } else if matches!(os, build_target::Os::Windows) {
            RocRaySupportedTarget::Windows
        } else {
            panic!("Unsupported target");
        }
    }
}

fn manifest_dir() -> PathBuf {
    PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap())
}
