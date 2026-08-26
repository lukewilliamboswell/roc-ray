// Narrow C shim over SQLite.
//
// The host module is built freestanding and has no C headers, so it cannot
// @cImport sqlite3.h. This shim lives inside the sqlite library (which does
// have libc) and exposes only primitives and opaque pointers, so the Zig side
// needs no sqlite types and there is no struct layout to mirror. See
// src/sqlite_effect.zig for the matching `extern fn` declarations.
//
// Every function here is a thin forward to one sqlite3 call. The step loop,
// the result encoding, the caps, and the per-connection mutex all live on the
// Zig side, where the buffers and the bounds are.
//
// Strings crossing this boundary are NUL-terminated: a Roc `Str` is not, so
// the Zig side makes a sentinel-terminated copy before calling in. That copy
// is also what keeps a path or a statement out of sqlite's hands after the
// call returns.

#include "sqlite3.h"
#include <string.h>

int rocray_sqlite_init(void) {
    return sqlite3_initialize();
}

void rocray_sqlite_shutdown(void) {
    sqlite3_shutdown();
}

// Cross-platform bounded idle wait for the dedicated Observatory writer.
// This delegates to SQLite's configured OS sleep primitive, avoiding a
// pthread/Win32 condition-variable abstraction in the freestanding Zig host.
int rocray_sqlite_sleep(int milliseconds) {
    return sqlite3_sleep(milliseconds);
}

// Cross-platform wall clock exposed by SQLite's selected VFS. This is used
// only for recorder self-observation intervals; it is not CPU time and is not
// used for application timestamps. The VFS unit is 1/86400000 of a day.
sqlite3_int64 rocray_sqlite_wall_time_ms(void) {
    sqlite3_vfs *vfs = sqlite3_vfs_find(0);
    sqlite3_int64 julian_ms = 0;
    if (!vfs || !vfs->xCurrentTimeInt64 || vfs->xCurrentTimeInt64(vfs, &julian_ms) != SQLITE_OK) return 0;
    return julian_ms;
}

static sqlite3_int64 rocray_vfs_file_size(sqlite3_vfs *vfs, const char *path, int type_flag) {
    sqlite3_file *file;
    sqlite3_int64 size = 0;
    int exists = 0;
    int flags = 0;
    if (vfs->xAccess(vfs, path, SQLITE_ACCESS_EXISTS, &exists) != SQLITE_OK || !exists) return 0;
    file = sqlite3_malloc64((sqlite3_uint64)vfs->szOsFile);
    if (!file) return -1;
    memset(file, 0, (size_t)vfs->szOsFile);
    if (vfs->xOpen(vfs, path, file, SQLITE_OPEN_READONLY | type_flag, &flags) != SQLITE_OK) {
        sqlite3_free(file);
        return -1;
    }
    if (file->pMethods->xFileSize(file, &size) != SQLITE_OK) size = -1;
    file->pMethods->xClose(file);
    sqlite3_free(file);
    return size;
}

// Logical bytes currently held by the main database and its active WAL.
sqlite3_int64 rocray_sqlite_storage_size(void *opaque_db) {
    sqlite3 *db = (sqlite3 *)opaque_db;
    sqlite3_vfs *vfs = sqlite3_vfs_find(0);
    const char *main_path = sqlite3_db_filename(db, "main");
    sqlite3_int64 main_size;
    sqlite3_int64 wal_size;
    char *wal_path;
    if (!vfs || !main_path) return -1;
    main_size = rocray_vfs_file_size(vfs, main_path, SQLITE_OPEN_MAIN_DB);
    if (main_size < 0) return -1;
    wal_path = sqlite3_mprintf("%s-wal", main_path);
    if (!wal_path) return -1;
    wal_size = rocray_vfs_file_size(vfs, wal_path, SQLITE_OPEN_WAL);
    sqlite3_free(wal_path);
    if (wal_size < 0) return -1;
    return main_size + wal_size;
}

// mode: 0 read/write/create, 1 read/write, 2 read-only,
// 3 read/write/exclusive-create (used by Observatory, which never overwrites).
//
// A read-only connection is also locked down: DEFENSIVE blocks the writable_schema
// and rowid-table tricks that turn a "read-only" handle into a writer, and an
// attached-database limit of zero stops `ATTACH` reaching a second file. A
// visualization app that opens someone else's database gets what it asked for.
int rocray_sqlite_open(const char *path, int mode, int busy_timeout_ms, void **out_db) {
    sqlite3 *db = 0;
    int flags;
    int rc;

    switch (mode) {
        case 1: flags = SQLITE_OPEN_READWRITE; break;
        case 2: flags = SQLITE_OPEN_READONLY; break;
        case 3: flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE; break;
        default: flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE; break;
    }
    flags |= SQLITE_OPEN_EXRESCODE;

    rc = sqlite3_open_v2(path, &db, flags, 0);
    *out_db = (void *)db;
    // sqlite3_open_v2 hands back a handle even on failure, so the caller can
    // read the message off it; the caller closes it either way.
    if (rc != SQLITE_OK) return rc;

    sqlite3_busy_timeout(db, busy_timeout_ms);

    if (mode == 2) {
        sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, 1, 0);
        sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0);
    }
    return SQLITE_OK;
}

int rocray_sqlite_close(void *db) {
    // close_v2, not close: a statement that outlives its connection leaves the
    // handle a zombie that closes when the last one is finalized, so the order
    // the two host resource heaps drain in cannot matter.
    return sqlite3_close_v2((sqlite3 *)db);
}

