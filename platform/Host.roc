## Private structural transport between Roc platform adapters and the native
## host.
##
## This module is the single catalogue of native hosted functions and the wire
## values they exchange. It is deliberately not an application API: public
## modules own application-facing validation, naming, composition, and phase
## documentation. A hosted declaration may carry a shared pure type or the
## same concrete outcome tags its public adapter exposes. `Host` is exposed as
## `rr.Host` for direct structural interface access.
##
## Declarations are grouped into interfaces which contain, where applicable:
##
## 1. Opaque resource handles.
## 2. Structural record aliases for hosted arguments and results.
## 3. Hosted effectful functions.
##
## Records stay structural and unions use concrete, closed rows because `roc
## glue` generates the corresponding native layouts from these declarations.
##
## Interface glossary:
##
## Raylib-backed rendering and interaction interfaces:
##
## > `Texture` resource: loading, generation, updates, configuration, and render targets.
## > `Text` resource: font loading, glyph metrics, and text preparation.
## > `Shader` resource: loading, uniform lookup, and uniform updates.
## > `Store` resource: confined asset directories.
## > `Mouse`: cursor shape, visibility, and capture effects.
## > `Audio`: host-owned sounds and music plus playback effects.
## > `Random`: operating-system entropy and the backend's ranged generator.
## > `Keys`: host keyboard policy such as the configured exit key.
## > `Window`: clipboard, window geometry, DPI scale, and monitor operations.
## > `Tilemap`: flattened TMX data and batched tile-layer drawing.
## > `Draw`: frame authority, render resources, scopes, and drawing primitives.
## > `Capture`: virtual input, recording, screenshots, and pixel readback.
##
## Host-service interfaces:
##
## > `App`: startup authority, process inputs, startup file reads, and exit.
## > `Task`: sleeping, spawning, and delivery of one finished message.
## > `Time`: normalized wall-clock timestamps.
## > `Trace`: bounded diagnostic marks, zones, and numeric samples.
## > `Files`: bounded text and byte I/O, metadata, and directory listings.
## > `Http`: complete bounded requests and responses.
## > `Cmd`: bounded child-process execution and captured output.
## > `Stdio`: bounded queued writes to standard output and error.
## > `Udp`: bound sockets and bounded datagram send/receive batches.
## > `Sqlite`: connection and statement handles plus flattened query results.
##
## Opaque `Box(U64)` values are typed resource tokens resolved
## and lifetime-checked by the host, never exposing native addresses.
## Native pointers, backend objects, public unions, and application policy do
## not belong here.
import rrt.Camera
import rrt.Color
import rrt.Font
import rrt.Math
import rrt.Texture

