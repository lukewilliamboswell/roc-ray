## Internal operating-system and window transport.
##
## This module is intentionally not exposed by the platform package.
HostHost := [].{
	ReadFileResult : {
		ok : Bool,
		err : U8,
		contents : Str,
	}

	exit! : I32 => {}
	read_env! : Str => Try(Str, [NotFound])
	read_file! : Str => ReadFileResult
	random_i32! : I32, I32 => I32
	set_screen_size! : { width : F32, height : F32 } => Try({}, [NotSupported])
	set_target_fps! : I32 => {}
}
