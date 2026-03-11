#!/usr/bin/env bash
# Build a minimal macOS sysroot from xcode-frameworks
# Places TBD files at paths matching their install-names (no symlinks needed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SYSROOT_DIR="$ROOT_DIR/platform/targets/macos-sysroot"

# Find xcode-frameworks in Zig cache (pulled by raylib-zig dependency)
XCODE_FW=$(find ~/.cache/zig/p -maxdepth 1 -name "N-V-*" -exec sh -c '
    if [ -d "$1/Frameworks" ] && [ -f "$1/lib/libobjc.tbd" ]; then
        echo "$1"
        exit 0
    fi
' _ {} \; 2>/dev/null | head -1)

if [ -z "$XCODE_FW" ]; then
    echo "Error: Could not find xcode-frameworks in Zig cache"
    echo "Run 'zig build' first to fetch dependencies"
    exit 1
fi

echo "Found xcode-frameworks at: $XCODE_FW"

# Clean and create sysroot
rm -rf "$SYSROOT_DIR"
mkdir -p "$SYSROOT_DIR/usr/lib"
mkdir -p "$SYSROOT_DIR/System/Library/Frameworks"

# Copy libSystem.tbd from Zig's bundled darwin stubs
# Try multiple possible locations
ZIG_DARWIN=""
for path in \
    "$(dirname "$(which zig)")/../lib/libc/darwin" \
    "/Users/luke/zig-aarch64-macos-0.15.2/lib/libc/darwin" \
    "$HOME/zig/lib/libc/darwin"; do
    if [ -f "$path/libSystem.tbd" ]; then
        ZIG_DARWIN="$path"
        break
    fi
done

if [ -n "$ZIG_DARWIN" ] && [ -f "$ZIG_DARWIN/libSystem.tbd" ]; then
    cp "$ZIG_DARWIN/libSystem.tbd" "$SYSROOT_DIR/usr/lib/"
    echo "Copied libSystem.tbd from Zig"
else
    echo "Warning: Could not find Zig's libSystem.tbd"
fi

# Copy libobjc
cp "$XCODE_FW/lib/libobjc.tbd" "$SYSROOT_DIR/usr/lib/"
cp "$XCODE_FW/lib/libobjc.A.tbd" "$SYSROOT_DIR/usr/lib/"
echo "Copied libobjc.tbd"

# Process each framework
process_tbd() {
    local tbd_file="$1"
    local install_name

    # Extract install-name from TBD file
    install_name=$(grep "^install-name:" "$tbd_file" | head -1 | sed "s/install-name:[[:space:]]*'\\(.*\\)'/\\1/")

    if [ -z "$install_name" ]; then
        return
    fi

    # Convert install-name to sysroot path
    # e.g., /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
    # becomes $SYSROOT_DIR/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit.tbd
    local dest_path="$SYSROOT_DIR${install_name}.tbd"
    local dest_dir=$(dirname "$dest_path")

    mkdir -p "$dest_dir"
    cp "$tbd_file" "$dest_path"
}

# Also copy TBD to framework root for -framework flag resolution
copy_to_root() {
    local tbd_file="$1"
    local fw_name=$(basename "$(dirname "$tbd_file")" .framework)
    local dest_dir="$SYSROOT_DIR/System/Library/Frameworks/${fw_name}.framework"

    mkdir -p "$dest_dir"
    cp "$tbd_file" "$dest_dir/"
}

echo "Processing frameworks..."
framework_count=0

for fw_dir in "$XCODE_FW/Frameworks"/*.framework; do
    fw_name=$(basename "$fw_dir" .framework)

    # Copy root-level TBD if it exists
    if [ -f "$fw_dir/$fw_name.tbd" ]; then
        copy_to_root "$fw_dir/$fw_name.tbd"
        process_tbd "$fw_dir/$fw_name.tbd"
        ((framework_count++))
    fi

    # Process TBDs in Versions/Current if they exist
    if [ -d "$fw_dir/Versions/Current" ]; then
        for tbd in "$fw_dir/Versions/Current"/*.tbd; do
            [ -f "$tbd" ] && process_tbd "$tbd"
        done
    fi

    # Process nested frameworks (e.g., ApplicationServices/Frameworks/*)
    if [ -d "$fw_dir/Frameworks" ]; then
        for nested_fw in "$fw_dir/Frameworks"/*.framework; do
            if [ -d "$nested_fw" ]; then
                nested_name=$(basename "$nested_fw" .framework)
                if [ -f "$nested_fw/$nested_name.tbd" ]; then
                    process_tbd "$nested_fw/$nested_name.tbd"
                fi
                if [ -d "$nested_fw/Versions/Current" ]; then
                    for tbd in "$nested_fw/Versions/Current"/*.tbd; do
                        [ -f "$tbd" ] && process_tbd "$tbd"
                    done
                fi
            fi
        done
    fi
done

echo "Processed $framework_count frameworks"

# Show final size
echo ""
echo "Sysroot created at: $SYSROOT_DIR"
du -sh "$SYSROOT_DIR"
echo ""
echo "TBD files:"
find "$SYSROOT_DIR" -name "*.tbd" | wc -l
