## Filesystem reads and writes, and their typed terminal outcomes.
##
## These effects wait. Every one of them is legal in `init!`, where it blocks
## startup until the answer is in -- which is what loading assets wants -- and
## in tasks, where it parks the task while the frame loop keeps drawing. They
## are refused in `update!` and `render!`, with a message naming the effect and
## the fix.
##
## ```roc
## update! = |model, input| {
##     if input.devices.key_pressed(KeyEnter) {
##         Task.spawn!(input, || SaveLoaded(Files.read_text!("save.json")))
##     }
##     Ok(model)
## }
## ```
##
## Because a task is ordinary straight-line code, a multi-step load is a
## function rather than a state machine spread over `Msg` and `update!`:
##
## ```roc
## load_level! : Str => Msg
## load_level! = |dir| {
##     manifest = Files.read_text!("${dir}/level.json") ? |_e| LevelFailed
##     tiles = Files.read_bytes!("${dir}/tiles.bin") ? |_e| LevelFailed
##     LevelLoaded({ manifest, tiles })
## }
## ```
##
## Paths are used as the app gives them, resolved against the process working
## directory, and nothing here is sandboxed. `Capture` is the one part of this
## platform with an output root, and it confines captures only; see
## `write_text!`.
import FilesHost

Files := [].{

	## One entry returned by `list!`.
	Entry : { name : Str, kind : EntryKind }

	## The filesystem kind relevant to a non-recursive directory walk.
	EntryKind : [File, Dir, Other]

	## Why `read_text!` produced no UTF-8 string.
	ReadTextError : [NotFound, ReadFailed, Busy, Unavailable, TooLarge, NotUtf8]

	## Why `read_bytes!` produced no byte list.
	ReadBytesError : [NotFound, ReadFailed, Busy, Unavailable, TooLarge]

	## Why `list!` produced no directory entries.
	ListError : [NotFound, NotADirectory, ReadFailed, Busy, Unavailable, TooLarge]

	## Why a write did not leave the file on disk.
	##
	## `NotFound` means a component of the path is a file rather than a
	## directory, or names something that cannot be created; the missing
	## directories a write would otherwise trip over are created for it.
	## `NoSpace` is the filesystem being full or over quota, and `WriteFailed`
	## is every other refusal the host cannot name more precisely.
	WriteError : [NotFound, PermissionDenied, NoSpace, WriteFailed, Unavailable]

	## Read a bounded UTF-8 file into a `Str`.
	##
	## The whole file is copied into the string, so this is capped well below
	## what `read_bytes!` will read: a file past the cap is `TooLarge`, and one
	## that is not valid UTF-8 is `NotUtf8` rather than an invalid `Str`.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	read_text! : Str => Try(Str, ReadTextError)
	read_text! = |path| {
		result = FilesHost.read_text!(path)
		if result.err == 0 {
			Ok(result.contents)
		} else {
			Err(read_text_error(result.err))
		}
	}

	## Read a bounded file as ordinary Roc bytes.
	##
	## The delivered list owns host-backed storage through Roc ARC without the
	## payload being copied, so retaining a sublist can retain the complete
	## source allocation. `List.release_excess_capacity` copies out the part
	## worth keeping when that matters.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	read_bytes! : Str => Try(List(U8), ReadBytesError)
	read_bytes! = |path| {
		result = FilesHost.read_bytes!(path)
		if result.err == 0 {
			Ok(result.bytes)
		} else {
			Err(read_bytes_error(result.err))
		}
	}

	## List one directory without recursively walking its children.
	##
	## Entry order is the filesystem's observed order and is not sorted.
	## Recursion is the app's to drive: only the app knows which subtrees are
	## worth descending into, and a host-side walk would be one unbounded wait.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	list! : Str => Try(List(Entry), ListError)
	list! = |path| {
		result = FilesHost.list!(path)
		if result.err == 0 {
			Ok(decode_listing(result.bytes))
		} else {
			Err(list_error(result.err))
		}
	}

	## Replace a file's contents with a `Str`, creating it if it is not there.
	##
	## The write replaces the whole file: there is no append, and no partial
	## write is reported as success. Missing parent directories are created,
	## the same as for every file the host writes itself, so an app's first
	## `write_text!("saves/slot1.json", ...)` does not need a separate step to
	## make `saves/`.
	##
	## The path is used as the app gave it, resolved against the process
	## working directory, exactly as `read_text!` resolves one. `Files` is not
	## sandboxed in either direction: an app that can read `/etc/hosts` can
	## write `/tmp/out.txt`. The one output root this platform enforces belongs
	## to `Capture`, whose paths are computed by recording machinery rather
	## than written out by the app, and it confines captures only.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	##
	## ```roc
	## update! = |model, input| {
	##     if input.devices.key_pressed(KeyS) {
	##         Task.spawn!(
	##             input,
	##             || match Files.write_text!("saves/slot1.json", encode(model)) {
	##                 Ok({}) => Saved
	##                 Err(err) => SaveFailed(err)
	##             },
	##         )
	##     }
	##     Ok(model)
	## }
	## ```
	write_text! : Str, Str => Try({}, WriteError)
	write_text! = |path, contents| write_result(FilesHost.write_text!(path, contents))

	## Replace a file's contents with ordinary Roc bytes.
	##
	## The same path rules, the same whole-file replacement, and the same
	## parent-directory creation as `write_text!`; only the payload differs.
	## Nothing about the bytes is inspected, so this is the call for a PNG, a
	## save blob, or anything else that is not text.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	write_bytes! : Str, List(U8) => Try({}, WriteError)
	write_bytes! = |path, bytes| write_result(FilesHost.write_bytes!(path, bytes))

}

