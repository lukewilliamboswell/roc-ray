#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
platform_dir="$root_dir/platform"
output_dir="$root_dir"
package="default"
macos_interfaces_dir="${ROC_RAY_MACOS_INTERFACES_DIR:-$platform_dir/targets/macos-sysroot}"
roc_bundle_args=()
roc_bin="${ROC:-roc}"

if [[ "$roc_bin" == */* ]]; then
    roc_bin="$(cd "$(dirname "$roc_bin")" && pwd)/$(basename "$roc_bin")"
fi

usage() {
    cat <<'EOF'
Usage: scripts/bundle.sh [--platform default|wayland] [--output-dir DIR]
                         [--macos-interfaces-dir DIR]
                         [roc bundle args...]

The default package includes all supported native targets. The Wayland package
is Linux x64 only.

Host archives come from `zig build`; every other linker input is installed from
the release locked by link-inputs.lock.json and verified before use.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform|--package)
            if [[ $# -lt 2 ]]; then
                echo "error: $1 requires a package name" >&2
                exit 1
            fi
            package="$2"
            shift 2
            ;;
        --platform=*|--package=*)
            package="${1#*=}"
            shift
            ;;
        --host)
            if [[ $# -lt 2 ]]; then
                echo "error: --host requires a package name" >&2
                exit 1
            fi
            package="$2"
            shift 2
            ;;
        --host=*)
            package="${1#--host=}"
            shift
            ;;
        --output-dir)
            if [[ $# -lt 2 ]]; then
                echo "error: --output-dir requires a directory" >&2
                exit 1
            fi
            output_dir="$2"
            shift 2
            ;;
        --output-dir=*)
            output_dir="${1#--output-dir=}"
            shift
            ;;
        --macos-interfaces-dir)
            if [[ $# -lt 2 ]]; then
                echo "error: --macos-interfaces-dir requires a directory" >&2
                exit 1
            fi
            macos_interfaces_dir="$2"
            shift 2
            ;;
        --macos-interfaces-dir=*)
            macos_interfaces_dir="${1#--macos-interfaces-dir=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                roc_bundle_args+=("$1")
                shift
            done
            ;;
        *)
            roc_bundle_args+=("$1")
            shift
            ;;
    esac
done

if [[ "$package" == "x11" ]]; then
    package="default"
fi

case "$package" in
    default|wayland)
        ;;
    *)
        echo "error: unknown platform package '$package' (expected default or wayland)" >&2
        exit 1
        ;;
esac

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

stage_dir=""
cleanup_stage() {
    if [[ -n "${stage_dir:-}" && -z "${ROC_RAY_KEEP_BUNDLE_STAGE:-}" ]]; then
        rm -rf "$stage_dir"
    fi
}

copy_required() {
    local src="$1"
    local dest="$2"

    if [[ ! -f "$src" ]]; then
        echo "error: missing required bundle input: $src" >&2
        echo "hint: run zig build before bundling" >&2
        exit 1
    fi

    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
}

copy_shared_roc_files() {
    local roc relative
    while IFS= read -r -d '' roc; do
        relative="${roc#"$platform_dir/"}"
        case "$relative" in
            main.roc|main-wayland.roc|targets/*) continue ;;
        esac
        mkdir -p "$stage_dir/$(dirname "$relative")"
        cp "$roc" "$stage_dir/$relative"
    done < <(find "$platform_dir" -name '*.roc' -print0)
}

copy_host() {
    local target="$1" file="$2"
    copy_required "$platform_dir/targets/$target/$file" "$stage_dir/targets/$target/$file"
}

# Installs the locked profiles (targets/ and their licences/) into the stage,
# after checking every archive against the lock. It never builds an input.
install_link_inputs() {
    local args=()
    local profile
    for profile in "$@"; do
        args+=(--profile "$profile")
    done
    # Producer validation only: an unpublished candidate, checked the same way.
    if [[ -n "${ROC_RAY_LINK_INPUT_CANDIDATE:-}" ]]; then
        args+=(--candidate "$ROC_RAY_LINK_INPUT_CANDIDATE")
    fi
    python3 "$root_dir/scripts/link_inputs.py" install "${args[@]}" --destination "$stage_dir"
}

stage_dir="$(mktemp -d "$root_dir/.bundle-stage-${package}.XXXXXX")"
trap cleanup_stage EXIT
mkdir -p "$stage_dir/targets"
copy_shared_roc_files

case "$package" in
    default)
        cp "$platform_dir/main.roc" "$stage_dir/main.roc"

        install_link_inputs x64mac arm64mac x64glibc-x11 x64win
        copy_host x64mac libhost.a
        copy_host arm64mac libhost.a
        copy_host x64glibc libhost.a
        copy_host x64win host.lib

        if [[ ! -d "$macos_interfaces_dir" ]]; then
            echo "error: missing macOS interface tree: $macos_interfaces_dir" >&2
            exit 1
        fi
        cp -R "$macos_interfaces_dir" "$stage_dir/targets/macos-sysroot"
        ;;
    wayland)
        cp "$platform_dir/main-wayland.roc" "$stage_dir/main.roc"

        install_link_inputs x64glibc-wayland
        copy_host x64glibc libhost.a
        ;;
esac

cd "$stage_dir"

roc_files=(main.roc)
while IFS= read -r -d '' roc_file; do
    [[ "$roc_file" == "./main.roc" ]] || roc_files+=("${roc_file#./}")
done < <(find . -name '*.roc' -print0)
# libvpx's BSD-3 licence requires its notice, conditions, and disclaimer to
# accompany binary redistribution, and the bundle ships compiled VP8 encoder
# objects. The patent grant travels with it.
notice_files=()
for notice in licenses/*; do
    if [[ -f "$notice" ]]; then
        notice_files+=("$notice")
    fi
done

lib_files=()
for lib in targets/*/*.a targets/*/*.o targets/*/*.lib targets/*/*.so; do
    if [[ -f "$lib" ]]; then
        lib_files+=("$lib")
    fi
done

sysroot_files=()
sysroot_metadata_files=()
if [[ -d "targets/macos-sysroot" ]]; then
    while IFS= read -r -d '' tbd; do
        sysroot_files+=("$tbd")
    done < <(find targets/macos-sysroot -name "*.tbd" -print0)
    for metadata in targets/macos-sysroot/interfaces.json targets/macos-sysroot/manifest.json targets/macos-sysroot/PROVENANCE.md; do
        if [[ -f "$metadata" ]]; then
            sysroot_metadata_files+=("$metadata")
        fi
    done
fi

echo "Bundling:"
echo "  - platform package: $package"
echo "  - ${#roc_files[@]} .roc files"
echo "  - ${#lib_files[@]} library files"
echo "  - ${#sysroot_files[@]} sysroot TBD files"
echo "  - ${#sysroot_metadata_files[@]} sysroot provenance files"
if [[ -n "${ROC_RAY_KEEP_BUNDLE_STAGE:-}" ]]; then
    echo "  - staged at: $stage_dir"
fi

bundle_args=("${roc_files[@]}")
if ((${#notice_files[@]})); then
    bundle_args+=("${notice_files[@]}")
fi
if [[ "${#lib_files[@]}" -gt 0 ]]; then
    bundle_args+=("${lib_files[@]}")
fi
if [[ "${#sysroot_files[@]}" -gt 0 ]]; then
    bundle_args+=("${sysroot_files[@]}")
fi
if [[ "${#sysroot_metadata_files[@]}" -gt 0 ]]; then
    bundle_args+=("${sysroot_metadata_files[@]}")
fi
bundle_args+=(--output-dir "$output_dir")
if [[ "${#roc_bundle_args[@]}" -gt 0 ]]; then
    bundle_args+=("${roc_bundle_args[@]}")
fi

"$roc_bin" bundle "${bundle_args[@]}"
