fn main() {
    println!("cargo:rustc-link-search=native=.");

    #[cfg(not(target_os = "windows"))]
    {
        println!("cargo:rerun-if-changed=app.o");
        println!("cargo:rustc-link-lib=static=app.o");
    }

    #[cfg(target_os = "windows")]
    {
        println!("cargo:rerun-if-changed=app.lib");
        println!("cargo:rustc-link-lib=static=app");
    }
}
