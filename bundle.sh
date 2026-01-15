#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$root_dir/platform"

# Collect all .roc files
roc_files=(*.roc)

# Collect all host libraries from targets directories
lib_files=()
for lib in targets/*/*.a targets/*/*.o targets/*/*.lib targets/*/*.so; do
    if [[ -f "$lib" ]]; then
        lib_files+=("$lib")
    fi
done

# Collect all TBD files from macos-sysroot (for cross-compilation)
sysroot_files=()
if [[ -d "targets/macos-sysroot" ]]; then
    while IFS= read -r -d '' tbd; do
        sysroot_files+=("$tbd")
    done < <(find targets/macos-sysroot -name "*.tbd" -print0)
fi

echo "Bundling:"
echo "  - ${#roc_files[@]} .roc files"
echo "  - ${#lib_files[@]} library files"
echo "  - ${#sysroot_files[@]} sysroot TBD files"

roc bundle "${roc_files[@]}" "${lib_files[@]}" "${sysroot_files[@]}" --output-dir "$root_dir" "$@"
