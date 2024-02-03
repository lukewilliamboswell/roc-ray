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

# List of files to ignore
IGNORED_FILES=("Counter.roc")

# roc check
for ROC_FILE in $EXAMPLES_DIR/*.roc; do
    if [[ " ${IGNORED_FILES[*]} " != *" ${ROC_FILE##*/} "* ]]; then
        $ROC check $ROC_FILE
    fi
done

# Remove zig-out if it exists
if [ -d zig-out/ ]; then
  rm -rf zig-out/
fi

# Build with zig
$ZIG build

# Check the output of the `uname` command to detect the operating system
if [[ "$(uname)" == "Darwin" ]]; then
  LIBTOOL=`which libtool`
  $LIBTOOL -static -o platform/macos-arm64.o zig-out/lib/*
elif [[ "$(uname)" == "Linux" ]]; then
  # bust open each of the archives and repackage into new archive
  cd zig-out/lib/
  ar x libraylib.a
  ar x libraylib-zig.a 
  ar x libroc-ray.a
  cd ../../
  ar rcs platform/linux-x64.a zig-out/lib/*.o
else
  echo "Unsupported operating system"
fi

# roc build
for ROC_FILE in $EXAMPLES_DIR/*.roc; do
    if [[ " ${IGNORED_FILES[*]} " != *" ${ROC_FILE##*/} "* ]]; then
        $ROC build --prebuilt-platform --linker=legacy $ROC_FILE
    fi
done

# test building docs website
$ROC docs $PLATFORM_DIR/main.roc