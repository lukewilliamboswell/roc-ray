{
  description = "Roc Ray platform flake";

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
          default = pkgs.mkShell {
            packages = [ rocPkgs.cli pkgs.rustc pkgs.cargo ] ++ linuxDeps ++ macosDeps;
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

        }
      );
    };
}
