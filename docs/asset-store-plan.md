# Asset store implementation plan

1. Introduce an opaque `Assets.Store` whose host value owns an opened directory
   handle in a dedicated typed ARC heap. Resolve all disk assets through that
   handle; do not use or change process CWD after opening.
2. Define explicit root policies (beside executable, working-directory, and
   absolute external directory), portable store-relative paths, and startup
   manifest validation. Keep validation proportional to the manifest, never to
   the number of loose files.
3. Add store-relative texture, font, and shader-source loaders plus byte/source
   constructors for embedded authored assets. Loaders borrow Roc payloads for
   their synchronous native calls and retain only the decoded GPU/font object.
4. Regenerate the ABI, cover native helpers and ARC routing with tests, migrate
   one example, and document integrity guarantees and the later async/packaging
   work separately.
