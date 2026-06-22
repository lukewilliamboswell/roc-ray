#!/usr/bin/env bash
set -euo pipefail

ROC_COMMIT=$(python3 ci/get_roc_commit.py)

if [ "${ROC_SKIP_BUILD:-}" = "1" ]; then
  if ! command -v roc >/dev/null 2>&1; then
    echo "ROC_SKIP_BUILD=1 was set, but no roc executable was found on PATH" >&2
    exit 1
  fi

  ROC_PATH=$(command -v roc)
  ROC_VERSION=$(roc --version)
  SHORT_COMMIT=${ROC_COMMIT:0:8}

  echo "Skipping Roc build because ROC_SKIP_BUILD=1"
  echo "Using Roc executable from PATH: $ROC_PATH"
  echo "Roc version: $ROC_VERSION"
  echo "Expected pinned Roc commit: $ROC_COMMIT"

  if [[ "$ROC_VERSION" != *"$SHORT_COMMIT"* ]]; then
    echo "warning: roc --version did not include pinned commit prefix $SHORT_COMMIT" >&2
  fi

  exit 0
fi

echo "Building Roc from commit: $ROC_COMMIT"

if [ ! -d roc-src/.git ]; then
  git init --initial-branch=main roc-src
  git -C roc-src remote add origin https://github.com/roc-lang/roc
fi

git -C roc-src fetch --depth 1 origin "$ROC_COMMIT"
git -C roc-src checkout --detach FETCH_HEAD

cd roc-src

attempts="${ROC_BUILD_ATTEMPTS:-3}"
for attempt in $(seq 1 "$attempts"); do
  echo "zig build roc (attempt $attempt/$attempts)"
  if zig build roc; then
    if [ -n "${GITHUB_PATH:-}" ]; then
      echo "$(pwd)/zig-out/bin" >> "$GITHUB_PATH"
    fi
    exit 0
  fi

  if [ "$attempt" -lt "$attempts" ]; then
    sleep_seconds=$((attempt * 10))
    echo "zig build roc failed; retrying in ${sleep_seconds}s"
    sleep "$sleep_seconds"
  fi
done

echo "zig build roc failed after $attempts attempts" >&2
exit 1
