## The pure value types a RocRay app, a library, and the platform all pass
## around: device snapshots, keys, colors, vectors, cameras, fonts, textures,
## and the small records that describe a window or a recording. There are no
## effects here and no dependency on the platform, so a library written against
## this package works with any RocRay app.
##
## This is also where the receivers are documented. `roc docs` attaches a
## nominal's receivers to the module that declares it, so `Camera2D.with_zoom`,
## `Snapshot.position` and the rest appear on these pages rather than on the
## platform pages that re-export the same types under their own names.
##
## Most apps never depend on this package directly. The platform's `Color`,
## `Devices`, `Keys`, `Mouse`, `Gamepad`, `Time`, `Window`, `Math`, `Camera`,
## `Physics`, `Capture`, `Draw` and `Text` modules re-export what is here, so an
## app names these types through the platform it already depends on. Depend on
## this package when writing a library that should not depend on the platform.
##
## `Devices` is the entry point: it is the snapshot `App.Input` carries, and it
## holds the keyboard, the mouse, and the gamepads.
##
## ```roc
## quitting : Devices.Snapshot -> Bool
## quitting = |devices| devices.key_pressed(KeyEscape)
## ```
package
	[Devices, Keys, Mouse, Gamepad, Time, Window, Math, Camera, Physics, Color, Capture, Font, Texture, Drawing]
	{
		unicode: "https://github.com/roc-lang/unicode/releases/download/3.0.0/ACj5ceJnEY6vaejuQArN1naVzcxeThATZrKYYgzJCZJ5.tar.zst",
	}
