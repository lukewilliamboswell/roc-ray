use std::process::Command;

fn main() {
    println!("cargo:rustc-link-search=native=.");

    #[cfg(target_os = "macos")]
    {
        println!("cargo:rerun-if-changed=app.o");
        println!("cargo:rustc-link-lib=static=app.o");
    }

    #[cfg(target_os = "linux")]
    {
        println!("cargo:rerun-if-changed=app.o");

        // Run the `ar rcs libapp.a app.o` command
        let output = Command::new("ar")
            .args(&["rcs", "libapp.a", "app.o"])
            .output()
            .expect("Failed to execute ar command");

        if !output.status.success() {
            panic!("ar command failed with status: {}", output.status);
        }

        println!("cargo:rustc-link-lib=static=app");
    }

    #[cfg(target_os = "windows")]
    {
        println!("cargo:rerun-if-changed=app.lib");
        println!("cargo:rustc-link-lib=static=app");
    }
}
