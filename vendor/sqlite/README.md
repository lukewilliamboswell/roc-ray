# Vendored SQLite

The SQLite amalgamation, built from source for every target by `build.zig`
(`buildSqlite3`). `src/sqlite_effect.zig` is the only Zig file that calls it,
and it does so through `shim/rocray_sqlite.c` rather than a `@cImport`, because
the host module is freestanding and has no C headers.

## Version

| | |
| --- | --- |
| Release | 3.50.4 |
| Source | <https://sqlite.org/2025/sqlite-amalgamation-3500400.zip> |
| SHA-256 of the zip | `1d3049dd0f830a025a53105fc79fd2ab9431aea99e137809d064d8ee8356b032` |

`sqlite3.c` and `sqlite3.h` are copied unmodified from that archive.
`sqlite3ext.h` and `shell.c` are not vendored: extension loading is compiled
out and the command-line shell is not built.

SQLite is in the public domain; see <https://sqlite.org/copyright.html>.

## Updating

1. Download the amalgamation zip for the new release and record its SHA-256
   above.
2. Replace `sqlite3.c` and `sqlite3.h`; leave `shim/` alone.
3. Run `zig build` and `zig build test`.
4. Check whether the unix VFS reaches any libc symbol that
   `platform/targets/x64glibc/libc_stub.s` does not yet define. A missing one
   is a link error naming the symbol; add it to the stub in the same shape as
   its neighbours.

## Compile flags

Set in `sqlite3_flags` in `build.zig`. The reasons that are not obvious:

- `SQLITE_THREADSAFE=1` — serialized mode. The host already holds one mutex per
  connection, so mode 2 would do, but serialized mode is what makes
  `sqlite3_interrupt` from the frame thread safe against a query running on a
  blocking-pool thread without further reasoning, and the locking costs nothing
  next to the I/O it wraps. Shutdown depends on that interrupt.
- `SQLITE_OMIT_LOAD_EXTENSION` — a database file can never cause native code to
  be loaded. This is a security boundary, not a size decision.
- `SQLITE_DQS=0` — a double-quoted string is an identifier, never a string
  literal, so a typo in a column name is an error rather than silently
  becoming text.
- `SQLITE_ENABLE_MATH_FUNCTIONS` and JSON1 (on by default) are kept: both are
  what makes a visualization query worth running in the database instead of in
  Roc.
- `SQLITE_OMIT_DEPRECATED`, `SQLITE_OMIT_SHARED_CACHE`,
  `SQLITE_DEFAULT_MEMSTATUS=0`, `SQLITE_LIKE_DOESNT_MATCH_BLOBS`,
  `SQLITE_MAX_EXPR_DEPTH=0` are the recommended size and speed options from
  <https://sqlite.org/compile.html>.
- `-fno-stack-protector` / `-mno-stack-arg-probe` for the same reason libvpx
  needs them: the Windows archive is compiled against mingw headers and linked
  into an MSVC-target binary, which has no libgcc helpers.
