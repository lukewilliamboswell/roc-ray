#!/usr/bin/env python3
"""Repo-specific helpers for the RocRay release workflow."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any

from local_bundles import rewrite_compiler_pin
from release_notes_markdown import ConversionError, convert_file
from roc_platform_abi import read_pin


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
    notes.add_argument("--notes-dir", default="docs/releases")
    notes.set_defaults(func=cmd_make_release_notes)

    preview = subcommands.add_parser(
        "preview-release-notes",
        help="print the Markdown a release-notes .adoc file becomes on the GitHub release page",
    )
    preview.add_argument("notes")
    preview.set_defaults(func=cmd_preview_release_notes)

    examples = subcommands.add_parser("update-example-urls")
    examples.add_argument("--release-version", default="")
    examples.add_argument("--release-bundles", default="")
    examples.add_argument("--default-url", default="")
    examples.add_argument("--examples-dir", default="examples")
    examples.add_argument("--repo", default="")
    examples.set_defaults(func=cmd_update_example_urls)

    package = subcommands.add_parser("package-examples")
    package.add_argument("--release-version", default="")
    package.add_argument("--release-bundles", default="")
    package.add_argument("--bundle-url", default="")
    package.add_argument("--tag", default="")
    package.add_argument("--examples-dir", default="examples")
    package.add_argument("--repo", default="")
    package.add_argument("--output", default="")
    package.add_argument("--output-dir", default=".release")
    package.add_argument("--github-output", default="")
    package.set_defaults(func=cmd_package_examples)

    docs = subcommands.add_parser(
        "package-docs",
        help="build the manual (HTML and PDF) and the API reference, and package them as release assets",
    )
    docs.add_argument("--release-version", default="")
    docs.add_argument("--docs-version", default="")
    docs.add_argument("--roc", default="roc")
    docs.add_argument("--output-dir", default=".release")
    docs.set_defaults(func=cmd_package_docs)

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

        releases = gh_json(["api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"])
        previous = latest_platform_release([release for page in releases for release in page])
        previous_url = default_url_from_release(previous) if previous else ""

    Path(args.output_file).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output_file).write_text(previous_url + "\n", encoding="utf-8")
    if args.github_output:
        append_github_output(args.github_output, "previous_url", previous_url)
        append_github_output(args.github_output, "bump_check", bump_check_mode(previous_url))
    return 0


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

    editorial_notes = read_editorial_notes(Path(args.notes_dir), release_version)

    lines = [
        editorial_notes,
        "",
        f"Supported compiler: `{read_pin().nightly}`. Install this compiler before running the examples.",
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
    examples_url = release_asset_url(repo, release_version, f"examples-{release_version}.zip")
    lines.extend([
        "",
        "## Examples",
        "",
        f"A [zip of the examples]({examples_url}) pinned to this release is attached to every",
        "release; unzip and `roc examples/<name>/main.roc`.",
    ])

    lines.extend(["", "## Docs", ""])
    docs_url = args.docs_url or os.environ.get("DOCS_URL", "")
    if docs_url:
        lines.append(f"- [View the API reference for {release_version}]({docs_url})")
    manual_pdf = release_asset_url(repo, release_version, f"roc-ray-manual-{release_version}.pdf")
    manual_zip = release_asset_url(repo, release_version, f"roc-ray-manual-{release_version}.zip")
    api_zip = release_asset_url(repo, release_version, f"roc-ray-api-docs-{release_version}.zip")
    lines.extend([
        f"- [The manual as a PDF]({manual_pdf})",
        f"- [The manual as a static site]({manual_zip}); unzip and open `index.html`",
        f"- [The API reference as a static site]({api_zip}); unzip and open `index.html`",
    ])

    Path(args.output_file).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output_file).write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return 0


def read_editorial_notes(notes_dir: Path, release_version: str) -> str:
    """The hand-written notes for a release, as Markdown.

    Notes are written in AsciiDoc (`<version>.adoc`), the manual's format, and
    converted here. A Markdown file (`<version>.md`) is used as it is. With
    neither, the release gets a one-line generated introduction.
    """
    adoc = notes_dir / f"{release_version}.adoc"
    markdown = notes_dir / f"{release_version}.md"
    if adoc.exists() and markdown.exists():
        raise RuntimeError(f"release notes exist as both {adoc} and {markdown}; keep one")
    notes_path = adoc if adoc.exists() else markdown
    if not notes_path.exists():
        return f"Release {release_version}."
    if not notes_path.is_file():
        raise RuntimeError(f"release notes path is not a file: {notes_path}")
    if not notes_path.read_text(encoding="utf-8").strip():
        raise RuntimeError(f"release notes are empty: {notes_path}")
    if notes_path.suffix == ".adoc":
        try:
            return convert_file(notes_path).strip()
        except ConversionError as err:
            raise RuntimeError(str(err)) from None
    return notes_path.read_text(encoding="utf-8").strip()


def cmd_preview_release_notes(args: argparse.Namespace) -> int:
    try:
        sys.stdout.write(convert_file(Path(args.notes)))
    except ConversionError as err:
        raise RuntimeError(str(err)) from None
    return 0


def resolve_default_bundle_url(
    explicit_url: str, release_version: str, release_bundles: str, repo: str
) -> str:
    """The published default-bundle URL this release's examples must point at."""
    if explicit_url:
        return require_url(explicit_url)

    release_version = release_version or os.environ.get("RELEASE_VERSION", "")
    if not release_version:
        raise RuntimeError("release version is required")
    if not release_bundles:
        raise RuntimeError("release bundle metadata is required")

    repo = repo or os.environ.get("GITHUB_REPOSITORY", "")
    if not repo:
        raise RuntimeError("repo is required")

    bundles = read_json(release_bundles)
    default_file = artifact_file_for(bundles, "default")
    return release_asset_url(repo, release_version, default_file)


