## Pure parts of `scripts/check_release_hosts.roc`: which host libraries a
## release ships, and whether one was built with Zig's debug allocator.
Hosts := [].{

	## The host library of every native target, relative to the repository.
	libraries : List(Str)
	libraries = [
		"platform/targets/x64mac/libhost.a",
		"platform/targets/arm64mac/libhost.a",
		"platform/targets/x64v1glibc/libhost.a",
		"platform/targets/x64win/host.lib",
	]

	## Symbol names that only a host built with the debug allocator contains.
	debug_markers : List(Str)
	debug_markers = ["heap.debug_allocator.DebugAllocator", "debug.captureCurrentStackTrace"]

	## The debug markers found in a library's bytes.
	markers_in : List(U8) -> List(Str)
	markers_in = |bytes| debug_markers.keep_if(|marker| contains(bytes, marker.to_utf8()))
}

## Whether `needle` occurs in `haystack`. Only a position whose first byte
## matches is compared in full, so a scan of a host archive stays linear in
## practice.
contains : List(U8), List(U8) -> Bool
contains = |haystack, needle| {
	match needle.first() {
		Err(_) => Bool.True
		Ok(head) => {
			width = needle.len()
			if (haystack.len() < width) return Bool.False
			last = haystack.len() - width
			var $start = 0
			while $start <= last {
				if haystack.get($start) == Ok(head) and haystack.sublist({ start: $start, len: width }) == needle {
					return Bool.True
				}
				$start = $start + 1
			}
			Bool.False
		}
	}
}

expect contains("a heap.debug_allocator.DebugAllocator here".to_utf8(), "heap.debug_allocator.DebugAllocator".to_utf8())
expect !contains("heap.debug_allocator.Debug".to_utf8(), "heap.debug_allocator.DebugAllocator".to_utf8())
expect contains("abc".to_utf8(), [])
expect !contains([], "a".to_utf8())
expect contains("aab".to_utf8(), "ab".to_utf8())
expect Hosts.markers_in([0, 1, 2]) == []
expect Hosts.markers_in("x debug.captureCurrentStackTrace y".to_utf8()) == ["debug.captureCurrentStackTrace"]
expect Hosts.libraries.len() == 4
