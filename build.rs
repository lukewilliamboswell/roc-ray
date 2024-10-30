use std::path::{Path, PathBuf};

fn main() {
    // Get the build cache directory
    let out_dir = std::env::var("OUT_DIR").unwrap();
    let out_dir = Path::new(&out_dir);

    // Get the roc ray target
    let target = RocRaySupportedTarget::default();

    // Re-run this build script if roc rebuild's the app
    watch_app_o(&target);

    // Find required static libraries in the build cache
    println!("cargo:rustc-link-search={}", out_dir.display());

    // Get the roc app object file (ensure it exists)
    let app_o = get_roc_app_object(&target);

    match target {
        RocRaySupportedTarget::Linux => {
            // Run the `ar rcs libapp.a app.o` command
            let lib_app = out_dir.join("libapp.a");
            let output = std::process::Command::new("ar")
                .args(["rcs", lib_app.to_str().unwrap(), "app.o"])
                .output()
                .expect("Failed to execute ar command");

            assert!(output.status.success(), "{output:#?}");
            assert!(output.stdout.is_empty(), "{output:#?}");
            assert!(output.stderr.is_empty(), "{output:#?}");

            // Link with the app object file
            println!("cargo:rustc-link-lib=static=app");
        }
        RocRaySupportedTarget::Windows => {
            // Copy the app object to the build cache
            // NOTE we are changing the file extension to lib... but rust doesn't seem to mind
            // We coulp package this into a library using LIB.exe but that requires Visual Studio which users may not have installed
            let out_path = out_dir.join("app.lib");
            std::fs::copy(app_o, out_path).unwrap();

            // Link the Windows libraries
            println!("cargo:rustc-link-lib=user32");
            println!("cargo:rustc-link-lib=gdi32");
            println!("cargo:rustc-link-lib=winmm");
            println!("cargo:rustc-link-lib=shell32");
        }
        RocRaySupportedTarget::Web => {
            let output = std::process::Command::new("zig")
                .args([
                    "build-lib",
                    "-target",
                    "wasm32-wasi",
                    "-lc",
                    app_o.to_str().unwrap(),
                    &format!("-femit-bin={}", out_dir.join("libapp.a").to_str().unwrap()),
                ])
                .output()
                .unwrap();

            assert!(output.status.success(), "{output:#?}");
            assert!(output.stdout.is_empty(), "{output:#?}");
            assert!(output.stderr.is_empty(), "{output:#?}");

            println!("cargo:rustc-link-lib=static=app");
        }
        RocRaySupportedTarget::MacOS => {
            // Run the `libtool -static -o libapp.a app.o` command
            // to create a static library from the object file
            let lib_app = out_dir.join("libapp.a");
            let output = std::process::Command::new("libtool")
                .args(["-static", "-o", lib_app.to_str().unwrap(), "app.o"])
                .output()
                .unwrap();

            assert!(output.status.success(), "{output:#?}");
            assert!(output.stdout.is_empty(), "{output:#?}");
            assert!(output.stderr.is_empty(), "{output:#?}");

            // Link with the app object file
            println!("cargo:rustc-link-lib=static=app");

            // Link with the required frameworks
            println!("cargo:rustc-link-lib=framework=CoreFoundation");
            println!("cargo:rustc-link-lib=framework=CoreGraphics");
            println!("cargo:rustc-link-lib=framework=IOKit");
            println!("cargo:rustc-link-lib=framework=AppKit");
            println!("cargo:rustc-link-lib=framework=Foundation");
        }
    }
}

#[derive(Debug)]
enum RocRaySupportedTarget {
    MacOS,
    Linux,
    Windows,
    Web,
}

impl RocRaySupportedTarget {
    fn default() -> RocRaySupportedTarget {
        let arch = build_target::target_arch().unwrap();
        let os = build_target::target_os().unwrap();
        RocRaySupportedTarget::from_arch_os(arch, os)
    }

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

fn get_roc_app_object(target: &RocRaySupportedTarget) -> PathBuf {
    match target {
        RocRaySupportedTarget::Windows => {
            // Check if the app.obj built by roc exists
            let app_obj = manifest_dir().join("app.obj");
            if !app_obj.exists() {
                panic!("app.obj file not found -- this should have been generated by roc");
            }

            app_obj.to_path_buf()
        }
        RocRaySupportedTarget::MacOS
        | RocRaySupportedTarget::Linux
        | RocRaySupportedTarget::Web => {
            // Check if the app.o built by roc exists
            let app_o = manifest_dir().join("app.o");
            if !app_o.exists() {
                panic!("app.o file not found -- this should have been generated by roc");
            }

            app_o.to_path_buf()
        }
    }
}

fn watch_app_o(target: &RocRaySupportedTarget) {
    match target {
        RocRaySupportedTarget::Windows => println!("cargo:rerun-if-changed=app.obj"),
        RocRaySupportedTarget::MacOS
        | RocRaySupportedTarget::Linux
        | RocRaySupportedTarget::Web => println!("cargo:rerun-if-changed=app.o"),
    }
}
