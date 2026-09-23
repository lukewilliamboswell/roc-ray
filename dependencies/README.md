# Platform linker inputs

This directory contains reviewed recipes and source records for linker inputs.
Generated interfaces and archives are not committed. Independent producer CI
publishes deterministic release assets with GitHub build-provenance
attestations; consumers select exact bytes through `dependencies.lock.json`.

This directory covers the project-authored macOS interface set, selected by
`dependencies.lock.json`. The platform's other linker inputs (raylib, msf_gif,
libvpx, SQLite, and the CRT, Linux stub, and Windows import libraries) are
released separately and selected by `link-inputs.lock.json`. See
[`link-inputs/README.md`](link-inputs/README.md). The two locks stay separate
because they are separate trust boundaries.

Each lock entry identifies the producer repository, immutable release and
asset, target, SHA-256, byte length, source commit and trusted branch, signer
workflow, and producer-input fingerprint. Downloads are cached by digest and
their size and digest are checked again on every use. Archives reject links,
special files, duplicate or escaping paths, undeclared payloads, and mismatched
target manifests before atomic extraction.

After adoption, ordinary development and platform release assembly consume the
locked release. Source generation is an explicit contributor mode used while
changing the reviewed catalog. A downloaded artifact that fails identity,
integrity, inventory, or attestation checks is never replaced silently with
locally generated interfaces.

The macOS producer is bootstrapped in two reviews. This tree is the producer
review: it must land on `main` before GitHub can attest an artifact whose source
identity is trusted. The follow-up publishes that artifact, reviews the
workflow-generated lock, switches ordinary builds and releases to it, and only
then removes the old checked-in SDK snapshot. See
[`macos-interfaces/README.md`](macos-interfaces/README.md).
