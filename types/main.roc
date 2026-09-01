## Shared RocRay vocabulary and caller-injected effect interfaces.
##
## Apps normally use the platform's re-exports. Depend on this package when a
## library needs shared snapshots, geometry, resources, configuration types, or
## an effect handle without depending on the RocRay platform. This package has
## no hosted declarations and cannot create resources or callback authority;
## only a handle configured and supplied by the application can reach the host.
##
## A reusable renderer accepts `Drawing.Effects`. A package that needs a
## waiting effect accepts `App.Effects(frame)` and exposes a task body; the
## application supplies the configured handle, input witness, and message
## wrapper. See `docs/package-authors.md` in the RocRay repository for the
## complete dependency and authority pattern.
##
## ```roc
## draw_panel! : Drawing.Effects, Drawing.RoundedRectangle => {}
## draw_panel! = |draw, panel| draw.rounded_rectangle!(panel)
## ```
package
	[App, Devices, Keys, Mouse, Gamepad, Time, Window, Math, Camera, Physics, Color, Capture, Font, Texture, Drawing, Files]
	{
		unicode: "https://github.com/roc-lang/unicode/releases/download/3.0.0/ACj5ceJnEY6vaejuQArN1naVzcxeThATZrKYYgzJCZJ5.tar.zst",
	}
