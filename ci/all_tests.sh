#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -euxo pipefail

if [ -z "${ROC:-}" ]; then
  echo "INFO: The ROC environment variable is not set."
  export ROC=$(which roc)
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

# test building docs website
$ROC docs $PLATFORM_DIR/main.roc
