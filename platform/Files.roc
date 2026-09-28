## Files beneath directory handles, and their typed terminal outcomes.
##
## An app never names a file by an ambient path. It asks `io.files()` for a
## directory handle and names files relative to it:
##
## ```roc
## init! = App.init(
##     App.default.with_app_id("dev.example.notes"),
##     |io| {
##         saves = io.files().app_data!()?
##         Ok({ saves: saves })
##     },
## )
##
## update! = |model, input, _io| {
##     if input.devices.key_pressed(KeyS) {
##         saves = model.saves
##         Task.spawn!(input, || Saved(saves.write_text!("slot1.json", encode(model))))
##     }
##     Ok(model)
## }
## ```
##
## Where a handle can come from:
##
## - `app_data!`, `app_config!`, `app_cache!`: the app's private storage under
##   the user's home, created on first use. Needs `App.Config.with_app_id`.
## - `beside_executable!`: the directory the executable is in, read-only -- the
##   app's own bundle.
## - `working_directory!` and `working_directory_read!`: the launch directory,
##   when the app declares `WorkingDirectory`.
## - `open_dir!` and `open_dir_read!`: a directory a `Directory`,
##   `WorkingDirectory`, or `FilesAny` declaration covers.
## - `accept_drop!` and `from_arg!`: a file or directory the user dropped on
##   the window or named as an argument, as a `Designated` item.
##
## A `Dir` can write; a `ReadDir` cannot, and `Dir.read_only` narrows one to
## the other. `subdir` narrows either to a directory beneath it. A handle is an
## ordinary value: keep it in the model, pass it to a helper, capture it in a
## task. Whoever holds it can reach what is beneath it and nothing else.
##
## A path given to a handle is plainly relative: no leading `/`, no drive, no
## backslash, and no empty, `.`, or `..` component. Symbolic links beneath a
## handle are not followed, and an existing link where a write would land is
## not written through.
##
## Two errors say why a target was refused, and they mean different things:
##
## - `PathInvalid`: the path's shape, or a link it meets, is refused. The rule
##   is the same wherever the path would have led, so fix the path.
## - `PermissionDenied`: no grant covers the target. That is a directory no
##   declaration covers, a stub handle, a drop that is not from this cycle, or
##   a string that is not one of the app's arguments. Declare more, or ask
##   the user to choose the item.
##
## Every effect here waits except `subdir`, `read_only`, `dir`,
## `accept_drop!` and `from_arg!`, which open nothing. A
## waiting effect is legal in `init!`, where it blocks startup, and in tasks,
## where it parks the task; it is refused in `update!` and `render!`.
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
	## `PathInvalid` is a path that is not plainly relative, or that meets a
	## symbolic link. `PermissionDenied` is a stub handle, which reaches
	## nothing. `NotFound` is no file at that path. `TooLarge` is a file past
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
	ReadTextError : [PermissionDenied, PathInvalid, NotFound, ReadFailed, Busy, Unavailable, TooLarge, NotUtf8]

	## Why `read_bytes!` produced no byte list.
	##
	## The same tags as `ReadTextError` minus `NotUtf8`, since nothing about
	## the bytes is inspected, and with a much larger ceiling: `TooLarge` here
	## is a file past 16 mebibytes. `ReadFailed` covers a permission denial in
	## exactly the same way.
	ReadBytesError : [PermissionDenied, PathInvalid, NotFound, ReadFailed, Busy, Unavailable, TooLarge]

	## Why `list!` produced no directory entries.
	##
	## `NotADirectory` is a path that is there and is a file. `TooLarge` is a
	## directory whose listing would exceed 8192 entries or one mebibyte of
	## encoded names, whichever binds first. The rest mean what they mean for a
	## read, `ReadFailed` included.
	ListError : [PermissionDenied, PathInvalid, NotFound, NotADirectory, ReadFailed, Busy, Unavailable, TooLarge]

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
	## cannot represent. `AccessRefused` is a directory on the way to the path
	## this process may not look inside -- the one failure a stat can name that
	## a read cannot. `PathInvalid` and `PermissionDenied` mean what they mean
	## for a read, except that a link at the end of the path is described as
	## `Other` rather than refused. `Unavailable` is the app shutting down while the stat was
	## parked, and `ReadFailed` is every other refusal.
	##
	## There is no `Busy`: a stat holds no host-owned payload, so there is no
	## delivery slot for it to run out of.
	MetadataError : [NotFound, AccessRefused, PathInvalid, PermissionDenied, ReadFailed, Unavailable]

	## Why a write did not leave the file on disk. This is `Files`' own
	## `WriteError`; `Stdout` and `Stderr` declare a different one under the
	## same name, for the different things a stream write can refuse.
	##
	## `NotFound` means a component of the path is a file rather than a
	## directory, or names something that cannot be created; the missing
	## directories a write would otherwise trip over are created for it.
	## `NoSpace` is the filesystem being full or over quota. `AccessRefused` is
	## the operating system refusing the write, such as a read-only file or
	## filesystem. `PathInvalid` is a path that is not plainly relative, one
	## that meets a symbolic link, or an existing symbolic link at the path
	## itself. `PermissionDenied` is a stub handle. `WriteFailed` is every
	## other refusal the host cannot name more precisely.
	WriteError : [NotFound, AccessRefused, PathInvalid, PermissionDenied, NoSpace, WriteFailed, Unavailable]

	## Why a directory handle could not be opened.
	##
	## `PermissionDenied` is a directory no declaration covers. `PathInvalid`
	## is a declared path with a `..` component, which only `FilesAny` can
	## cover; only `open_dir!` and `open_dir_read!` answer it. `NotFound` is
	## a read-only directory that is not there -- a writable one is created --
	## and `NotADirectory` is a path that is there and is a file.
	## `AccessRefused` is the operating system refusing to open it, and
	## `OpenFailed` is every other refusal. `Unavailable` is the app shutting
	## down while the open was parked.
	OpenError : [PermissionDenied, PathInvalid, NotFound, NotADirectory, AccessRefused, OpenFailed, Unavailable]

	## Why a path given to `subdir` is not one a handle accepts: it is empty,
	## absolute, or has a backslash, a drive, a NUL, or an empty, `.`, or `..`
	## component.
	PathInvalid : [PathInvalid]

	## A directory the app may read beneath, and nothing else.
	##
	## Get one from `io.files()`, from `Dir.read_only`, or from `subdir`.
	ReadDir :: { authority : Resource.Authority, root : Str, prefix : Str }.{

		## Resource-free handle for pure tests. Every effect through it is
		## `PermissionDenied`.
		stub : ReadDir
		stub = ReadDir.(stub_handle)

		## The directory `path` names beneath this one. Pure: nothing is
		## opened, and a directory that is not there is found out on first use.
		subdir : ReadDir, Str -> Try(ReadDir, [PathInvalid])
		subdir = |ReadDir.(handle), path| Ok(ReadDir.(beneath(handle, path)?))

		## Read a bounded UTF-8 file into a `Str`: at most 64 kibibytes, and a
		## file past that is `TooLarge` rather than truncated. One that is not
		## valid UTF-8 is `NotUtf8` rather than an invalid `Str`.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		read_text! : ReadDir, Str => Try(Str, ReadTextError)
		read_text! = |ReadDir.(handle), path| perform_read_text!(handle, path)

		## Read a bounded file as ordinary Roc bytes: at most 16 mebibytes, and
		## a file past that is `TooLarge`.
		##
		## Nothing is copied, so the list owns host-backed storage; at most 32
		## such allocations are live at once, and a read made while all 32 are
		## held answers `Busy` without touching the disk. Retaining a sublist
		## retains the whole allocation, which `List.release_excess_capacity`
		## releases by copying out the part worth keeping.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		read_bytes! : ReadDir, Str => Try(List(U8), ReadBytesError)
		read_bytes! = |ReadDir.(handle), path| perform_read_bytes!(handle, path)

		## List one directory without walking its children; `""` lists this
		## handle's own directory. Entry order is the filesystem's, unsorted.
		## A listing is bounded at 8192 entries and one mebibyte of encoded
		## names, and a directory past either is `TooLarge`.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		list! : ReadDir, Str => Try(List(Entry), ListError)
		list! = |ReadDir.(handle), path| perform_list!(handle, path)

		## What one path is, how big it is, and when it last changed; `""` is
		## this handle's own directory. A symbolic link is reported as `Other`
		## rather than followed.
		##
		## Polling `modified` from a task, sleeping between stats, is how an app
		## hot-reloads a shader, a level, or a dataset it did not write.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		metadata! : ReadDir, Str => Try(Metadata, MetadataError)
		metadata! = |ReadDir.(handle), path| perform_metadata!(handle, path)

		## Internal bridge for platform operations that open things beneath a
		## handle, such as an asset store or a database.
		for_host : ReadDir -> { authority : Resource.Authority, root : Str, path : Str }
		for_host = |ReadDir.(handle)| { authority: handle.authority, root: handle.root, path: handle.prefix }
	}

	## A directory the app may read and write beneath, and nothing else.
	##
	## Get one from `io.files()` or from `subdir`.
	Dir :: { authority : Resource.Authority, root : Str, prefix : Str }.{

		## Resource-free handle for pure tests. Every effect through it is
		## `PermissionDenied`.
		stub : Dir
		stub = Dir.(stub_handle)

		## The same directory, without the right to write.
		read_only : Dir -> ReadDir
		read_only = |Dir.(handle)| ReadDir.(handle)

		## The directory `path` names beneath this one. Pure, as for `ReadDir`;
		## a missing directory is created by the first write into it.
		subdir : Dir, Str -> Try(Dir, [PathInvalid])
		subdir = |Dir.(handle), path| Ok(Dir.(beneath(handle, path)?))

		## As `ReadDir.read_text!`.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		read_text! : Dir, Str => Try(Str, ReadTextError)
		read_text! = |Dir.(handle), path| perform_read_text!(handle, path)

		## As `ReadDir.read_bytes!`.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		read_bytes! : Dir, Str => Try(List(U8), ReadBytesError)
		read_bytes! = |Dir.(handle), path| perform_read_bytes!(handle, path)

		## As `ReadDir.list!`.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		list! : Dir, Str => Try(List(Entry), ListError)
		list! = |Dir.(handle), path| perform_list!(handle, path)

		## As `ReadDir.metadata!`.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		metadata! : Dir, Str => Try(Metadata, MetadataError)
		metadata! = |Dir.(handle), path| perform_metadata!(handle, path)

		## Replace a file's contents with a `Str`, creating it and any missing
		## directories on the way. The write replaces the whole file: there is
		## no append, and no partial write is reported as success. An existing
		## symbolic link at the path is refused rather than written through.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		write_text! : Dir, Str, Str => Try({}, WriteError)
		write_text! = |Dir.(handle), path, contents| perform_write_text!(handle, path, contents)

		## Replace a file's contents with ordinary Roc bytes, exactly as
		## `write_text!` does with a string.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		write_bytes! : Dir, Str, List(U8) => Try({}, WriteError)
		write_bytes! = |Dir.(handle), path, bytes| perform_write_bytes!(handle, path, bytes)

		## Internal bridge for platform operations that open things beneath a
		## handle, such as a database.
		for_host : Dir -> { authority : Resource.Authority, root : Str, path : Str }
		for_host = |Dir.(handle)| { authority: handle.authority, root: handle.root, path: handle.prefix }
	}

	## One file or directory the user chose for the app: dropped on its window,
	## or named as an argument when it was launched. The choosing is the
	## granting, so no permission is declared, and the handle reaches exactly
	## that item and nothing beside it.
	##
	## Read it as a file with `read_text!`, `read_bytes!`, and `metadata!`, or,
	## when it is a directory, reach beneath it with `dir`.
	Designated :: { authority : Resource.Authority, path : Str, parent : Str, name : Str }.{

		## Resource-free handle for pure tests. Every effect through it is
		## `PermissionDenied`.
		stub : Designated
		stub = Designated.({ authority: Resource.Authority.stub, path: "", parent: "", name: "" })

		## The absolute path that was designated, for showing to the user.
		path : Designated -> Str
		path = |Designated.(item)| item.path

		## Read the designated file into a `Str`, as `ReadDir.read_text!` does.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		read_text! : Designated => Try(Str, ReadTextError)
		read_text! = |Designated.(item)| perform_read_text!(parent_handle(item), item.name)

		## Read the designated file as bytes, as `ReadDir.read_bytes!` does.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		read_bytes! : Designated => Try(List(U8), ReadBytesError)
		read_bytes! = |Designated.(item)| perform_read_bytes!(parent_handle(item), item.name)

		## What the designated item is, how big it is, and when it last changed.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		metadata! : Designated => Try(Metadata, MetadataError)
		metadata! = |Designated.(item)| perform_metadata!(parent_handle(item), item.name)

		## The designated item as a directory, when it is one. Pure; an item that
		## is not a directory is found out on first use.
		dir : Designated -> ReadDir
		dir = |Designated.(item)| ReadDir.({ authority: item.authority, root: item.path, prefix: "" })
	}

	## Opaque filesystem authority supplied by App.Io: where directory handles
	## come from.
	Access :: Resource.Authority.{

		## Private platform construction; no application can manufacture the argument.
		for_host : Resource.Authority -> Access
		for_host = |authority| Access.(authority)

		## The app's private data directory, created on first use: saves,
		## databases, anything the app keeps for itself. Needs
		## `App.Config.with_app_id`; without one the app stops, naming it.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		app_data! : Access => Try(Dir, [PermissionDenied, PathInvalid, NotFound, NotADirectory, AccessRefused, OpenFailed, Unavailable])
		app_data! = |Access.(authority)| open_root!(authority, AppData, Bool.True) |> map_dir

		## The app's private configuration directory, created on first use.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		app_config! : Access => Try(Dir, [PermissionDenied, PathInvalid, NotFound, NotADirectory, AccessRefused, OpenFailed, Unavailable])
		app_config! = |Access.(authority)| open_root!(authority, AppConfig, Bool.True) |> map_dir

		## The app's private cache directory, created on first use: files it
		## can recreate if the user clears it.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		app_cache! : Access => Try(Dir, [PermissionDenied, PathInvalid, NotFound, NotADirectory, AccessRefused, OpenFailed, Unavailable])
		app_cache! = |Access.(authority)| open_root!(authority, AppCache, Bool.True) |> map_dir

		## The directory the executable is in, read-only: the app's own bundle.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		beside_executable! : Access => Try(ReadDir, [PermissionDenied, PathInvalid, NotFound, NotADirectory, AccessRefused, OpenFailed, Unavailable])
		beside_executable! = |Access.(authority)| open_root!(authority, BesideExecutable, Bool.False) |> map_read_dir

		## The launch directory, writable. Needs `WorkingDirectory(ReadWrite)`.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		working_directory! : Access => Try(Dir, [PermissionDenied, PathInvalid, NotFound, NotADirectory, AccessRefused, OpenFailed, Unavailable])
		working_directory! = |Access.(authority)| open_root!(authority, WorkingDirectory, Bool.True) |> map_dir

		## The launch directory, read-only. Needs `WorkingDirectory` in either
		## mode.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		working_directory_read! : Access => Try(ReadDir, [PermissionDenied, PathInvalid, NotFound, NotADirectory, AccessRefused, OpenFailed, Unavailable])
		working_directory_read! = |Access.(authority)| open_root!(authority, WorkingDirectory, Bool.False) |> map_read_dir

		## A declared directory, writable. A directory that is not there is
		## created, with any missing parents, so the first run of an app finds
		## an empty directory rather than `NotFound`.
		##
		## An absolute path names the directory directly; a relative one is
		## opened beneath the working directory. Whether a declaration covers
		## the path is decided from its text, not by asking the filesystem:
		##
		## - `Directory(dir, ReadWrite)` covers `dir` and every path beneath it
		##   written the same way: an absolute declaration covers absolute
		##   paths, a relative one covers relative paths.
		## - `WorkingDirectory(ReadWrite)` covers every relative path.
		## - `FilesAny(ReadWrite)` covers every path.
		##
		## A path no declaration covers is `PermissionDenied`. A path with a
		## `..` component is `PathInvalid` unless `FilesAny` covers it, because
		## its text alone does not say where it leads. The directory the path
		## names is the grant, however the filesystem spells it, so links on the
		## way to it are followed; links beneath the handle never are.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		open_dir! : Access, Str => Try(Dir, [PermissionDenied, PathInvalid, NotFound, NotADirectory, AccessRefused, OpenFailed, Unavailable])
		open_dir! = |Access.(authority), path| open_root!(authority, Declared(path), Bool.True) |> map_dir

		## Accept a file or directory the user dropped on the window, from the
		## `update!` whose `input.dropped` delivered it.
		##
		## ```roc
		## update! = |model, input, io| {
		##     for drop in input.dropped {
		##         match io.files().accept_drop!(drop.path) {
		##             Ok(item) => Task.spawn!(input, || Opened(item.path(), item.read_bytes!()))
		##             Err(PermissionDenied) => {}
		##         }
		##     }
		##     Ok(model)
		## }
		## ```
		##
		## Only a path the host delivered this cycle is accepted; a string made
		## up, or kept from an earlier cycle, is `PermissionDenied`. Nothing is
		## opened, so it is legal wherever a drop can be seen.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		accept_drop! : Access, Str => Try(Designated, [PermissionDenied])
		accept_drop! = |Access.(authority), path| designate!(authority, Drop(path))

		## Accept a file or directory named as an application argument, such
		## as `my-tool data.csv`. The operator naming it is the grant.
		##
		## Only a string byte-identical to one of the app's arguments (what
		## `io.args!()` returns in `init!`) is accepted, and the item is
		## read-only. Anything else is `PermissionDenied`: the operator did not
		## name it. A relative argument names an item beneath the directory the
		## app was launched in, fixed when it is accepted. Legal in `init!`,
		## `update!`, and tasks; refused in `render!`.
		from_arg! : Access, Str => Try(Designated, [PermissionDenied])
		from_arg! = |Access.(authority), arg| designate!(authority, Arg(arg))

		## A declared directory, read-only, covered by a declaration in either
		## mode. Coverage is decided as for `open_dir!`, but nothing is created:
		## a directory that is not there is `NotFound`.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it parks
		## the task; refused in `update!` and `render!`.
		open_dir_read! : Access, Str => Try(ReadDir, [PermissionDenied, PathInvalid, NotFound, NotADirectory, AccessRefused, OpenFailed, Unavailable])
		open_dir_read! = |Access.(authority), path| open_root!(authority, Declared(path), Bool.False) |> map_read_dir
	}

}

