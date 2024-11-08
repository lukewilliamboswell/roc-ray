use std::path::{Path, PathBuf};

#[allow(dead_code)]
#[derive(Debug)]
enum AppType {
    Static(PathBuf),
    Dynamic(PathBuf),
}

fn main() {
    // Re-run this build script if roc rebuild's the app
    watch_app_o();

    // Get the build cache directory
    let out_dir = std::env::var("OUT_DIR").unwrap();
    let out_dir = Path::new(&out_dir);

    // Get the roc ray target
    let target = RocRaySupportedTarget::default();

    // Find required static libraries in the build cache or root directory
    println!("cargo:rustc-link-search={}", out_dir.display());

    // Get the roc app object file (ensure it exists)
    let app = get_roc_app_object(&target);

    match (target, app) {
        (RocRaySupportedTarget::Linux, AppType::Static(..)) => {
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
        (RocRaySupportedTarget::Windows, AppType::Static(app_o)) => {
            // Copy the app object to the build cache
            // NOTE we are changing the file extension to lib... but rust doesn't seem to mind
            // We coulp package this into a library using LIB.exe but that requires Visual Studio which users may not have installed
            let out_path = out_dir.join("app.lib");
            std::fs::copy(app_o, out_path).unwrap();


            // TODO Investigate why we need this... we this error when linking raylib
            // this seems to be an acceptable workaround.
            // = note: libraylib-69fe326be1a79017.rlib(rcore.obj) : error LNK2005: CloseWindow already defined in user32.lib(USER32.dll)␍
            // libraylib-69fe326be1a79017.rlib(raudio.obj) : error LNK2005: PlaySound already defined in winmm.lib(WINMM.dll)␍
            println!("cargo:rustc-link-arg=/FORCE:MULTIPLE");

            // Link the Windows libraries
            println!("cargo:rustc-link-lib=user32");
            println!("cargo:rustc-link-lib=gdi32");
            println!("cargo:rustc-link-lib=winmm");
            println!("cargo:rustc-link-lib=shell32");
        }
        (RocRaySupportedTarget::Web, AppType::Static(app_o)) => {
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

            if std::env::var("PROFILE").unwrap() == "release" {
                println!(
                    "cargo:rustc-env=EMCC_CFLAGS={}",
                    std::env::var("EMCC_CFLAGS_RELEASE").unwrap()
                );
            } else {
                println!(
                    "cargo:rustc-env=EMCC_CFLAGS={}",
                    std::env::var("EMCC_CFLAGS_DEBUG").unwrap()
                );
            }
        }
        (RocRaySupportedTarget::MacOS, AppType::Static(..)) => {
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
        }
        (RocRaySupportedTarget::MacOS, AppType::Dynamic(app_dylib)) => {
            // Copy the app dylib to the build cache
            let out_path = out_dir.join("libapp.dylib");
            std::fs::copy(app_dylib, out_path).unwrap();

            // Add linking flags to make sure our symbols are visible to roc
            println!("cargo:rustc-link-arg=-Wl,-export_dynamic");

            // Link with the app object file
            println!("cargo:rustc-link-lib=dylib=app");
        }
        (RocRaySupportedTarget::Linux, AppType::Dynamic(app_so)) => {
            // Copy the app dylib to the build cache
            let out_path = out_dir.join("libapp.so");
            std::fs::copy(app_so, out_path).unwrap();

            // Add linking flags to make sure our symbols are visible to roc
            println!("cargo:rustc-link-arg=-Wl,-export_dynamic");

            // Link with the app object file
            println!("cargo:rustc-link-lib=dylib=app");
        }
        err => {
            todo!("Implement build script for {:?}", err)
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
        let os = build_target::target_os().unwrap();
        if matches!(os, build_target::Os::Emscripten) {
            RocRaySupportedTarget::Web
        } else if matches!(os, build_target::Os::MacOs) {
            RocRaySupportedTarget::MacOS
        } else if matches!(os, build_target::Os::Linux) {
            RocRaySupportedTarget::Linux
        } else if matches!(os, build_target::Os::Windows) {
            RocRaySupportedTarget::Windows
        } else {
            panic!("Unsupported target -- build.rs probably needs updating");
        }
    }
}

fn manifest_dir() -> PathBuf {
    PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap())
}

// preferences the static library over the dynamic library if both are present
fn get_roc_app_object(target: &RocRaySupportedTarget) -> AppType {
    match target {
        RocRaySupportedTarget::Windows => {
            // Check if the app.obj built by roc exists
            let app_obj = manifest_dir().join("app.obj");
            let app_lib = manifest_dir().join("app.lib");
            if app_obj.exists() {
                AppType::Static(app_obj.to_path_buf())
            } else if app_lib.exists() {
                AppType::Dynamic(app_lib.to_path_buf())
            } else {
                panic!(
                    "app.obj or app.lib file not found -- this should have been generated by roc"
                );
            }
        }
        RocRaySupportedTarget::MacOS => {
            let app_o = manifest_dir().join("app.o");
            let app_dylib = manifest_dir().join("libapp.dylib");
            if app_o.exists() {
                AppType::Static(app_o.to_path_buf())
            } else if app_dylib.exists() {
                AppType::Dynamic(app_dylib.to_path_buf())
            } else {
                panic!(
                    "app.o or libapp.dylib file not found -- this should have been generated by roc"
                );
            }
        }
        RocRaySupportedTarget::Linux => {
            // Check if the app.o built by roc exists
            let app_o = manifest_dir().join("app.o");
            let app_so = manifest_dir().join("libapp.so");
            if app_o.exists() {
                AppType::Static(app_o.to_path_buf())
            } else if app_so.exists() {
                AppType::Dynamic(app_so.to_path_buf())
            } else {
                panic!(
                    "app.o or libapp.so file not found -- this should have been generated by roc"
                );
            }
        }
        RocRaySupportedTarget::Web => {
            let new_target = match std::env::consts::OS {
                "macos" => RocRaySupportedTarget::MacOS,
                "windows" => RocRaySupportedTarget::Windows,
                "linux" => RocRaySupportedTarget::Linux,
                _ => panic!("Unrecongised OS -- build.rs probably needs updating"),
            };

            get_roc_app_object(&new_target)
        }
    }
}

fn watch_app_o() {
    let os = build_target::target_os().unwrap();
    match os {
        build_target::Os::Windows => {
            println!("cargo:rerun-if-changed=app.lib");
            println!("cargo:rerun-if-changed=app.obj");
        }
        build_target::Os::MacOs => {
            println!("cargo:rerun-if-changed=libapp.dylib");
            println!("cargo:rerun-if-changed=app.o");
        }
        build_target::Os::Linux => {
            println!("cargo:rerun-if-changed=app.o");
            println!("cargo:rerun-if-changed=libapp.so");
        }
        build_target::Os::Emscripten => {
            // Assume static linking for wasm32
            println!("cargo:rerun-if-changed=app.o");
            println!("cargo:rerun-if-changed=app.obj");
        }
        _ => panic!("Unrecognised Os ... build.rs probably needs updating to support this"),
    }
}
