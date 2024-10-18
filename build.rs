use std::env;
use std::path::{Path, PathBuf};

#[cfg(target_os = "macos")]
fn main() {
    // Re-run this build script if roc rebuild's the app
    println!("cargo:rerun-if-changed=app.o");

    // Check if the app.o file exists
    if !Path::new("app.o").exists() {
        panic!("app.o file not found -- this should have been generated by roc");
    }

    // Get the build cache directory (OUT_DIR)
    let out_dir = env::var("OUT_DIR").unwrap();

    // Search for static libraries in the cache directory
    println!("cargo:rustc-link-search=native={out_dir}");

    // Run the `libtool -static -o libapp.a app.o` command
    // to create a static library from the object file
    let lib_app_path = Path::new(&out_dir).join("libapp.a");
    let output = std::process::Command::new("libtool")
        .args(&[
            "-static",
            "-o",
            format!("{}", lib_app_path.into_os_string().into_string().unwrap()).as_str(),
            "app.o",
        ])
        .output()
        .expect("Failed to execute libtool command");

    if !output.status.success() {
        panic!("libtool command failed with status: {}", output.status);
    }

    let out_path = Path::new(&out_dir).join("libraylib.a");

    let vendored_path = manifest_dir()
        .join("vendor")
        .join("raylib-5.0_macos")
        .join("libraylib.a");

    std::fs::copy(vendored_path, out_path).unwrap();

    // Static link the app and raylib libraries, and dynamic link the required Macos frameworks
    println!("cargo:rustc-link-lib=static=app");
    println!("cargo:rustc-link-lib=static=raylib");
    println!("cargo:rustc-link-lib=framework=CoreFoundation");
    println!("cargo:rustc-link-lib=framework=CoreGraphics");
    println!("cargo:rustc-link-lib=framework=IOKit");
    println!("cargo:rustc-link-lib=framework=AppKit");
    println!("cargo:rustc-link-lib=framework=Foundation");
}

#[cfg(target_os = "linux")]
fn main() {
    // Re-run this build script if roc rebuild's the app
    println!("cargo:rerun-if-changed=app.o");

    // Check if the app.o file exists
    if !Path::new("app.o").exists() {
        panic!("app.o file not found -- this should have been generated by roc");
    }

    // Get the build cache directory (OUT_DIR)
    let out_dir = env::var("OUT_DIR").unwrap();

    // Search for static libraries in the cache directory
    println!("cargo:rustc-link-search=native={out_dir}");

    // Run the `ar rcs libapp.a app.o` command
    let lib_app_path = Path::new(&out_dir).join("libapp.a");
    let output = std::process::Command::new("ar")
        .args(&[
            "rcs",
            format!("{}", lib_app_path.into_os_string().into_string().unwrap()).as_str(),
            "app.o",
        ])
        .output()
        .expect("Failed to execute ar command");

    if !output.status.success() {
        panic!("ar command failed with status: {}", output.status);
    }

    let vendored_path = manifest_dir()
        .join("vendor")
        .join("raylib-5.0_linux_amd64")
        .join("libraylib.a");

    let out_path = Path::new(&out_dir).join("libraylib.a");

    std::fs::copy(vendored_path, out_path).unwrap();

    println!("cargo:rustc-link-lib=static=app");
    println!("cargo:rustc-link-lib=static=raylib");
}

#[cfg(target_os = "windows")]
fn main() {
    // Re-run this build script if roc rebuild's the app
    println!("cargo:rerun-if-changed=app.lib");

    // Check if the app.o file exists
    if !Path::new("app.lib").exists() {
        panic!("app.lib file not found -- this should have been generated by roc");
    }

    // Get the build cache directory (OUT_DIR)
    let out_dir = env::var("OUT_DIR").unwrap();

    // Search for static libraries in the cache directory
    println!("cargo:rustc-link-search=native={out_dir}");

    let vendored_path = manifest_dir()
        .join("vendor")
        .join("raylib-5.0_win64_msvc16")
        .join("raylib.lib");

    let out_path = Path::new(&out_dir).join("raylib.lib");

    std::fs::copy(vendored_path, out_path).unwrap();

    println!("cargo:rustc-link-lib=static=app");
    println!("cargo:rustc-link-lib=static=raylib");
    println!("cargo:rustc-link-lib=user32");
    println!("cargo:rustc-link-lib=gdi32");
    println!("cargo:rustc-link-lib=winmm");
    println!("cargo:rustc-link-lib=shell32");
}

fn manifest_dir() -> PathBuf {
    PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
}
