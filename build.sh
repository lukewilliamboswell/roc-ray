
lib="libroc-ray.a"

# Build for macos-arm64
rm -rf zig-out/

# TODO figure out why this fails with fatal error: 'Carbon/Carbon.h' file not found
# zig build -Dtarget=aarch64-macos 

zig build
cp zig-out/lib/$lib platform/macos-arm64.a

roc build --prebuilt-platform examples/basic.roc