## A handle's root, as the host resolved it, and the relative path of the
## directory it names beneath that root. The root is where every operation
## starts walking, so a `subdir` can never be reached through a link.
Handle : { authority : Resource.Authority, root : Str, prefix : Str }

stub_handle : Handle
stub_handle = { authority: Resource.Authority.stub, root: "", prefix: "" }

## Join a validated relative path onto a handle's prefix.
beneath : Handle, Str -> Try(Handle, [PathInvalid])
beneath = |handle, path|
	if is_safe_relative(path) {
		Ok({ ..handle, prefix: joined(handle.prefix, path) })
	} else {
		Err(PathInvalid)
	}

joined : Str, Str -> Str
joined = |prefix, path|
	if prefix == "" {
		path
	} else if path == "" {
		prefix
	} else {
		"${prefix}/${path}"
	}

## Mirrors `isSafeRelative` in `src/confined_path.zig`, which the host checks
## again on every use.
is_safe_relative : Str -> Bool
is_safe_relative = |path|
	if path == "" or Str.starts_with(path, "/") or Str.contains(path, "\\") or Str.contains(path, ":") or Str.contains(path, "\u(0)") {
		Bool.False
	} else {
		Str.split_on(path, "/").all(|part| part != "" and part != "." and part != "..")
	}

