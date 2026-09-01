## Pure RocRay value types for reusable packages.
##
## Apps normally use the platform's re-exports. Depend on this package when a
## library needs shared snapshots, geometry, resources, or configuration types
## without acquiring host effects. Resource handles remain opaque and cannot
## be created here.
##
## ```roc
## quitting : Devices.Snapshot -> Bool
## quitting = |devices| devices.key_pressed(KeyEscape)
## ```
package
	[App, Devices, Keys, Mouse, Gamepad, Time, Window, Math, Camera, Physics, Color, Capture, Resource, Font, Texture, Drawing]
	{
		unicode: "https://github.com/roc-lang/unicode/releases/download/3.0.0/ACj5ceJnEY6vaejuQArN1naVzcxeThATZrKYYgzJCZJ5.tar.zst",
	}