def cmd_update_example_urls(args: argparse.Namespace) -> int:
    default_url = resolve_default_bundle_url(
        args.default_url, args.release_version, args.release_bundles, args.repo
    )

    examples_dir = Path(args.examples_dir)
    examples = sorted(examples_dir.glob("*/main.roc"))
    if not examples:
        raise RuntimeError(f"no Roc examples found in {examples_dir}")

    replacement = f'"{default_url}"'
    compiler = read_pin(examples_dir.resolve().parent / "platform" / "main.roc").nightly
    for example in examples:
        original = example.read_text(encoding="utf-8")
        rewritten, count = PLATFORM_REF_RE.subn(replacement, original)
        if count != 1:
            raise RuntimeError(
                f"expected one recognized platform reference in {example}, found {count}"
            )
        rewritten = rewrite_compiler_pin(rewritten, compiler)
        example.write_text(rewritten, encoding="utf-8")

    print(f"Updated {len(examples)} example(s) to {default_url}")
    return 0


def zip_tree(source: Path, output: Path, prefix: str) -> None:
    """Zip every file under `source` beneath one top-level `prefix` directory,
    in a stable order, so an unzipped copy is one folder named for the release."""
    files = sorted(path for path in source.rglob("*") if path.is_file())
    if not files:
        raise RuntimeError(f"nothing to package under {source}")
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path, f"{prefix}/{path.relative_to(source).as_posix()}")


def cmd_package_docs(args: argparse.Namespace) -> int:
    """Build the release's documentation and package it beside the bundles.

    Produces three assets, each named for the release:

    - `roc-ray-manual-<tag>.pdf`: the manual as one PDF;
    - `roc-ray-manual-<tag>.zip`: the manual as a static site, opening at
      `index.html`, with the PDF beside it;
    - `roc-ray-api-docs-<tag>.zip`: the `roc docs` API reference.

    Pages carries the latest of each; these keep every release's copy with the
    release itself. Prints the asset paths, one per line, for the publish step.
    """
    tag = args.release_version or os.environ.get("RELEASE_VERSION", "")
    if not tag or "/" in tag or "\\" in tag or not tag.strip():
        raise RuntimeError(f"a valid release version is required, got {tag!r}")
    docs_version = args.docs_version or tag
    root = repo_root()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="rr-release-docs-") as scratch:
        scratch_root = Path(scratch)

        api_root = scratch_root / "api"
        subprocess.run(
            [sys.executable, str(root / "scripts" / "build_docs.py"), "--roc", args.roc,
             "--docs-root", str(api_root), "--version", docs_version],
            check=True, cwd=root,
        )
        api_zip = output_dir / f"roc-ray-api-docs-{tag}.zip"
        zip_tree(api_root / docs_version, api_zip, f"roc-ray-api-docs-{tag}")

        # The manual builds in a container that sees only the checkout, so its
        # output has to be inside it; `.docs-out/` is ignored.
        manual_root = root / ".docs-out" / f"release-{tag}"
        try:
            subprocess.run(
                [sys.executable, str(root / "scripts" / "build_manual.py"), "--pdf",
                 "--docs-version", tag, "--output", str(manual_root)],
                check=True, cwd=root,
            )
            pdf = output_dir / f"roc-ray-manual-{tag}.pdf"
            shutil.copyfile(manual_root / "roc-ray.pdf", pdf)
            manual_zip = output_dir / f"roc-ray-manual-{tag}.zip"
            zip_tree(manual_root / "site", manual_zip, f"roc-ray-manual-{tag}")
        finally:
            shutil.rmtree(manual_root, ignore_errors=True)

    for asset in (manual_zip, pdf, api_zip):
        print(asset)
    return 0


