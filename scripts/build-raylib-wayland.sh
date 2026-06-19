#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/build-raylib-wayland.sh <raylib-6.0-source-dir>

Build raylib's static Linux x64 archive with bundled GLFW Wayland support and
copy it to vendor/raylib/linux-x64-wayland/libraylib.a.

Run this on Linux with Wayland build dependencies installed. On Debian/Ubuntu:

  sudo apt install cmake build-essential libwayland-dev libxkbcommon-dev
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "error: build the Wayland raylib archive on Linux" >&2
    exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "error: cmake is required" >&2
    exit 1
fi

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
raylib_src="$(cd "$1" && pwd)"
build_dir="$root_dir/build/raylib-wayland"
output_dir="$root_dir/vendor/raylib/linux-x64-wayland"
output_archive="$output_dir/libraylib.a"

if [[ ! -f "$raylib_src/CMakeLists.txt" || ! -d "$raylib_src/src" ]]; then
    echo "error: not a raylib source directory: $raylib_src" >&2
    exit 1
fi

cmake -S "$raylib_src" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DPLATFORM=Desktop \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DUSE_EXTERNAL_GLFW=OFF \
    -DGLFW_BUILD_WAYLAND=ON \
    -DGLFW_BUILD_X11=OFF \
    -DWITH_PIC=ON

cmake --build "$build_dir" --target raylib --config Release

archive="$(find "$build_dir" -type f -name 'libraylib.a' | head -n 1)"
if [[ -z "$archive" ]]; then
    echo "error: raylib build did not produce libraylib.a" >&2
    exit 1
fi

mkdir -p "$output_dir"
cp "$archive" "$output_archive"

echo "Created: $output_archive"
