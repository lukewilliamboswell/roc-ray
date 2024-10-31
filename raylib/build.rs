use std::path::PathBuf;

fn main() {
    // Get the roc ray supported target
    let arch = build_target::target_arch().unwrap();
    let os = build_target::target_os().unwrap();

    println!("cargo:warning=Architecture: {:?}", arch);
    println!("cargo:warning=OS: {:?}", os);

    let target = RocRaySupportedTarget::from_arch_os(arch, os);

    println!(
        "cargo:warning=Target from env: {:?}",
        std::env::var("TARGET")
    );
    println!("cargo:warning=RocRay Target: {:?}", target);

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
            );

            // Link Objective-C runtime first
            println!("cargo:rustc-link-lib=objc");

            // Then link required frameworks
            println!("cargo:rustc-link-lib=framework=Foundation");
            println!("cargo:rustc-link-lib=framework=Cocoa");
            println!("cargo:rustc-link-lib=framework=IOKit");
            println!("cargo:rustc-link-lib=framework=CoreFoundation");
            println!("cargo:rustc-link-lib=framework=CoreVideo");
            println!("cargo:rustc-link-lib=framework=AppKit");
            println!("cargo:rustc-link-lib=framework=OpenGL");
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