def cmd_package_examples(args: argparse.Namespace) -> int:
    default_url = resolve_default_bundle_url(
        args.bundle_url, args.release_version, args.release_bundles, args.repo
    )

    tag = args.tag or args.release_version or os.environ.get("RELEASE_VERSION", "")
    if not tag:
        raise RuntimeError("release tag is required")
    if "/" in tag or "\\" in tag or not tag.strip():
        raise RuntimeError(f"invalid release tag: {tag!r}")

    root = repo_root()
    compiler = read_pin(root / "platform" / "main.roc").nightly
    examples_dir = Path(args.examples_dir)
    if len(examples_dir.parts) != 1:
        raise RuntimeError(f"examples dir must be a single top-level directory: {examples_dir}")
    # README recordings live under examples/gallery but are documentation
    # media, not a runnable app or part of the downloadable examples archive.
    entries = [
        entry
        for entry in tracked_files(root, examples_dir)
        if not entry.startswith(f"{examples_dir.as_posix()}/gallery/")
    ]
    if not entries:
        raise RuntimeError(f"no tracked files found under {examples_dir}")

    output = Path(args.output) if args.output else Path(args.output_dir) / f"examples-{tag}.zip"
    output.parent.mkdir(parents=True, exist_ok=True)

    replacement = f'"{default_url}"'
    rewritten_headers = 0
    example_dirs: set[str] = set()
    packaged_apps: set[str] = set()

    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for entry in entries:
            source = root / entry
            if not source.is_file():
                raise RuntimeError(f"tracked example file is missing from the tree: {entry}")

            parts = entry.split("/")
            if len(parts) >= 3:
                example_dirs.add(parts[1])

            if parts[-1] == "main.roc" and len(parts) == 3:
                original = source.read_text(encoding="utf-8")
                rewritten, count = PLATFORM_REF_RE.subn(replacement, original)
                if count != 1:
                    raise RuntimeError(
                        f"expected one recognized platform reference in {entry}, found {count}"
                    )
                data = rewrite_compiler_pin(rewritten, compiler).encode("utf-8")
                rewritten_headers += 1
                packaged_apps.add(parts[1])
            else:
                data = source.read_bytes()

            write_zip_entry(archive, entry, data)

    missing = sorted(example_dirs - packaged_apps)
    if missing:
        output.unlink(missing_ok=True)
        raise RuntimeError(
            "example directories without a rewritten main.roc header: " + ", ".join(missing)
        )
    if not rewritten_headers:
        output.unlink(missing_ok=True)
        raise RuntimeError("no example headers were rewritten")

    if args.github_output:
        append_github_output(args.github_output, "examples_zip", output.as_posix())

    print(f"Wrote {output} with {len(entries)} file(s), {rewritten_headers} header(s) -> {default_url}")
    return 0


def repo_root() -> Path:
    """The working tree the examples are read from, so `git ls-files` agrees with it."""
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError((result.stdout + result.stderr).strip() or "not inside a git work tree")
    return Path(result.stdout.strip())


def tracked_files(root: Path, examples_dir: Path) -> list[str]:
    """Tracked paths under `examples_dir`, so build outputs and captures stay out."""
    result = subprocess.run(
        ["git", "ls-files", "-z", "--", examples_dir.as_posix()],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError((result.stdout + result.stderr).strip() or "git ls-files failed")
    return sorted(entry for entry in result.stdout.split("\0") if entry)


def write_zip_entry(archive: zipfile.ZipFile, name: str, data: bytes) -> None:
    """Add one file with a fixed timestamp so the archive is reproducible."""
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    archive.writestr(info, data)


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


# A platform release's tag is its version; the repository also publishes
# linker-input, macOS-interface and types releases under prefixed tags.
PLATFORM_TAG = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$")


def latest_platform_release(releases: list[dict[str, Any]]) -> dict[str, Any] | None:
    """The most recently published platform release, prereleases included.

    GitHub's "latest release" skips prereleases and can name a dependency
    release, so a bump check against it compares with the wrong API.
    """
    platform = [
        release for release in releases
        if not release.get("draft") and PLATFORM_TAG.match(str(release.get("tag_name", "")))
    ]
    return max(platform, key=lambda release: str(release.get("published_at") or ""), default=None)


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