## Error code for work the host would not start. Mirrored in
## `src/host_native.zig`.
read_err_busy : U8
read_err_busy = 3

## Error code for content the host declined to copy into a `Str`.
## Mirrored in `src/host_native.zig`.
read_err_too_large : U8
read_err_too_large = 5

## Error code for bytes that cannot become a `Str`. Mirrored in
## `src/host_native.zig`.
read_err_not_utf8 : U8
read_err_not_utf8 = 6

## The host refused to list the path because it is not a directory. Mirrored in
## `src/host_native.zig`.
read_err_not_a_directory : U8
read_err_not_a_directory = 7

## Decode the host's read-error code for a byte-list read. Mirrored in
## `src/host_native.zig`.
read_bytes_error : U8 -> Files.ReadBytesError
read_bytes_error = |code|
	if code == 1 {
		NotFound
	} else if code == read_err_busy {
		Busy
	} else if code == 4 {
		Unavailable
	} else if code == read_err_too_large {
		TooLarge
	} else {
		ReadFailed
	}

expect read_bytes_error(1) == NotFound
expect read_bytes_error(2) == ReadFailed
expect read_bytes_error(3) == Busy
expect read_bytes_error(4) == Unavailable
expect read_bytes_error(5) == TooLarge
expect read_bytes_error(99) == ReadFailed

## Decode the host's read-error code for a string-delivered read.
##
## The same codes plus one, rather than a second table: the two reads fail for
## the same reasons and only differ in what they were asked to produce.
read_text_error : U8 -> Files.ReadTextError
read_text_error = |code|
	if code == read_err_not_utf8 {
		NotUtf8
	} else {
		match read_bytes_error(code) {
			NotFound => NotFound
			Busy => Busy
			Unavailable => Unavailable
			TooLarge => TooLarge
			ReadFailed => ReadFailed
		}
	}

expect read_text_error(6) == NotUtf8
expect read_text_error(1) == NotFound
expect read_text_error(5) == TooLarge

## Decode the host's listing-error code. Mirrored in `src/host_native.zig`.
list_error : U8 -> Files.ListError
list_error = |code|
	if code == 1 {
		NotFound
	} else if code == read_err_busy {
		Busy
	} else if code == 4 {
		Unavailable
	} else if code == read_err_too_large {
		TooLarge
	} else if code == read_err_not_a_directory {
		NotADirectory
	} else {
		ReadFailed
	}

expect list_error(1) == NotFound
expect list_error(7) == NotADirectory
expect list_error(2) == ReadFailed

## The host refused the write because the path is not the app's to write.
## Mirrored in `src/host_native.zig`.
write_err_permission_denied : U8
write_err_permission_denied = 8

