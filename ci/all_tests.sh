#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -euxo pipefail

if [ -z "${ROC}" ]; then
  echo "ERROR: The ROC environment variable is not set.
    Set it to something like:
        /home/username/Downloads/roc_nightly-linux_x86_64-2023-10-30-cb00cfb/roc
        or
        /home/username/gitrepos/roc/target/build/release/roc" >&2

  exit 1
fi

EXAMPLES_DIR='./examples'
PLATFORM_DIR='./platform'

# roc check
for ROC_FILE in $EXAMPLES_DIR/*.roc; do
    $ROC check $ROC_FILE
done

# roc build
for ROC_FILE in $EXAMPLES_DIR/*.roc; do
    $ROC build $ROC_FILE --linker=legacy
done

# test building docs website
$ROC docs $PLATFORM_DIR/main.roc