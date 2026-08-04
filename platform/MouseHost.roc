## Internal native-cursor transport.
##
## This module is intentionally not exposed by the platform package.
MouseHost := [].{
	set_cursor_mode! : U8 => {}
	set_cursor! : U8 => {}
}