## The filesystem has no room for the file. Mirrored in
## `src/host_native.zig`.
write_err_no_space : U8
write_err_no_space = 9

## Turn a write's error code into its terminal outcome.
##
## The codes a write shares with a read -- `NotFound`, `Unavailable`, and the
## generic failure -- are numbered the same as the read table's, so one code
## never means two things across the boundary. The two a read cannot produce
## are numbered past it.
write_result : U8 -> Try({}, Files.WriteError)
write_result = |code|
	if code == 0 {
		Ok({})
	} else {
		Err(write_error(code))
	}

write_error : U8 -> Files.WriteError
write_error = |code|
	if code == 1 {
		NotFound
	} else if code == 4 {
		Unavailable
	} else if code == write_err_permission_denied {
		PermissionDenied
	} else if code == write_err_no_space {
		NoSpace
	} else {
		WriteFailed
	}

expect write_result(0) == Ok({})
expect write_result(1) == Err(NotFound)
expect write_error(1) == NotFound
expect write_error(2) == WriteFailed
expect write_error(4) == Unavailable
expect write_error(8) == PermissionDenied
expect write_error(9) == NoSpace
expect write_error(99) == WriteFailed

## Decode a listing's bytes into entries.
##
## The encoding is one entry after another, each a kind byte, the entry's name,
## and a NUL. A name cannot contain a NUL on any platform the host runs on, so
## the terminator is unambiguous and the whole listing is one host allocation
## that reached Roc without being copied.
##
## Truncated input -- a kind byte with no terminator after it -- ends the
## listing rather than being guessed at. The host writes the terminator, so
## that cannot happen; answering with the entries that were whole is what keeps
## this total.
decode_listing : List(U8) -> List(Files.Entry)
decode_listing = |bytes| decode_entries(bytes, 0, [])

decode_entries : List(U8), U64, List(Files.Entry) -> List(Files.Entry)
decode_entries = |bytes, at, found|
	if at >= List.len(bytes) {
		found
	} else {
		match List.get(bytes, at) {
			Err(_) => found
			Ok(code) =>
				match index_of_nul(bytes, at + 1) {
					Err(_) => found
					Ok(end) =>
						decode_entries(
							bytes,
							end + 1,
							List.append(found, { name: entry_name(bytes, at + 1, end), kind: entry_kind(code) }),
						)
					}
			}
	}

## Copy one entry's name out of the listing.
##
## The copy is the point. A sublist of a host-delivered list is a seamless view
## onto the host's buffer, so a name retained that way would pin the whole
## listing for as long as the app held it. `release_excess_capacity` gives the
## name storage of its own -- and it has to happen before `from_utf8_lossy`,
## which may share the storage it is given.
entry_name : List(U8), U64, U64 -> Str
entry_name = |bytes, start, end|
	Str.from_utf8_lossy(List.release_excess_capacity(List.sublist(bytes, { start: start, len: end - start })))

## Entry kinds in an encoded listing. Mirrored in `src/host_native.zig`.
dir_entry_file : U8
dir_entry_file = 1

dir_entry_dir : U8
dir_entry_dir = 2

entry_kind : U8 -> Files.EntryKind
entry_kind = |code|
	if code == dir_entry_file {
		File
	} else if code == dir_entry_dir {
		Dir
	} else {
		Other
	}

index_of_nul : List(U8), U64 -> Try(U64, [NotFound])
index_of_nul = |bytes, at|
	match List.get(bytes, at) {
		Err(_) => Err(NotFound)
		Ok(byte) =>
			if byte == 0 {
				Ok(at)
			} else {
				index_of_nul(bytes, at + 1)
			}
		}

expect decode_listing([]) == []
expect decode_listing([1, 'a', 0]) == [{ name: "a", kind: File }]
expect decode_listing([2, 's', 'r', 'c', 0, 1, 'a', '.', 't', 0]) == [
	{ name: "src", kind: Dir },
	{ name: "a.t", kind: File },
]

## A kind byte with no terminator after it ends the listing rather than being
## guessed at, so a truncated buffer still yields the entries that were whole.
expect decode_listing([1, 'a', 0, 2, 'b']) == [{ name: "a", kind: File }]
