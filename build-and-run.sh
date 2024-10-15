#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -euxo pipefail

# Get the app path from the first argument, default to "examples/basic-shapes.roc"
APP=${1:-"examples/basic-shapes.roc"}

roc build --no-link --output app.o $APP

cargo run
