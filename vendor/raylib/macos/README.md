# macOS raylib archive

This universal archive is raylib 6.0 with the upstream
[initial macOS window size fix](https://github.com/raysan5/raylib/commit/cba8f4286d5b42ed5e999ba543ca6ebb22d99572)
applied as `initial-window-size.patch`. The fix records the logical size
from GLFW after AppKit has sized the window and before raylib calculates
its initial render dimensions.

Only `rcore.o` is rebuilt in each architecture slice. The other objects
come from the upstream [raylib 6.0 macOS archive](https://github.com/raysan5/raylib/releases/tag/6.0).
The unpatched `libraylib.a` has SHA-256
`0f1b656b22083ec666ae5401b1610025f8f0830f64e0ae6bd406e19fb48e838d`.

Extract a fresh [raylib 6.0 source archive](https://codeload.github.com/raysan5/raylib/tar.gz/refs/tags/6.0)
(SHA-256 `2b3ee1e2120c7a0796b33062c7e9a694dd8a8caa56a96319ac8c8ecf54a90d0b`).
Set `raylib_source` and `base_archive` to the absolute paths of the extracted
source tree and the unpatched static archive. Run these commands from
this directory with Xcode selected. The committed objects were compiled
with Xcode 26.3, Apple clang 17.0.0 (clang-1700.6.4.2), and macOS SDK 26.2.
The target versions match upstream's macOS 6.0 build.

```sh
git -C "$raylib_source" apply "$PWD/initial-window-size.patch"
slice_dir=$(mktemp -d)
for target in x86_64-apple-macos10.12 arm64-apple-macos11; do
    arch=${target%%-*}
    mkdir "$slice_dir/$arch"
    xcrun lipo "$base_archive" -thin "$arch" -output "$slice_dir/$arch/libraylib.a"
    make -C "$raylib_source/src" -B rcore.o PLATFORM=PLATFORM_DESKTOP RAYLIB_LIBTYPE=STATIC \
        CUSTOM_CFLAGS="-target $target -DGL_SILENCE_DEPRECATION"
    cp "$raylib_source/src/rcore.o" "$slice_dir/$arch/"
    (cd "$slice_dir/$arch" && ZERO_AR_DATE=1 xcrun ar -r libraylib.a rcore.o)
done
xcrun lipo -create "$slice_dir/x86_64/libraylib.a" "$slice_dir/arm64/libraylib.a" \
    -output libraylib.a
```

Follow the [linker-input publication workflow](../../../dependencies/link-inputs/README.md)
to adopt the rebuilt archive in ordinary builds and releases.
