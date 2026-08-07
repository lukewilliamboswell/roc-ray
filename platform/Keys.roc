## Keys module - keyboard state and key constants.
##
## The types and pure helpers live in the companion `roc-ray-types` package so
## reusable packages can depend on them without depending on this platform.
## This module re-exports them, so `KeyboardKey` here and in the package are the
## same nominal type and values pass between them freely.
import rrt.Keys as RrtKeys

Keys := [].{

	## Named raylib keyboard keys plus a validated backend-specific escape hatch.
	KeyboardKey : RrtKeys.KeyboardKey

	## Which key, if any, closes the window. `NoExitKey` disables the behaviour.
	ExitKey := [NoExitKey, ExitKey(KeyboardKey)].{
		is_eq : _
	}

	## Flatten an exit key to the raylib key code the host passes to
	## `SetExitKey`. `0` is raylib's `KEY_NULL`, which disables the behaviour.
	## Shared by the startup config and the runtime `Host.set_exit_key!` effect
	## so the two cannot drift.
	exit_key_code : ExitKey -> I32
	exit_key_code = |value|
		match value {
			NoExitKey => 0
			ExitKey(key) => U64.to_i32_wrap(Keys.key_code(key))
		}

	## Validate and wrap a raw raylib key code.
	from_code : U64 -> Try(KeyboardKey, [InvalidKeyCode, ..])
	from_code = RrtKeys.from_code

	## raylib key code for a key (index into the Host key-state lists).
	key_code : KeyboardKey -> U64
	key_code = RrtKeys.key_code

	## Check if a specific key is currently held down. Pass `host` directly.
	key_down : { keys : List(U8), ..state }, KeyboardKey -> Bool
	key_down = RrtKeys.key_down

	## Check if a specific key is currently not pressed (up). Pass `host` directly.
	key_up : { keys : List(U8), ..state }, KeyboardKey -> Bool
	key_up = RrtKeys.key_up

	## Check if a key was first pressed this frame. Pass `host` directly.
	key_pressed : { keys : List(U8), ..state }, KeyboardKey -> Bool
	key_pressed = RrtKeys.key_pressed

	## Check if a key was released this frame. Pass `host` directly.
	key_released : { keys : List(U8), ..state }, KeyboardKey -> Bool
	key_released = RrtKeys.key_released
}
