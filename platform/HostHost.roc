## Internal operating-system and window transport.
##
## This module is intentionally not exposed by the platform package.
HostHost := [].{

	## Zero-sized startup capability constructed only by the platform adapter.
	Startup :: {}.{
		for_host : Startup
		for_host = Startup.({})
	}

	ReadFileResult : {
		ok : Bool,
		err : U8,
		contents : Str,
	}

	exit! : I32 => {}
	get_clipboard_text! : () => Try(Str, [Unavailable])
	read_env! : Str => Try(Str, [NotFound])
	read_file! : Str => ReadFileResult
	random_i32! : I32, I32 => I32
	set_clipboard_text! : Str => {}
	set_exit_key! : I32 => {}
	set_screen_size! : { width : I32, height : I32 } => Try({}, [NotSupported])
	set_target_fps! : I32 => {}
	set_window_min_size! : { width : I32, height : I32 } => {}
}
