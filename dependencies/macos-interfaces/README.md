# Generated macOS linker interfaces

RocRay generates the minimal text-based linker interfaces needed to connect its
compiled host and native libraries to libraries supplied by macOS. The generated
`.tbd` files are our own output. They are produced from the reviewed
[`interfaces.json`](interfaces.json)
catalog and [`PROVENANCE.md`](PROVENANCE.md), not extracted from macOS or Xcode.

## Generation inputs

The generator reads the committed catalog and provenance statement. It reads no
Apple SDK headers, TBDs, framework binaries, dylibs, object files, symbol tables,
generated SDK metadata, or other installed macOS software. None of those
materials supplies symbols, library ownership, install names, reexports, or
availability information to the catalog.

Permitted evidence is deliberately separated:

- Apple's publicly available developer documentation may establish the exact
  spelling and public declaration of an interface.
- Identified public open-source source code may establish runtime ABI or library
  ownership when its repository, revision, file, and declaration are recorded.
- Community-maintained FFI bindings and raylib/GLFW source may explain why the host
  references an interface, but do not by themselves prove which system library
  owns it.
- The project-built macOS archives may be inspected only to inventory their unresolved
  references. It does not establish library ownership, reachability after dead
  stripping, public API status, weak-link behavior, or inclusion in the catalog.

Installed macOS tools may execute the final link and application for validation.
That validation tests our independently generated interfaces against the runtime
provided by the operating system; it does not derive or amend the interfaces
from installed Apple software.

## Reviewed catalog and generation

Every selected symbol record identifies its owning interface and evidence. Every
library record identifies its install path and supporting public or open-source
evidence. Ownership is reviewed symbol by symbol. Prefix matching,
framework-name guessing, and archive-wide collection do not establish ownership.

`scripts/audit_macos_archives.py` inventories unresolved references in the
project-built host, raylib, GIF, VP8, and SQLite archives. The inventory is intentionally broader than the final
application: static archives contain members that may be discarded by the final
link, and dynamically looked-up Objective-C names may not appear as linker
references. Audit output is evidence for what needs investigation, never an
automatic input to `interfaces.json`.

`scripts/build_macos_stubs.py` deterministically writes TAPI v4 YAML from the
reviewed catalog. Generation is offline. It reads no SDK or installed system
interface material. The output manifest binds the catalog, generator,
provenance, target, and generated-file hashes. `scripts/build_macos_interfaces.py`
packages that output as the independent external-input release; compiled
archives are not part of the interface archive's identity.

The TAPI text format is openly implemented by
[LLVM's TextAPI reader and writer](https://www.llvm.org/docs/doxygen/TextStub_8cpp_source.html).
The generated files contain only targets, install names, and selected symbol
names required for linking. macOS supplies all implementations at runtime.

## Reviewing a catalog change

1. Build RocRay's macOS archives solely from RocRay and its reviewed open-source inputs.
2. Inventory unresolved references with `audit_macos_archives.py` using the
   Xcode toolchain's `llvm-nm`, recording its identity in the audit output.
3. Compare the inventory with the catalog. For each proposed addition, establish
   its exact declaration and owning library from permitted public or open-source
   evidence. Record precise URLs and pinned revisions.
4. Review the change to `interfaces.json` manually. Catalog entries do not come
   from symbol prefixes, linker diagnostics, installed SDK contents, or
   the audit inventory.
5. Generate candidate interfaces offline and run the generator and archive-audit
   tests.
6. Final-link every maintained RocRay application with the selected host and
   candidate interfaces, then run the headless suite on both supported macOS
   architectures. Graphical validation remains a real-Mac check because hosted
   macOS runners do not provide a usable OpenGL pixel format.

A missing symbol requires gathering and reviewing evidence rather than copying
the system stub or bulk-adding archive references. An unexplained symbol remains
unselected until ownership evidence is available.

## Release and consumer admission

The macOS interfaces are an independently versioned external dependency. Their
producer builds the deterministic archive from committed reviewed inputs, tests
it against a compatible host, records validation identities, creates a signed
build-provenance attestation, and publishes a content-addressed release whose
tag and asset names producer policy never reuses. Host validation does not turn
the host archive into a generator input.

Consumers admit the exact release recorded in the dependency lock and verify its
repository, signer workflow, source revision, size, digest, manifest, and target.
The final platform bundle validates the same bytes through native final links,
semantic specifications, and runtime smoke tests before publishing them without
rebuilding.