expect is_safe_relative("saves/slot1.json")
expect !is_safe_relative("../up")
expect !is_safe_relative("a/./b")
expect !is_safe_relative("/etc")
expect !is_safe_relative("a//b")
expect !is_safe_relative("")
expect !is_safe_relative("C:x")
expect joined("", "a") == "a"
expect joined("a", "") == "a"
expect joined("a", "b/c") == "a/b/c"

designate! : Resource.Authority, Host.FilesDesignation => Try(Files.Designated, [PermissionDenied])
designate! = |authority, source|
	match Host.files_designate!(authority, source) {
		Ok(item) => Ok(Files.Designated.({ authority, path: item.path, parent: item.parent, name: item.name }))
		Err(PermissionDenied) => Err(PermissionDenied)
	}

parent_handle : { authority : Resource.Authority, path : Str, parent : Str, name : Str } -> Handle
parent_handle = |item| { authority: item.authority, root: item.parent, prefix: "" }

open_root! : Resource.Authority, Host.FilesRoot, Bool => Try(Handle, [PermissionDenied, PathInvalid, NotFound, NotADirectory, AccessRefused, OpenFailed, Unavailable])
open_root! = |authority, root, writable|
	match Host.files_open_root!(authority, root, writable) {
		Ok(path) => Ok({ authority, root: path, prefix: "" })
		Err(AccessRefused) => Err(AccessRefused)
		Err(NotADirectory) => Err(NotADirectory)
		Err(NotFound) => Err(NotFound)
		Err(OpenFailed) => Err(OpenFailed)
		Err(PathInvalid) => Err(PathInvalid)
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(Unavailable) => Err(Unavailable)
	}

