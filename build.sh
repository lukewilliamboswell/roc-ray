set -ex
# CLEANUP PREVIOUS
rm -f platform/macos-arm64.o
rm -f platform/linux-x64.a

# PRE-BUILD PLATFORM FOR MACOS-ARM64
rm -rf zig-out/
# zig build -Doptimize=ReleaseSmall
zig build
libtool -static -o platform/macos-arm64.o zig-out/lib/*

# TODO test this proplery and find out why it fails
# PRE-BUILD PLATFORM FOR LINUX-x64 
# rm -rf zig-out/
# zig build
# ar rcs platform/linux-x64.a zig-out/lib/*

# RUN DEMOS
# roc dev --prebuilt-platform examples/squares.roc
roc dev --prebuilt-platform examples/gui-counter.roc
# roc dev --prebuilt-platform examples/basic_shapes.roc
# roc dev --prebuilt-platform examples/pong.roc