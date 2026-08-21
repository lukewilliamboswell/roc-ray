## Internal host transport for validated startup configuration.
##
## `App` owns the application-facing `Config` and its receivers. This module
## holds only the flattening to the native ABI record, and is deliberately
## omitted from the platform's `exposes` list so an app cannot reach it.
##
## It reads a Config through `App`'s public receivers rather than its fields:
## a `::` nominal is opaque outside the module that declares it.
import App
import Capture
import Keys
import Mouse
import rrt.Capture as RrtCapture

AppHostConfig : {
	title : Str,
	width : I32,
	height : I32,
	min_width : I32,
	min_height : I32,
	target_fps : I32,
	resizable : Bool,
	fullscreen : Bool,
	vsync : Bool,
	cursor_visible : Bool,
	exit_key_code : I32,
	visible : Bool,
	output_dir : Str,
	record_enabled : Bool,
	record_path : Str,
	record_format : U8,
	record_fps : I32,
	record_max_frames : U64,
	record_scale_numerator : U32,
	record_scale_denominator : U32,
	record_every_nth : U32,
	record_timing : U8,
	record_cursor : U8,
	record_quality : U8,
}

AppConfig := [].{

	## Flatten validated choices to the stable native ABI record. This is a
	## module function, not a Config receiver, and AppConfig is not exposed.
	HostConfig : AppHostConfig

	to_host : {}, App.Config -> HostConfig
	to_host = |_, cfg| {
		pacing = host_pacing(cfg.frame_pacing())
		size = cfg.size()
		min_size = cfg.min_size()
		record = host_recording(cfg.recording())
		{
			title: cfg.title(),
			width: size.width,
			height: size.height,
			min_width: min_size.width,
			min_height: min_size.height,
			target_fps: pacing.target_fps,
			resizable: cfg.resizable(),
			fullscreen: cfg.fullscreen(),
			vsync: pacing.vsync,
			cursor_visible: Mouse.cursor_mode_code(cfg.cursor_mode()) == 0,
			exit_key_code: Keys.exit_key_code(cfg.exit_key()),
			visible: cfg.visible(),
			output_dir: cfg.output_dir(),
			record_enabled: record.enabled,
			record_path: record.path,
			record_format: record.format,
			record_fps: record.fps,
			record_max_frames: record.max_frames,
			record_scale_numerator: record.scale_numerator,
			record_scale_denominator: record.scale_denominator,
			record_every_nth: record.every_nth,
			record_timing: record.timing,
			record_cursor: record.cursor,
			record_quality: record.quality,
		}
	}
}

## Flatten the optional startup recording to the flat ABI fields.
##
## `NoRecording` still has to fill every field, so it supplies inert values the
## host ignores while `record_enabled` is false.
host_recording : [NoRecording, Record(Capture.Recording)] -> {
	enabled : Bool,
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
host_recording = |value|
	match value {
		NoRecording => {
			enabled: Bool.False,
			path: "",
			format: 0,
			fps: 0,
			max_frames: 0,
			scale_numerator: 1,
			scale_denominator: 1,
			every_nth: 1,
			timing: 0,
			cursor: 0,
			quality: RrtCapture.quality_code(Balanced),
		}
		Record(recording) => {
			ratio = RrtCapture.scale_ratio(recording.scale())
			{
				enabled: Bool.True,
				path: recording.path(),
				format: RrtCapture.format_code(recording.format()),
				fps: recording.fps(),
				max_frames: recording.max_frames(),
				scale_numerator: ratio.numerator,
				scale_denominator: ratio.denominator,
				every_nth: recording.every_nth(),
				timing: RrtCapture.timing_code(recording.timing()),
				cursor: RrtCapture.cursor_code(recording.cursor()),
				quality: RrtCapture.quality_code(recording.quality()),
			}
		}
	}

host_pacing : App.FramePacing -> { target_fps : I32, vsync : Bool }
host_pacing = |value|
	match value {
		VSync => { target_fps: 0, vsync: Bool.True }
		Capped(fps) => { target_fps: fps, vsync: Bool.False }
		Uncapped => { target_fps: 0, vsync: Bool.False }
	}

expect {
	cfg = App.default.with_title("Test").with_size({ width: 320, height: 240 })
	host = AppConfig.to_host({}, cfg)
	host.title == "Test" and host.width == 320 and host.height == 240 and host.target_fps == 240 and !(host.vsync) and host.cursor_visible
}
expect AppConfig.to_host({}, App.default.with_frame_pacing(Capped(120))) == { ..AppConfig.to_host({}, App.default), target_fps: 120 }
expect {
	host = AppConfig.to_host({}, App.default.with_resizable(Bool.True).with_fullscreen(Bool.True))
	host.resizable and host.fullscreen
}
expect AppConfig.to_host({}, App.default.with_size({ width: 0, height: -5 })) == AppConfig.to_host({}, App.default)
expect {
	host = AppConfig.to_host({}, App.default.with_min_size({ width: 640, height: -1 }))
	host.min_width == 640 and host.min_height == 0
}
expect AppConfig.to_host({}, App.default).exit_key_code == 256
expect AppConfig.to_host({}, App.default.with_exit_key(NoExitKey)).exit_key_code == 0
expect AppConfig.to_host({}, App.default.with_exit_key(ExitKey(KeyQ))).exit_key_code == 81
expect AppConfig.to_host({}, App.default).visible
expect !(AppConfig.to_host({}, App.default.with_visible(Bool.False)).visible)
expect AppConfig.to_host({}, App.default).output_dir == "."
expect AppConfig.to_host({}, App.default.with_output_dir("captures")).output_dir == "captures"
expect !(AppConfig.to_host({}, App.default).record_enabled)
expect {
	host = AppConfig.to_host({}, App.default.with_recording(RrtCapture.default))
	host.record_enabled and host.record_path == "recording.gif" and host.record_format == 1 and host.record_fps == 25
}
expect {
	host = AppConfig.to_host({}, App.default.with_recording(RrtCapture.default))
	host.record_max_frames == 300 and host.record_scale_numerator == 1 and host.record_scale_denominator == 2
}
expect {
	host = AppConfig.to_host({}, App.default.with_recording(RrtCapture.default))
	host.record_every_nth == 1 and host.record_timing == 1 and host.record_cursor == 0
}
expect AppConfig.to_host({}, App.default.with_recording(RrtCapture.default)).record_quality == 1
expect {
	fast = RrtCapture.default.with_quality(Fast)
	best = RrtCapture.default.with_quality(Best)
	AppConfig.to_host({}, App.default.with_recording(fast)).record_quality == 0 and AppConfig.to_host({}, App.default.with_recording(best)).record_quality == 2
}
expect {
	custom =
		RrtCapture.default
			.with_path("demo.webm")
			.with_format(WebM)
			.with_scale(Quarter)
			.with_timing(RealTime)
			.with_cursor(DrawCursor)
			.with_every_nth(4)
	host = AppConfig.to_host({}, App.default.with_recording(custom))
	host.record_path == "demo.webm" and host.record_format == 2 and host.record_scale_denominator == 4 and host.record_timing == 0 and host.record_cursor == 1 and host.record_every_nth == 4
}

## A disabled recording still fills every ABI field with inert values.
expect {
	host = AppConfig.to_host({}, App.default)
	host.record_path == "" and host.record_scale_denominator == 1 and host.record_every_nth == 1 and host.record_quality == 1
}
