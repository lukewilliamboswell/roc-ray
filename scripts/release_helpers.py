#!/usr/bin/env python3
"""Repo-specific helpers for the RocRay release workflow."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


BUNDLE_SUFFIX = ".tar.zst"
DEFAULT_TEST_OS = ["ubuntu-latest", "macos-15-intel", "macos-latest", "windows-latest"]
WAYLAND_TEST_OS = ["ubuntu-latest"]
PLATFORM_REF_RE = re.compile(
    r'"(?:\.\./\.\./platform/main\.roc|'
    r'https://github\.com/lukewilliamboswell/roc-ray/releases/download/[^\"]+\.tar\.zst)"'
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)

    manifest = subcommands.add_parser("write-bundle-manifest")
    manifest.add_argument("--default-bundle", required=True)
    manifest.add_argument("--wayland-bundle", required=True)
    manifest.add_argument("--output", required=True)
    manifest.set_defaults(func=cmd_write_bundle_manifest)

    previous = subcommands.add_parser("resolve-previous-default-url")
    previous.add_argument("--provided-url", default="")
    previous.add_argument("--repo", default="")
    previous.add_argument("--output-file", required=True)
    previous.add_argument("--github-output", default="")
    previous.set_defaults(func=cmd_resolve_previous_default_url)

    notes = subcommands.add_parser("make-release-notes")
    notes.add_argument("--release-version", default="")
    notes.add_argument("--release-bundles", required=True)
    notes.add_argument("--output-file", required=True)
    notes.add_argument("--docs-url", default="")
    notes.set_defaults(func=cmd_make_release_notes)

    examples = subcommands.add_parser("update-example-urls")
    examples.add_argument("--release-version", default="")
    examples.add_argument("--release-bundles", default="")
    examples.add_argument("--default-url", default="")
    examples.add_argument("--examples-dir", default="examples")
    examples.add_argument("--repo", default="")
    examples.set_defaults(func=cmd_update_example_urls)

    args = parser.parse_args()
    try:
        return args.func(args)
    except RuntimeError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1


def cmd_write_bundle_manifest(args: argparse.Namespace) -> int:
    default_bundle = require_bundle(args.default_bundle, "default bundle")
    wayland_bundle = require_bundle(args.wayland_bundle, "Wayland bundle")
    if default_bundle == wayland_bundle:
        raise RuntimeError("default and Wayland bundle paths must be different")

    write_json(
        args.output,
        [
            {
                "name": "default",
                "path": default_bundle.as_posix(),
                "test_os": DEFAULT_TEST_OS,
            },
            {
                "name": "wayland",
                "path": wayland_bundle.as_posix(),
                "test_os": WAYLAND_TEST_OS,
            },
        ],
    )
    return 0


def cmd_resolve_previous_default_url(args: argparse.Namespace) -> int:
    provided = args.provided_url.strip()
    if provided:
        previous_url = require_url(provided)
    else:
        repo = args.repo or os.environ.get("GITHUB_REPOSITORY", "")
        if not repo:
            raise RuntimeError("repo is required")

        latest = gh_json(["api", f"repos/{repo}/releases/latest"])
        previous_url = default_url_from_release(latest)

    Path(args.output_file).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output_file).write_text(previous_url + "\n", encoding="utf-8")
    if args.github_output:
        append_github_output(args.github_output, "previous_url", previous_url)
        append_github_output(args.github_output, "bump_check", bump_check_mode(previous_url))
    return 0


def read_types_pin() -> str:
    """The published roc-ray-types bundle the platform bundles were built against."""
    pin = Path(__file__).resolve().parent.parent / ".types-version"
    if not pin.is_file():
        return ""
    for line in pin.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            return stripped
    return ""


def cmd_make_release_notes(args: argparse.Namespace) -> int:
    release_version = args.release_version or os.environ.get("RELEASE_VERSION", "")
    if not release_version:
        raise RuntimeError("release version is required")

    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not repo:
        raise RuntimeError("GITHUB_REPOSITORY is required")

    bundles = read_json(args.release_bundles)
    default_file = artifact_file_for(bundles, "default")
    wayland_file = artifact_file_for(bundles, "wayland")
    default_url = release_asset_url(repo, release_version, default_file)
    wayland_url = release_asset_url(repo, release_version, wayland_file)

    lines = [
        f"Release {release_version}.",
        "",
        "## Bundles",
        "",
        "### Default bundle",
        "",
        "Use this bundle for macOS Intel, macOS Apple Silicon, Windows x64, and Linux x64 systems that can use the X11 raylib build.",
        "",
        "```roc",
        f'platform "{default_url}"',
        "```",
        "",
        "### Wayland bundle",
        "",
        "Use this bundle on Linux x64 Wayland systems when you want the Wayland raylib build instead of the default X11/XWayland path.",
        "",
        "```roc",
        f'platform "{wayland_url}"',
        "```",
    ]
    types_url = read_types_pin()
    if types_url:
        lines.extend([
            "",
            "### roc-ray-types package",
            "",
            "Shared data types and pure helpers, released independently of the platform. The",
            "bundles above already depend on this version; add it to your app only if a reusable",
            "package of your own also uses these types, so both resolve the same URL.",
            "",
            "```roc",
            f'"{types_url}"',
            "```",
        ])

    docs_url = args.docs_url or os.environ.get("DOCS_URL", "")
    if docs_url:
        lines.extend(["", "## Docs", "", f"- [View docs for {release_version}]({docs_url})"])

    Path(args.output_file).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output_file).write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return 0


def cmd_update_example_urls(args: argparse.Namespace) -> int:
    if args.default_url:
        default_url = require_url(args.default_url)
    else:
        release_version = args.release_version or os.environ.get("RELEASE_VERSION", "")
        if not release_version:
            raise RuntimeError("release version is required")
        if not args.release_bundles:
            raise RuntimeError("release bundle metadata is required")

        repo = args.repo or os.environ.get("GITHUB_REPOSITORY", "")
        if not repo:
            raise RuntimeError("repo is required")

        bundles = read_json(args.release_bundles)
        default_file = artifact_file_for(bundles, "default")
        default_url = release_asset_url(repo, release_version, default_file)

    examples_dir = Path(args.examples_dir)
    examples = sorted(examples_dir.glob("*/main.roc"))
    if not examples:
        raise RuntimeError(f"no Roc examples found in {examples_dir}")

    replacement = f'"{default_url}"'
    for example in examples:
        original = example.read_text(encoding="utf-8")
        rewritten, count = PLATFORM_REF_RE.subn(replacement, original)
        if count != 1:
            raise RuntimeError(
                f"expected one recognized platform reference in {example}, found {count}"
            )
        example.write_text(rewritten, encoding="utf-8")

    print(f"Updated {len(examples)} example(s) to {default_url}")
    return 0


def require_bundle(path_text: str, description: str) -> Path:
    path = Path(path_text)
    if not path.is_file():
        raise RuntimeError(f"{description} is missing: {path}")
    if path.name != path.name.replace("/", "") or not path.name.endswith(BUNDLE_SUFFIX):
        raise RuntimeError(f"{description} must be a {BUNDLE_SUFFIX} file: {path}")
    return path


def require_url(url: str) -> str:
    if "\n" in url or "\r" in url or not url.startswith("https://") or not url.endswith(BUNDLE_SUFFIX):
        raise RuntimeError(f"invalid previous release URL: {url!r}")
    return url


def bump_check_mode(_previous_url: str) -> str:
    """Keep bump checks advisory until the Roc compiler reaches 0.1.0."""
    return "warn"


def default_url_from_release(release: dict[str, Any]) -> str:
    body = str(release.get("body", ""))
    default_section = re.search(
        r"### Default bundle(?P<section>.*?)(?:\n### |\Z)",
        body,
        flags=re.S,
    )
    if default_section:
        match = re.search(r'platform\s+"(?P<url>https://[^"]+\.tar\.zst)"', default_section.group("section"))
        if match:
            return require_url(match.group("url"))

    assets = release.get("assets", [])
    matches = [
        str(asset.get("browser_download_url", ""))
        for asset in assets
        if str(asset.get("name", "")).endswith(BUNDLE_SUFFIX)
    ]
    matches = [url for url in matches if url]
    if len(matches) == 1:
        return require_url(matches[0])
    if not matches:
        return ""
    raise RuntimeError("latest release has multiple bundle assets but no default bundle URL in release notes")


def artifact_file_for(bundles: Any, name: str) -> str:
    if not isinstance(bundles, list):
        raise RuntimeError("release bundle metadata must be a list")
    for bundle in bundles:
        if isinstance(bundle, dict) and bundle.get("name") == name:
            artifact_file = str(bundle.get("artifact_file", ""))
            if artifact_file.endswith(BUNDLE_SUFFIX) and "/" not in artifact_file:
                return artifact_file
    raise RuntimeError(f"release bundle metadata is missing {name!r} bundle")


def release_asset_url(repo: str, release_version: str, artifact_file: str) -> str:
    return f"https://github.com/{repo}/releases/download/{release_version}/{artifact_file}"


def gh_json(args: list[str]) -> dict[str, Any]:
    result = subprocess.run(["gh", *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        if "HTTP 404" in result.stderr:
            return {}
        raise RuntimeError((result.stdout + result.stderr).strip())
    return json.loads(result.stdout)


def read_json(path_text: str) -> Any:
    return json.loads(Path(path_text).read_text(encoding="utf-8"))


def write_json(path_text: str, data: Any) -> None:
    path = Path(path_text)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def append_github_output(path_text: str, name: str, value: str) -> None:
    with open(path_text, "a", encoding="utf-8") as handle:
        handle.write(f"{name}={value}\n")


if __name__ == "__main__":
    raise SystemExit(main())
