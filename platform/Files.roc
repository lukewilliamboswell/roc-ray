## Filesystem reads and writes, and their typed terminal outcomes.
##
## Every effect here waits. It is legal in `init!`, where it blocks startup,
## and in tasks, where it parks the task; it is refused in `update!` and
## `render!`.
##
## ```roc
## update! = |model, input, io| {
##     if input.devices.key_pressed(KeyEnter) {
##         Task.spawn!(input, || SaveLoaded(io.files().read_text!("save.json")))
##     }
##     Ok(model)
## }
## ```
##
## Paths are used as the app gives them, resolved against the process working
## directory. Filesystem access is not sandboxed; `Capture` confines only its
## own outputs.
import Host
import Resource
import Time

Files := [].{

	## One entry returned by `list!`.
	Entry : { name : Str, kind : EntryKind }

	## The filesystem kind relevant to a non-recursive directory walk.
	EntryKind : [File, Dir, Other]

	## Why `read_text!` produced no UTF-8 string.
	##
	## `NotFound` is no file at that path. `TooLarge` is a file past
	## `read_text!`'s 64 kibibyte ceiling, which is a refusal rather than a
	## failure: nothing went wrong and the file is there. `NotUtf8` is a file
	## that was read and is not valid UTF-8, reported rather than delivered as
	## an invalid `Str`. `Busy` is the host's thirty-two file-delivery slots all
	## being held by byte lists an app has retained; nothing was read, and the
	## same call later can succeed. `Unavailable` is the app shutting down
	## while the read was parked.
	##
	## `ReadFailed` is every other refusal, and a permission the process does
	## not have is one of them: the host does not distinguish it from a read
	## that failed for any other reason. `metadata!` does, so a path that may be
	## unreadable can be stat'd first to tell the two apart.
	ReadTextError : [PermissionDenied, NotFound, ReadFailed, Busy, Unavailable, TooLarge, NotUtf8]

	## Why `read_bytes!` produced no byte list.
	##
	## The same tags as `ReadTextError` minus `NotUtf8`, since nothing about
	## the bytes is inspected, and with a much larger ceiling: `TooLarge` here
	## is a file past 16 mebibytes. `ReadFailed` covers a permission denial in
	## exactly the same way.
	ReadBytesError : [PermissionDenied, NotFound, ReadFailed, Busy, Unavailable, TooLarge]

	## Why `list!` produced no directory entries.
	##
	## `NotADirectory` is a path that is there and is a file. `TooLarge` is a
	## directory whose listing would exceed 8192 entries or one mebibyte of
	## encoded names, whichever binds first. The rest mean what they mean for a
	## read, `ReadFailed` included.
	ListError : [PermissionDenied, NotFound, NotADirectory, ReadFailed, Busy, Unavailable, TooLarge]

	## What one path is, how big it is, and when it last changed.
	##
	## `size_bytes` is the file's length; for a directory it is whatever the
	## filesystem reports for the directory itself, which is not the size of
	## what is inside it. `modified` is wall-clock time, so it is comparable
	## with `Time.now!` and with a `modified` this app recorded earlier, and it
	## is not comparable with `input.time`.
	Metadata : { kind : EntryKind, size_bytes : U64, modified : Time.Timestamp }

	## Why `metadata!` could not describe the path.
	##
	## `NotFound` is nothing at that path, including a path a component of
	## which is a file rather than a directory, and a name this filesystem
	## cannot represent. `PermissionDenied` is a directory on the way to the
	## path this process may not look inside -- the one failure a stat can name
	## that a read cannot. `Unavailable` is the app shutting down while the
	## stat was parked, and `ReadFailed` is every other refusal.
	##
	## There is no `Busy`: a stat holds no host-owned payload, so there is no
	## delivery slot for it to run out of.
	MetadataError : [NotFound, PermissionDenied, ReadFailed, Unavailable]

	## Why a write did not leave the file on disk. This is `Files`' own
	## `WriteError`; `Stdout` and `Stderr` declare a different one under the
	## same name, for the different things a stream write can refuse.
	##
	## `NotFound` means a component of the path is a file rather than a
	## directory, or names something that cannot be created; the missing
	## directories a write would otherwise trip over are created for it.
	## `NoSpace` is the filesystem being full or over quota, and `WriteFailed`
	## is every other refusal the host cannot name more precisely.
	WriteError : [NotFound, PermissionDenied, NoSpace, WriteFailed, Unavailable]

	## Opaque files authority supplied by App.Io. Effects return PermissionDenied when external access is disabled.
	Access :: Resource.Authority.{

		## Private platform construction; no application can manufacture the argument.
		for_host : Resource.Authority -> Access
		for_host = |authority| Access.(authority)

		## Read a bounded UTF-8 file into a `Str`.
		##
		## The whole file is copied into the string, so this is capped well below
		## what `read_bytes!` will read: at most 64 kibibytes, and a file past that
		## is `TooLarge` rather than truncated. One that is not valid UTF-8 is
		## `NotUtf8` rather than an invalid `Str`.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		read_text! : Access, Str => Try(Str, ReadTextError)
		read_text! = |Access.(authority), path| perform_read_text!(authority, path)

		## Read a bounded file as ordinary Roc bytes.
		##
		## At most 16 mebibytes, and a file past that is `TooLarge`. The ceiling is
		## far above `read_text!`'s because nothing is copied: the buffer the read
		## filled is the buffer Roc gets.
		##
		## That is also why there is a second bound. The delivered list owns
		## host-backed storage through Roc ARC, and at most 32 such allocations are
		## live at once; a read made while all 32 are held answers `Busy` without
		## touching the disk. Retaining a sublist retains the complete source
		## allocation and so holds a slot, which `List.release_excess_capacity`
		## releases by copying out the part worth keeping.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		read_bytes! : Access, Str => Try(List(U8), ReadBytesError)
		read_bytes! = |Access.(authority), path| perform_read_bytes!(authority, path)

		## List one directory without recursively walking its children.
		##
		## Entry order is the filesystem's observed order and is not sorted.
		## Recursion is the app's to drive: only the app knows which subtrees are
		## worth descending into, and a host-side walk would be one unbounded wait.
		##
		## A listing is bounded at 8192 entries and at one mebibyte of encoded
		## names, whichever binds first; a directory past either is `TooLarge`
		## rather than a partial listing. It is delivered through the same 32
		## file-byte slots a byte read uses, so it can answer `Busy` for the same
		## reason.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		list! : Access, Str => Try(List(Entry), ListError)
		list! = |Access.(authority), path| perform_list!(authority, path)

		## What one path is, how big it is, and when it last changed.
		##
		## Symbolic links are followed, so a link to a file is `File` and a link to
		## nothing is `NotFound`. That differs from `list!`, which reports the kind
		## the directory itself records and so calls a symbolic link `Other`;
		## `metadata!` answers about the thing at the end of the path, which is
		## what an app deciding whether to read it wants to know.
		##
		## Polling `modified` is how an app hot-reloads a shader, a level, or a
		## dataset it did not write. Do it inside a task, and sleep between stats,
		## so the watching costs a parked task rather than a stat every frame:
		##
		## ```roc
		## watch! : Str, Time.Timestamp => Msg
		## watch! = |path, seen| {
		##     var $outcome = Unchanged
		##     while $outcome == Unchanged {
		##         Task.sleep!(250)
		##         $outcome = match io.files().metadata!(path) {
		##             Ok(meta) if meta.modified != seen => Modified(meta.modified)
		##             Ok(_) => Unchanged
		##             Err(NotFound) => Unchanged
		##             Err(other) => Stopped(other)
		##         }
		##     }
		##     match $outcome {
		##         Modified(at) => Changed(path, at)
		##         Stopped(err) => WatchFailed(err)
		##         Unchanged => crash("watch!: the loop only ends once the path changed or the stat failed")
		##     }
		## }
		## ```
		##
		## The loop carries a sentinel tag rather than the message itself, so its
		## `while` condition can compare it, and the `match` after the loop turns
		## that sentinel into the one message the task owes.
		##
		## A loop rather than a recursive call, because a task runs on a
		## fixed-size coroutine stack. `NotFound` keeps waiting rather than giving
		## up: an editor saving a file often replaces it, so the path can be
		## missing for a moment. `update!` spawns the watcher again when it handles
		## `Changed`, and each live watcher holds one of the host's thirty-two task
		## slots for as long as it watches.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		metadata! : Access, Str => Try(Metadata, MetadataError)
		metadata! = |Access.(authority), path| perform_metadata!(authority, path)

		## Replace a file's contents with a `Str`, creating it if it is not there.
		##
		## The write replaces the whole file: there is no append, and no partial
		## write is reported as success. Missing parent directories are created,
		## the same as for every file the host writes itself, so an app's first
		## `io.files().write_text!("saves/slot1.json", ...)` does not need a separate step to
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
		## update! = |model, input, io| {
		##     if input.devices.key_pressed(KeyS) {
		##         Task.spawn!(
		##             input,
		##             || match io.files().write_text!("saves/slot1.json", encode(model)) {
		##                 Ok({}) => Saved
		##                 Err(err) => SaveFailed(err)
		##             },
		##         )
		##     }
		##     Ok(model)
		## }
		## ```
		write_text! : Access, Str, Str => Try({}, WriteError)
		write_text! = |Access.(authority), path, contents| perform_write_text!(authority, path, contents)

		## Replace a file's contents with ordinary Roc bytes.
		##
		## The same path rules, the same whole-file replacement, and the same
		## parent-directory creation as `write_text!`; only the payload differs.
		## Nothing about the bytes is inspected, so this is the call for a PNG, a
		## save blob, or anything else that is not text.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		write_bytes! : Access, Str, List(U8) => Try({}, WriteError)
		write_bytes! = |Access.(authority), path, bytes| perform_write_bytes!(authority, path, bytes)

	}

}

