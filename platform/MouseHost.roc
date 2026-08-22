## Internal native-cursor transport.
##
## This module is intentionally not exposed by the platform package.
MouseHost := [].{

	## Apply visibility and capture as one operation. `Mouse.cursor_mode_code`
	## flattens the tag.
	set_cursor_mode! : U8 => {}

	## Set the native cursor shape. `Mouse.cursor_code` flattens the tag.
	set_cursor! : U8 => {}
}
