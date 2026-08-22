## Filesystem reads and their typed terminal outcomes.
##
## These effects wait. Inside `Task.spawn!` they park the task on the host's
## event loop and the frame loop keeps drawing; in `init!` they block until the
## answer is in, which is what loading assets at startup wants. Calling one from
## `update!` or `render!` is a programmer error and stops the app with a message
## naming the effect and the fix.
##
##     update! = |model, input| {
##         if input.devices.key_pressed(KeyEnter) {
##             Task.spawn!(input, || SaveLoaded(Files.read_text!("save.json")))
##         }
##         Ok(model)
##     }
##
## Because a task is ordinary straight-line code, a multi-step load is a
## function rather than a state machine spread over `Msg` and `update!`:
##
##     load_level! : Str => Msg
##     load_level! = |dir| {
##         manifest = Files.read_text!("${dir}/level.json") ? |_e| LevelFailed
##         tiles = Files.read_bytes!("${dir}/tiles.bin") ? |_e| LevelFailed
##         LevelLoaded({ manifest, tiles })
##     }
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

	## Read a bounded UTF-8 file into a `Str`.
	##
	## The whole file is copied into the string, so this is capped well below
	## what `read_bytes!` will read: a file past the cap is `TooLarge`, and one
	## that is not valid UTF-8 is `NotUtf8` rather than an invalid `Str`.
	##
	## Valid inside a task, where it parks the coroutine, and inside `init!`,
	## where it blocks. Calling it from `update!` or `render!` is a programmer
	## error and stops the app.
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
	## Valid inside a task, where it parks the coroutine, and inside `init!`,
	## where it blocks. Calling it from `update!` or `render!` is a programmer
	## error and stops the app.
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
	## Valid inside a task, where it parks the coroutine, and inside `init!`,
	## where it blocks. Calling it from `update!` or `render!` is a programmer
	## error and stops the app.
	list! : Str => Try(List(Entry), ListError)
	list! = |path| {
		result = FilesHost.list!(path)
		if result.err == 0 {
			Ok(decode_listing(result.bytes))
		} else {
			Err(list_error(result.err))
		}
	}

	## Read a bounded UTF-8 file and map its terminal result into an app message.
	read_text : Str, (Try(Str, ReadTextError) -> msg) -> [ReadText({ path : Str, callback : Try(Str, ReadTextError) -> msg }), ..]
	read_text = |path, callback| ReadText({ path, callback })

	## Read a bounded file as ordinary Roc bytes and map its terminal result.
	## The delivered list owns host-backed storage through Roc ARC; retaining a
	## sublist can retain the complete source allocation.
	read_bytes : Str, (Try(List(U8), ReadBytesError) -> msg) -> [ReadBytes({ path : Str, callback : Try(List(U8), ReadBytesError) -> msg }), ..]
	read_bytes = |path, callback| ReadBytes({ path, callback })

	## List one directory without recursively walking its children.
	## Entry order is the filesystem's observed order and is not sorted.
	list : Str, (Try(List(Entry), ListError) -> msg) -> [ListDirectory({ path : Str, callback : Try(List(Entry), ListError) -> msg }), ..]
	list = |path, callback| ListDirectory({ path, callback })
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