## Re-lift a write's closed error union onto the open one `Files` exposes.
lifted : Try({}, Host.FilesWriteError) -> Try({}, Files.WriteError)
lifted = |result|
	match result {
		Ok({}) => Ok({})
		Err(NoSpace) => Err(NoSpace)
		Err(NotFound) => Err(NotFound)
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(Unavailable) => Err(Unavailable)
		Err(WriteFailed) => Err(WriteFailed)
	}

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

## Private authority-taking implementations.
perform_read_text! : Resource.Authority, Str => Try(Str, Files.ReadTextError)
perform_read_text! = |authority, path|
	match Host.files_read_text!(authority, path) {
		# closed error union to open error union
		Ok(contents) => Ok(contents)
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(Busy) => Err(Busy)
		Err(NotFound) => Err(NotFound)
		Err(NotUtf8) => Err(NotUtf8)
		Err(ReadFailed) => Err(ReadFailed)
		Err(TooLarge) => Err(TooLarge)
		Err(Unavailable) => Err(Unavailable)
	}

perform_read_bytes! : Resource.Authority, Str => Try(List(U8), Files.ReadBytesError)
perform_read_bytes! = |authority, path|
	match Host.files_read_bytes!(authority, path) {
		# closed error union to open error union
		Ok(bytes) => Ok(bytes)
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(Busy) => Err(Busy)
		Err(NotFound) => Err(NotFound)
		Err(ReadFailed) => Err(ReadFailed)
		Err(TooLarge) => Err(TooLarge)
		Err(Unavailable) => Err(Unavailable)
	}

