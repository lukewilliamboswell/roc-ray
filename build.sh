
# CLEANUP previous builds
rm -f platform/macos-arm64.o
rm -f platform/linux-x64.a

# PRE-BUILD PLATFORM 

# UNCOMMENT FOR MACOS-ARM64
rm -rf zig-out/
zig build
libtool -static -o platform/macos-arm64.o zig-out/lib/*

# UNCOMMENT FOR LINUX-x64
# TODO test this
# rm -rf zig-out/
# zig build
# libtool -static -o platform/linux-x64.a zig-out/lib/*

# JUST BUILD
# roc build --prebuilt-platform examples/basic.roc

# BUILD AND RUN 
roc dev --prebuilt-platform examples/basic.roc