// Safe to call from another thread while a query is running on this
// connection, which is the whole reason it exists: shutdown interrupts an
// in-flight step so the blocking worker unwinds instead of holding the exit.
void rocray_sqlite_interrupt(void *db) {
    sqlite3_interrupt((sqlite3 *)db);
}

const char *rocray_sqlite_errmsg(void *db) {
    return sqlite3_errmsg((sqlite3 *)db);
}

int rocray_sqlite_extended_errcode(void *db) {
    return sqlite3_extended_errcode((sqlite3 *)db);
}

long long rocray_sqlite_changes(void *db) {
    return (long long)sqlite3_changes64((sqlite3 *)db);
}

long long rocray_sqlite_last_insert_rowid(void *db) {
    return (long long)sqlite3_last_insert_rowid((sqlite3 *)db);
}

// out_tail_used reports whether anything but whitespace followed the first
// statement, so the caller can refuse a multi-statement string rather than
// silently running only its first part.
int rocray_sqlite_prepare(void *db, const char *sql, void **out_stmt, int *out_tail_used) {
    sqlite3_stmt *stmt = 0;
    const char *tail = 0;
    int rc = sqlite3_prepare_v2((sqlite3 *)db, sql, -1, &stmt, &tail);

    *out_stmt = (void *)stmt;
    *out_tail_used = 0;
    if (rc == SQLITE_OK && tail != 0) {
        while (*tail != '\0') {
            if (*tail != ' ' && *tail != '\t' && *tail != '\n' &&
                *tail != '\r' && *tail != '\v' && *tail != '\f' && *tail != ';') {
                *out_tail_used = 1;
                break;
            }
            tail++;
        }
    }
    return rc;
}

int rocray_sqlite_finalize(void *stmt) {
    return sqlite3_finalize((sqlite3_stmt *)stmt);
}

int rocray_sqlite_reset(void *stmt) {
    return sqlite3_reset((sqlite3_stmt *)stmt);
}

int rocray_sqlite_clear_bindings(void *stmt) {
    return sqlite3_clear_bindings((sqlite3_stmt *)stmt);
}

// 0 when the statement has no such parameter, which the caller reports as a
// binding that names nothing rather than silently dropping it.
int rocray_sqlite_bind_index(void *stmt, const char *name) {
    return sqlite3_bind_parameter_index((sqlite3_stmt *)stmt, name);
}

int rocray_sqlite_bind_null(void *stmt, int index) {
    return sqlite3_bind_null((sqlite3_stmt *)stmt, index);
}

int rocray_sqlite_bind_int64(void *stmt, int index, long long value) {
    return sqlite3_bind_int64((sqlite3_stmt *)stmt, index, (sqlite3_int64)value);
}

int rocray_sqlite_bind_double(void *stmt, int index, double value) {
    return sqlite3_bind_double((sqlite3_stmt *)stmt, index, value);
}

// SQLITE_TRANSIENT: sqlite copies the bytes, so the caller's buffer is free
// the moment this returns. The alternative would pin a Roc-owned allocation
// for the life of the statement.
int rocray_sqlite_bind_text(void *stmt, int index, const char *bytes, long long len) {
    return sqlite3_bind_text64((sqlite3_stmt *)stmt, index, bytes,
                               (sqlite3_uint64)len, SQLITE_TRANSIENT, SQLITE_UTF8);
}

int rocray_sqlite_bind_blob(void *stmt, int index, const void *bytes, long long len) {
    return sqlite3_bind_blob64((sqlite3_stmt *)stmt, index, bytes,
                               (sqlite3_uint64)len, SQLITE_TRANSIENT);
}

int rocray_sqlite_step(void *stmt) {
    return sqlite3_step((sqlite3_stmt *)stmt);
}

int rocray_sqlite_column_count(void *stmt) {
    return sqlite3_column_count((sqlite3_stmt *)stmt);
}

const char *rocray_sqlite_column_name(void *stmt, int index) {
    return sqlite3_column_name((sqlite3_stmt *)stmt, index);
}

// 1 integer, 2 float, 3 text, 4 blob, 5 null -- SQLITE_INTEGER and friends.
int rocray_sqlite_column_type(void *stmt, int index) {
    return sqlite3_column_type((sqlite3_stmt *)stmt, index);
}

long long rocray_sqlite_column_int64(void *stmt, int index) {
    return (long long)sqlite3_column_int64((sqlite3_stmt *)stmt, index);
}

double rocray_sqlite_column_double(void *stmt, int index) {
    return sqlite3_column_double((sqlite3_stmt *)stmt, index);
}

// Call the _bytes accessor that matches the payload: asking for text length
// after reading a blob pointer makes sqlite convert the value in place.
const void *rocray_sqlite_column_blob(void *stmt, int index) {
    return sqlite3_column_blob((sqlite3_stmt *)stmt, index);
}

const void *rocray_sqlite_column_text(void *stmt, int index) {
    return (const void *)sqlite3_column_text((sqlite3_stmt *)stmt, index);
}

int rocray_sqlite_column_bytes(void *stmt, int index) {
    return sqlite3_column_bytes((sqlite3_stmt *)stmt, index);
}

// Runs every statement in `sql`, which is what a schema or a migration is.
// No bindings and no rows: a script is written by the app, not assembled from
// user input, and anything that returns rows belongs in a query.
int rocray_sqlite_exec(void *db, const char *sql) {
    return sqlite3_exec((sqlite3 *)db, sql, 0, 0, 0);
}
