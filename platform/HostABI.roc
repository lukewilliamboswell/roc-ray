## Private structural transport between Roc platform adapters and the native
## host.
##
## This module is the single catalogue of native hosted functions and the wire
## values they exchange. It is deliberately not an application API: public
## modules own application-facing types, validation, decoding, error tags, and
## phase documentation. `HostABI` is intentionally absent from the platform's
## `exposes` list.
##
## Declarations are grouped into transport domains. A transport domain is the
## private boundary vocabulary for one facility, not necessarily a public Roc
## module or a native backend subsystem. A domain contains, where applicable,
## opaque resource handles, flat request and result records, and finally the
## hosted function declarations that move those values. Records stay
## structural and unions cross as scalar codes because `roc glue` generates the
## corresponding native layouts from these declarations.
##
## Transport-domain glossary:
##
## - `Mouse`: cursor shape, visibility, and capture effects.
## - `Input`: raw per-cycle observations decoded into `App.Input`.
## - `Trace`: bounded diagnostic marks, zones, and numeric samples.
## - `Time`: normalized wall-clock timestamps.
## - `Task`: sleeping, spawning, and delivery of one finished message.
## - `Audio`: host-owned sounds and music plus playback effects.
## - `Assets`: confined asset stores and host-owned textures.
## - `Files`: bounded text and byte I/O, metadata, and directory listings.
## - `Http`: complete bounded requests and responses.
## - `Cmd`: bounded child-process execution and captured output.
## - `Stdio`: bounded queued writes to standard output and error.
## - `Udp`: bound sockets and bounded datagram send/receive batches.
## - `App`: startup authority, process inputs, startup file reads, and exit.
## - `Random`: operating-system entropy and the backend's ranged generator.
## - `Keys`: host keyboard policy such as the configured exit key.
## - `Window`: clipboard, window geometry, DPI scale, and monitor operations.
## - `Tilemap`: flattened TMX data and batched tile-layer drawing.
## - `Sqlite`: connection and statement handles plus flattened query results.
## - `Draw`: frame authority, draw resources, scopes, and ordered draw calls.
## - `Capture`: virtual input, recording, screenshots, and pixel readback.
##
## Native pointers, backend objects, public unions, and application policy do
## not belong here. Opaque `Box(U64)` values are typed resource tokens resolved
## and lifetime-checked by the host, never exposed native addresses.
import rrt.Camera
import rrt.Color
import rrt.Font
import rrt.Math
import rrt.Texture