Host := [].{

	## Texture resource interface
	## Store-relative texture path.
	TextureLoadStore : { store : Store, path : Str }

	## Loaded texture or error.
	TextureResult : { texture : Texture, err : U8 }

	## Encoded texture bytes and format code.
	TextureBytes : { format : U8, bytes : List(U8) }

	## Solid-color texture parameters.
	TextureGenerateColor : { width : I32, height : I32, color : Color.Rgba }

	## Checkerboard texture parameters.
	TextureGenerateChecked : {
		width : I32,
		height : I32,
		checks_x : I32,
		checks_y : I32,
		color_a : Color.Rgba,
		color_b : Color.Rgba,
	}

	## Full texture update.
	TextureUpdate : { texture : Texture, pixels : List(Color.Rgba) }

	## Rectangular texture update.
	TextureUpdateRegion : {
		texture : Texture,
		x : I32,
		y : I32,
		width : I32,
		height : I32,
		pixels : List(Color.Rgba),
	}

	## Load a texture from an asset store.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	texture_load_store! : TextureLoadStore => TextureResult

	## Load a texture from encoded bytes.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	texture_load_bytes! : TextureBytes => TextureResult

	## Generate a solid-color texture.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	texture_generate_color! : TextureGenerateColor => TextureResult

	## Generate a checkerboard texture.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	texture_generate_checked! : TextureGenerateChecked => TextureResult

	## Replace all texture pixels.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	texture_update! : TextureUpdate => U8

	## Replace pixels within a texture rectangle.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	texture_update_region! : TextureUpdateRegion => U8

	## Set the texture scaling filter.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	texture_set_filter! : Texture, U8 => {}

	## Set the texture wrapping mode.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	texture_set_wrap! : Texture, U8 => {}

	## Texture used as a render target.
	TextureRenderTarget : Texture

	## Render-target dimensions.
	TextureRenderTargetSize : { width : I32, height : I32 }

	## Loaded render target or error.
	TextureRenderTargetResult : { target : TextureRenderTarget, err : U8 }

	## Load a render target.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	texture_load_render_target! : TextureRenderTargetSize => TextureRenderTargetResult

	## Text resource interface
	## Opaque ARC-owned prepared text.
	TextPrepared : Box(U64)

	## Text-preparation parameters.
	TextPrepare : { text : Str, size : F32, spacing : F32, font : Font.Handle }

	## Prepared text, measured size, or error.
	TextPrepareResult : { prepared : TextPrepared, width : F32, height : F32, err : U8 }

	## Font bytes, format, and pixel size.
	TextLoadFontBytes : { format : U8, bytes : List(U8), size : I32 }

	## Store-relative font path and pixel size.
	TextLoadStoreFont : { store : Store, path : Str, size : I32 }

	## Failures while constructing a font from encoded bytes.
	TextLoadFontError : [FontLoadFailed, ResourceLimit]

	## Failures while reading and constructing a font from an asset store.
	TextLoadStoreFontError : [FontLoadFailed, NotFound, PathInvalid, ReadFailed, ResourceLimit]

	## Snapshot the built-in default font.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	text_default_font! : () => Font

	## Get the default font during startup.
	## Legal only in `init!`.
	text_startup_default_font! : () => Try(Font, [AssetPathInvalid, AssetNotFound, AssetReadFailed, FontLoadFailed, ResourceLimit])

	## Load a font from encoded bytes.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	text_load_font! : TextLoadFontBytes => Try(Font, TextLoadFontError)

	## Load a font from an asset store.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	text_load_store_font! : TextLoadStoreFont => Try(Font, TextLoadStoreFontError)

	## Shape and measure text for repeated drawing.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	text_prepare! : TextPrepare => TextPrepareResult

	## Shader resource interface
	## Opaque ARC-owned shader.
	Shader : Box(U64)

	## Located shader uniform.
	ShaderUniform : { shader : Shader, location : I32 }

	## Vertex and fragment shader sources.
	ShaderLoadSource : { vertex_source : Str, fragment_source : Str }

	## Store-relative vertex and fragment shader paths.
	ShaderLoadStore : { store : Store, vertex_path : Str, fragment_path : Str }

	## Shader-uniform lookup parameters.
	ShaderLocation : { shader : Shader, name : Str }

	## Scalar floating-point uniform value.
	ShaderFloat : { uniform : ShaderUniform, value : F32 }

	## Scalar integer uniform value.
	ShaderInt : { uniform : ShaderUniform, value : I32 }

	## Two-component vector uniform value.
	ShaderVec2 : { uniform : ShaderUniform, value : Math.Vec2 }

	## Three-component vector uniform value.
	ShaderVec3 : { uniform : ShaderUniform, value : { x : F32, y : F32, z : F32 } }

	## Four-component vector uniform value.
	ShaderVec4 : { uniform : ShaderUniform, value : { x : F32, y : F32, z : F32, w : F32 } }

	## Texture uniform value.
	ShaderTexture : { uniform : ShaderUniform, texture : Texture }

	## Loaded shader or error.
	ShaderResult : { shader : Shader, err : U8 }

	## Load a shader from source strings.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	shader_load_source! : ShaderLoadSource => ShaderResult

	## Load a shader from an asset store.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	shader_load_store! : ShaderLoadStore => ShaderResult

	## Get a shader uniform location.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	shader_location! : ShaderLocation => I32

	## Set a floating-point shader uniform.
	## Legal in `render!` only.
	shader_set_float! : ShaderFloat => {}

	## Set an integer shader uniform.
	## Legal in `render!` only.
	shader_set_int! : ShaderInt => {}

	## Set a two-component shader uniform.
	## Legal in `render!` only.
	shader_set_vec2! : ShaderVec2 => {}

	## Set a three-component shader uniform.
	## Legal in `render!` only.
	shader_set_vec3! : ShaderVec3 => {}

	## Set a four-component shader uniform.
	## Legal in `render!` only.
	shader_set_vec4! : ShaderVec4 => {}

	## Set a texture shader uniform.
	## Legal in `render!` only.
	shader_set_texture! : ShaderTexture => {}

	## Store resource interface
	## Opaque ARC-owned directory store; copies keep it open.
	Store : Box(U64)

	## Parameters for opening a confined asset store.
	StoreOpen : {
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
	StoreOpenResult : { store : Store, err : U8 }

	## Open a confined asset store.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	store_open! : StoreOpen => StoreOpenResult

	## Mouse interface
	## Apply the flattened cursor visibility and capture mode.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	mouse_set_cursor_mode! : U8 => {}

	## Set the flattened native cursor shape.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	mouse_set_cursor! : U8 => {}

	## Trace interface
	## Record one instantaneous annotation.
	## Legal in `init!`, `update!`, `render!`, and tasks.
	trace_mark! : Str => {}

	## Begin a nested zone and return its host-owned matching token.
	## Legal in `init!`, `update!`, `render!`, and tasks.
	trace_begin! : Str => U64

	## End the zone named by a token returned from `trace_begin!`.
	## Legal in `init!`, `update!`, `render!`, and tasks.
	trace_end! : U64 => {}

	## Record one signed integer sample with its private unit code.
	## Legal in `init!`, `update!`, `render!`, and tasks.
	trace_sample_i64! : Str, I64, U8 => {}

	## Record one floating-point sample with its private unit code.
	## Legal in `init!`, `update!`, `render!`, and tasks.
	trace_sample_f64! : Str, F64, U8 => {}

	## Time interface
	## Normalized Unix timestamp. `seconds` uses floor division and `nanosecond`
	## is below 1,000,000,000, including before the epoch.
	TimeRawTimestamp : {
		seconds : I64,
		nanosecond : U32,
	}

	## Read the host's wall clock.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	time_now! : () => TimeRawTimestamp

	## Task interface
	## Park for at least this many milliseconds; block only during `init!`.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	task_sleep! : U64 => {}

	## Run an erased task closure on its own coroutine.
	## Legal in `update!` and in tasks; refused in `init!` and `render!`.
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

	## Audio interface
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
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_gen_tone! : { freq : F32, ms : I32 } => AudioSoundResult

	## Generate a sound.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_gen_sound! : AudioGenSound => AudioSoundResult

	## Load a sound from a file.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	audio_load_sound! : Str => AudioSoundResult

	## Load a music stream from a file.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	audio_load_music! : Str => AudioMusicResult

	## Play a sound.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_play_sound! : AudioSound => {}

	## Stop a sound.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_stop_sound! : AudioSound => {}

	## Pause a sound.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_pause_sound! : AudioSound => {}

	## Resume a paused sound.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_resume_sound! : AudioSound => {}

	## Report whether a sound is playing.
	## Legal in any callback, `render!` included.
	audio_is_sound_playing! : AudioSound => Bool

	## Set sound volume; `1` is full volume.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_set_sound_volume! : AudioSound, F32 => {}

	## Set sound pitch; `1` is the original pitch.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_set_sound_pitch! : AudioSound, F32 => {}

	## Set sound pan; `0.5` is centered.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_set_sound_pan! : AudioSound, F32 => {}

	## Start a music stream.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_play_music! : AudioMusic => {}

	## Stop a music stream.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_stop_music! : AudioMusic => {}

	## Pause a music stream.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_pause_music! : AudioMusic => {}

	## Resume a paused music stream.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_resume_music! : AudioMusic => {}

	## Set music volume; `1` is full volume.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_set_music_volume! : AudioMusic, F32 => {}

	## Set music pitch; `1` is the original pitch.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_set_music_pitch! : AudioMusic, F32 => {}

	## Set music pan; `0.5` is centered.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_set_music_pan! : AudioMusic, F32 => {}

	## Enable or disable music looping.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_set_music_looping! : AudioMusic, Bool => {}

	## Report whether a music stream is playing.
	## Legal in any callback, `render!` included.
	audio_is_music_playing! : AudioMusic => Bool

	## Seek to a position in seconds.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_seek_music! : AudioMusic, F32 => {}

	## Get music length in seconds.
	## Legal in any callback, `render!` included.
	audio_music_length! : AudioMusic => F32

	## Get elapsed music time in seconds.
	## Legal in any callback, `render!` included.
	audio_music_time_played! : AudioMusic => F32

	## Set master volume; `1` is full volume.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	audio_set_master_volume! : F32 => {}

	## Files interface
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
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	files_read_text! : Str => FilesTextResult

	## Stat one path, following symbolic links.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	files_metadata! : Str => FilesMetadataResult

	## Read bounded bytes without copying the payload.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	files_read_bytes! : Str => FilesBytesResult

	## List one directory into the encoded form `Files` decodes.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	files_list! : Str => FilesBytesResult

	## Replace a file with UTF-8; return `0` or a `Files` write-error code.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	files_write_text! : Str, Str => U8

	## Replace a file with bytes; use the same result codes as text writes.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	files_write_bytes! : Str, List(U8) => U8

	## Http interface
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
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	http_send! : HttpRequestToHost => HttpResponseFromHost

	## Cmd interface
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
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	cmd_run! : CmdRunArgs => CmdRunResult

	## Stdio interface
	## Queue UTF-8 atomically; return `0` or a stdio result code.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	stdio_write_text! : U8, Str => U8

	## Queue UTF-8 and a newline as one reservation.
	##
	## Host-side appending avoids a copy and prevents interleaved writes.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	stdio_write_line! : U8, Str => U8

	## Queue bytes atomically; use the text-write result codes.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	stdio_write_bytes! : U8, List(U8) => U8

	## Udp interface
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
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	udp_bind! : UdpBindArgs => UdpBindResult

	## Send one datagram; return `0` or a `Udp` error code.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	udp_send! : UdpSendArgs => U8

	## Wait for at least one datagram, then drain what is already buffered.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	udp_receive! : UdpReceiveArgs => UdpReceiveResult

	## App interface
	## Zero-sized startup authority minted by the adapter.
	AppStartup : {}

	## Stop after `init!` returns.
	## Legal only in `init!`.
	app_exit! : I32 => {}

	## Launcher arguments without reserved `--host-*` switches.
	## Legal only in `init!`.
	app_args! : () => List(Str)

	## Read an environment variable.
	## Legal only in `init!`.
	app_read_env! : Str => Try(Str, [NotFound])

	## Read a whole UTF-8 file during startup.
	## Legal only in `init!`.
	app_read_text! : Str => Try(Str, [NotFound, ReadFailed])

	## Random interface
	## Draw from operating-system entropy.
	##
	## Falls back rather than failing; this seeds games, not cryptography.
	## Legal only in `init!`.
	random_entropy! : () => U64

	## Draw inclusively from `[min, max]` using the backend generator.
	## Legal only in `init!`.
	random_i32! : I32, I32 => I32

	## Keys interface
	## Set the exit-key code; `0` disables it.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	keys_set_exit_key! : I32 => {}

	## Window interface
	## Clipboard text when `err == 0`; otherwise empty.
	WindowClipboardResult : {
		err : U8,
		contents : Str,
	}

	## Get clipboard text.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	window_read_clipboard! : () => WindowClipboardResult

	## Replace the clipboard with UTF-8 text.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	window_set_clipboard_text! : Str => {}

	## Suggest a logical size; `NotSupported` means a fixed-size target.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	window_suggest_size! : { width : I32, height : I32 } => Try({}, [NotSupported])

	## Set the CPU-side frame cap; nonpositive means uncapped.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	window_set_target_fps! : I32 => {}

	## Suggest a minimum size; zero leaves an axis unconstrained.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	window_suggest_min_size! : { width : I32, height : I32 } => {}

	## Framebuffer-to-logical scale; invalid factors become `1`.
	## Legal in any callback, `render!` included.
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
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	window_monitors! : () => List(WindowMonitorInfo)

	## Suggest a top-left position in virtual-desktop coordinates.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	window_suggest_position! : { x : I32, y : I32 } => {}

	## Suggest a monitor; ignore a stale or invalid index.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	window_suggest_monitor! : I32 => {}

	## Tilemap interface
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

	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	tilemap_load_tmx! : Str => Try(TilemapMap, [NotFound, ParseFailed, ReadFailed, Unsupported])

	## Legal in `render!` only.
	tilemap_draw! : TilemapRenderRequest => {}

	## Sqlite interface
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
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	sqlite_open! : Str, U8, U64, U64 => SqliteOpenResult

	## Close early; final handle release remains the fallback.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	sqlite_close! : SqliteDb => SqliteStatusResult

	## Compile one statement for reuse.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	sqlite_prepare! : SqliteDb, Str => SqlitePrepareResult

	## Bind and run a prepared statement to completion, then reset it.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	sqlite_run_stmt! : SqliteStmt, List(SqliteBindingWire) => SqliteQueryResult

	## Prepare, bind, run, and finalize without retaining a statement.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	sqlite_run_once! : SqliteDb, Str, List(SqliteBindingWire) => SqliteQueryResult

	## Run a script without bindings or returned rows.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	sqlite_exec_script! : SqliteDb, Str => SqliteStatusResult

	## Draw interface
	## Zero-sized frame authority minted by the adapter.
	DrawFrame : {}

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

	## Prepared-text drawing parameters.
	DrawPreparedTextDraw : { prepared : TextPrepared, pos : Math.Vec2, color : Color.Rgba }

	## Current frame dimensions.
	DrawFrameSize : { width : F32, height : F32 }

	## Textured-rectangle parameters.
	DrawTextureDraw : { texture : Texture, source : Math.Rect, dest : Math.Rect, origin : Math.Vec2, rotation : F32, tint : Color.Rgba }

	## One textured-rectangle instance.
	DrawTextureInstance : { source : Math.Rect, dest : Math.Rect, origin : Math.Vec2, rotation : F32, tint : Color.Rgba }

	## Borrowed instances sharing one texture and hosted call.
	DrawTextureInstances : { texture : Texture, instances : List(DrawTextureInstance) }

	## Arbitrary textured-quad parameters.
	DrawTextureQuad : { texture : Texture, source : Math.Rect, top_left : Math.Vec2, bottom_left : Math.Vec2, bottom_right : Math.Vec2, top_right : Math.Vec2, q_top_left : F32, q_bottom_left : F32, q_bottom_right : F32, q_top_right : F32, tint : Color.Rgba }

	## Begin 2D drawing with a camera.
	## Legal in `render!` only.
	draw_begin_camera! : Camera.Camera2D => U8

	## End 2D camera drawing.
	## Legal in `render!` only.
	draw_end_camera! : () => {}

	## Begin the flattened blend mode.
	## Legal in `render!` only.
	draw_begin_blend! : U8 => U8

	## Restore alpha blending.
	## Legal in `render!` only.
	draw_end_blend! : () => {}

	## Begin drawing to a render target.
	## Legal in `render!` only.
	draw_begin_render_texture! : TextureRenderTarget => U8

	## End render-target drawing.
	## Legal in `render!` only.
	draw_end_render_texture! : () => {}

	## Begin clipping to a screen rectangle.
	## Legal in `render!` only.
	draw_begin_scissor! : DrawScissor => U8

	## End scissor clipping.
	## Legal in `render!` only.
	draw_end_scissor! : () => {}

	## Begin custom-shader drawing.
	## Legal in `render!` only.
	draw_begin_shader! : Shader => U8

	## Restore the default shader.
	## Legal in `render!` only.
	draw_end_shader! : () => {}

	## Draw a filled circle.
	## Legal in `render!` only.
	draw_circle! : DrawCircle => {}

	## Draw a gradient-filled circle.
	## Legal in `render!` only.
	draw_circle_gradient! : DrawCircleGradient => {}

	## Draw a circle outline.
	## Legal in `render!` only.
	draw_circle_lines! : DrawCircleLines => {}

	## Clear the current drawing target.
	## Legal in `render!` only.
	draw_clear! : Color.Rgba => {}

	## Draw the current FPS.
	## Legal in `render!` only.
	draw_fps! : DrawFps => {}

	## Draw a line.
	## Legal in `render!` only.
	draw_line! : DrawLine => {}

	## Draw prepared text.
	## Legal in `render!` only.
	draw_draw_prepared_text! : DrawPreparedTextDraw => {}

	## Get the current frame dimensions.
	## Legal in `render!` only.
	draw_frame_size! : () => DrawFrameSize

	## Draw a filled polygon.
	## Legal in `render!` only.
	draw_polygon! : DrawPolygon => {}

	## Draw a polygon outline.
	## Legal in `render!` only.
	draw_polygon_lines! : DrawPolygonLines => {}

	## Draw a filled rectangle.
	## Legal in `render!` only.
	draw_rectangle! : DrawRectangle => {}

	## Draw a horizontal-gradient rectangle.
	## Legal in `render!` only.
	draw_rectangle_gradient_h! : DrawRectangleGradientH => {}

	## Draw a vertical-gradient rectangle.
	## Legal in `render!` only.
	draw_rectangle_gradient_v! : DrawRectangleGradientV => {}

	## Draw a rectangle outline.
	## Legal in `render!` only.
	draw_rectangle_lines! : DrawRectangleLines => {}

	## Draw a filled rounded rectangle.
	## Legal in `render!` only.
	draw_rounded_rectangle! : DrawRoundedRectangle => {}

	## Draw a rounded-rectangle outline.
	## Legal in `render!` only.
	draw_rounded_rectangle_lines! : DrawRoundedRectangleLines => {}

	## Draw text with a font.
	## Legal in `render!` only.
	draw_text! : DrawText => {}

	## Draw part of a texture into a rectangle.
	## Legal in `render!` only.
	draw_draw_texture! : DrawTextureDraw => {}

	## Draw a batch of texture instances.
	## Legal in `render!` only.
	draw_draw_texture_instances! : DrawTextureInstances => {}

	## Draw part of a texture as an arbitrary quad.
	## Legal in `render!` only.
	draw_draw_texture_quad! : DrawTextureQuad => {}

	## Draw a filled counter-clockwise triangle.
	## Legal in `render!` only.
	draw_triangle! : DrawTriangle => {}

	## Draw a counter-clockwise triangle outline.
	## Legal in `render!` only.
	draw_triangle_lines! : DrawTriangleLines => {}

	## Capture interface
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

	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	capture_set_virtual_mouse! : CaptureVirtualMouse => {}

	## Scripted held keys; inactive returns control to hardware.
	##
	## The host derives edges between consecutive states.
	CaptureVirtualKeys : {
		active : Bool,
		keys : List(U64),
	}

	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	capture_set_virtual_keys! : CaptureVirtualKeys => {}

	## Queue codepoints for one delivery on the next frame.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	capture_set_virtual_text! : List(U32) => {}

	## Arm recording and latch its result for the next `Input`.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	capture_start_recording! : CaptureStartRecording => U8

	## Finalize the running recording and write its file.
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	capture_stop_recording! : () => CaptureStopResult

	## Write the next framebuffer as PNG, parking until complete.
	## Legal only in a task, where it parks the task; refused in `init!`, `update!`, and `render!`.
	capture_screenshot! : Str => U8

	## A render target and output path.
	CaptureTextureShot : {
		target : TextureRenderTarget,
		path : Str,
	}

	## Read back a target, then park while encoding and writing its PNG.
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks the task; refused in `update!` and `render!`.
	capture_screenshot_texture! : CaptureTextureShot => U8

	## Flattened screen-or-target source.
	##
	## `screen` selects the last frame; otherwise `target` is used.
	CapturePixelSource : {
		target : TextureRenderTarget,
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
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
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
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	capture_read_region! : CaptureRegionProbe => CaptureRegionResult

}
