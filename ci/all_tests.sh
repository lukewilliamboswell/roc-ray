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
LIBTOOL=`which libtool`

# List of files to ignore
IGNORED_FILES=("Counter.roc" "draw.roc")

# roc check
for ROC_FILE in $EXAMPLES_DIR/*.roc; do
    if [[ " ${IGNORED_FILES[*]} " != *" ${ROC_FILE##*/} "* ]]; then
        $ROC check $ROC_FILE
    fi
done

# TODO activate when I figure out how to build on linux-x64
# # Remove zig-out if it exists
# if [ -d zig-out/ ]; then
#   rm -rf zig-out/
# fi

# # Build with zig
# $ZIG build

# # Check the output of the `uname` command to detect the operating system
# if [[ "$(uname)" == "Darwin" ]]; then
#   $LIBTOOL -static -o platform/macos-arm64.o zig-out/lib/*
# elif [[ "$(uname)" == "Linux" ]]; then
#   $LIBTOOL -o platform/linux-x64.a zig-out/lib/*
# else
#   echo "Unsupported operating system"
# fi

# # roc build
# for ROC_FILE in $EXAMPLES_DIR/*.roc; do
#     if [[ " ${IGNORED_FILES[*]} " != *" ${ROC_FILE##*/} "* ]]; then
#         $ROC build --prebuilt-platform --linker=legacy $ROC_FILE
#     fi
# done

# test building docs website
$ROC docs $PLATFORM_DIR/main.roc