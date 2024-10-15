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
            pkgs.xorg.libX11
            pkgs.libGL
            pkgs.mesa.drivers
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
            packages = [ rocPkgs.cli ] ++ linuxDeps ++ macosDeps;
            shellHook = ''
              if [ "$(uname)" = "Darwin" ]; then
                export SDKROOT=$(xcrun --show-sdk-path)
              fi

              if [ "$(uname)" = "Linux" ]; then
                export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath linuxDeps}:$LD_LIBRARY_PATH
              fi

              unset NIX_CFLAGS_COMPILE
              unset NIX_LDFLAGS
            '';
          };
        }
      );
    };
}
