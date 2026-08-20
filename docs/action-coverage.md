# Action coverage

A hosted effect reachable in the commit phase without a corresponding
`Program.Action` is dead API.

`update` is pure and `render!` may only draw, so after `init!` returns there is
exactly one way for an app to change host state: return an `Action` from
`update` and let `run_action!` in `platform/main.roc` interpret it. An effect the
host will accept during the commit phase but that no action can ask for is
therefore reachable only from `init!` -- which makes the commit-phase permission
a lie, and leaves apps with a capability they can see in the docs and cannot use.

Every operation the host guards with `enforcePhase(name, during_commit)` in
`src/host_native.zig` appears in the table below, either against the action that
reaches it or against the reason it deliberately has none. `zig build lint`
fails when a name is missing, so adding a commit-phase effect without deciding
this question breaks the build.

## Actions

| Hosted operation | Action | Constructor |
| --- | --- | --- |
| `Program.exit` | `Exit` | `Program.exit` |
| `Mouse.set_cursor` | `SetCursor` | `Mouse.set_cursor` |
| `Mouse.set_cursor_mode` | `SetCursorMode` | `Mouse.set_cursor_mode` |
| `Window.set_clipboard_text` | `SetClipboardText` | `Window.set_clipboard_text` |
| `Keys.set_exit_key` | `SetExitKey` | `Keys.set_exit_key` |
| `Window.set_size` | `SetWindowSize` | `Window.set_size` |
| `Window.set_window_min_size` | `SetWindowMinSize` | `Window.set_window_min_size` |
| `Window.set_target_fps` | `SetTargetFps` | `Window.set_target_fps` |
| `Audio.Sound.play!` | `PlaySound` | `sound.play()`, `sound.playback().play()` |
| `Audio.Sound.stop!` | `StopSound` | `sound.stop()` |
| `Audio.Sound.pause!` | `PauseSound` | `sound.pause()` |
| `Audio.Sound.resume!` | `ResumeSound` | `sound.resume()` |
| `Audio.Music.play!` | `PlayMusic` | `music.play()` |
| `Audio.Music.stop!` | `StopMusic` | `music.stop()` |
| `Audio.Music.pause!` | `PauseMusic` | `music.pause()` |
| `Audio.Music.resume!` | `ResumeMusic` | `music.resume()` |
| `Audio.Music.set_volume!` | `SetMusicVolume` | `music.set_volume(v)` |
| `Audio.Music.set_pitch!` | `SetMusicPitch` | `music.set_pitch(p)` |
| `Audio.Music.set_pan!` | `SetMusicPan` | `music.set_pan(p)` |
| `Audio.Music.set_looping!` | `SetMusicLooping` | `music.set_looping(b)` |
| `Audio.Music.seek!` | `SeekMusic` | `music.seek(seconds)` |
| `Audio.set_master_volume!` | `SetMasterVolume` | `Audio.set_master_volume` |
| `Assets.update_texture!` | `UpdateTexture` | `Assets.update_texture` |
| `Assets.update_texture_region!` | `UpdateTextureRegion` | `Assets.update_texture_region` |
| `Assets.set_texture_filter!` | `SetTextureFilter` | `Assets.set_texture_filter` |
| `Assets.set_texture_wrap!` | `SetTextureWrap` | `Assets.set_texture_wrap` |
| `Capture.set_virtual_mouse` | `SetVirtualMouse` | `Capture.set_virtual_mouse` |
| `Capture.start` | `StartRecording` | `Capture.start` |
| `Capture.stop` | `StopRecording` | `Capture.stop` |

## Commit-phase effects with no action

| Hosted operation | Why not an action |
| --- | --- |
| `Audio.Sound.set_volume!` | Folded into `PlaySound`. See below. |
| `Audio.Sound.set_pitch!` | Folded into `PlaySound`. See below. |
| `Audio.Sound.set_pan!` | Folded into `PlaySound`. See below. |

raylib holds volume, pitch, and pan on the sound resource itself, so they
outlive the play that set them and the next play by anyone inherits them.
`Audio.Playback` states all three on every play instead, which makes the
parameters an argument of playing rather than sticky state, and `Sound.play!`
is defined as `sound.playback().play!()` so the effectful path cannot differ
from the action path. There is deliberately no `Sound.set_volume!` left to call:
setting one and expecting it to last was a trap, because the very next
`PlaySound` overwrote it silently and no headless test could hear the
difference.

## Capabilities that are not actions at all

These never appear in the table above, because the host does not allow them in
the commit phase in the first place. They are listed so the absence is a
decision rather than an oversight.

**Reads of host state** -- `App.Startup.get_clipboard_text!`,
`Audio.Sound.is_playing!`, `Audio.Music.is_playing!`, `Audio.Music.length!`,
`Audio.Music.time_played!`, `App.Startup.random_i32!`, `Host.read_env!`,
`Host.read_file!`. An action has no result channel: it runs, and the cycle moves
on. Anything with an answer arrives either on the `Step` the host samples for
each cycle, or as a `Program.Task` whose callback delivers one message on a
later step. Adding a read as an action would mean inventing somewhere for the
answer to go.

**Loading, generating, and allocating resources** -- `Assets.Store.open!`,
`Assets.load_texture!`, `Assets.texture_from_bytes!`,
`Assets.generate_color_texture!`, `Assets.generate_checked_texture!`,
`Audio.load_sound!`, `Audio.load_music!`, `Audio.gen_sound!`, `Audio.gen_tone!`,
`Draw.RenderTexture.load!`, `Draw.Shader.from_source!`, `Draw.Shader.from_store!`,
`Draw.font_from_bytes!`, `Text.prepare!`, `Tilemap.load_tmx!`. These block on I/O,
allocate on the GPU, or both, and are startup-only by design: an app loads in
`init!` and keeps the handle in its model. They also return a resource, which is
the same result-channel problem as a read.

**Drawing and draw state** -- everything guarded `during_render`. Draw calls and
the scopes around them are ordered against each other, and that order is only
meaningful inside `render!`. Shader uniforms in particular have to be set where
their position relative to the draws they affect is visible, which is inside
`Frame.with_shader!` and nowhere else.

`Draw.Frame.size!` is guarded the same way despite being a read rather than a
mutation, and for the same reason: its answer is the *active* surface, which is
the window normally and the render target inside `Frame.with_render_texture!`.
That is a fact about where the surrounding draw calls are landing, so it has no
meaning outside the frame -- and admitting it anywhere else would make it a way
for `update` to observe the window without going through the step.

**Toggling fullscreen at runtime** -- deliberately deferred. There is no hosted
effect for it yet, and adding one means deciding what fullscreen *means* here:
real mode switch or borderless window, what happens to the logical drawing size
the app has been laying out against, and what `Window.Snapshot` reports across
the transition. That is a design question rather than a missing variant, so it
is not being answered by adding an action.
