# Contributing to RocRay

Thank you for helping. The contributor guide is part of the RocRay manual:

- [Contributing](docs/contributing.adoc): development setup, everyday checks,
  design principles, examples and documentation, and the pull request
  checklist
- [Working on the host](docs/host-development.adoc): the Roc/host boundary,
  hosted effects, phases, declared permissions, and performance work
- [Dependencies, bundles, and releases](docs/maintaining.adoc): linker inputs,
  macOS interfaces, vendored C libraries, bundles, releases, and compiler
  updates
- [Architecture](docs/architecture.adoc): read this before proposing a change
  to a public API, platform behaviour, host integration, ownership, scheduling,
  resource limits, targets, or application lifecycle

The whole manual is published at
<https://lukewilliamboswell.github.io/roc-ray/manual/>.

Open an issue before a broad API change or a substantial new subsystem so its
shape can be discussed first. Before opening a pull request, run:

```bash
zig build lint
zig build test
```
