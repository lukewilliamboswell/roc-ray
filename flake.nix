{
  description = "Roc Ray platform flake";

  inputs = {
    roc.url = "github:roc-lang/roc";

    nixpkgs.follows = "roc/nixpkgs";

    # rust from nixpkgs has some libc problems, this is patched in the rust-overlay
    rust-overlay = {
        url = "github:oxalica/rust-overlay";
        inputs.nixpkgs.follows = "nixpkgs";
    };

    # to easily make configs for multiple architectures
    flake-utils.url = "github:numtide/flake-utils";

  };

  outputs = { self, roc, nixpkgs, rust-overlay, flake-utils  }:
    let supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    in flake-utils.lib.eachSystem supportedSystems (system:
        let
            overlays = [ (import rust-overlay) ];
            pkgs = import nixpkgs { inherit system overlays; };

            rocPkgs = roc.packages.${system};
            # llvmPkgs = pkgs.llvmPackages_16;

            rust = pkgs.rust-bin.fromRustupToolchainFile "${toString ./rust-toolchain.toml}";

            linuxDeps = if pkgs.stdenv.isLinux then [
                pkgs.xorg.libX11
                pkgs.libGL
                pkgs.mesa.drivers
                pkgs.alsa-lib
                pkgs.xorg.libXrandr
                pkgs.xorg.libXi
                pkgs.xorg.libXcursor
                pkgs.xorg.libXinerama
                pkgs.libxkbcommon
                pkgs.wayland
            ] else [];

            macosDeps = if pkgs.stdenv.isDarwin then [
                pkgs.libiconv
                pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
                pkgs.darwin.apple_sdk.frameworks.CoreGraphics
                pkgs.darwin.apple_sdk.frameworks.AppKit
            ] else [];

        in {

            devShell = if pkgs.stdenv.isDarwin then
                throw ''
                    HELP WANTED FOR ROC RAY NIX CONFIGURATION

                    Darwin/macOS is not currently supported due to framework linking issues.
                    If you'd like to help fix this, please check:
                    https://github.com/your-repo/roc-ray/issues

                    The main issue is with linking Objective-C runtime and macOS frameworks
                    correctly within the Nix environment. I can't find the right incantation
                    to make it work. If you have experience with this, please help! :smile:
                ''
                else pkgs.mkShell {

                packages = [
                        rocPkgs.cli
                        rust
                        pkgs.zig # For Web support, used to build roc wasm static library
                        pkgs.emscripten
                        pkgs.simple-http-server
                    ] ++ linuxDeps ++ macosDeps;

                shellHook = ''
                    if [ "$(uname)" = "Darwin" ]; then
                        export SDKROOT=$(xcrun --show-sdk-path)
                        export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath macosDeps}:$LD_LIBRARY_PATH
                    fi

                    if [ "$(uname)" = "Linux" ]; then
                        export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath linuxDeps}:$LD_LIBRARY_PATH
                    fi
                '';
            };

            formatter = pkgs.nixpkgs-fmt;

        });
}
