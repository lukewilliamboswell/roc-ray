#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -euxo pipefail

if [ -z "${ROC:-}" ]; then
  echo "INFO: The ROC environment variable is not set."
  export ROC=$(which roc)
fi

if [ -z "${CARGO:-}" ]; then
  echo "INFO: The CARGO environment variable is not set."
  export CARGO=$(which cargo)
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

# TODO restore this when we have emscripten and zig setup for CI
# build the example web
# note we do web first, so the app.o that is left around is the native one for `cargo test`
# for ROC_FILE in $EXAMPLES_DIR/*.roc; do
#     if [[ " ${IGNORED_FILES[*]} " != *" ${ROC_FILE##*/} "* ]]; then
#         $ROC build --target wasm32 --no-link --output app.o $ROC_FILE
#         $CARGO build --target wasm32-unknown-emscripten
#     fi
# done

# build the example native
for ROC_FILE in $EXAMPLES_DIR/*.roc; do
    if [[ " ${IGNORED_FILES[*]} " != *" ${ROC_FILE##*/} "* ]]; then
        $ROC build --no-link --output app.o $ROC_FILE
        $CARGO build
    fi
done

# run the cargo tests
# note we need an `app.o` file to build the test runner, so do this after buildings the examples
rm -f libapp.so
rm -f libapp.dylib
$ROC build --no-link --output app.o examples/basic-shapes.roc
$CARGO test

# test building docs website
$ROC docs $PLATFORM_DIR/main.roc
