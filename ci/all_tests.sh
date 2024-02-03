#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -euxo pipefail

if [ -z "${ROC}" ]; then
  echo "ERROR: The ROC environment variable is not set."
  exit 1
fi

if [ -z "${ZIG}" ]; then
  echo "ERROR: The ZIG environment variable is not set."
  exit 1
fi

EXAMPLES_DIR='./examples'
PLATFORM_DIR='./platform'

# Remove zig-out if it exists
if [ -d zig-out/ ]; then
  rm -rf zig-out/
fi

# Build with zig
$ZIG build

# Check the output of the `uname` command to detect the operating system
if [[ "$(uname)" == "Darwin" ]]; then
  $(which libtool) -static -o platform/macos-arm64.o zig-out/lib/*
elif [[ "$(uname)" == "Linux" ]]; then
  $(which libtool) -static -o platform/linux-x64.a zig-out/lib/*
else
    echo "Unsupported operating system"
fi

# List of files to ignore
IGNORED_FILES=("Counter.roc" "draw.roc")

# roc build
for ROC_FILE in $EXAMPLES_DIR/*.roc; do
    if [[ " ${IGNORED_FILES[*]} " != *" ${ROC_FILE##*/} "* ]]; then
        $ROC build --prebuilt-platform --linker=legacy "$ROC_FILE"
    fi
done

# test building docs website
$ROC docs $PLATFORM_DIR/main.roc