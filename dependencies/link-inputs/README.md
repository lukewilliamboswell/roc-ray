# Platform linker inputs

Every file named in the `targets` blocks of `platform/main.roc` and
`platform/main-wayland.roc` is a linker input, except the host archive
(`libhost.a`/`host.lib`) and the Roc app. That means raylib, msf_gif, libvpx,
SQLite, the Linux CRT objects and link stubs, and the Windows import libraries.
They change far less often than the host, so they are released on their own,
and `link-inputs.lock.json` selects exact bytes for them.

## Why production and consumption are separate

- **Cost.** An ordinary build, CI job, nightly check, or release compiles only
  the host. It restores the locked archives from a cache, or downloads them on
  a miss, and never rebuilds libvpx, SQLite, or the stubs for every target.
- **Reviewable identity.** The lock names one immutable, content-addressed
  release and each archive's SHA-256 and size. A lock change shows exactly
  which linker bytes changed. The cache is transport only: every use rehashes
  the archive against the lock, a cache hit included.
- **Authority.** The producer workflow can run PR code, so it has no
  permission to publish. The publisher has release and branch-write
  permission, so it runs only the pinned roc-automation controller from `main`
  and never executes PR code.
- **No silent substitution.** A missing, stale, or mismatched input fails the
  build with a pointer to this page. It never falls back to a local rebuild,
  which would link unreviewed bytes that depend on the runner.

## Profiles

| Profile | Installs into | Serves |
| --- | --- | --- |
| `x64mac` | `targets/x64mac/` | `platform/main.roc` |
| `arm64mac` | `targets/arm64mac/` | `platform/main.roc` |
| `x64glibc-x11` | `targets/x64glibc/` | `platform/main.roc` |
| `x64glibc-wayland` | `targets/x64glibc/` | `platform/main-wayland.roc` |
| `x64win` | `targets/x64win/` | `platform/main.roc` (COFF, `host.lib` contract) |

X11 and Wayland share Roc's `x64glibc` target but not their bytes. Each has
its own archive, and each archive's manifest names its profile. The consumer
rejects an archive installed under the wrong profile, and it refuses to
install both profiles into one tree.

Each archive's inventory is derived from the platform header, so it must match
that header's `targets` list exactly, plus the libvpx licence notices.
Undeclared or missing files, links, special files, duplicate or escaping paths,
and wrong profile manifests are rejected before anything is copied into place.

The macOS SDK interfaces (`macos-sysroot`) are a separate dependency with a
separate lock, `dependencies.lock.json`. See `dependencies/macos-interfaces/`.

## Consuming (everyone)

`zig build` runs `scripts/link_inputs.py install` for the default package and
then builds the host from the checkout. `scripts/bundle.sh` installs the
locked profiles, the Wayland profile for the Wayland package, into its fresh
staging directory.

Archives are cached under `~/.cache/roc-ray/link-inputs`, or under
`$ROC_RAY_LINK_INPUT_CACHE` when it is set. CI caches that directory with a key
of `hashFiles('link-inputs.lock.json')`. Release publication also runs
`scripts/link_inputs.py verify-attestations`, which checks GitHub build
provenance for the manifest and every archive against the locked source commit
and producer workflow.

## Changing a linker input (maintainers)

Producer inputs are `link_inputs.zig`, `vendor/{raylib,msf_gif,libvpx,sqlite}`,
the committed x64glibc CRT objects and stub sources, `platform/targets/windows-def`,
`scripts/link_input_release.py`, and `.github/workflows/link-inputs.yml`. Their
committed git tree is the lock's `input_fingerprint`. Once any of them changes,
an ordinary build reports the lock as stale until a new release is adopted.

1. Make the change on a branch of this repository, not a fork, and open a PR.
   Iterate locally with the producer commands:

   ```bash
   zig build link-inputs                      # every profile into zig-out/link-inputs/
   zig build libvpx-parity                    # SIMD kernels against their C references
   python3 scripts/link_input_release.py --output /tmp/candidate
   python3 scripts/link_inputs.py install --candidate /tmp/candidate --destination platform --targets-only
   ```

   The candidate step refuses uncommitted producer inputs.
2. `link-inputs.yml` runs on the PR. It builds every profile twice from clean
   state, requires identical bytes, and links and runs the examples against
   the exact candidate on every supported OS.
3. From `main`, run **Publish PR linker inputs** (`publish-link-inputs.yml`)
   with the PR number. It dispatches the producer at the PR's exact head with
   attestation enabled, admits the candidate, publishes the immutable release
   `link-inputs-sha256-<manifest digest>`, and pushes one signed commit that
   changes only `link-inputs.lock.json`.
4. Review the lock commit as a dependency change. Check the source SHA and ref,
   the producer run, the attestations, target coverage, and that routine CI on
   the new head consumed the release without rebuilding it.
5. Merge with a merge commit, so the attested producer commit and the signed
   lock commit stay in history. Never rebuild, retag, or replace the release.

Keep the X11 archive's glibc baseline in mind: the vendored Linux raylib
references glibc 2.38 symbols (issue #170). A new release must not claim
broader compatibility than it has been shown to have.
