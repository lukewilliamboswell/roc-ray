#!/bin/bash
# Build a Roc app for WASM and serve it locally
#
# Usage: ./wasm examples/hello_world.roc
#        ./wasm examples/hello_world.roc --no-serve
#
# This script:
# 1. Builds the host library (zig build)
# 2. Builds the Roc app for wasm32 target
# 3. Copies app.wasm, host.js, and index.html to www/
# 4. Starts a local web server on port 8080

set -e

# Check for Roc file argument
if [ -z "$1" ]; then
    echo "Usage: ./wasm <roc-file> [--no-serve]"
    echo "Example: ./wasm examples/hello_world.roc"
    exit 1
fi

ROC_FILE="$1"
NO_SERVE=false

# Check for --no-serve flag
if [ "$2" = "--no-serve" ]; then
    NO_SERVE=true
fi

# Validate the Roc file exists
if [ ! -f "$ROC_FILE" ]; then
    echo "Error: Roc file not found: $ROC_FILE"
    exit 1
fi

# Get the base name without extension for output
BASENAME=$(basename "$ROC_FILE" .roc)

echo "=== Building host library ==="
zig build

echo "=== Building Roc app for WASM ==="
roc build --target=wasm32 "$ROC_FILE"

echo "=== Setting up www/ directory ==="
mkdir -p www

# Copy the wasm file (Roc outputs to same directory as source)
SOURCE_DIR=$(dirname "$ROC_FILE")
WASM_FILE="$SOURCE_DIR/$BASENAME.wasm"

if [ ! -f "$WASM_FILE" ]; then
    # Try current directory if not in source dir
    WASM_FILE="$BASENAME.wasm"
fi

if [ ! -f "$WASM_FILE" ]; then
    echo "Error: WASM file not found. Expected: $SOURCE_DIR/$BASENAME.wasm or $BASENAME.wasm"
    exit 1
fi

cp "$WASM_FILE" www/app.wasm
cp platform/web/host.js www/
cp platform/web/index.html www/

echo "=== Files ready in www/ ==="
ls -la www/

if [ "$NO_SERVE" = true ]; then
    echo ""
    echo "Build complete. To serve manually:"
    echo "  cd www && python3 -m http.server 8080"
    exit 0
fi

echo ""
echo "=== Starting web server ==="
echo "Open http://localhost:8080 in your browser"
echo "Press Ctrl+C to stop"
echo ""

cd www
python3 -m http.server 8080
