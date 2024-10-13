#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -euxo pipefail

# Get the app path from the first argument, default to "examples/basic-shapes.roc"
APP=${1:-"examples/basic-shapes.roc"}

if [ -z "${ZIG:-}" ]; then
  echo "INFO: The ZIG environment variable was not set."
  export ZIG=$(which zig)
fi

# Build the roc app and then link that with the host to produce the executable
# $ZIG build --release=safe -Dapp="$APP" # --release=safe gives better debugging for the host
$ZIG build --release=fast -Dapp="$APP" # --release=fast gives best runtime performance

# Run the executable
./zig-out/bin/rocray
