## Shared RocRay vocabulary and caller-injected effect interfaces.
##
## Apps normally use the platform's re-exports. Depend on this package when a
## library needs shared snapshots, geometry, resources, configuration types, or
## an effect handle without depending on the RocRay platform. This package has
## no hosted declarations and cannot create resources or callback authority;
## only a handle configured and supplied by the application can reach the host.
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
