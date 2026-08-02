#!/usr/bin/env python3
"""Reject release host libraries that contain Zig's debug allocator."""

from pathlib import Path


HOST_LIBRARIES = (
    Path("platform/targets/x64mac/libhost.a"),
    Path("platform/targets/arm64mac/libhost.a"),
    Path("platform/targets/x64glibc/libhost.a"),
    Path("platform/targets/x64win/host.lib"),
)
DEBUG_ALLOCATOR_MARKERS = (
    b"heap.debug_allocator.DebugAllocator",
    b"debug.captureCurrentStackTrace",
)


def main() -> int:
    failures: list[str] = []

    for library in HOST_LIBRARIES:
        if not library.is_file():
            failures.append(f"missing release host: {library}")
            continue

        contents = library.read_bytes()
        markers = [
            marker.decode() for marker in DEBUG_ALLOCATOR_MARKERS if marker in contents
        ]
        if markers:
            failures.append(
                f"{library} contains debug allocator marker(s): {', '.join(markers)}"
            )
        else:
            print(f"Verified release host: {library}")

    if failures:
        for failure in failures:
            print(f"ERROR: {failure}")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