HostABI := [].{

	## Mouse transport
	## Apply visibility and capture as one operation. `Mouse.cursor_mode_code`
	## flattens the tag.
	mouse_set_cursor_mode! : U8 => {}

	## Set the native cursor shape. `Mouse.cursor_code` flattens the tag.
	mouse_set_cursor! : U8 => {}

	## Input transport
	## One cycle's sampled recording state. Unions do not cross the host
	## boundary, so this arrives flat and `AppTransport.capture_status` turns it
	## into the public `Capture.Status`.
	AppRawCaptureStatus : {
		status : U8,
		err : U8,
		frames : U64,
		dropped : U64,
		bytes : U64,
	}

	## Trace transport
	## Record one instantaneous annotation.
	trace_mark! : Str => {}

	## Begin a nested zone and return its host-owned matching token.
	trace_begin! : Str => U64

	## End the zone named by a token returned from `trace_begin!`.
	trace_end! : U64 => {}

	## Record one signed integer sample with its private unit code.
	trace_sample_i64! : Str, I64, U8 => {}

	## Record one floating-point sample with its private unit code.
	trace_sample_f64! : Str, F64, U8 => {}

	## Time transport
	## An instant on the host's wall clock, already normalized: `seconds` is
	## floor-based seconds since the Unix epoch and `nanosecond` is always less
	## than 1,000,000,000, so an instant before the epoch has a negative
	## `seconds` and a non-negative `nanosecond`.
	TimeRawTimestamp : {
		seconds : I64,
		nanosecond : U32,
	}

	## Read the host's wall clock.
	time_now! : () => TimeRawTimestamp

	## Task transport
	## Park the calling task for at least this many milliseconds. The host runs
	## the frame loop while it waits; inside `init!` it blocks instead.
	task_sleep! : U64 => {}

	## Run an erased task closure on its own coroutine. Only the adapter's
	## `run_task_for_host!` ever names the message type again.
	task_spawn! : Box(() => msg) => {}

	## One finished task's message, on its way back to `update!`.
	##
	## The message travels in an erased thunk rather than a `Box(msg)` to work
	## around a defect in `roc glue`. Glue renders a `List(Box(msg))` field with
	## a one-word list header, because `layoutContainsRefcounted` reports
	## `false` for the `box_of_zst` layout a `Box(a)` gets while `a` is a
	## platform's `requires`-bound rigid. Every backend widens the same decision
	## with `layoutContainsRcErasedBox` before allocating or freeing such a
	## list, so the allocation really carries the two-word refcounted prefix and
	## the host frees eight bytes past its base. The generated release policy
	## gives an erased box no element policy either, so the boxed messages would
	## leak. An `erased_callable` is reported refcounted, so a thunk crosses
	## correctly, for one extra box and one extra call per message.
	##
	## In the compiler the decision is `is_type_refcounted` in
	## `src/glue/src/ZigGlue.roc`, reading the `abi.contains_refcounted` that
	## `src/glue/glue.zig` sets from `store.layoutContainsRefcounted`.
	##
	## TODO(compiler): deliver `List(Box(msg))` directly once glue widens
	## `is_type_refcounted` the way the backends do, and emits a `decrefBox`
	## element policy for an erased box.
	TaskFinishedTask(msg) : {
		deliver : Box({} -> Box(msg)),
	}

	## Audio transport
	AudioSound : Box(U64)

	AudioMusic : Box(U64)

	AudioSoundResult : { sound : AudioSound, err : U8 }

	AudioMusicResult : { music : AudioMusic, err : U8 }

	AudioGenSound : {
		waveform : U8,
		freq_start : F32,
		freq_end : F32,
		ms : I32,
		attack_ms : I32,
		decay_ms : I32,
		sustain : F32,
		release_ms : I32,
		volume : F32,
	}

	audio_gen_tone! : { freq : F32, ms : I32 } => AudioSoundResult
	audio_gen_sound! : AudioGenSound => AudioSoundResult
	audio_load_sound! : Str => AudioSoundResult
	audio_load_music! : Str => AudioMusicResult
	audio_play_sound! : AudioSound => {}
	audio_stop_sound! : AudioSound => {}
	audio_pause_sound! : AudioSound => {}
	audio_resume_sound! : AudioSound => {}
	audio_is_sound_playing! : AudioSound => Bool
	audio_set_sound_volume! : AudioSound, F32 => {}
	audio_set_sound_pitch! : AudioSound, F32 => {}
	audio_set_sound_pan! : AudioSound, F32 => {}
	audio_play_music! : AudioMusic => {}
	audio_stop_music! : AudioMusic => {}
	audio_pause_music! : AudioMusic => {}
	audio_resume_music! : AudioMusic => {}
	audio_set_music_volume! : AudioMusic, F32 => {}
	audio_set_music_pitch! : AudioMusic, F32 => {}
	audio_set_music_pan! : AudioMusic, F32 => {}
	audio_set_music_looping! : AudioMusic, Bool => {}
	audio_is_music_playing! : AudioMusic => Bool
	audio_seek_music! : AudioMusic, F32 => {}
	audio_music_length! : AudioMusic => F32
	audio_music_time_played! : AudioMusic => F32
	audio_set_master_volume! : F32 => {}

	## Assets transport
	## Opaque directory store. The backing directory handle is owned by a typed
	## host ARC heap, so a copied Roc value keeps the directory open.
	AssetsStore : Box(U64)

	AssetsStoreOpen : {
		location_kind : U8,
		root : Str,
		manifest_required : Bool,
		asset_set : Str,
		schema : U32,
		content_version : U32,
		content_hash_mode : U8,
		content_hash : Str,
	}

	AssetsStoreOpenResult : { store : AssetsStore, err : U8 }
	AssetsStoreLoad : { store : AssetsStore, path : Str }

	AssetsTextureResult : { texture : Texture, err : U8 }
	AssetsTextureBytes : { format : U8, bytes : List(U8) }

	AssetsGenerateColorTexture : { width : I32, height : I32, color : Color.Rgba }

	AssetsGenerateCheckedTexture : {
		width : I32,
		height : I32,
		checks_x : I32,
		checks_y : I32,
		color_a : Color.Rgba,
		color_b : Color.Rgba,
	}

	AssetsUpdateTexture : { texture : Texture, pixels : List(Color.Rgba) }

	AssetsUpdateTextureRegion : {
		texture : Texture,
		x : I32,
		y : I32,
		width : I32,
		height : I32,
		pixels : List(Color.Rgba),
	}

	assets_open_store! : AssetsStoreOpen => AssetsStoreOpenResult
	assets_load_store_texture! : AssetsStoreLoad => AssetsTextureResult
	assets_load_texture_bytes! : AssetsTextureBytes => AssetsTextureResult
	assets_generate_color_texture! : AssetsGenerateColorTexture => AssetsTextureResult
	assets_generate_checked_texture! : AssetsGenerateCheckedTexture => AssetsTextureResult
	assets_update_texture! : AssetsUpdateTexture => U8
	assets_update_texture_region! : AssetsUpdateTextureRegion => U8
	assets_set_texture_filter! : Texture, U8 => {}
	assets_set_texture_wrap! : Texture, U8 => {}

	## Files transport
	## A finished text read. `contents` is the file when `err` is `0`, and an
	## empty string otherwise.
	FilesTextResult : {
		err : U8,
		contents : Str,
	}

	## A finished byte read, or one encoded directory listing. `bytes` is the
	## payload when `err` is `0`, and empty otherwise.
	##
	## The list owns the host's own allocation rather than a copy of it: the
	## read fills native memory and that allocation moves into Roc list ARC.
	FilesBytesResult : {
		err : U8,
		bytes : List(U8),
	}

	## One finished `stat`. Every field but `err` is zero when `err` is not.
	##
	## Flat scalars rather than a payload: a stat allocates nothing and hands
	## nothing back but numbers, so nothing here is owned by either side.
	## `modified_seconds` and `modified_nanosecond` are the normalized parts
	## `Time.Timestamp` holds.
	FilesMetadataResult : {
		err : U8,
		kind : U8,
		size_bytes : U64,
		modified_seconds : I64,
		modified_nanosecond : U32,
	}

	## Read a bounded UTF-8 file. The host validates the encoding, so a file
	## that is not text is reported rather than delivered as an invalid `Str`.
	files_read_text! : Str => FilesTextResult

	## Stat one path, following symbolic links.
	files_metadata! : Str => FilesMetadataResult

	## Read a bounded file as bytes, without copying its payload.
	files_read_bytes! : Str => FilesBytesResult

	## List one directory into the encoded form `Files` decodes.
	files_list! : Str => FilesBytesResult

	## Replace a file's contents with this UTF-8 string. `0` means the file is
	## on disk; anything else is a `WRITE_ERR_*` code `Files` names.
	files_write_text! : Str, Str => U8

	## Replace a file's contents with these bytes. Same codes as `files_write_text!`.
	files_write_bytes! : Str, List(U8) => U8

	## Http transport
	## One HTTP header, in the order the peer sent or expects it.
	HttpHeaderPair : {
		name : Str,
		value : Str,
	}

	## A request, already validated by `Http` and flattened for the host.
	##
	## `method` is basic-cli's numeric method code and `method_ext` names the
	## method when the code cannot (`QUERY`, and anything `Unknown`). `Http`
	## refuses both before this effect runs, so `method_ext` is empty on every
	## request that gets here; the field stays because it is part of the shape
	## basic-cli's host reads, and the host keeps its own refusal for it.
	##
	## `timeout_ms` of 0 means no deadline, matching basic-cli's
	## `to_host_timeout`. `max_response_bytes` is a hard cap on the decompressed
	## body; the host stops reading and answers `ERR_BODY_TOO_LARGE` rather than
	## letting a remote server decide how much of this process's memory to use.
	HttpRequestToHost : {
		method : U8,
		method_ext : Str,
		headers : List(HttpHeaderPair),
		uri : Str,
		body : List(U8),
		timeout_ms : U64,
		max_response_bytes : U64,
	}

	## A response, or the transport failure that replaced it.
	##
	## `err` is 0 on success and one of the `ERR_*` codes below otherwise. On a
	## failure `status`, `headers` and `body` are empty and `err_message` carries
	## the host's description; on success `err_message` is empty.
	HttpResponseFromHost : {
		err : U8,
		err_message : Str,
		status : U16,
		headers : List(HttpHeaderPair),
		body : List(U8),
	}

	## Send one request and wait for the whole response.
	http_send! : HttpRequestToHost => HttpResponseFromHost

	## Cmd transport
	## One environment variable, as the child will see it.
	CmdEnvPair : {
		name : Str,
		value : Str,
	}

	## A command, already defaulted and validated by `Cmd`.
	##
	## `program` is `argv[0]`; it is looked up on this process's `PATH` when it
	## contains no path separator, and used as a path when it does. `args` are
	## the arguments after it, passed to the child exactly as given: no shell
	## reads them, so nothing is split, globbed, or expanded.
	##
	## `timeout_ms`, `stdout_limit_bytes` and `stderr_limit_bytes` are always
	## set -- `Cmd` has no way to build a command without them -- and the host
	## clamps each limit to its own ceiling.
	CmdRunArgs : {
		program : Str,
		args : List(Str),
		envs : List(CmdEnvPair),
		clear_envs : Bool,
		working_dir : Str,
		timeout_ms : U64,
		stdout_limit_bytes : U64,
		stderr_limit_bytes : U64,
	}

	## A finished child, or the reason there is none.
	##
	## `err` is `0` when the child ran to its own end, whatever it exited with:
	## a non-zero `exit_code` is data, not an error. When `err` is the deadline
	## code, `stdout` and `stderr` hold what the child had written before it
	## was killed and `exit_code` is `-1`. Every other code leaves all three
	## empty or zero.
	CmdRunResult : {
		err : U8,
		exit_code : I64,
		stdout : List(U8),
		stderr : List(U8),
	}

	## Start one child process and wait for it to finish.
	cmd_run! : CmdRunArgs => CmdRunResult

	## Stdio transport
	## Queue a string's UTF-8 bytes for one stream. `0` means every byte was
	## queued; anything else is a code `stdio_write_result` names.
	stdio_write_text! : U8, Str => U8

	## Queue a string's UTF-8 bytes and then one newline.
	##
	## The newline is appended by the host rather than by the app, so a line is
	## one reservation rather than two: the string does not have to be copied
	## to grow it, and no other write can land between the text and its
	## terminator.
	stdio_write_line! : U8, Str => U8

	## Queue arbitrary bytes for one stream. Same codes as `stdio_write_text!`.
	stdio_write_bytes! : U8, List(U8) => U8

	## Udp transport
	## Opaque bound socket. The descriptor is owned by a typed host ARC heap,
	## so a copied Roc value keeps the socket open and the last one closes it.
	UdpHandle : Box(U64)

	## A request to bind. `ip` is a dotted-quad IPv4 literal, which the host
	## parses; a port of `0` asks the operating system to choose one.
	UdpBindArgs : {
		ip : Str,
		port : U16,
	}

	## The bound socket, or the reason there is none. `ip` and `port` are the
	## address the kernel actually assigned, which differs from the requested
	## one whenever the app passed port `0`.
	UdpBindResult : {
		handle : UdpHandle,
		ip : U32,
		port : U16,
		err : U8,
	}

	## One outgoing datagram. `ip` is a dotted-quad IPv4 literal.
	UdpSendArgs : {
		socket : UdpHandle,
		ip : Str,
		port : U16,
		bytes : List(U8),
	}

	## A request to receive. `timeout_ms` of `0` means no deadline;
	## `max_datagrams` is clamped by the host to its own batch ceiling.
	UdpReceiveArgs : {
		socket : UdpHandle,
		timeout_ms : U64,
		max_datagrams : U32,
	}

	## Where one datagram came from, and where its bytes sit in the batch's
	## shared `payload`.
	UdpDatagramSlice : {
		ip : U32,
		port : U16,
		start : U64,
		len : U64,
	}

	## A finished batch. `err` is `0` when `slices` and `payload` are
	## meaningful, and both are empty otherwise.
	UdpReceiveResult : {
		err : U8,
		slices : List(UdpDatagramSlice),
		payload : List(U8),
	}

	## Open and bind one IPv4 UDP socket.
	udp_bind! : UdpBindArgs => UdpBindResult

	## Hand one datagram to the kernel. `0` means it was accepted for sending;
	## anything else is an error code `Udp` names.
	udp_send! : UdpSendArgs => U8

	## Wait for at least one datagram, then drain what is already buffered.
	udp_receive! : UdpReceiveArgs => UdpReceiveResult

	## App transport
	## Zero-sized startup capability constructed only by the platform adapter.
	AppStartup : {}

	## A finished startup file read. `contents` is the file when `ok` is true;
	## `err` is `1` for a missing file and anything else for a failed read.
	AppReadFileResult : {
		ok : Bool,
		err : U8,
		contents : Str,
	}

	## Ask the host to stop after `init!` returns.
	app_exit! : I32 => {}

	## The launcher's argv, with the host's own `--host-*` switches removed.
	app_args! : () => List(Str)

	## An environment variable, or `NotFound` when it is not set.
	app_read_env! : Str => Try(Str, [NotFound])

	## Read a whole UTF-8 file, blocking the caller.
	app_read_file! : Str => AppReadFileResult

	## Random transport
	## One draw from the operating system's entropy source.
	##
	## Never fails: the implementation falls back to a less secure mechanism
	## rather than reporting that entropy is unavailable, because what this
	## seeds is a game's generator rather than a key.
	random_entropy! : () => U64

	## A number in the inclusive range `[min, max]`, from the backend's own
	## generator rather than from the operating system.
	random_i32! : I32, I32 => I32

	## Keys transport
	## Set the raylib exit-key code; `0` disables the behaviour.
	keys_set_exit_key! : I32 => {}

	## Window transport
	## A clipboard read with the refusal codes `Window.ClipboardReadError`
	## names. `contents` is the clipboard when `err` is `0`.
	WindowClipboardResult : {
		err : U8,
		contents : Str,
	}

	window_read_clipboard! : () => WindowClipboardResult

	## Replace the clipboard with UTF-8 text.
	window_set_clipboard_text! : Str => {}

	## Ask the window manager for a logical window size. `NotSupported` is a
	## target whose windows cannot be resized, not a refused request.
	window_suggest_size! : { width : I32, height : I32 } => Try({}, [NotSupported])

	## Set raylib's CPU-side frame-rate cap; at or below zero is uncapped.
	window_set_target_fps! : I32 => {}

	## Set the smallest window size the user can drag down to. `0` in an axis
	## leaves it unconstrained.
	window_suggest_min_size! : { width : I32, height : I32 } => {}

	## The window's framebuffer-to-logical scale, one factor per axis.
	##
	## Non-positive or non-finite factors are replaced by `1` before they
	## cross, so the caller never has to defend against dividing by them.
	window_scale_dpi! : () => { x : F32, y : F32 }

	## One connected display, flattened for the wire. `Window.Monitor` is the
	## grouped shape an application sees; the nesting is done in Roc.
	WindowMonitorInfo : {
		index : I32,
		name : Str,
		width : I32,
		height : I32,
		x : I32,
		y : I32,
		refresh_hz : I32,
	}

	## Every display the windowing backend can currently see, in its own order.
	window_monitors! : () => List(WindowMonitorInfo)

	## Ask the window manager to move the window's top-left corner to a
	## position in virtual-desktop coordinates.
	window_suggest_position! : { x : I32, y : I32 } => {}

	## Ask the window manager to move the window to a monitor index. An index
	## outside the connected set is ignored.
	window_suggest_monitor! : I32 => {}

	## Tilemap transport
	TilemapProperty : {
		name : Str,
		kind : U8,
		text : Str,
		number : F32,
		integer : I64,
		bool_value : Bool,
	}

	TilemapTileset : {
		first_gid : U64,
		name : Str,
		tile_width : F32,
		tile_height : F32,
		tile_count : U64,
		columns : U64,
		image_source : Str,
		image_width : F32,
		image_height : F32,
		property_start : U64,
		property_count : U64,
	}

	TilemapTileProperties : { gid : U64, property_start : U64, property_count : U64 }

	TilemapLayer : {
		name : Str,
		width : U64,
		height : U64,
		gid_start : U64,
		gid_count : U64,
		property_start : U64,
		property_count : U64,
		visible : Bool,
		opacity : F32,
	}

	TilemapPoint : { x : F32, y : F32 }

	TilemapObject : {
		id : U64,
		name : Str,
		type_name : Str,
		x : F32,
		y : F32,
		width : F32,
		height : F32,
		rotation : F32,
		kind : U8,
		point_start : U64,
		point_count : U64,
		property_start : U64,
		property_count : U64,
	}

	TilemapMap : {
		width : U64,
		height : U64,
		tile_width : F32,
		tile_height : F32,
		map_property_start : U64,
		map_property_count : U64,
		tilesets : List(TilemapTileset),
		tile_properties : List(TilemapTileProperties),
		layers : List(TilemapLayer),
		gids : List(U64),
		objects : List(TilemapObject),
		points : List(TilemapPoint),
		properties : List(TilemapProperty),
	}

	TilemapLoadResult : { ok : Bool, err : U8, map : TilemapMap }

	## Primitive layer metadata prepared once by `Tilemap.Builder.build` and
	## borrowed by the host for a complete batched draw operation.
	TilemapRenderLayer : {
		width : U64,
		height : U64,
		gid_start : U64,
		gid_count : U64,
		visible : Bool,
		role : U8,
	}

	## A resolved tileset. The surrounding list owns each texture while a draw
	## request is in flight, so the host can safely borrow its lifecycle token.
	TilemapRenderTileset : {
		first_gid : U64,
		tile_width : F32,
		tile_height : F32,
		columns : U64,
		texture : Texture,
	}

	## Borrowed flat render plan. Lists are built once with the Tilemap value and
	## shared across calls; constructing this record never constructs a List.
	TilemapRenderRequest : {
		gids : List(U64),
		layers : List(TilemapRenderLayer),
		tilesets : List(TilemapRenderTileset),
		origin_x : F32,
		origin_y : F32,
		map_tile_width : F32,
		map_tile_height : F32,
		selector_kind : U8,
		selector_value : U64,
		culled : Bool,
		min_col : U64,
		min_row : U64,
		max_col : U64,
		max_row : U64,
	}

	tilemap_load_tmx! : Str => TilemapLoadResult
	tilemap_draw! : TilemapRenderRequest => {}

	## Sqlite transport
	## Opaque database connection. The `sqlite3*` is owned by a typed host ARC
	## heap, so a copied Roc value keeps the connection open and the last one
	## released closes it.
	SqliteDb : Box(U64)

	## Opaque prepared statement. Its heap slot retains the connection's, so a
	## statement cannot outlive the database it was prepared against.
	SqliteStmt : Box(U64)

	## One column of one row, in row-major order, `ncols` to a row.
	##
	## `kind` is SQLite's own column type: `1` integer, `2` real, `3` text,
	## `4` blob, `5` null. `integer` and `real` carry the value for the first
	## two; `start` and `len` locate it in `payload` for the other two. The
	## unused fields are zero, not meaningful.
	SqliteCell : {
		kind : U8,
		integer : I64,
		real : F64,
		start : U64,
		len : U64,
	}

	## One parameter binding, flattened. `kind` uses the same numbering as
	## `SqliteCell.kind`, and only the field that `kind` names is read.
	SqliteBindingWire : {
		name : Str,
		kind : U8,
		integer : I64,
		real : F64,
		text : Str,
		blob : List(U8),
	}

	## A connection, or the failure that replaced it. `db` is the invalid
	## handle when `err` is not `0`.
	SqliteOpenResult : { err : I64, message : Str, db : SqliteDb }

	## A prepared statement, or the failure that replaced it.
	SqlitePrepareResult : { err : I64, message : Str, stmt : SqliteStmt }

	## An operation with nothing to hand back but its outcome.
	SqliteStatusResult : { err : I64, message : Str }

	## One finished query.
	##
	## `names` holds `ncols` NUL-terminated column names in column order.
	## `cells` holds `ncols * row_count` cells. `payload` is the shared byte
	## buffer that `names`, text cells and blob cells all index into; it is one
	## host allocation and is empty when nothing referred to it.
	##
	## `changes` and `last_insert_rowid` are read after the statement finished,
	## so they describe this statement rather than the connection's history.
	SqliteQueryResult : {
		err : I64,
		message : Str,
		names : List(U8),
		ncols : U64,
		row_count : U64,
		cells : List(SqliteCell),
		payload : List(U8),
		changes : I64,
		last_insert_rowid : I64,
	}

	## Open or create a database. `mode` is `0` read/write/create, `1`
	## read/write, `2` read-only.
	sqlite_open! : Str, U8, U64, U64 => SqliteOpenResult

	## Close a connection early. The final handle release closes it anyway;
	## this is for paying a checkpoint at a time the app chooses.
	sqlite_close! : SqliteDb => SqliteStatusResult

	## Compile one statement for reuse.
	sqlite_prepare! : SqliteDb, Str => SqlitePrepareResult

	## Bind and run a prepared statement to completion, then reset it.
	sqlite_run_stmt! : SqliteStmt, List(SqliteBindingWire) => SqliteQueryResult

	## Prepare, bind, run and finalize in one call, without occupying a
	## statement slot.
	sqlite_run_once! : SqliteDb, Str, List(SqliteBindingWire) => SqliteQueryResult

	## Run every statement in a script. No bindings, and no rows come back.
	sqlite_exec_script! : SqliteDb, Str => SqliteStatusResult

	## Draw transport
	## Zero-sized frame capability constructed only by the platform adapter.
	DrawFrame : {}

	DrawPreparedText : Box(U64)

	DrawRenderTexture : Texture

	DrawShader : Box(U64)

	DrawUniform : { shader : DrawShader, location : I32 }

	DrawRectangle : { x : F32, y : F32, width : F32, height : F32, color : Color.Rgba }
	DrawScissor : { x : F32, y : F32, width : F32, height : F32 }
	DrawRectangleLines : { x : F32, y : F32, width : F32, height : F32, color : Color.Rgba, thickness : F32 }
	DrawRoundedRectangle : { x : F32, y : F32, width : F32, height : F32, radius : F32, segments : I32, color : Color.Rgba }
	DrawRoundedRectangleLines : { x : F32, y : F32, width : F32, height : F32, radius : F32, segments : I32, color : Color.Rgba, thickness : F32 }
	DrawRectangleGradientV : { x : F32, y : F32, width : F32, height : F32, color_top : Color.Rgba, color_bottom : Color.Rgba }
	DrawRectangleGradientH : { x : F32, y : F32, width : F32, height : F32, color_left : Color.Rgba, color_right : Color.Rgba }
	DrawCircle : { center : Math.Vec2, radius : F32, color : Color.Rgba }
	DrawCircleLines : { center : Math.Vec2, radius : F32, color : Color.Rgba, thickness : F32 }
	DrawCircleGradient : { center : Math.Vec2, radius : F32, color_inner : Color.Rgba, color_outer : Color.Rgba }
	DrawLine : { start : Math.Vec2, end : Math.Vec2, color : Color.Rgba, thickness : F32 }
	DrawTriangle : { a : Math.Vec2, b : Math.Vec2, c : Math.Vec2, color : Color.Rgba }
	DrawTriangleLines : { a : Math.Vec2, b : Math.Vec2, c : Math.Vec2, color : Color.Rgba, thickness : F32 }
	DrawPolygon : { points : List(Math.Vec2), color : Color.Rgba }
	DrawPolygonLines : { points : List(Math.Vec2), color : Color.Rgba, thickness : F32 }
	DrawFps : { pos : Math.Vec2, size : F32, color : Color.Rgba }
	DrawText : { pos : Math.Vec2, text : Str, size : F32, spacing : F32, color : Color.Rgba, font : Font.Handle }
	DrawGlyphMetric : { codepoint : U32, advance_x : F32, offset_x : F32, offset_y : F32, width : F32, height : F32 }
	DrawFontMetrics : { base_size : F32, line_spacing : F32, fallback_index : U64, glyphs : List(DrawGlyphMetric) }
	DrawFrameSize : { width : F32, height : F32 }
	DrawPrepareText : { text : Str, size : F32, spacing : F32, font : Font.Handle }
	DrawPrepareTextResult : { prepared : DrawPreparedText, width : F32, height : F32, err : U8 }
	DrawPreparedTextDraw : { prepared : DrawPreparedText, pos : Math.Vec2, color : Color.Rgba }
	DrawLoadFontBytes : { format : U8, bytes : List(U8), size : I32 }
	DrawLoadStoreFont : { store : AssetsStore, path : Str, size : I32 }
	DrawRenderTextureSize : { width : I32, height : I32 }
	DrawLoadShaderSource : { vertex_source : Str, fragment_source : Str }
	DrawLoadStoreShader : { store : AssetsStore, vertex_path : Str, fragment_path : Str }
	DrawTextureDraw : { texture : Texture, source : Math.Rect, dest : Math.Rect, origin : Math.Vec2, rotation : F32, tint : Color.Rgba }
	DrawTextureInstance : { source : Math.Rect, dest : Math.Rect, origin : Math.Vec2, rotation : F32, tint : Color.Rgba }

	## Borrowed instance batch. One hosted call draws every instance with the same
	## texture, so a per-sprite crossing becomes a single crossing per batch.
	DrawTextureInstances : { texture : Texture, instances : List(DrawTextureInstance) }
	DrawTextureQuad : { texture : Texture, source : Math.Rect, top_left : Math.Vec2, bottom_left : Math.Vec2, bottom_right : Math.Vec2, top_right : Math.Vec2, q_top_left : F32, q_bottom_left : F32, q_bottom_right : F32, q_top_right : F32, tint : Color.Rgba }
	DrawShaderLocation : { shader : DrawShader, name : Str }
	DrawShaderFloat : { uniform : DrawUniform, value : F32 }
	DrawShaderInt : { uniform : DrawUniform, value : I32 }
	DrawShaderVec2 : { uniform : DrawUniform, value : Math.Vec2 }
	DrawShaderVec3 : { uniform : DrawUniform, value : { x : F32, y : F32, z : F32 } }
	DrawShaderVec4 : { uniform : DrawUniform, value : { x : F32, y : F32, z : F32, w : F32 } }
	DrawShaderTexture : { uniform : DrawUniform, texture : Texture }
	DrawFontResult : { font : Font.Handle, err : U8 }
	DrawRenderTextureResult : { target : DrawRenderTexture, err : U8 }
	DrawShaderResult : { shader : DrawShader, err : U8 }

	draw_begin_camera! : Camera.Camera2D => U8
	draw_end_camera! : () => {}
	draw_begin_blend! : U8 => U8
	draw_end_blend! : () => {}
	draw_begin_render_texture! : DrawRenderTexture => U8
	draw_end_render_texture! : () => {}
	draw_begin_scissor! : DrawScissor => U8
	draw_end_scissor! : () => {}
	draw_begin_shader! : DrawShader => U8
	draw_end_shader! : () => {}
	draw_circle! : DrawCircle => {}
	draw_circle_gradient! : DrawCircleGradient => {}
	draw_circle_lines! : DrawCircleLines => {}
	draw_clear! : Color.Rgba => {}
	draw_fps! : DrawFps => {}
	draw_line! : DrawLine => {}
	draw_default_font! : () => Font.Handle
	draw_startup_default_font! : () => DrawFontResult
	draw_load_font_bytes! : DrawLoadFontBytes => DrawFontResult
	draw_load_store_font! : DrawLoadStoreFont => DrawFontResult
	draw_load_render_texture! : DrawRenderTextureSize => DrawRenderTextureResult
	draw_load_shader_source! : DrawLoadShaderSource => DrawShaderResult
	draw_load_store_shader! : DrawLoadStoreShader => DrawShaderResult
	draw_font_metrics! : Font.Handle => DrawFontMetrics
	draw_frame_size! : () => DrawFrameSize
	draw_prepare_text! : DrawPrepareText => DrawPrepareTextResult
	draw_draw_prepared_text! : DrawPreparedTextDraw => {}
	draw_polygon! : DrawPolygon => {}
	draw_polygon_lines! : DrawPolygonLines => {}
	draw_rectangle! : DrawRectangle => {}
	draw_rectangle_gradient_h! : DrawRectangleGradientH => {}
	draw_rectangle_gradient_v! : DrawRectangleGradientV => {}
	draw_rectangle_lines! : DrawRectangleLines => {}
	draw_rounded_rectangle! : DrawRoundedRectangle => {}
	draw_rounded_rectangle_lines! : DrawRoundedRectangleLines => {}
	draw_text! : DrawText => {}
	draw_draw_texture! : DrawTextureDraw => {}
	draw_draw_texture_instances! : DrawTextureInstances => {}
	draw_draw_texture_quad! : DrawTextureQuad => {}
	draw_triangle! : DrawTriangle => {}
	draw_triangle_lines! : DrawTriangleLines => {}
	draw_shader_location! : DrawShaderLocation => I32
	draw_set_shader_float! : DrawShaderFloat => {}
	draw_set_shader_int! : DrawShaderInt => {}
	draw_set_shader_vec2! : DrawShaderVec2 => {}
	draw_set_shader_vec3! : DrawShaderVec3 => {}
	draw_set_shader_vec4! : DrawShaderVec4 => {}
	draw_set_shader_texture! : DrawShaderTexture => {}

	## Capture transport
	## A recording request flattened to primitives the host ABI can carry.
	CaptureStartRecording : {
		path : Str,
		format : U8,
		fps : I32,
		max_frames : U64,
		scale_numerator : U32,
		scale_denominator : U32,
		every_nth : U32,
		timing : U8,
		cursor : U8,
		quality : U8,
	}

	## Outcome of finalizing a recording. `err` is `0` when the file was written.
	CaptureStopResult : {
		err : U8,
		frames : U64,
		bytes : U64,
	}

	## A scripted pointer state. `active` false hands control back to hardware.
	CaptureVirtualMouse : {
		active : Bool,
		x : F32,
		y : F32,
		left : Bool,
		middle : Bool,
		right : Bool,
		wheel : F32,
	}

	capture_set_virtual_mouse! : CaptureVirtualMouse => {}

	## A scripted keyboard state. `active` false hands control back to hardware.
	##
	## `keys` carries the raylib key codes held down, and only those. Press and
	## release edges are derived by the host from consecutive frames exactly as
	## they are for hardware, so nothing here describes an edge.
	CaptureVirtualKeys : {
		active : Bool,
		keys : List(U64),
	}

	capture_set_virtual_keys! : CaptureVirtualKeys => {}

	## Queue Unicode codepoints as the text entered on the next frame.
	##
	## The host delivers them once and then forgets them, the way a real
	## keyboard's characters arrive on one frame and not the next.
	capture_set_virtual_text! : List(U32) => {}

	## Arm a recording. The refusal code is latched by the host rather than
	## acted on here, so the outcome is observed the same way whichever phase
	## started it: an app reads it off `input.capture` on the next cycle.
	capture_start_recording! : CaptureStartRecording => U8

	## Finalize the running recording and write its file.
	capture_stop_recording! : () => CaptureStopResult

	## Capture the framebuffer at the end of this frame and write it as a PNG.
	##
	## Waits: the calling task parks until the file has been written, so the
	## returned code is the write's own outcome rather than a promise.
	capture_screenshot! : Str => U8

	## A render target and the path its pixels are written to.
	##
	## The target crosses as the public `RenderTexture` rather than as its
	## transport handle, the same way `DrawLoadStoreShader` carries an
	## `Store`: the host resolves the handle it already knows.
	CaptureTextureShot : {
		target : DrawRenderTexture,
		path : Str,
	}

	## Read a render target back and write it as a PNG.
	##
	## Waits: the readback itself is synchronous, because it needs the graphics
	## context the frame thread holds. The calling task parks for the encode and
	## the write, so the returned code is the write's own outcome.
	capture_screenshot_texture! : CaptureTextureShot => U8

	## Which pixels a readback reads, flattened for the host ABI.
	##
	## `screen` picks the last presented frame and leaves `target` unread; when
	## it is false the pixels come from `target`. `Capture.Source` is the tag
	## union this pair encodes, and it passes `RenderTexture.stub` as the
	## unread target so the field always carries a value.
	CapturePixelSource : {
		target : DrawRenderTexture,
		screen : Bool,
	}

	## One pixel's channels and why they are or are not real.
	##
	## `err` is `0` when the colour was read; otherwise the channels are zero
	## and the code names the refusal.
	CapturePixelResult : {
		err : U8,
		r : U8,
		g : U8,
		b : U8,
		a : U8,
	}

	## A point in a source, in pixels from its top-left corner.
	CapturePixelProbe : {
		source : CapturePixelSource,
		x : I32,
		y : I32,
	}

	## Read one pixel out of a source.
	##
	## Synchronous: the screen is read from a snapshot the host already holds,
	## and a render target is read through the graphics context this thread
	## owns, so nothing here parks.
	capture_pixel_at! : CapturePixelProbe => CapturePixelResult

	## A rectangle in a source, in pixels from its top-left corner.
	CaptureRegionProbe : {
		source : CapturePixelSource,
		x : I32,
		y : I32,
		width : I32,
		height : I32,
	}

	## Packed RGBA8 bytes and why they are or are not there.
	##
	## The list is handed over rather than copied, the same ownership transfer
	## `files_read_bytes!` uses, so a large region costs no second buffer.
	CaptureRegionResult : {
		err : U8,
		bytes : List(U8),
	}

	## Read a rectangle of a source as row-major, top-down RGBA8 bytes.
	capture_read_region! : CaptureRegionProbe => CaptureRegionResult

}
