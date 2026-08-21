## Keys module - keyboard state and key constants.
##
## The types and pure helpers live in the companion `roc-ray-types` package so
## reusable packages can depend on them without depending on this platform.
## This module re-exports them, so `Key` here and in the package are the
## same nominal type and values pass between them freely.
##
## Receivers are documented in the [roc-ray-types docs](../types/),
## which is where the nominal is declared.
import rrt.Keys as RrtKeys

Keys := [].{

	## Named raylib keyboard keys plus a validated backend-specific escape hatch.
	Key : RrtKeys.Key

	## Which key, if any, closes the window. `NoExitKey` disables the behaviour.
	ExitKey : RrtKeys.ExitKey

	## Flatten an exit key to the raylib key code the host passes to `SetExitKey`.
	exit_key_code : ExitKey -> I32
	exit_key_code = RrtKeys.exit_key_code

	## Validate and wrap a raw raylib key code.
	from_code : U64 -> Try(Key, [InvalidKeyCode, ..])
	from_code = RrtKeys.from_code

	## raylib key code for a key (index into the sampled key-state lists).
	key_code : Key -> U64
	key_code = RrtKeys.key_code

	## Check if a specific key is currently held down. Pass `input.devices` directly.
	key_down : { keys : List(U8), ..state }, Key -> Bool
	key_down = RrtKeys.key_down

	## Check if a specific key is currently not pressed (up). Pass `input.devices` directly.
	key_up : { keys : List(U8), ..state }, Key -> Bool
	key_up = RrtKeys.key_up

	## Check if a key was pressed during this input interval. Pass `input.devices` directly.
	key_pressed : { keys : List(U8), ..state }, Key -> Bool
	key_pressed = RrtKeys.key_pressed

	## Check if a key was released during this input interval. Pass `input.devices` directly.
	key_released : { keys : List(U8), ..state }, Key -> Bool
	key_released = RrtKeys.key_released

	## Set which key closes the window, as a command.
	##
	## `NoExitKey` stops any key from closing it; raylib defaults to
	## `ExitKey(KeyEscape)`. The window close button is unaffected either way,
	## so an app that disables the exit key should still handle shutdown itself
	## through `App.exit`.
	set_exit_key : ExitKey -> [SetExitKey(ExitKey), ..]
	set_exit_key = |key| SetExitKey(key)
}
