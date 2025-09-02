#!/bin/bash

# # e.g. 'aarch64-apple-darwin'
# triple=$(rustc -vV | sed -n 's|host: ||p' | sed 's|-|_|g')

OUTPUT_DIR="../src"
OUTPUT_FILE="$OUTPUT_DIR/lib.rs"

[[ -d "$OUTPUT_DIR" ]] || mkdir "$OUTPUT_DIR"

# The output of bindgen will be appended to the following header for warning suppression.
FLAGS_HEADER="#![allow(dead_code)]
#![allow(nonstandard_style)]
#![allow(unused_variables)]
"

echo "$FLAGS_HEADER" > "$OUTPUT_FILE"

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
  >> "$OUTPUT_FILE"
  #--output "$OUTPUT_DIR/lib.rs"


