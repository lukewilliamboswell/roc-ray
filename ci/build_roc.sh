#!/usr/bin/env bash
set -euo pipefail

ROC_COMMIT=$(python3 ci/get_roc_commit.py)
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
