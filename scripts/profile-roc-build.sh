#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/profile-roc-build.sh <roc-file> [seconds]

Profiles `roc build <roc-file>` with Linux perf and prints the top call stacks.

Environment:
  ROC             Roc compiler to run (default: roc)
  PERF            perf executable to run (default: perf)
  PERF_OUT        perf data path (default: /tmp/roc-build-<name>.perf.data)
  PERF_EVENT      perf event (default: cycles:u)
  PERF_FREQ       samples per second (default: 99)
  PERCENT_LIMIT   perf report percentage cutoff (default: 5)

Example:
  scripts/profile-roc-build.sh examples/cave_climb.roc 20
USAGE
}

if [[ $# -lt 1 || $# -gt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 2
fi

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "This script uses Linux perf and only runs on Linux." >&2
    exit 1
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$1"
seconds="${2:-20}"
roc_bin="${ROC:-roc}"
perf_bin="${PERF:-perf}"
event="${PERF_EVENT:-cycles:u}"
freq="${PERF_FREQ:-99}"
percent_limit="${PERCENT_LIMIT:-5}"

target_name="$(basename "$target" .roc)"
out="${PERF_OUT:-/tmp/roc-build-${target_name}.perf.data}"

if ! command -v "$perf_bin" >/dev/null 2>&1; then
    echo "Could not find perf executable: $perf_bin" >&2
    exit 1
fi

if ! command -v "$roc_bin" >/dev/null 2>&1 && [[ ! -x "$roc_bin" ]]; then
    echo "Could not find Roc compiler: $roc_bin" >&2
    exit 1
fi

echo "Profiling: $roc_bin build $target"
echo "Timeout:   ${seconds}s"
echo "Event:     $event"
echo "Output:    $out"
echo

set +e
(
    cd "$root_dir"
    timeout "$seconds" "$perf_bin" record --quiet -F "$freq" -e "$event" -g -o "$out" -- "$roc_bin" build "$target"
)
status=$?
set -e

case "$status" in
    0)
        echo "roc build completed before the timeout."
        ;;
    124)
        echo "roc build timed out after ${seconds}s; reporting collected samples."
        ;;
    *)
        echo "roc build/perf exited with status $status; reporting collected samples if available."
        ;;
esac

if [[ ! -s "$out" ]]; then
    echo "No perf data was written to $out" >&2
    exit "$status"
fi

echo
echo "Top cumulative call stacks:"
"$perf_bin" report --stdio --children --percent-limit "$percent_limit" -i "$out" | sed -n '1,180p'

echo
echo "Top self-time symbols:"
"$perf_bin" report --stdio --no-children --percent-limit "$percent_limit" -i "$out" | sed -n '1,120p'

exit "$status"
