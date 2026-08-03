## Internal native-cursor transport.
##
## This module is intentionally not exposed by the platform package.
MouseHost := [].{
	show_cursor! : () => {}
	hide_cursor! : () => {}
	lock_cursor! : () => {}
	unlock_cursor! : () => {}
	set_cursor! : U8 => {}
}
