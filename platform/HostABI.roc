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
## module or a native backend subsystem. A domain contains, where applicable:
##
## 1. Opaque resource handles.
## 2. Structural record aliases for hosted arguments and results.
## 3. Hosted effectful functions.
##
## Records stay structural and unions cross as scalar codes because `roc glue`
## generates the corresponding native layouts from these declarations.
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
	## Apply the flattened cursor visibility and capture mode.
	mouse_set_cursor_mode! : U8 => {}

	## Set the flattened native cursor shape.
	mouse_set_cursor! : U8 => {}

	## Input transport
	## Flat capture status sampled for one `App.Input`.
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
	## Normalized Unix timestamp. `seconds` uses floor division and `nanosecond`
	## is below 1,000,000,000, including before the epoch.
	TimeRawTimestamp : {
		seconds : I64,
		nanosecond : U32,
	}

	## Read the host's wall clock.
	time_now! : () => TimeRawTimestamp

	## Task transport
	## Park for at least this many milliseconds; block only during `init!`.
	task_sleep! : U64 => {}

	## Run an erased task closure on its own coroutine.
	task_spawn! : Box(() => msg) => {}

	## One finished task message awaiting delivery to `update!`.
	##
	## An erased thunk replaces `Box(msg)` because `roc glue` misclassifies that
	## box when `msg` is a `requires`-bound rigid. It emits the wrong list header
	## and no element release policy, causing invalid frees and leaks. An
	## `erased_callable` is classified correctly.
	##
	## Compiler path: `is_type_refcounted` in `src/glue/src/ZigGlue.roc`, fed by
	## `store.layoutContainsRefcounted` in `src/glue/glue.zig`.
	##
	## TODO(compiler): deliver `List(Box(msg))` directly once glue widens
	## `is_type_refcounted` the way the backends do, and emits a `decrefBox`
	## element policy for an erased box.
	TaskFinishedTask(msg) : {
		deliver : Box({} -> Box(msg)),
	}

	## Audio transport
	## Opaque ARC-owned sound.
	AudioSound : Box(U64)

	## Opaque ARC-owned music stream.
	AudioMusic : Box(U64)

	## Loaded sound or error.
	AudioSoundResult : { sound : AudioSound, err : U8 }

	## Loaded music stream or error.
	AudioMusicResult : { music : AudioMusic, err : U8 }

	## Parameters for a generated sound envelope.
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

	## Generate a tone.
	audio_gen_tone! : { freq : F32, ms : I32 } => AudioSoundResult

	## Generate a sound.
	audio_gen_sound! : AudioGenSound => AudioSoundResult

	## Load a sound from a file.
	audio_load_sound! : Str => AudioSoundResult

	## Load a music stream from a file.
	audio_load_music! : Str => AudioMusicResult

	## Play a sound.
	audio_play_sound! : AudioSound => {}

	## Stop a sound.
	audio_stop_sound! : AudioSound => {}

	## Pause a sound.
	audio_pause_sound! : AudioSound => {}

	## Resume a paused sound.
	audio_resume_sound! : AudioSound => {}

	## Report whether a sound is playing.
	audio_is_sound_playing! : AudioSound => Bool

	## Set sound volume; `1` is full volume.
	audio_set_sound_volume! : AudioSound, F32 => {}

	## Set sound pitch; `1` is the original pitch.
	audio_set_sound_pitch! : AudioSound, F32 => {}

	## Set sound pan; `0.5` is centered.
	audio_set_sound_pan! : AudioSound, F32 => {}

	## Start a music stream.
	audio_play_music! : AudioMusic => {}

	## Stop a music stream.
	audio_stop_music! : AudioMusic => {}

	## Pause a music stream.
	audio_pause_music! : AudioMusic => {}

	## Resume a paused music stream.
	audio_resume_music! : AudioMusic => {}

	## Set music volume; `1` is full volume.
	audio_set_music_volume! : AudioMusic, F32 => {}

	## Set music pitch; `1` is the original pitch.
	audio_set_music_pitch! : AudioMusic, F32 => {}

	## Set music pan; `0.5` is centered.
	audio_set_music_pan! : AudioMusic, F32 => {}

	## Enable or disable music looping.
	audio_set_music_looping! : AudioMusic, Bool => {}

	## Report whether a music stream is playing.
	audio_is_music_playing! : AudioMusic => Bool

	## Seek to a position in seconds.
	audio_seek_music! : AudioMusic, F32 => {}

	## Get music length in seconds.
	audio_music_length! : AudioMusic => F32

	## Get elapsed music time in seconds.
	audio_music_time_played! : AudioMusic => F32

	## Set master volume; `1` is full volume.
	audio_set_master_volume! : F32 => {}

	## Assets transport
	## Opaque ARC-owned directory store; copies keep it open.
	AssetsStore : Box(U64)

	## Parameters for opening a confined asset store.
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

	## Open asset store or error.
	AssetsStoreOpenResult : { store : AssetsStore, err : U8 }

	## Store-relative asset path.
	AssetsStoreLoad : { store : AssetsStore, path : Str }

	## Loaded texture or error.
	AssetsTextureResult : { texture : Texture, err : U8 }

	## Encoded texture bytes and format code.
	AssetsTextureBytes : { format : U8, bytes : List(U8) }

	## Solid-color texture parameters.
	AssetsGenerateColorTexture : { width : I32, height : I32, color : Color.Rgba }

	## Checkerboard texture parameters.
	AssetsGenerateCheckedTexture : {
		width : I32,
		height : I32,
		checks_x : I32,
		checks_y : I32,
		color_a : Color.Rgba,
		color_b : Color.Rgba,
	}

	## Full texture update.
	AssetsUpdateTexture : { texture : Texture, pixels : List(Color.Rgba) }

	## Rectangular texture update.
	AssetsUpdateTextureRegion : {
		texture : Texture,
		x : I32,
		y : I32,
		width : I32,
		height : I32,
		pixels : List(Color.Rgba),
	}

	## Open a confined asset store.
	assets_open_store! : AssetsStoreOpen => AssetsStoreOpenResult

	## Load a texture from an asset store.
	assets_load_store_texture! : AssetsStoreLoad => AssetsTextureResult

	## Load a texture from encoded bytes.
	assets_load_texture_bytes! : AssetsTextureBytes => AssetsTextureResult

	## Generate a solid-color texture.
	assets_generate_color_texture! : AssetsGenerateColorTexture => AssetsTextureResult

	## Generate a checkerboard texture.
	assets_generate_checked_texture! : AssetsGenerateCheckedTexture => AssetsTextureResult

	## Replace all texture pixels.
	assets_update_texture! : AssetsUpdateTexture => U8

	## Replace pixels within a texture rectangle.
	assets_update_texture_region! : AssetsUpdateTextureRegion => U8

	## Set the texture scaling filter.
	assets_set_texture_filter! : Texture, U8 => {}

	## Set the texture wrapping mode.
	assets_set_texture_wrap! : Texture, U8 => {}

	## Files transport
	## Text contents when `err` is `0`; otherwise empty.
	FilesTextResult : {
		err : U8,
		contents : Str,
	}

	## Read bytes or an encoded directory listing; empty on error.
	##
	## The host allocation transfers into Roc list ARC without copying.
	FilesBytesResult : {
		err : U8,
		bytes : List(U8),
	}

	## One `stat`; all payload fields are zero on error.
	##
	## Modification time uses the normalized `Time.Timestamp` parts.
	FilesMetadataResult : {
		err : U8,
		kind : U8,
		size_bytes : U64,
		modified_seconds : I64,
		modified_nanosecond : U32,
	}

	## Read bounded, validated UTF-8.
	files_read_text! : Str => FilesTextResult

	## Stat one path, following symbolic links.
	files_metadata! : Str => FilesMetadataResult

	## Read bounded bytes without copying the payload.
	files_read_bytes! : Str => FilesBytesResult

	## List one directory into the encoded form `Files` decodes.
	files_list! : Str => FilesBytesResult

	## Replace a file with UTF-8; return `0` or a `Files` write-error code.
	files_write_text! : Str, Str => U8

	## Replace a file with bytes; use the same result codes as text writes.
	files_write_bytes! : Str, List(U8) => U8

	## Http transport
	## One ordered HTTP header.
	HttpHeaderPair : {
		name : Str,
		value : Str,
	}

	## A validated request flattened for the host.
	##
	## `method_ext` remains for basic-cli layout compatibility but is always
	## empty because `Http` rejects extended methods first.
	##
	## `timeout_ms == 0` means no deadline. `max_response_bytes` caps the
	## decompressed body.
	HttpRequestToHost : {
		method : U8,
		method_ext : Str,
		headers : List(HttpHeaderPair),
		uri : Str,
		body : List(U8),
		timeout_ms : U64,
		max_response_bytes : U64,
	}

	## A response when `err == 0`; otherwise only `err_message` is populated.
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
	## One child-process environment variable.
	CmdEnvPair : {
		name : Str,
		value : Str,
	}

	## A validated command with explicit bounds.
	##
	## `program` is `argv[0]` and uses `PATH` only without a separator. Arguments
	## bypass the shell.
	##
	## The host clamps the timeout and output limits to its ceilings.
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

	## A finished child or launch failure.
	##
	## `err == 0` includes nonzero child exits. A timeout preserves captured
	## output and sets `exit_code` to `-1`; other errors leave payloads empty.
	CmdRunResult : {
		err : U8,
		exit_code : I64,
		stdout : List(U8),
		stderr : List(U8),
	}

	## Start one child process and wait for it to finish.
	cmd_run! : CmdRunArgs => CmdRunResult

	## Stdio transport
	## Queue UTF-8 atomically; return `0` or a stdio result code.
	stdio_write_text! : U8, Str => U8

	## Queue UTF-8 and a newline as one reservation.
	##
	## Host-side appending avoids a copy and prevents interleaved writes.
	stdio_write_line! : U8, Str => U8

	## Queue bytes atomically; use the text-write result codes.
	stdio_write_bytes! : U8, List(U8) => U8

	## Udp transport
	## Opaque ARC-owned bound socket.
	UdpHandle : Box(U64)

	## Bind a dotted-quad IPv4 literal; port `0` requests an assigned port.
	UdpBindArgs : {
		ip : Str,
		port : U16,
	}

	## A bound socket and its assigned address, or an error.
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

	## Receive request; zero timeout means none, and the host caps the batch.
	UdpReceiveArgs : {
		socket : UdpHandle,
		timeout_ms : U64,
		max_datagrams : U32,
	}

	## One datagram's source and range in the shared payload.
	UdpDatagramSlice : {
		ip : U32,
		port : U16,
		start : U64,
		len : U64,
	}

	## A received batch when `err == 0`; otherwise both lists are empty.
	UdpReceiveResult : {
		err : U8,
		slices : List(UdpDatagramSlice),
		payload : List(U8),
	}

	## Open and bind one IPv4 UDP socket.
	udp_bind! : UdpBindArgs => UdpBindResult

	## Send one datagram; return `0` or a `Udp` error code.
	udp_send! : UdpSendArgs => U8

	## Wait for at least one datagram, then drain what is already buffered.
	udp_receive! : UdpReceiveArgs => UdpReceiveResult

	## App transport
	## Zero-sized startup authority minted by the adapter.
	AppStartup : {}

	## Startup file contents, or `1` for missing and another code for failure.
	AppReadFileResult : {
		ok : Bool,
		err : U8,
		contents : Str,
	}

	## Stop after `init!` returns.
	app_exit! : I32 => {}

	## Launcher arguments without reserved `--host-*` switches.
	app_args! : () => List(Str)

	## Read an environment variable.
	app_read_env! : Str => Try(Str, [NotFound])

	## Read a whole UTF-8 file during startup.
	app_read_file! : Str => AppReadFileResult

	## Random transport
	## Draw from operating-system entropy.
	##
	## Falls back rather than failing; this seeds games, not cryptography.
	random_entropy! : () => U64

	## Draw inclusively from `[min, max]` using the backend generator.
	random_i32! : I32, I32 => I32

	## Keys transport
	## Set the exit-key code; `0` disables it.
	keys_set_exit_key! : I32 => {}

	## Window transport
	## Clipboard text when `err == 0`; otherwise empty.
	WindowClipboardResult : {
		err : U8,
		contents : Str,
	}

	## Get clipboard text.
	window_read_clipboard! : () => WindowClipboardResult

	## Replace the clipboard with UTF-8 text.
	window_set_clipboard_text! : Str => {}

	## Suggest a logical size; `NotSupported` means a fixed-size target.
	window_suggest_size! : { width : I32, height : I32 } => Try({}, [NotSupported])

	## Set the CPU-side frame cap; nonpositive means uncapped.
	window_set_target_fps! : I32 => {}

	## Suggest a minimum size; zero leaves an axis unconstrained.
	window_suggest_min_size! : { width : I32, height : I32 } => {}

	## Framebuffer-to-logical scale; invalid factors become `1`.
	window_scale_dpi! : () => { x : F32, y : F32 }

	## One connected display, flattened from `Window.Monitor`.
	WindowMonitorInfo : {
		index : I32,
		name : Str,
		width : I32,
		height : I32,
		x : I32,
		y : I32,
		refresh_hz : I32,
	}

	## All currently connected displays in backend order.
	window_monitors! : () => List(WindowMonitorInfo)

	## Suggest a top-left position in virtual-desktop coordinates.
	window_suggest_position! : { x : I32, y : I32 } => {}

	## Suggest a monitor; ignore a stale or invalid index.
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

	## Layer metadata borrowed by one batched draw.
	TilemapRenderLayer : {
		width : U64,
		height : U64,
		gid_start : U64,
		gid_count : U64,
		visible : Bool,
		role : U8,
	}

	## Resolved tileset whose list retains the texture during drawing.
	TilemapRenderTileset : {
		first_gid : U64,
		tile_width : F32,
		tile_height : F32,
		columns : U64,
		texture : Texture,
	}

	## Borrowed render plan whose lists are reused across draws.
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
	## Opaque ARC-owned database connection.
	SqliteDb : Box(U64)

	## Opaque statement that retains its connection.
	SqliteStmt : Box(U64)

	## One row-major query cell.
	##
	## `kind` uses SQLite's type codes `1` through `5`. Numbers use scalar fields;
	## text and blobs use a range in the shared payload. Unused fields are zero.
	SqliteCell : {
		kind : U8,
		integer : I64,
		real : F64,
		start : U64,
		len : U64,
	}

	## One flattened binding using `SqliteCell.kind` codes.
	SqliteBindingWire : {
		name : Str,
		kind : U8,
		integer : I64,
		real : F64,
		text : Str,
		blob : List(U8),
	}

	## A connection when `err == 0`; otherwise an invalid handle.
	SqliteOpenResult : { err : I64, message : Str, db : SqliteDb }

	## A prepared statement or its failure.
	SqlitePrepareResult : { err : I64, message : Str, stmt : SqliteStmt }

	## An outcome without a payload.
	SqliteStatusResult : { err : I64, message : Str }

	## One completed query.
	##
	## `names` holds NUL-terminated column names; `cells` is row-major; `payload`
	## is their shared byte buffer.
	##
	## `changes` and `last_insert_rowid` describe this statement.
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

	## Close early; final handle release remains the fallback.
	sqlite_close! : SqliteDb => SqliteStatusResult

	## Compile one statement for reuse.
	sqlite_prepare! : SqliteDb, Str => SqlitePrepareResult

	## Bind and run a prepared statement to completion, then reset it.
	sqlite_run_stmt! : SqliteStmt, List(SqliteBindingWire) => SqliteQueryResult

	## Prepare, bind, run, and finalize without retaining a statement.
	sqlite_run_once! : SqliteDb, Str, List(SqliteBindingWire) => SqliteQueryResult

	## Run a script without bindings or returned rows.
	sqlite_exec_script! : SqliteDb, Str => SqliteStatusResult

	## Draw transport
	## Zero-sized frame authority minted by the adapter.
	DrawFrame : {}

	## Opaque ARC-owned prepared text.
	DrawPreparedText : Box(U64)

	## Texture used as a render target.
	DrawRenderTexture : Texture

	## Opaque ARC-owned shader.
	DrawShader : Box(U64)

	## Located shader uniform.
	DrawUniform : { shader : DrawShader, location : I32 }

	## Filled rectangle parameters.
	DrawRectangle : { x : F32, y : F32, width : F32, height : F32, color : Color.Rgba }

	## Scissor rectangle parameters.
	DrawScissor : { x : F32, y : F32, width : F32, height : F32 }

	## Rectangle-outline parameters.
	DrawRectangleLines : { x : F32, y : F32, width : F32, height : F32, color : Color.Rgba, thickness : F32 }

	## Rounded-rectangle parameters.
	DrawRoundedRectangle : { x : F32, y : F32, width : F32, height : F32, radius : F32, segments : I32, color : Color.Rgba }

	## Rounded-rectangle-outline parameters.
	DrawRoundedRectangleLines : { x : F32, y : F32, width : F32, height : F32, radius : F32, segments : I32, color : Color.Rgba, thickness : F32 }

	## Vertical-gradient rectangle parameters.
	DrawRectangleGradientV : { x : F32, y : F32, width : F32, height : F32, color_top : Color.Rgba, color_bottom : Color.Rgba }

	## Horizontal-gradient rectangle parameters.
	DrawRectangleGradientH : { x : F32, y : F32, width : F32, height : F32, color_left : Color.Rgba, color_right : Color.Rgba }

	## Filled-circle parameters.
	DrawCircle : { center : Math.Vec2, radius : F32, color : Color.Rgba }

	## Circle-outline parameters.
	DrawCircleLines : { center : Math.Vec2, radius : F32, color : Color.Rgba, thickness : F32 }

	## Gradient-circle parameters.
	DrawCircleGradient : { center : Math.Vec2, radius : F32, color_inner : Color.Rgba, color_outer : Color.Rgba }

	## Line parameters.
	DrawLine : { start : Math.Vec2, end : Math.Vec2, color : Color.Rgba, thickness : F32 }

	## Filled-triangle parameters.
	DrawTriangle : { a : Math.Vec2, b : Math.Vec2, c : Math.Vec2, color : Color.Rgba }

	## Triangle-outline parameters.
	DrawTriangleLines : { a : Math.Vec2, b : Math.Vec2, c : Math.Vec2, color : Color.Rgba, thickness : F32 }

	## Filled-polygon parameters.
	DrawPolygon : { points : List(Math.Vec2), color : Color.Rgba }

	## Polygon-outline parameters.
	DrawPolygonLines : { points : List(Math.Vec2), color : Color.Rgba, thickness : F32 }

	## FPS-counter parameters.
	DrawFps : { pos : Math.Vec2, size : F32, color : Color.Rgba }

	## Text-drawing parameters.
	DrawText : { pos : Math.Vec2, text : Str, size : F32, spacing : F32, color : Color.Rgba, font : Font.Handle }

	## One glyph's layout metrics.
	DrawGlyphMetric : { codepoint : U32, advance_x : F32, offset_x : F32, offset_y : F32, width : F32, height : F32 }

	## Font metrics and glyph lookup data.
	DrawFontMetrics : { base_size : F32, line_spacing : F32, fallback_index : U64, glyphs : List(DrawGlyphMetric) }

	## Current frame dimensions.
	DrawFrameSize : { width : F32, height : F32 }

	## Text-preparation parameters.
	DrawPrepareText : { text : Str, size : F32, spacing : F32, font : Font.Handle }

	## Prepared text, measured size, or error.
	DrawPrepareTextResult : { prepared : DrawPreparedText, width : F32, height : F32, err : U8 }

	## Prepared-text drawing parameters.
	DrawPreparedTextDraw : { prepared : DrawPreparedText, pos : Math.Vec2, color : Color.Rgba }

	## Font bytes, format, and pixel size.
	DrawLoadFontBytes : { format : U8, bytes : List(U8), size : I32 }

	## Store-relative font path and pixel size.
	DrawLoadStoreFont : { store : AssetsStore, path : Str, size : I32 }

	## Render-target dimensions.
	DrawRenderTextureSize : { width : I32, height : I32 }

	## Vertex and fragment shader sources.
	DrawLoadShaderSource : { vertex_source : Str, fragment_source : Str }

	## Store-relative vertex and fragment shader paths.
	DrawLoadStoreShader : { store : AssetsStore, vertex_path : Str, fragment_path : Str }

	## Textured-rectangle parameters.
	DrawTextureDraw : { texture : Texture, source : Math.Rect, dest : Math.Rect, origin : Math.Vec2, rotation : F32, tint : Color.Rgba }

	## One textured-rectangle instance.
	DrawTextureInstance : { source : Math.Rect, dest : Math.Rect, origin : Math.Vec2, rotation : F32, tint : Color.Rgba }

	## Borrowed instances sharing one texture and hosted call.
	DrawTextureInstances : { texture : Texture, instances : List(DrawTextureInstance) }

	## Arbitrary textured-quad parameters.
	DrawTextureQuad : { texture : Texture, source : Math.Rect, top_left : Math.Vec2, bottom_left : Math.Vec2, bottom_right : Math.Vec2, top_right : Math.Vec2, q_top_left : F32, q_bottom_left : F32, q_bottom_right : F32, q_top_right : F32, tint : Color.Rgba }

	## Shader-uniform lookup parameters.
	DrawShaderLocation : { shader : DrawShader, name : Str }

	## Scalar floating-point uniform value.
	DrawShaderFloat : { uniform : DrawUniform, value : F32 }

	## Scalar integer uniform value.
	DrawShaderInt : { uniform : DrawUniform, value : I32 }

	## Two-component vector uniform value.
	DrawShaderVec2 : { uniform : DrawUniform, value : Math.Vec2 }

	## Three-component vector uniform value.
	DrawShaderVec3 : { uniform : DrawUniform, value : { x : F32, y : F32, z : F32 } }

	## Four-component vector uniform value.
	DrawShaderVec4 : { uniform : DrawUniform, value : { x : F32, y : F32, z : F32, w : F32 } }

	## Texture uniform value.
	DrawShaderTexture : { uniform : DrawUniform, texture : Texture }

	## Loaded font or error.
	DrawFontResult : { font : Font.Handle, err : U8 }

	## Loaded render target or error.
	DrawRenderTextureResult : { target : DrawRenderTexture, err : U8 }

	## Loaded shader or error.
	DrawShaderResult : { shader : DrawShader, err : U8 }

	## Begin 2D drawing with a camera.
	draw_begin_camera! : Camera.Camera2D => U8

	## End 2D camera drawing.
	draw_end_camera! : () => {}

	## Begin the flattened blend mode.
	draw_begin_blend! : U8 => U8

	## Restore alpha blending.
	draw_end_blend! : () => {}

	## Begin drawing to a render target.
	draw_begin_render_texture! : DrawRenderTexture => U8

	## End render-target drawing.
	draw_end_render_texture! : () => {}

	## Begin clipping to a screen rectangle.
	draw_begin_scissor! : DrawScissor => U8

	## End scissor clipping.
	draw_end_scissor! : () => {}

	## Begin custom-shader drawing.
	draw_begin_shader! : DrawShader => U8

	## Restore the default shader.
	draw_end_shader! : () => {}

	## Draw a filled circle.
	draw_circle! : DrawCircle => {}

	## Draw a gradient-filled circle.
	draw_circle_gradient! : DrawCircleGradient => {}

	## Draw a circle outline.
	draw_circle_lines! : DrawCircleLines => {}

	## Clear the current drawing target.
	draw_clear! : Color.Rgba => {}

	## Draw the current FPS.
	draw_fps! : DrawFps => {}

	## Draw a line.
	draw_line! : DrawLine => {}

	## Get the default font during rendering.
	draw_default_font! : () => Font.Handle

	## Get the default font during startup.
	draw_startup_default_font! : () => DrawFontResult

	## Load a font from encoded bytes.
	draw_load_font_bytes! : DrawLoadFontBytes => DrawFontResult

	## Load a font from an asset store.
	draw_load_store_font! : DrawLoadStoreFont => DrawFontResult

	## Load a render target.
	draw_load_render_texture! : DrawRenderTextureSize => DrawRenderTextureResult

	## Load a shader from source strings.
	draw_load_shader_source! : DrawLoadShaderSource => DrawShaderResult

	## Load a shader from an asset store.
	draw_load_store_shader! : DrawLoadStoreShader => DrawShaderResult

	## Get font and glyph metrics.
	draw_font_metrics! : Font.Handle => DrawFontMetrics

	## Get the current frame dimensions.
	draw_frame_size! : () => DrawFrameSize

	## Shape and measure text for repeated drawing.
	draw_prepare_text! : DrawPrepareText => DrawPrepareTextResult

	## Draw prepared text.
	draw_draw_prepared_text! : DrawPreparedTextDraw => {}

	## Draw a filled polygon.
	draw_polygon! : DrawPolygon => {}

	## Draw a polygon outline.
	draw_polygon_lines! : DrawPolygonLines => {}

	## Draw a filled rectangle.
	draw_rectangle! : DrawRectangle => {}

	## Draw a horizontal-gradient rectangle.
	draw_rectangle_gradient_h! : DrawRectangleGradientH => {}

	## Draw a vertical-gradient rectangle.
	draw_rectangle_gradient_v! : DrawRectangleGradientV => {}

	## Draw a rectangle outline.
	draw_rectangle_lines! : DrawRectangleLines => {}

	## Draw a filled rounded rectangle.
	draw_rounded_rectangle! : DrawRoundedRectangle => {}

	## Draw a rounded-rectangle outline.
	draw_rounded_rectangle_lines! : DrawRoundedRectangleLines => {}

	## Draw text with a font.
	draw_text! : DrawText => {}

	## Draw part of a texture into a rectangle.
	draw_draw_texture! : DrawTextureDraw => {}

	## Draw a batch of texture instances.
	draw_draw_texture_instances! : DrawTextureInstances => {}

	## Draw part of a texture as an arbitrary quad.
	draw_draw_texture_quad! : DrawTextureQuad => {}

	## Draw a filled counter-clockwise triangle.
	draw_triangle! : DrawTriangle => {}

	## Draw a counter-clockwise triangle outline.
	draw_triangle_lines! : DrawTriangleLines => {}

	## Get a shader uniform location.
	draw_shader_location! : DrawShaderLocation => I32

	## Set a floating-point shader uniform.
	draw_set_shader_float! : DrawShaderFloat => {}

	## Set an integer shader uniform.
	draw_set_shader_int! : DrawShaderInt => {}

	## Set a two-component shader uniform.
	draw_set_shader_vec2! : DrawShaderVec2 => {}

	## Set a three-component shader uniform.
	draw_set_shader_vec3! : DrawShaderVec3 => {}

	## Set a four-component shader uniform.
	draw_set_shader_vec4! : DrawShaderVec4 => {}

	## Set a texture shader uniform.
	draw_set_shader_texture! : DrawShaderTexture => {}

	## Capture transport
	## Flattened recording request.
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

	## Finalized recording when `err == 0`.
	CaptureStopResult : {
		err : U8,
		frames : U64,
		bytes : U64,
	}

	## Scripted pointer state; inactive returns control to hardware.
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

	## Scripted held keys; inactive returns control to hardware.
	##
	## The host derives edges between consecutive states.
	CaptureVirtualKeys : {
		active : Bool,
		keys : List(U64),
	}

	capture_set_virtual_keys! : CaptureVirtualKeys => {}

	## Queue codepoints for one delivery on the next frame.
	capture_set_virtual_text! : List(U32) => {}

	## Arm recording and latch its result for the next `Input`.
	capture_start_recording! : CaptureStartRecording => U8

	## Finalize the running recording and write its file.
	capture_stop_recording! : () => CaptureStopResult

	## Write the next framebuffer as PNG, parking until complete.
	capture_screenshot! : Str => U8

	## A render target and output path.
	CaptureTextureShot : {
		target : DrawRenderTexture,
		path : Str,
	}

	## Read back a target, then park while encoding and writing its PNG.
	capture_screenshot_texture! : CaptureTextureShot => U8

	## Flattened screen-or-target source.
	##
	## `screen` selects the last frame; otherwise `target` is used.
	CapturePixelSource : {
		target : DrawRenderTexture,
		screen : Bool,
	}

	## One RGBA pixel when `err == 0`; otherwise zeroed channels.
	CapturePixelResult : {
		err : U8,
		r : U8,
		g : U8,
		b : U8,
		a : U8,
	}

	## A source-relative pixel coordinate.
	CapturePixelProbe : {
		source : CapturePixelSource,
		x : I32,
		y : I32,
	}

	## Read one pixel synchronously.
	capture_pixel_at! : CapturePixelProbe => CapturePixelResult

	## A source-relative pixel rectangle.
	CaptureRegionProbe : {
		source : CapturePixelSource,
		x : I32,
		y : I32,
		width : I32,
		height : I32,
	}

	## Packed RGBA8 bytes transferred into Roc list ARC; empty on error.
	CaptureRegionResult : {
		err : U8,
		bytes : List(U8),
	}

	## Read a rectangle of a source as row-major, top-down RGBA8 bytes.
	capture_read_region! : CaptureRegionProbe => CaptureRegionResult

}
