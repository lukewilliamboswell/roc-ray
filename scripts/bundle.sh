#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
platform_dir="$root_dir/platform"
output_dir="$root_dir"
package="default"
types_url_base=""
types_output_dir=""
roc_bundle_args=()
roc_bin="${ROC:-roc}"

if [[ "$roc_bin" == */* ]]; then
    roc_bin="$(cd "$(dirname "$roc_bin")" && pwd)/$(basename "$roc_bin")"
fi

usage() {
    cat <<'EOF'
Usage: scripts/bundle.sh [--platform default|wayland] [--output-dir DIR]
                         [--types-url-base URL] [roc bundle args...]

The default package includes all supported native targets. The Wayland package
is Linux x64 only and requires vendor/raylib/linux-x64-wayland/libraylib.a.

The platform depends on the roc-ray-types package by relative path so local
development works. A relative path cannot survive bundling, so --types-url-base
is required: this script bundles the package, appends its content-addressed
filename to that base, and rewrites the staged platform header to point at the
resulting URL. Pass the release download URL when publishing, or a locally
served directory when testing.
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
        --types-url-base)
            if [[ $# -lt 2 ]]; then
                echo "error: --types-url-base requires a URL" >&2
                exit 1
            fi
            types_url_base="${2%/}"
            shift 2
            ;;
        --types-output-dir)
            if [[ $# -lt 2 ]]; then
                echo "error: --types-output-dir requires a directory" >&2
                exit 1
            fi
            types_output_dir="$2"
            shift 2
            ;;
        --types-output-dir=*)
            types_output_dir="${1#--types-output-dir=}"
            shift
            ;;
        --types-url-base=*)
            types_url_base="${1#--types-url-base=}"
            types_url_base="${types_url_base%/}"
            shift
            ;;
        --output-dir=*)
            output_dir="${1#--output-dir=}"
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

# The types bundle can be written elsewhere so a release glob that collects
# platform bundles does not also pick it up -- it is a release asset, but it is
# not a platform bundle and has nothing to test.
if [[ -z "$types_output_dir" ]]; then
    types_output_dir="$output_dir"
else
    mkdir -p "$types_output_dir"
    types_output_dir="$(cd "$types_output_dir" && pwd)"
fi

# The platform header points at the roc-ray-types package by relative path so
# local development works without a published artifact. `roc bundle` silently
# drops such a dependency -- the archive builds and then fails at the consumer
# with INVALID PACKAGE DEPENDENCY -- so the header is rewritten to a real URL
# here.
#
# With --types-url-base the package is bundled and served from that base, which
# is what the local and CI bundle tests do. Without it the pinned published URL
# in .types-version is used, which is what a platform release does.
pinned_types_url=""
if [[ -f "$root_dir/.types-version" ]]; then
    # An all-comments file yields no lines; grep exits 1 and would trip set -e.
    pinned_types_url="$(grep -v '^[[:space:]]*#' "$root_dir/.types-version" 2>/dev/null | tr -d '[:space:]' | head -1 || true)"
fi

if [[ -z "$types_url_base" && -z "$pinned_types_url" ]]; then
    cat >&2 <<'EOF'
error: no roc-ray-types URL available.

The platform depends on the types package by relative path, which cannot
survive bundling. Either pin a published package in .types-version by running
the "Release roc-ray-types" workflow, or pass a base URL to serve it from:

    scripts/bundle.sh --types-url-base http://127.0.0.1:8000
EOF
    exit 1
fi

types_url=""
if [[ -n "$types_url_base" ]]; then
    # Bundle from inside the types directory. Bundling `types/main.roc` from
    # the repo root roots the archive at `package/`, one level deeper than roc
    # resolves on extraction.
    if ! types_output="$(cd "$root_dir/types" && "$roc_bin" bundle main.roc --output-dir "$types_output_dir" 2>&1)"; then
        echo "$types_output" >&2
        echo "error: failed to bundle the roc-ray-types package" >&2
        exit 1
    fi
    # `Created:` carries an absolute path; take its basename. Git Bash on Windows
    # reports backslash separators, so strip either.
    types_bundle="$(printf '%s\n' "$types_output" | sed -n 's|^Created: ||p' | tail -1 | sed 's|.*[/\\]||')"
    if [[ -z "$types_bundle" ]]; then
        echo "$types_output" >&2
        echo "error: could not determine the roc-ray-types bundle filename" >&2
        exit 1
    fi
    types_url="$types_url_base/$types_bundle"
    echo "Types package bundle: $types_bundle"
    echo "Types package path: $types_output_dir/$types_bundle"
    echo "Types package URL: $types_url"
else
    types_url="$pinned_types_url"
    # Bundles are content addressed, so re-bundling types/ and comparing the
    # filename says whether the pin still describes this source tree.
    verify_dir="$(mktemp -d)"
    if ! verify_output="$(cd "$root_dir/types" && "$roc_bin" bundle main.roc --output-dir "$verify_dir" 2>&1)"; then
        echo "$verify_output" >&2
        rm -rf "$verify_dir"
        echo "error: failed to bundle the roc-ray-types package for verification" >&2
        exit 1
    fi
    verify_bundle="$(printf '%s\n' "$verify_output" | sed -n 's|^Created: ||p' | tail -1 | sed 's|.*[/\\]||')"
    rm -rf "$verify_dir"
    if [[ "${types_url##*/}" != "$verify_bundle" ]]; then
        cat >&2 <<EOF
error: types/ has changed since the pinned roc-ray-types release.

  pinned:  ${types_url##*/}
  current: $verify_bundle

Release the types package first with the "Release roc-ray-types" workflow,
update .types-version, then release the platform.
EOF
        exit 1
    fi
    echo "Types package (pinned): $types_url"
fi

# Point the staged header at the bundled package instead of the relative path
# used during local development.
rewrite_types_dep() {
    local staged="$1"
    [[ -n "$types_url" ]] || return 0
    if ! grep -q 'rrt: "\.\./types/main\.roc",' "$staged"; then
        echo "error: expected a relative rrt: dependency in $staged to rewrite" >&2
        exit 1
    fi
    python3 - "$staged" "$types_url" <<'PYEOF'
import pathlib, sys
staged, url = pathlib.Path(sys.argv[1]), sys.argv[2]
text = staged.read_text(encoding="utf-8")
staged.write_text(text.replace('rrt: "../types/main.roc",', f'rrt: "{url}",'), encoding="utf-8")
PYEOF
}

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
    local files=()
    if git -C "$root_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        while IFS= read -r roc; do
            files+=("$root_dir/$roc")
        done < <(git -C "$root_dir" ls-files "platform/*.roc")
    else
        files=("$platform_dir"/*.roc)
    fi

    for roc in "${files[@]}"; do
        # A tracked module can be intentionally deleted in the worktree before
        # the deletion is committed (for example while consolidating APIs).
        [[ -f "$roc" ]] || continue
        case "$(basename "$roc")" in
            main.roc|main-wayland.roc)
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

# Redistribute the vendored libraries' licence texts alongside their binaries.
copy_vendor_notices() {
    mkdir -p "$stage_dir/licenses"
    copy_required "$root_dir/vendor/libvpx/LICENSE" "$stage_dir/licenses/LICENSE.libvpx"
    copy_required "$root_dir/vendor/libvpx/PATENTS" "$stage_dir/licenses/PATENTS.libvpx"
    copy_required "$root_dir/vendor/libvpx/AUTHORS" "$stage_dir/licenses/AUTHORS.libvpx"
}

case "$package" in
    default)
        cp "$platform_dir/main.roc" "$stage_dir/main.roc"
        rewrite_types_dep "$stage_dir/main.roc"

        copy_target_files x64mac libhost.a libraylib.a libmsf_gif.a libvpx.a
        copy_target_files arm64mac libhost.a libraylib.a libmsf_gif.a libvpx.a
        copy_target_files x64glibc Scrt1.o crti.o libhost.a libraylib.a libmsf_gif.a libvpx.a libm.so libX11.so libc.so crtn.o
        copy_target_files x64win host.lib raylib.lib msf_gif.lib vpx.lib gdi32.lib user32.lib winmm.lib opengl32.lib shell32.lib

        if [[ -d "$platform_dir/targets/macos-sysroot" ]]; then
            cp -R "$platform_dir/targets/macos-sysroot" "$stage_dir/targets/"
        fi
        copy_vendor_notices
        ;;
    wayland)
        cp "$platform_dir/main-wayland.roc" "$stage_dir/main.roc"
        rewrite_types_dep "$stage_dir/main.roc"

        copy_target_files x64glibc Scrt1.o crti.o libhost.a libmsf_gif.a libvpx.a libm.so libc.so crtn.o

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
        copy_vendor_notices
        ;;
esac

cd "$stage_dir"

roc_files=(*.roc)
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
if ((${#notice_files[@]})); then
    bundle_args+=("${notice_files[@]}")
fi
if [[ "${#lib_files[@]}" -gt 0 ]]; then
    bundle_args+=("${lib_files[@]}")
fi
if [[ "${#sysroot_files[@]}" -gt 0 ]]; then
    bundle_args+=("${sysroot_files[@]}")
fi
bundle_args+=(--output-dir "$output_dir")
if [[ "${#roc_bundle_args[@]}" -gt 0 ]]; then
    bundle_args+=("${roc_bundle_args[@]}")
fi

"$roc_bin" bundle "${bundle_args[@]}"
