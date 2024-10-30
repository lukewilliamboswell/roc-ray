#!/bin/bash

# e.g. 'aarch64-apple-darwin'
triple=$(rustc -vV | sed -n 's|host: ||p' | sed 's|-|_|g')

# Generate bindings
# install binidgen with `cargo install bindgen-cli`
bindgen raylib.h \
  --blocklist-item "DEG2RAD" \
  --blocklist-item "PI" \
  --blocklist-item "RAD2DEG" \
  --blocklist-item "__GNUC_VA_LIST" \
  --blocklist-item "__bool_true_false_are_defined" \
  --blocklist-item "false_" \
  --blocklist-item "true_" \
  --blocklist-type "ENUM_PATTERN.*" \
  --merge-extern-blocks \
  --no-layout-tests \
  --output "../lib.rs"
