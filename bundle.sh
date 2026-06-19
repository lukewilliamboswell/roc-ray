#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")" && pwd)"
platform_dir="$root_dir/platform"
package="default"
roc_bundle_args=()

usage() {
    cat <<'EOF'
Usage: ./bundle.sh [--platform default|wayland] [roc bundle args...]

The default package includes all supported native targets. The Wayland package
is Linux x64 only and requires vendor/raylib/linux-x64-wayland/libraylib.a.
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
    local roc
    for roc in "$platform_dir"/*.roc; do
        case "$(basename "$roc")" in
            main.roc|main-default.roc|main-wayland.roc)
                ;;
            *)
                cp "$roc" "$stage_dir/"
                ;;
        esac
    done
}

copy_target_files() {
    local target="$1"
    shift

    local file
    for file in "$@"; do
        copy_required \
            "$platform_dir/targets/$target/$file" \
            "$stage_dir/targets/$target/$file"
    done
}

stage_dir="$(mktemp -d "$root_dir/.bundle-stage-${package}.XXXXXX")"
trap cleanup_stage EXIT
mkdir -p "$stage_dir/targets"
copy_shared_roc_files

case "$package" in
    default)
        cp "$platform_dir/main-default.roc" "$stage_dir/main.roc"

        copy_target_files x64mac libhost.a libraylib.a
        copy_target_files arm64mac libhost.a libraylib.a
        copy_target_files x64glibc Scrt1.o crti.o libhost.a libraylib.a libm.so libX11.so libc.so crtn.o
        copy_target_files x64win host.lib raylib.lib gdi32.lib user32.lib winmm.lib opengl32.lib shell32.lib

        if [[ -d "$platform_dir/targets/macos-sysroot" ]]; then
            cp -R "$platform_dir/targets/macos-sysroot" "$stage_dir/targets/"
        fi
        ;;
    wayland)
        cp "$platform_dir/main-wayland.roc" "$stage_dir/main.roc"

        copy_target_files x64glibc Scrt1.o crti.o libhost.a libm.so libc.so crtn.o

        wayland_raylib="$root_dir/vendor/raylib/linux-x64-wayland/libraylib.a"
        if [[ ! -f "$wayland_raylib" ]]; then
            cat >&2 <<'EOF'
error: missing Wayland raylib archive: vendor/raylib/linux-x64-wayland/libraylib.a

Build it on Linux from a raylib 6.0 source checkout:
  scripts/build-raylib-wayland.sh /path/to/raylib-6.0
EOF
            exit 1
        fi
        copy_required "$wayland_raylib" "$stage_dir/targets/x64glibc/libraylib.a"
        ;;
esac

cd "$stage_dir"

roc_files=(*.roc)
lib_files=()
for lib in targets/*/*.a targets/*/*.o targets/*/*.lib targets/*/*.so; do
    if [[ -f "$lib" ]]; then
        lib_files+=("$lib")
    fi
done

sysroot_files=()
if [[ -d "targets/macos-sysroot" ]]; then
    while IFS= read -r -d '' tbd; do
        sysroot_files+=("$tbd")
    done < <(find targets/macos-sysroot -name "*.tbd" -print0)
fi

echo "Bundling:"
echo "  - platform package: $package"
echo "  - ${#roc_files[@]} .roc files"
echo "  - ${#lib_files[@]} library files"
echo "  - ${#sysroot_files[@]} sysroot TBD files"
if [[ -n "${ROC_RAY_KEEP_BUNDLE_STAGE:-}" ]]; then
    echo "  - staged at: $stage_dir"
fi

bundle_args=("${roc_files[@]}")
if [[ "${#lib_files[@]}" -gt 0 ]]; then
    bundle_args+=("${lib_files[@]}")
fi
if [[ "${#sysroot_files[@]}" -gt 0 ]]; then
    bundle_args+=("${sysroot_files[@]}")
fi
bundle_args+=(--output-dir "$root_dir")
if [[ "${#roc_bundle_args[@]}" -gt 0 ]]; then
    bundle_args+=("${roc_bundle_args[@]}")
fi

roc bundle "${bundle_args[@]}"
