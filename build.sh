
# CLEANUP previous builds
rm -f platform/macos-arm64.o

# PRE-BUILD PLATFORM 

# macos-arm64
rm -rf zig-out/

# TODO figure out why this fails with fatal error: 'Carbon/Carbon.h' file not found
# zig build -Dtarget=aarch64-macos 

zig build -Doptimize=ReleaseSmall
libtool -static -o platform/macos-arm64.o zig-out/lib/*

# BUILD
# roc build --prebuilt-platform examples/basic.roc

# RUN 
roc dev --prebuilt-platform examples/basic.roc