perform_list! : Resource.Authority, Str => Try(List(Files.Entry), Files.ListError)
perform_list! = |authority, path|
	match Host.files_list!(authority, path) {
		# closed error union to open error union
		Ok(bytes) => Ok(decode_listing(bytes))
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(Busy) => Err(Busy)
		Err(NotADirectory) => Err(NotADirectory)
		Err(NotFound) => Err(NotFound)
		Err(ReadFailed) => Err(ReadFailed)
		Err(TooLarge) => Err(TooLarge)
		Err(Unavailable) => Err(Unavailable)
	}

perform_metadata! : Resource.Authority, Str => Try(Files.Metadata, Files.MetadataError)
perform_metadata! = |authority, path|
	match Host.files_metadata!(authority, path) {
		# closed error union to open error union
		Ok(stat) =>
		# The host normalizes the instant before it crosses, so the only
		# way this fails is a host that is wrong about its own contract.
		# Saying so is more use than reporting it as a filesystem error an
		# app could act on.
			match Time.Timestamp.from_parts({ seconds: stat.modified_seconds, nanosecond: stat.modified_nanosecond }) {
				Ok(modified) => Ok({ kind: entry_kind(stat.kind), size_bytes: stat.size_bytes, modified: modified })
				Err(InvalidNanosecond) => crash ("roc-ray: Files.Access.metadata! received a modification time the host had not normalized")
			}
		Err(NotFound) => Err(NotFound)
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(ReadFailed) => Err(ReadFailed)
		Err(Unavailable) => Err(Unavailable)
	}

perform_write_text! : Resource.Authority, Str, Str => Try({}, Files.WriteError)
perform_write_text! = |authority, path, contents| lifted(Host.files_write_text!(authority, path, contents))

perform_write_bytes! : Resource.Authority, Str, List(U8) => Try({}, Files.WriteError)
perform_write_bytes! = |authority, path, bytes| lifted(Host.files_write_bytes!(authority, path, bytes))
