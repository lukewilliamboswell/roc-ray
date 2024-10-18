#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -euxo pipefail

# Get the app path from the first argument, default to "examples/basic-shapes.roc"
APP=${1:-"examples/basic-shapes.roc"}

# --no-link will instruct roc not to link with the host, we will use the rust toolchain to do this
# --optimize will instruct roc to use the LLVM backend and produce runtime optimised machine code
# --output will instruct roc to put the output in the current directory
# $APP is that path to the roc app we want to build
roc build --no-link --profiling --output app.o $APP

# Build the app executable
cargo run