map_dir : Try(Handle, err) -> Try(Files.Dir, err)
map_dir = |result| result.map_ok(|handle| Files.Dir.(handle))

map_read_dir : Try(Handle, err) -> Try(Files.ReadDir, err)
map_read_dir = |result| result.map_ok(|handle| Files.ReadDir.(handle))

## Re-lift a write's closed error union onto the open one `Files` exposes.
lifted : Try({}, Host.FilesWriteError) -> Try({}, Files.WriteError)
lifted = |result|
	match result {
		Ok({}) => Ok({})
		Err(NoSpace) => Err(NoSpace)
		Err(NotFound) => Err(NotFound)
		Err(AccessRefused) => Err(AccessRefused)
		Err(PathInvalid) => Err(PathInvalid)
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

## Private handle-taking implementations. Each passes the handle's root and
## the path beneath it; the host checks the path again and walks it without
## following a link.
perform_read_text! : Handle, Str => Try(Str, Files.ReadTextError)
perform_read_text! = |handle, path|
	match Host.files_read_text!(handle.authority, handle.root, joined(handle.prefix, path)) {
		# closed error union to open error union
		Ok(contents) => Ok(contents)
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(PathInvalid) => Err(PathInvalid)
		Err(Busy) => Err(Busy)
		Err(NotFound) => Err(NotFound)
		Err(NotUtf8) => Err(NotUtf8)
		Err(ReadFailed) => Err(ReadFailed)
		Err(TooLarge) => Err(TooLarge)
		Err(Unavailable) => Err(Unavailable)
	}

perform_read_bytes! : Handle, Str => Try(List(U8), Files.ReadBytesError)
perform_read_bytes! = |handle, path|
	match Host.files_read_bytes!(handle.authority, handle.root, joined(handle.prefix, path)) {
		# closed error union to open error union
		Ok(bytes) => Ok(bytes)
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(PathInvalid) => Err(PathInvalid)
		Err(Busy) => Err(Busy)
		Err(NotFound) => Err(NotFound)
		Err(ReadFailed) => Err(ReadFailed)
		Err(TooLarge) => Err(TooLarge)
		Err(Unavailable) => Err(Unavailable)
	}

perform_list! : Handle, Str => Try(List(Files.Entry), Files.ListError)
perform_list! = |handle, path|
	match Host.files_list!(handle.authority, handle.root, joined(handle.prefix, path)) {
		# closed error union to open error union
		Ok(bytes) => Ok(decode_listing(bytes))
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(PathInvalid) => Err(PathInvalid)
		Err(Busy) => Err(Busy)
		Err(NotADirectory) => Err(NotADirectory)
		Err(NotFound) => Err(NotFound)
		Err(ReadFailed) => Err(ReadFailed)
		Err(TooLarge) => Err(TooLarge)
		Err(Unavailable) => Err(Unavailable)
	}

perform_metadata! : Handle, Str => Try(Files.Metadata, Files.MetadataError)
perform_metadata! = |handle, path|
	match Host.files_metadata!(handle.authority, handle.root, joined(handle.prefix, path)) {
		# closed error union to open error union
		Ok(stat) =>
		# The host normalizes the instant before it crosses, so the only
		# way this fails is a host that is wrong about its own contract.
		# Saying so is more use than reporting it as a filesystem error an
		# app could act on.
			match Time.Timestamp.from_parts({ seconds: stat.modified_seconds, nanosecond: stat.modified_nanosecond }) {
				Ok(modified) => Ok({ kind: entry_kind(stat.kind), size_bytes: stat.size_bytes, modified: modified })
				Err(InvalidNanosecond) => crash ("roc-ray: Files metadata! received a modification time the host had not normalized")
			}
		Err(NotFound) => Err(NotFound)
		Err(AccessRefused) => Err(AccessRefused)
		Err(PathInvalid) => Err(PathInvalid)
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(ReadFailed) => Err(ReadFailed)
		Err(Unavailable) => Err(Unavailable)
	}

perform_write_text! : Handle, Str, Str => Try({}, Files.WriteError)
perform_write_text! = |handle, path, contents| lifted(Host.files_write_text!(handle.authority, handle.root, joined(handle.prefix, path), contents))

perform_write_bytes! : Handle, Str, List(U8) => Try({}, Files.WriteError)
perform_write_bytes! = |handle, path, bytes| lifted(Host.files_write_bytes!(handle.authority, handle.root, joined(handle.prefix, path), bytes))
