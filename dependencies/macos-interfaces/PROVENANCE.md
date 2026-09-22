# Generated macOS linker interface provenance

RocRay generates these `.tbd` files from scratch as minimal text descriptions
of selected symbol names, library paths, required reexports, and target
architectures.
They exist solely to link the independently compiled RocRay host to libraries
that macOS supplies at runtime.

The reviewed `interfaces.json` catalog records the evidence for each interface.
Sources are limited to publicly available developer documentation and identified
public open-source declarations with pinned revisions. Generation uses the
committed catalog offline.

Project archive symbol tables establish only requirement context. Apple public
documentation or pinned Apple OSS establishes declarations and ownership; pinned
public LLVM or runtime source establishes compiler-generated ABI transformations.
Raylib, GLFW, and community bindings cannot be the sole evidence for a generated
system interface.

The producer does not read, copy, or modify Apple SDK headers, TBDs, framework
binaries, dylibs, object files, symbol tables, generated SDK metadata, or other
installed macOS software. The generated interface package redistributes no Apple
SDK files or framework implementations.

The independently compiled host, raylib, GIF, VP8, and SQLite archives are used
only to inventory unresolved references and later to validate a candidate. An
archive reference does not establish its owning library, public status, weak-link behavior, or final-link
reachability, so archive audits never populate the catalog automatically.
Ownership and selection require separate reviewed public or open-source evidence.

The producer reads only the catalog, generator, and this provenance statement.
Its manifest records their identities and every generated-file hash. Native
final-link and runtime checks validate the resulting interfaces against a
source-matched host built independently in the producer workflow and the
operating system without deriving interface data
from installed Apple software. Host identity is validation evidence, not part of
the generated interface archive's identity.
