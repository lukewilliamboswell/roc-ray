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
	[
		App,
		Devices,
		Keys,
		Mouse,
		Gamepad,
		Time,
		Window,
		Math,
		Camera,
		Physics,
		Color,
		Capture,
		Handle,
		Font,
		Texture,
		Shader,
		Store,
		TextPrepared,
		AudioSound,
		AudioMusic,
		UdpSocket,
		SqliteDb,
		SqliteStmt,
		Drawing,
	]
	{}

import resources/Handle
import resources/Font
import resources/Texture
import resources/Shader
import resources/Store
import resources/TextPrepared
import resources/AudioSound
import resources/AudioMusic
import resources/UdpSocket
import resources/SqliteDb
import resources/SqliteStmt
