## Finite filesystem requests and their typed terminal outcomes.
Files := [].{

	## One entry returned by `list`.
	Entry : { name : Str, kind : EntryKind }

	## The filesystem kind relevant to a non-recursive directory walk.
	EntryKind : [File, Dir, Other]

	## Why `read_text` produced no UTF-8 string.
	ReadTextError : [NotFound, ReadFailed, Busy, Unavailable, TooLarge, NotUtf8]

	## Why `read_bytes` produced no byte list.
	ReadBytesError : [NotFound, ReadFailed, Busy, Unavailable, TooLarge]

	## Why `list` produced no directory entries.
	ListError : [NotFound, NotADirectory, ReadFailed, Busy, Unavailable, TooLarge]

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
