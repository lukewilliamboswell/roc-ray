{
  description = "Roc Raylib platform flake";

  inputs = {
    roc.url = "github:roc-lang/roc";
    nixpkgs.url = "github:nixos/nixpkgs";
  };

  outputs = { self, roc, nixpkgs }:
    let
        supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
        forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {
        devShells = forAllSystems (system:
        let
            pkgs = nixpkgs.legacyPackages.${system};

            rocPkgs = roc.packages.${system};

            linuxDeps = if pkgs.stdenv.isLinux then [
                pkgs.libasound
                pkgs.libX11
                pkgs.libXrandr
                pkgs.libXi
                pkgs.mesa
                pkgs.libGLU
                pkgs.libXcursor
                pkgs.libXinerama
                pkgs.wayland
                pkgs.libxkbcommon
            ] else [];

            macosDeps = if pkgs.stdenv.isDarwin then [
                pkgs.darwin.apple_sdk.frameworks.Foundation
                pkgs.darwin.apple_sdk.frameworks.CoreServices
                pkgs.darwin.apple_sdk.frameworks.CoreGraphics
                pkgs.darwin.apple_sdk.frameworks.AppKit
                pkgs.darwin.apple_sdk.frameworks.IOKit
                pkgs.darwin.apple_sdk.frameworks.AudioToolbox
                pkgs.darwin.apple_sdk.frameworks.CoreMIDI
            ] else [];

        in {
            default = pkgs.mkShell {

                packages = [ pkgs.zig_0_13  rocPkgs.cli ] ++ linuxDeps ++ macosDeps;

                shellHook = ''
                    if [ "$(uname)" = "Darwin" ]; then
                        export SDKROOT=$(xcrun --show-sdk-path)
                    fi

                    # We unset some NIX environment variables that might interfere with the zig
                    # compiler.
                    # Issue: https://github.com/ziglang/zig/issues/18998
                    unset NIX_CFLAGS_COMPILE
                    unset NIX_LDFLAGS
                '';
            };
        });
    };
}
