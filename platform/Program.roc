## Message-driven application updates and deferred host work.
##
## The host calls pure `update` once per cycle with a `Step`. The result contains
## the next model, immediate `Action` values, and asynchronous `Task` values.
## Actions run in order before rendering. Each submitted task invokes its typed
## callback exactly once on a later step while the app remains running,
## contributing one application message. App termination drops pending callbacks
## because there can be no later `Step` to deliver them on.
##
## `Delay` uses wall time. Animation and physics should use `step.time`.
import Input
import Window
import Time
import Keys
import Mouse
import Audio
import Assets
import Capture
import Color
import Draw
import rrt.Texture

Program := [].{

	## Everything the host observed since the previous cycle.
	##
	## `messages` contains all task callbacks completed for this cycle, in the
	## order the host observed their completions. Independent asynchronous tasks
	## may complete in any order; their submission order does not constrain it.
	## `capture` contains the recording status sampled for this cycle.
	Step(msg) := {
		input : Input.Snapshot,
		window : Window.Snapshot,
		time : Time.Frame,
		messages : List(msg),
		capture : Capture.Status,
	}.{

		## Return the complete structural step for platform-independent libraries.
		fields : Step(msg) -> {
			input : Input.Snapshot,
			window : Window.Snapshot,
			time : Time.Frame,
			messages : List(msg),
			capture : Capture.Status,
		}
		fields = |step| step

		## Construct a static update through the step capability
		static : Step(msg), value -> Update(value, msg)
		static = |_step, value| Program.static(value)
	}

	## A value paired with work for the platform.
	##
	## `Update` is the application-facing update result. Use `Program.static` to
	## start one, then its receiver methods to add work. It is applicative, so a
	## record whose fields are `Update` values can use the record-builder form:
	##
	##     { game: game_update, ui: ui_update }.Program
	##
	## This combines fields and appends their work from left to right.
	## `actions` run this cycle, in order, before `render!`. `tasks` go to the
	## host in list order and answer on a later `Step`. While the app remains
	## running, every submitted task gets exactly one terminal callback, including
	## `Err(Busy)` when current host capacity cannot complete it; independent
	## asynchronous completions have no specified order. App termination drops pending
	## callbacks because no later step can observe them.
	##
	## Changing a collection in the model costs a copy of it. The model reaches
	## `update` still referenced by the box it arrived in, so the first write to
	## one of its lists allocates a new one rather than mutating in place:
	## measured at 4,000,000 bytes per frame for a one-million-element
	## `List(F32)` (`test/model_inplace`, checked by
	## `scripts/test_model_allocation.py`). Later writes to that same collection
	## within one cycle are in place, so batching a cycle's changes into one
	## `update` costs one copy rather than several. A collection that changes
	## every frame is worth keeping small until this is fixed.
	Update(value, msg) := [
		Update(
			{
				value : value,
				actions : List(Action),
				tasks : List(Task(msg)),
			},
		),
	].{

		## Inspect the value and work. This is for the platform adapter; app code
		## should prefer `static`, receiver builders, and record builders.
		fields : Update(value, msg) -> {
			value : value,
			actions : List(Action),
			tasks : List(Task(msg)),
		}
		fields = |update|
			match update {
				Update(fields) => fields
			}

		## Start an update with no host work.
		static : value -> Update(value, msg)
		static = |value| Update.(Update({ value, actions: [], tasks: [] }))

		## Transform the value while retaining its ordered host work.
		map : Update(a, msg), (a -> b) -> Update(b, msg)
		map = |update, transform| {
			update_fields = update.fields()
			Update.(Update({ value: transform(update_fields.value), actions: update_fields.actions, tasks: update_fields.tasks }))
		}

		## Lift an update's messages into an enclosing application's message type.
		##
		## The value and the actions are carried through unchanged; every task is
		## mapped with `Task.map`, so each task still asks the host for exactly
		## the same work and only its callback is wrapped. This is the piece that
		## lets a reusable component own tasks: the component's `update` returns
		## `Update(ChildModel, ChildMsg)`, and the parent lifts the whole result
		## in one call rather than unpacking the task list.
		##
		##     # The component, which knows nothing about its parent:
		##     Counter.update : Counter.Model, Program.Step(Counter.Msg) -> Program.Update(Counter.Model, Counter.Msg)
		##     Counter.update = |model, _step|
		##         Program.static({ ..model, ticks: model.ticks + 1 })
		##             .with_task(Program.delay(200, |_| Tick))
		##
		##     # The parent, whose `Msg` wraps the component's. `counter_step`
		##     # is the parent's own helper, narrowing `step.messages` to the
		##     # ones it wrapped.
		##     Msg : [Counter(Counter.Msg), Quit]
		##
		##     update = |model, step|
		##         Counter.update(model.counter, counter_step(step))
		##             .map(|counter| { ..model, counter })
		##             .map_msg(|inner| Counter(inner))
		##
		## A lifted update is an ordinary `Update`, so a parent that owns two
		## components combines them with the record-builder form:
		##
		##     Model : { left : Counter.Model, right : Counter.Model }
		##     Msg : [Left(Counter.Msg), Right(Counter.Msg)]
		##
		##     update = |model, step|
		##         {
		##             left: Counter.update(model.left, left_step(step)).map_msg(|inner| Left(inner)),
		##             right: Counter.update(model.right, right_step(step)).map_msg(|inner| Right(inner)),
		##         }.Program
		##
		## That builds the model from both components' values and appends their
		## work, left to right, into one `Update(Model, Msg)`.
		map_msg : Update(value, a), (a -> b) -> Update(value, b)
		map_msg = |update, transform| {
			update_fields = update.fields()
			Update.(
				Update({
					value: update_fields.value,
					actions: update_fields.actions,
					tasks: List.map(update_fields.tasks, |task| task.map(transform)),
				}),
			)
		}

		## Combine two updates from left to right.
		##
		## This is what enables `{ field: update }.Program` record builders.
		map2 : Update(a, msg), Update(b, msg), (a, b -> c) -> Update(c, msg)
		map2 = |left, right, combine| {
			left_fields = left.fields()
			right_fields = right.fields()
			Update.(
				Update({
					value: combine(left_fields.value, right_fields.value),
					actions: List.concat(left_fields.actions, right_fields.actions),
					tasks: List.concat(left_fields.tasks, right_fields.tasks),
				}),
			)
		}

		## Append one action after actions already requested by this update.
		with_action : Update(value, msg), Action -> Update(value, msg)
		with_action = |update, action| {
			update_fields = update.fields()
			Program.from_parts(update_fields.value, List.append(update_fields.actions, action), update_fields.tasks)
		}

		## Append actions after actions already requested by this update.
		with_actions : Update(value, msg), List(Action) -> Update(value, msg)
		with_actions = |update, actions| {
			update_fields = update.fields()
			Program.from_parts(update_fields.value, List.concat(update_fields.actions, actions), update_fields.tasks)
		}

		## Append one deferred task after tasks already requested by this update.
		with_task : Update(value, msg), Task(msg) -> Update(value, msg)
		with_task = |update, task| {
			update_fields = update.fields()
			Program.from_parts(update_fields.value, update_fields.actions, List.append(update_fields.tasks, task))
		}

		## Append deferred tasks after tasks already requested by this update.
		with_tasks : Update(value, msg), List(Task(msg)) -> Update(value, msg)
		with_tasks = |update, tasks| {
			update_fields = update.fields()
			Program.from_parts(update_fields.value, update_fields.actions, List.concat(update_fields.tasks, tasks))
		}
	}

	## Start an update with no host work.
	##
	## This and `map2` live on `Program` so `Update` participates in Roc's
	## record-builder syntax: `{ field: update }.Program`.
	static : value -> Update(value, msg)
	static = Update.static

	## Start an update with all of its ordered host work.
	##
	## Most code reads better with `static(...).with_action(...)`; this is useful
	## when a helper already computes both lists.
	from_parts : value, List(Action), List(Task(msg)) -> Update(value, msg)
	from_parts = |value, actions, tasks| Update.(Update({ value, actions, tasks }))

	## Transform an update's value while retaining its ordered host work.
	map : Update(a, msg), (a -> b) -> Update(b, msg)
	map = Update.map

	## Combine updates from left to right for record builders and explicit use.
	map2 : Update(a, msg), Update(b, msg), (a, b -> c) -> Update(c, msg)
	map2 = Update.map2

	## Lift an update's messages into an enclosing application's message type.
	##
	## See `Update.map_msg` for the parent/child recipe. This alias exists for
	## the same reason `map` and `map2` do: so the whole applicative vocabulary
	## reads from one place.
	map_msg : Update(value, a), (a -> b) -> Update(value, b)
	map_msg = Update.map_msg

	## Something the platform does on the app's behalf during this cycle.
	##
	## Actions run in list order before rendering and produce no completion.
	## Because `update` is pure and `render!` may only draw, this union is the
	## whole of what a running app can change about host state: every hosted
	## effect reachable after `init!` has a variant here, or a documented reason
	## in `docs/action-coverage.md` for why it does not.
	##
	## Set shader uniforms during `Frame.with_shader!`, where their order relative
	## to draw calls is explicit.
	Action : [
		Exit(I64),
		SetCursor(Mouse.Cursor),
		SetCursorMode(Mouse.CursorMode),
		SetClipboardText(Str),
		SetExitKey(Keys.ExitKey),
		SetWindowSize({ width : I32, height : I32 }),
		SetWindowMinSize({ width : I32, height : I32 }),
		SetTargetFps(I32),

		## Play a sound at a stated volume, pitch, and pan.
		##
		## There is deliberately no action that sets one of those on a `Sound`
		## and leaves it there: raylib holds them on the sound resource, so a
		## later play by anyone would inherit them.
		PlaySound(Audio.Playback),
		StopSound(Audio.Sound),
		PauseSound(Audio.Sound),
		ResumeSound(Audio.Sound),
		PlayMusic(Audio.Music),
		StopMusic(Audio.Music),
		PauseMusic(Audio.Music),
		ResumeMusic(Audio.Music),
		SetMusicVolume({ music : Audio.Music, volume : F32 }),
		SetMusicPitch({ music : Audio.Music, pitch : F32 }),
		SetMusicPan({ music : Audio.Music, pan : F32 }),
		SetMusicLooping({ music : Audio.Music, looping : Bool }),
		SeekMusic({ music : Audio.Music, seconds : F32 }),
		SetMasterVolume(F32),

		## Replace a texture's pixels.
		##
		## Uploads are the only actions with a runtime limit: a cycle may upload
		## `Assets.max_upload_bytes_per_step` in total. The first upload that
		## does not fit is skipped, and so is every upload after it in the same
		## cycle; those textures keep the contents they already had. Nothing
		## about that is fatal, and `check_uploads` predicts it exactly.
		UpdateTexture({ texture : Texture, pixels : List(Color.Rgba) }),
		UpdateTextureRegion({ texture : Texture, region : Assets.Region }),
		SetTextureFilter({ texture : Texture, filter : Assets.TextureFilter }),
		SetTextureWrap({ texture : Texture, wrap : Assets.TextureWrap }),
		SetVirtualMouse(Capture.Pointer),

		## Arm a recording, or finalize the one that is running.
		##
		## The outcome is reported through `step.capture`.
		StartRecording(Capture.Recording),
		StopRecording,
	]

	## The dimensions a shape keeps for a texture. The handle is left out: it is
	## an opaque host resource, and nothing pure can say anything about it.
	TextureShape : { width : F32, height : F32 }

	## What an `Action` says, with its host resources left out.
	##
	## An `Action` can carry a live host resource -- a texture handle, a sound, a
	## music stream -- and those are opaque boxed values that structural equality
	## cannot look inside. So an app cannot compare the actions its `update`
	## returned against expected ones directly. `action_shape` drops the
	## resources and keeps the parameters, which is what a test wants to assert
	## on anyway. This is the supported way to test `update`:
	##
	##     expect
	##         List.map(update(model, step).fields().actions, Program.action_shape)
	##             == [PlaySound({ volume: 1, pitch: 0.8, pan: 0 })]
	##
	## A shape deliberately does not say *which* resource an action names,
	## because a resource has no identity a pure test could name it by. Two
	## different sounds paused in the same cycle have the same shape. A texture
	## keeps its dimensions, because those are ordinary data on the value.
	##
	## `SetCursor` carries the flattened raylib cursor code that
	## `Mouse.cursor_code` produces, rather than the `Mouse.Cursor` itself: that
	## type is declared in the companion types package and does not derive
	## equality, and a shape that cannot be compared would be pointless.
	ActionShape : [
		Exit(I64),
		SetCursor(U8),
		SetCursorMode(Mouse.CursorMode),
		SetClipboardText(Str),
		SetExitKey(Keys.ExitKey),
		SetWindowSize({ width : I32, height : I32 }),
		SetWindowMinSize({ width : I32, height : I32 }),
		SetTargetFps(I32),
		PlaySound({ volume : F32, pitch : F32, pan : F32 }),
		StopSound,
		PauseSound,
		ResumeSound,
		PlayMusic,
		StopMusic,
		PauseMusic,
		ResumeMusic,
		SetMusicVolume(F32),
		SetMusicPitch(F32),
		SetMusicPan(F32),
		SetMusicLooping(Bool),
		SeekMusic(F32),
		SetMasterVolume(F32),
		UpdateTexture({ texture : TextureShape, pixel_count : U64 }),
		UpdateTextureRegion({ texture : TextureShape, x : I32, y : I32, width : I32, height : I32, pixel_count : U64 }),
		SetTextureFilter({ texture : TextureShape, filter : Assets.TextureFilter }),
		SetTextureWrap({ texture : TextureShape, wrap : Assets.TextureWrap }),
		SetVirtualMouse(Capture.Pointer),
		StartRecording(Capture.Recording),
		StopRecording,
	]

	## Reduce one action to comparable data. See `ActionShape`.
	action_shape : Action -> ActionShape
	action_shape = |action|
		match action {
			Exit(code) => Exit(code)
			SetCursor(cursor) => SetCursor(Mouse.cursor_code(cursor))
			SetCursorMode(mode) => SetCursorMode(mode)
			SetClipboardText(text) => SetClipboardText(text)
			SetExitKey(key) => SetExitKey(key)
			SetWindowSize(size) => SetWindowSize(size)
			SetWindowMinSize(size) => SetWindowMinSize(size)
			SetTargetFps(fps) => SetTargetFps(fps)
			PlaySound(settings) => PlaySound({ volume: settings.volume, pitch: settings.pitch, pan: settings.pan })
			StopSound(_sound) => StopSound
			PauseSound(_sound) => PauseSound
			ResumeSound(_sound) => ResumeSound
			PlayMusic(_music) => PlayMusic
			StopMusic(_music) => StopMusic
			PauseMusic(_music) => PauseMusic
			ResumeMusic(_music) => ResumeMusic
			SetMusicVolume(request) => SetMusicVolume(request.volume)
			SetMusicPitch(request) => SetMusicPitch(request.pitch)
			SetMusicPan(request) => SetMusicPan(request.pan)
			SetMusicLooping(request) => SetMusicLooping(request.looping)
			SeekMusic(request) => SeekMusic(request.seconds)
			SetMasterVolume(volume) => SetMasterVolume(volume)
			UpdateTexture(request) =>
				UpdateTexture({
					texture: texture_shape(request.texture),
					pixel_count: List.len(request.pixels),
				})

			UpdateTextureRegion(request) =>
				UpdateTextureRegion({
					texture: texture_shape(request.texture),
					x: request.region.x,
					y: request.region.y,
					width: request.region.width,
					height: request.region.height,
					pixel_count: List.len(request.region.pixels),
				})

			SetTextureFilter(request) => SetTextureFilter({ texture: texture_shape(request.texture), filter: request.filter })
			SetTextureWrap(request) => SetTextureWrap({ texture: texture_shape(request.texture), wrap: request.wrap })
			SetVirtualMouse(pointer) => SetVirtualMouse(pointer)
			StartRecording(recording) => StartRecording(recording)
			StopRecording => StopRecording
		}

	## Why a cycle's uploads would be refused, or `Ok` if all of them fit.
	##
	## This stops at the first refusal, which is exactly what the platform does:
	## `PixelCountMismatch` and `RegionOutOfBounds` are programmer errors and stop
	## the app, while `UploadBudgetExceeded` names the first upload that does not
	## fit in `Assets.max_upload_bytes_per_step` -- that upload and every upload
	## after it in the same cycle are skipped, and the rest of the actions still
	## run. Calling this during `update` therefore tells an app exactly which of
	## its uploads will land, so it can defer the rest itself instead of losing
	## them.
	check_uploads : List(Action) -> Try({}, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded])
	check_uploads = |actions| check_uploads_from(actions, 0, 0, Assets.max_upload_bytes_per_step)

	## What a step's upload budget does with one action, and what it carries on.
	##
	## `apply` is whether the action runs at all; only an upload is ever refused.
	## `charged` is the upload bytes accounted for once this action has been
	## placed, and is what the next action must be placed against.
	UploadPlacement : { apply : Bool, charged : U64 }

	## Place one action against what a step has already charged for uploads.
	##
	## Platform-internal: `main.roc`'s adapter calls this while applying actions
	## in order. Apps ask the same question about a whole cycle with
	## `check_uploads`, which is the form worth reaching for.
	place_upload : Action, U64 -> UploadPlacement
	place_upload = |action, charged| place_upload_within(action, charged, Assets.max_upload_bytes_per_step)

	## Ask the host to shut down with an exit code.
	##
	## The exit happens once this cycle is finished, so the frame that asked for
	## it is still drawn -- and, if a recording is running, still captured.
	exit : I64 -> [Exit(I64), ..]
	exit = |code| Exit(code)

	## Work for the host to do, answered later. Returning one never blocks.
	##
	## A task owns the typed function that turns its one terminal result into the
	## application's message. The platform retains that function privately until
	## the matching host completion arrives. Task tickets are transport-only and
	## are not part of the supported application API.
	##
	## Platform wrappers capture only the callback supplied here, never the model
	## or request-only data. The callback itself retains every value it captures,
	## however, so prefer small stable context or generation values over capturing
	## an entire model for work that may remain pending.
	##
	## `ReadSmallFile` returns a UTF-8 `Str` and rejects files above its inline
	## copy limit. `ReadFile` returns ordinary Roc bytes for files up to the
	## host's 16 MiB per-file limit. The worker allocation becomes a seamless
	## `List(U8)` view, so delivery allocates and copies no payload bytes.
	## `Screenshot` captures the end of the frame that submitted it.
	Task(msg) :: [
		ReadSmallFile({ path : Str, callback : Try(Str, SmallFileError) -> msg }),
		ReadFile({ path : Str, callback : Try(List(U8), FileReadError) -> msg }),
		Delay({ millis : U64, callback : Try({}, [Busy]) -> msg }),
		Screenshot({ path : Str, callback : Try({}, ScreenshotError) -> msg }),
		ReadClipboard({ callback : Try(Str, [Unavailable, TooLarge, Busy]) -> msg }),
		ListDir({ path : Str, callback : Try(List(DirEntry), DirListError) -> msg }),
	].{

		## Lift a task's message into an enclosing application's message type.
		##
		## The request is untouched; only the callback is composed, so the task
		## the host receives asks for exactly the same work and `task_shape` is
		## unchanged. This is what lets a reusable component own tasks: the
		## component builds `Task(ChildMsg)` values and the parent wraps them
		## without knowing which variant it holds.
		##
		##     Program.delay(200, |_| Tick).map(|child_msg| Child(child_msg))
		##
		## `Update.map_msg` maps every task in an update at once and is usually
		## the one to reach for.
		map : Task(a), (a -> b) -> Task(b)
		map = |Task.(task), transform|
			match task {
				ReadSmallFile({ path, callback }) => Task.(ReadSmallFile({ path, callback: |result| transform(callback(result)) }))
				ReadFile({ path, callback }) => Task.(ReadFile({ path, callback: |result| transform(callback(result)) }))
				Delay({ millis, callback }) => Task.(Delay({ millis, callback: |result| transform(callback(result)) }))
				Screenshot({ path, callback }) => Task.(Screenshot({ path, callback: |result| transform(callback(result)) }))
				ReadClipboard({ callback }) => Task.(ReadClipboard({ callback: |result| transform(callback(result)) }))
				ListDir({ path, callback }) => Task.(ListDir({ path, callback: |result| transform(callback(result)) }))
			}
	}

	## What a `Task` asks for, with its callback left out.
	##
	## A `Task` holds a function, so `==` cannot compare two of them and no test
	## can assert on one directly. `TaskShape` is the same request as ordinary
	## data -- no functions, no host resources -- so it derives `==` and prints
	## in a failing `expect`.
	TaskShape : [
		ReadSmallFile({ path : Str }),
		ReadFile({ path : Str }),
		Delay({ millis : U64 }),
		Screenshot({ path : Str }),
		ReadClipboard,
		ListDir({ path : Str }),
	]

	## Describe what a task asks the host for, without its callback.
	##
	## This is the supported way to assert on the tasks an `update` returned:
	##
	##     result = update(model, step)
	##     expect List.map(result.fields().tasks, Program.task_shape) == [
	##         Delay({ millis: 200 }),
	##         ReadSmallFile({ path: "save.json" }),
	##     ]
	##
	## Comparing `Task` values themselves is not possible -- each one owns a
	## callback function, and equality cannot inspect a function. (Deriving `==`
	## over a union that reaches a host-resource `Box` is worse than impossible:
	## with the pinned compiler it crashes `roc test`.) Reducing the task to its
	## request first sidesteps both.
	##
	## `Task.map` and `Update.map_msg` rewrite only the callback, so a mapped
	## task keeps the shape it had. That is the property to lean on when testing
	## a component through its parent.
	task_shape : Task(msg) -> TaskShape
	task_shape = |Task.(task)|
		match task {
			ReadSmallFile({ path, callback: _ }) => ReadSmallFile({ path: path })
			ReadFile({ path, callback: _ }) => ReadFile({ path: path })
			Delay({ millis, callback: _ }) => Delay({ millis: millis })
			Screenshot({ path, callback: _ }) => Screenshot({ path: path })
			ReadClipboard({ callback: _ }) => ReadClipboard
			ListDir({ path, callback: _ }) => ListDir({ path: path })
		}

	## One entry of a directory listing.
	##
	## `name` is the entry's own name, not a path: joining it to the directory
	## that was listed is the caller's job, and is what lets a walk carry
	## whatever path convention it likes.
	DirEntry : {
		name : Str,
		kind : EntryKind,
	}

	## What one entry is.
	##
	## `Other` covers symbolic links, devices, sockets and anything else the
	## platform reports: this is the subset an app walking a tree acts on, and
	## everything it should not descend into or read is one case.
	EntryKind : [File, Dir, Other]

	## Why a `ListDir` produced no entries.
	##
	## `NotADirectory` is separate from `NotFound` because a walk wants to tell
	## an entry that has gone apart from one that turned out to be a file.
	## `TooLarge` means the directory holds more entries, or longer names, than
	## the host will encode in one listing.
	DirListError : [
		NotFound,
		NotADirectory,
		ReadFailed,
		Busy,
		Unavailable,
		TooLarge,
	]

	## Why a `ReadFile` produced no byte list.
	##
	## `Busy` means the host lacks current capacity to complete the read; retry it
	## explicitly when that suits the app. `Unavailable` means the host did not
	## start the read. `TooLarge` means the file exceeds the host's per-file limit.
	FileReadError : [
		NotFound,
		ReadFailed,
		Busy,
		Unavailable,
		TooLarge,
	]

	## Why a `ReadSmallFile` produced no string.
	##
	## `NotUtf8` means the bytes are not a valid Roc string. `TooLarge` refers to
	## the inline string-copy limit, which is lower than the `ReadFile` limit.
	SmallFileError : [
		NotFound,
		ReadFailed,
		Busy,
		Unavailable,
		TooLarge,
		NotUtf8,
	]

	## Why a screenshot was not written, including the sandbox refusing a path
	## that escapes the output directory.
	##
	## `AlreadyPending` means this app already has a screenshot request queued.
	## `Busy` means the shared host worker is full and the request may be retried.
	ScreenshotError : [
		PathInvalid,
		PathEscapesOutputDir,
		AlreadyPending,
		OutOfMemory,
		WriteFailed,
		Busy,

		## The screenshot worker is unavailable; retrying will not help.
		Unavailable,
	]

	## Read a UTF-8 file into a `Str` and turn its terminal result into `msg`.
	read_small_file : Str, (Try(Str, SmallFileError) -> msg) -> Task(msg)
	read_small_file = |path, callback| Task.(ReadSmallFile({ path, callback }))

	## Read a file into an ordinary Roc byte list and turn its terminal result
	## into `msg`.
	##
	## The list owns its host-backed storage through Roc ARC. The delivered list
	## and its sublists are seamless views, so retaining a small portion can keep
	## the whole source file alive. Use `List.release_excess_capacity` on the
	## value to retain when that copy is preferable to pinning the source file.
	## `Str.from_utf8` can share the same storage, but validating UTF-8 still scans
	## the selected bytes on the Roc thread.
	read_file : Str, (Try(List(U8), FileReadError) -> msg) -> Task(msg)
	read_file = |path, callback| Task.(ReadFile({ path, callback }))

	## Ask for the entries of one directory, as an ordinary message.
	##
	## `path` is resolved the same way `read_file`'s is: relative to the process
	## working directory. Only that directory is listed -- never its children --
	## so walking a tree is the app's own loop, one `list_dir` per directory it
	## decides to descend into. That is deliberate: a host-side recursive walk
	## would be a single unbounded operation, and the point of driving it from
	## the app is that every step of it goes through the same pacing, and the
	## same `TaskQueue`, as everything else.
	##
	##     Program.list_dir("assets", |result| Listed("assets", result))
	##
	## Entry order is whatever the filesystem reports, and is not sorted.
	list_dir : Str, (Try(List(DirEntry), DirListError) -> msg) -> Task(msg)
	list_dir = |path, callback| Task.(ListDir({ path, callback }))

	## Ask for one message after at least `millis` milliseconds have elapsed.
	delay : U64, (Try({}, [Busy]) -> msg) -> Task(msg)
	delay = |millis, callback| Task.(Delay({ millis, callback }))

	## Capture the end of this frame and write it to `path`.
	screenshot : Str, (Try({}, ScreenshotError) -> msg) -> Task(msg)
	screenshot = |path, callback| Task.(Screenshot({ path, callback }))

	## Read clipboard text on the frame thread and turn the result into `msg`.
	read_clipboard : (Try(Str, [Unavailable, TooLarge, Busy]) -> msg) -> Task(msg)
	read_clipboard = |callback| Task.(ReadClipboard({ callback: callback }))

	## The flat record a `Task` becomes on the way out to the host.
	##
	## Platform-internal transport, not supported application API. Apps construct
	## `Task` values only through the typed constructors above.
	##
	## Unions do not cross the host boundary in this platform; every effect
	## flattens to scalars behind a `U8` tag first. Actions never come here at
	## all -- they are applied in Roc, by the platform's own adapter. `deliver`
	## is an opaque Roc callable to the host: it moves with this request and is
	## invoked only when Roc receives the matching completion envelope.
	##
	## TODO(roc): make `TaskToHost`, `CompletionFromHost`, and
	## `CompletionEnvelope` opaque custom records once `roc glue` can traverse
	## them. With the pinned compiler, changing these declarations to `::` makes
	## `roc glue` crash even though `roc check` succeeds. Consequently these
	## structural records, including `CompletionFromHost.ticket`, are temporarily
	## nameable through `Program`; they are unsupported transport implementation
	## details. App code must use `Task` constructors and `Step.messages` and must
	## not construct, inspect, or depend on these records.
	TaskToHost(msg) : {
		kind : U8,

		path : Str,
		millis : U64,
		deliver : Box(CompletionFromHost -> Box(msg)),
	}

	## The flat record one completion arrives in.
	##
	## Platform-internal transport, not supported application API. The host owns
	## its ticket and pairs this raw result with the continuation it retained.
	##
	## A successful `ReadFile` places its one owning seamless `List(U8)` view in
	## `bytes` without copying the payload. The list is empty for other kinds and
	## failed reads.
	CompletionFromHost : {
		kind : U8,
		ticket : U64,
		err : U8,
		contents : Str,
		bytes : List(U8),
	}

	## A host-retained continuation returned to Roc with its terminal result.
	## Platform-internal transport, not supported application API.
	## The host treats `deliver` as an owned, opaque erased callable: it moves
	## and drops it, but never invokes it. This record is therefore the one
	## place a generic application message value crosses the ABI.
	##
	## The boxed function is necessary rather than an ordinary retained Roc
	## closure: the generated ABI gives `Box(function)` one fixed erased-callable
	## layout. Its body validates the expected kind, decodes the raw result, and
	## boxes the resulting application message for the ABI round trip.
	##
	## TODO(roc): make `TaskToHost`, `CompletionFromHost`, and
	## `CompletionEnvelope` opaque once `roc glue` handles opaque generic
	## transport records. That same generic opacity limitation rejects
	## `Box(Runtime(Model, Msg))`; the desired shape retains ordinary runtime
	## continuations inside an opaque `Runtime(Model, Msg)`, eliminating this
	## per-task box and per-message `Box(msg)` allocation.
	CompletionEnvelope(msg) : {
		raw : CompletionFromHost,
		deliver : Box(CompletionFromHost -> Box(msg)),
	}

	deliver_small_file : (Try(Str, SmallFileError) -> msg) -> Box(CompletionFromHost -> Box(msg))
	deliver_small_file = |callback|
		Box.box(
			|raw|
				if raw.kind != completion_small_file_read {
					crash "roc-ray: small-file callback received the wrong completion kind"
				} else {
					Box.box(callback(if raw.err == 0 Ok(raw.contents) else Err(small_file_error(raw.err))))
				},
		)

	deliver_file : (Try(List(U8), FileReadError) -> msg) -> Box(CompletionFromHost -> Box(msg))
	deliver_file = |callback|
		Box.box(
			|raw|
				if raw.kind != completion_file_read {
					crash "roc-ray: file callback received the wrong completion kind"
				} else {
					Box.box(callback(if raw.err == 0 Ok(raw.bytes) else Err(read_error(raw.err))))
				},
		)

	## A listing arrives in the same byte list a file read does, and is decoded
	## here rather than in the host: building a `List(DirEntry)` on the host side
	## would mean host code constructing refcounted Roc strings inside a
	## completion, and this way the transport stays the one that is already
	## proven and the decoding stays ordinary Roc that `expect` can cover.
	deliver_listing : (Try(List(DirEntry), DirListError) -> msg) -> Box(CompletionFromHost -> Box(msg))
	deliver_listing = |callback|
		Box.box(
			|raw|
				if raw.kind != completion_dir_listed {
					crash "roc-ray: directory callback received the wrong completion kind"
				} else {
					Box.box(callback(if raw.err == 0 Ok(decode_listing(raw.bytes)) else Err(list_error(raw.err))))
				},
		)

	deliver_delay : (Try({}, [Busy]) -> msg) -> Box(CompletionFromHost -> Box(msg))
	deliver_delay = |callback|
		Box.box(
			|raw|
				if raw.kind != completion_delay {
					crash "roc-ray: delay callback received the wrong completion kind"
				} else {
					Box.box(callback(if raw.err == 0 Ok({}) else Err(Busy)))
				},
		)

	deliver_screenshot : (Try({}, ScreenshotError) -> msg) -> Box(CompletionFromHost -> Box(msg))
	deliver_screenshot = |callback|
		Box.box(
			|raw|
				if raw.kind != completion_screenshot_finished {
					crash "roc-ray: screenshot callback received the wrong completion kind"
				} else {
					Box.box(callback(if raw.err == 0 Ok({}) else Err(screenshot_error(raw.err))))
				},
		)

	deliver_clipboard : (Try(Str, [Unavailable, TooLarge, Busy]) -> msg) -> Box(CompletionFromHost -> Box(msg))
	deliver_clipboard = |callback|
		Box.box(
			|raw|
				if raw.kind != completion_clipboard_read {
					crash "roc-ray: clipboard callback received the wrong completion kind"
				} else {
					Box.box(callback(if raw.err == 0 Ok(raw.contents) else Err(clipboard_error(raw.err))))
				},
		)

	## The flat record a cycle's recording state arrives in.
	##
	## `bytes` is the size of a finished file and is zero while a recording is
	## active. Start and stop outcomes are reported through this record.
	CaptureFromHost : {
		status : U8,
		err : U8,
		frames : U64,
		dropped : U64,
		bytes : U64,
	}

	## Move a task's operation data and its one erased continuation into the
	## flat host request. The host takes ownership of the continuation and assigns
	## a private monotonic ticket while accepting it.
	## Platform-internal, unsupported application API.
	##
	normalize : Task(msg) -> TaskToHost(msg)
	normalize = |Task.(task)|
		match task {
			ReadSmallFile(request) => { kind: task_read_small_file, path: request.path, millis: 0, deliver: deliver_small_file(request.callback) }
			ReadFile(request) => { kind: task_read_file, path: request.path, millis: 0, deliver: deliver_file(request.callback) }
			Delay(request) => { kind: task_delay, path: "", millis: request.millis, deliver: deliver_delay(request.callback) }
			Screenshot(request) => { kind: task_screenshot, path: request.path, millis: 0, deliver: deliver_screenshot(request.callback) }
			ReadClipboard(request) => { kind: task_read_clipboard, path: "", millis: 0, deliver: deliver_clipboard(request.callback) }
			ListDir(request) => { kind: task_list_dir, path: request.path, millis: 0, deliver: deliver_listing(request.callback) }
		}

	## Invoke the continuation returned by the host with its terminal result.
	## Platform-internal, unsupported application API.
	##
	## Every typed closure validates `raw.kind` before decoding it. The box around
	## the produced message is solely the generic ABI return envelope and is
	## immediately unboxed in Roc.
	complete : CompletionEnvelope(msg) -> msg
	complete = |completion| {
		deliver = Box.unbox(completion.deliver)
		Box.unbox(deliver(completion.raw))
	}

	## Rebuild the sampled recording state from the host's flat record.
	capture_from_host : CaptureFromHost -> Capture.Status
	capture_from_host = |raw|
		if raw.status == capture_status_active {
			Active({ frames: raw.frames, dropped: raw.dropped })
		} else if raw.status == capture_status_failed {
			Failed({ frames: raw.frames, reason: capture_failure(raw.err) })
		} else if raw.status == capture_status_finished {
			Finished({ frames: raw.frames, bytes: raw.bytes })
		} else {
			Idle
		}
}

## Keep the descriptive half of a texture and drop the resource handle.
texture_shape : Texture -> Program.TextureShape
texture_shape = |texture| { width: texture.width, height: texture.height }

## Walk a cycle's actions, accumulating upload bytes and stopping at the first
## upload that would be refused.
##
## `budget` is a parameter so tests can verify cumulative charging without
## constructing a four-mebibyte pixel list.
check_uploads_from : List(Program.Action), U64, U64, U64 -> Try({}, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded])
check_uploads_from = |actions, index, charged, budget|
	if index >= List.len(actions) {
		Ok({})
	} else {
		match List.get(actions, index) {
			Ok(action) => check_uploads_from(actions, index + 1, charge_upload(action, charged, budget)?, budget)

			# Unreachable: the index is bounded above.
			Err(_) => Ok({})
		}
	}

## Add one action's upload to the running total, or name why it cannot be made.
##
## Actions that are not uploads leave the running total unchanged.
charge_upload : Program.Action, U64, U64 -> Try(U64, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded])
charge_upload = |action, charged, budget|
	match action {
		UpdateTexture(request) =>
			if U64.to_f32(List.len(request.pixels)) != request.texture.width * request.texture.height {
				Err(PixelCountMismatch)
			} else {
				add_upload(charged, request.pixels, budget)
			}

		UpdateTextureRegion(request) => {
			region = request.region
			# Sizes are compared as F32 because that is what a texture reports
			# its own size in, and adding in F32 also means a huge `x + width`
			# cannot wrap the way I32 addition would.
			width = I32.to_f32(region.width)
			height = I32.to_f32(region.height)
			if region.width <= 0 or region.height <= 0 or region.x < 0 or region.y < 0 {
				Err(RegionOutOfBounds)
			} else if I32.to_f32(region.x) + width > request.texture.width or I32.to_f32(region.y) + height > request.texture.height {
				Err(RegionOutOfBounds)
			} else if U64.to_f32(List.len(region.pixels)) != width * height {
				Err(PixelCountMismatch)
			} else {
				add_upload(charged, region.pixels, budget)
			}
		}

		_ => Ok(charged)
	}

## Charge one upload against the frame's budget.
add_upload : U64, List(Color.Rgba), U64 -> Try(U64, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded])
add_upload = |charged, pixels, budget| {
	total = charged + Assets.upload_bytes(pixels)
	if total > budget Err(UploadBudgetExceeded) else Ok(total)
}

## Place one action against a stated budget.
##
## `budget` is a parameter for the same reason `check_uploads_from` takes one:
## so the cumulative behaviour is testable without a four-mebibyte pixel list.
place_upload_within : Program.Action, U64, U64 -> Program.UploadPlacement
place_upload_within = |action, charged, budget|
	match action {
		UpdateTexture(request) => place_bytes(charged, Assets.upload_bytes(request.pixels), budget)
		UpdateTextureRegion(request) => place_bytes(charged, Assets.upload_bytes(request.region.pixels), budget)

		# Only an upload is charged for, and only an upload can be refused.
		_ => { apply: Bool.True, charged: charged }
	}

## Fit one upload into what is left of the budget, or exhaust the budget.
##
## A refusal does not merely decline this upload: it carries a total that no
## later upload can fit under, so every upload after it in the same step is
## skipped too. That is what makes `check_uploads`, which stops at its first
## refusal, an exact prediction of what the platform will do rather than an
## approximation of it.
place_bytes : U64, U64, U64 -> Program.UploadPlacement
place_bytes = |charged, bytes, budget| {
	total = charged + bytes
	if total > budget {
		{ apply: Bool.False, charged: budget + 1 }
	} else {
		{ apply: Bool.True, charged: total }
	}
}

## `kind` code for a finished small-file read. Mirrored in `src/host_native.zig`.
completion_small_file_read : U8
completion_small_file_read = 0

## `kind` code for an elapsed delay. Mirrored in `src/host_native.zig`.
completion_delay : U8
completion_delay = 1

## `kind` code for a serviced screenshot. Mirrored in `src/host_native.zig`.
completion_screenshot_finished : U8
completion_screenshot_finished = 2

## `kind` code for a clipboard read. Mirrored in `src/host_native.zig`.
completion_clipboard_read : U8
completion_clipboard_read = 3

## `kind` code for an ordinary byte-list read. Mirrored in
## `src/host_native.zig`.
completion_file_read : U8
completion_file_read = 4

## `kind` code for a serviced directory listing. Mirrored in `src/host_native.zig`.
completion_dir_listed : U8
completion_dir_listed = 5

## `kind` code for a small-file read task. Mirrored in `src/host_native.zig`.
task_read_small_file : U8
task_read_small_file = 0

## `kind` code for a delay task. Mirrored in `src/host_native.zig`.
task_delay : U8
task_delay = 1

## `kind` code for a screenshot task. Mirrored in `src/host_native.zig`.
task_screenshot : U8
task_screenshot = 2

## `kind` code for a clipboard-read task. Mirrored in `src/host_native.zig`.
task_read_clipboard : U8
task_read_clipboard = 3

## `kind` code for an ordinary byte-list read task. Mirrored in `src/host_native.zig`.
task_read_file : U8
task_read_file = 4

## `kind` code for a directory listing task. Mirrored in `src/host_native.zig`.
task_list_dir : U8
task_list_dir = 5

## Entry kinds in an encoded listing. Mirrored in `src/host_native.zig`.
dir_entry_file : U8
dir_entry_file = 1

dir_entry_dir : U8
dir_entry_dir = 2

## The host refused to list the path because it is not a directory. Mirrored in
## `src/host_native.zig`.
read_err_not_a_directory : U8
read_err_not_a_directory = 7

## Decode the host's listing-error code. Mirrored in `src/host_native.zig`.
list_error : U8 -> Program.DirListError
list_error = |code|
	if code == 1 {
		NotFound
	} else if code == read_err_busy {
		Busy
	} else if code == 4 {
		Unavailable
	} else if code == read_err_too_large {
		TooLarge
	} else if code == read_err_not_a_directory {
		NotADirectory
	} else {
		ReadFailed
	}

## Decode a listing's bytes into entries.
##
## The encoding is one entry after another, each a kind byte, the entry's name,
## and a NUL. A name cannot contain a NUL on any platform the host runs on, so
## the terminator is unambiguous and the whole listing is one host allocation
## that reached Roc without being copied.
##
## Truncated input -- a kind byte with no terminator after it -- ends the
## listing rather than being guessed at. The host writes the terminator, so
## that cannot happen; answering with the entries that were whole is what keeps
## this total.
decode_listing : List(U8) -> List(Program.DirEntry)
decode_listing = |bytes| decode_entries(bytes, 0, [])

decode_entries : List(U8), U64, List(Program.DirEntry) -> List(Program.DirEntry)
decode_entries = |bytes, at, found|
	if at >= List.len(bytes) {
		found
	} else {
		match List.get(bytes, at) {
			Err(_) => found
			Ok(code) =>
				match index_of_nul(bytes, at + 1) {
					Err(_) => found
					Ok(end) =>
						decode_entries(
							bytes,
							end + 1,
							List.append(found, { name: entry_name(bytes, at + 1, end), kind: entry_kind(code) }),
						)
					}
			}
	}

## Copy one entry's name out of the listing.
##
## The copy is the point. A sublist of a host-delivered list is a seamless view
## onto the host's buffer, so a name retained that way would pin the whole
## listing for as long as the app held it. `release_excess_capacity` gives the
## name storage of its own -- and it has to happen before `from_utf8_lossy`,
## which may share the storage it is given.
entry_name : List(U8), U64, U64 -> Str
entry_name = |bytes, start, end|
	Str.from_utf8_lossy(List.release_excess_capacity(List.sublist(bytes, { start: start, len: end - start })))

entry_kind : U8 -> Program.EntryKind
entry_kind = |code|
	if code == dir_entry_file {
		File
	} else if code == dir_entry_dir {
		Dir
	} else {
		Other
	}

index_of_nul : List(U8), U64 -> Try(U64, [NotFound])
index_of_nul = |bytes, at|
	match List.get(bytes, at) {
		Err(_) => Err(NotFound)
		Ok(byte) =>
			if byte == 0 {
				Ok(at)
			} else {
				index_of_nul(bytes, at + 1)
			}
		}

## Decode the host's clipboard-error code. Mirrored in `src/host_native.zig`.
##
## Named rather than spelled inline, so the same code path every other decoder
## takes is testable the same way they are.
clipboard_error : U8 -> [Unavailable, TooLarge, Busy]
clipboard_error = |code|
	if code == read_err_too_large {
		TooLarge
	} else if code == read_err_busy {
		Busy
	} else {
		Unavailable
	}

## `status` code for a running recording. Mirrored in `src/capture.zig`.
capture_status_active : U8
capture_status_active = 1

## `status` code for a recording that stopped early. Mirrored in `src/capture.zig`.
capture_status_failed : U8
capture_status_failed = 2

## `status` code for a recording that ran to its end and wrote its file.
## Mirrored in `src/capture.zig`.
capture_status_finished : U8
capture_status_finished = 3

## Error code for content the frame thread declined to copy into a `Str`.
## Mirrored in `src/host_native.zig`.
read_err_too_large : U8
read_err_too_large = 5

## Error code for work the host would not start. Mirrored in
## `src/host_native.zig`.
read_err_busy : U8
read_err_busy = 3

## Error code for bytes that cannot become a `Str`. Mirrored in
## `src/host_native.zig`.
read_err_not_utf8 : U8
read_err_not_utf8 = 6

## Decode the host's read-error code for a byte-list read. Mirrored in
## `src/host_native.zig`.
read_error : U8 -> Program.FileReadError
read_error = |code|
	if code == 1 {
		NotFound
	} else if code == read_err_busy {
		Busy
	} else if code == 4 {
		Unavailable
	} else if code == read_err_too_large {
		TooLarge
	} else {
		ReadFailed
	}

## Decode the host's read-error code for a string-delivered read.
##
## The same codes plus one, rather than a second table: the two reads fail for
## the same reasons and only differ in what they were asked to produce.
small_file_error : U8 -> Program.SmallFileError
small_file_error = |code|
	if code == read_err_not_utf8 {
		NotUtf8
	} else {
		match read_error(code) {
			NotFound => NotFound
			Busy => Busy
			Unavailable => Unavailable
			TooLarge => TooLarge
			ReadFailed => ReadFailed
		}
	}

## Decode the host's capture-error code for a screenshot.
##
## These are `src/capture.zig`'s codes, the same ones `Capture.screenshot!`
## names, so a path that escapes the output directory is still reported as the
## sandbox refusing it rather than as a failed write.
screenshot_error : U8 -> Program.ScreenshotError
screenshot_error = |code|
	match code {
		1 => PathInvalid
		2 => PathEscapesOutputDir
		3 => AlreadyPending
		7 => OutOfMemory
		10 => Busy
		11 => Unavailable
		_ => WriteFailed
	}

## Name every failure code a recording can latch -- a start the host refused as
## well as a running recording that stopped early.
capture_failure : U8 -> Capture.FailureReason
capture_failure = |code|
	match code {
		1 => PathInvalid
		2 => PathEscapesOutputDir
		3 => AlreadyRecording
		5 => UnsupportedFormat
		6 => BudgetExceeded
		7 => OutOfMemory
		8 => WriteFailed
		9 => EncodeFailed
		_ => Unknown
	}

## The transport view of a task, used by the constructor tests to pin the wire
## `kind` codes the host reads. The host-only callback is deliberately left out
## because equality cannot inspect an erased callable.
##
## `Program.task_shape` is the supported, kind-code-free counterpart for apps.
task_transport_shape : Program.Task(msg) -> { kind : U8, path : Str, millis : U64 }
task_transport_shape = |task| {
	raw = Program.normalize(task)
	{
		kind: raw.kind,
		path: raw.path,
		millis: raw.millis,
	}
}

string_result_message : Try(Str, Program.SmallFileError) -> Str
string_result_message = |result|
	match result {
		Ok(contents) => contents
		Err(_) => "failed"
	}

unit_result_message : Try({}, [Busy]) -> Str
unit_result_message = |result|
	match result {
		Ok({}) => "elapsed"
		Err(Busy) => "busy"
	}

sixteen_pixels : List(Color.Rgba)
sixteen_pixels = List.repeat({ r: 1, g: 2, b: 3, a: 255 }, 16)

expect Program.check_uploads([]) == Ok({})

expect Assets.upload_bytes(sixteen_pixels) == 64

## Task constructors expose no IDs or completion unions. `normalize` moves each
## request and its erased callback envelope into the flat ABI record; the host
## gives the envelope its private ticket when it takes ownership.
expect task_transport_shape(Program.read_small_file("data.txt", string_result_message)) == { kind: 0, path: "data.txt", millis: 0 }
expect task_transport_shape(Program.read_file("data.bin", |_| "file")) == { kind: 4, path: "data.bin", millis: 0 }
expect task_transport_shape(Program.delay(250, unit_result_message)) == { kind: 1, path: "", millis: 250 }
expect task_transport_shape(Program.screenshot("scene.png", |_| "screenshot")) == { kind: 2, path: "scene.png", millis: 0 }
expect task_transport_shape(Program.read_clipboard(|_| "clipboard")) == { kind: 3, path: "", millis: 0 }
expect task_transport_shape(Program.list_dir("assets", |_| "listed")) == { kind: 5, path: "assets", millis: 0 }

small_task = Program.normalize(Program.read_small_file("data.txt", string_result_message))

delay_task = Program.normalize(Program.delay(1, unit_result_message))

clipboard_task = Program.normalize(
	Program.read_clipboard(
		|result| match result {
			Ok(text) => text
			Err(_) => "clipboard failed"
		},
	),
)

expect Program.complete({ raw: { kind: 0, ticket: 20, err: 0, contents: "hi", bytes: [] }, deliver: small_task.deliver }) == "hi"
expect Program.complete({ raw: { kind: 0, ticket: 20, err: 1, contents: "", bytes: [] }, deliver: small_task.deliver }) == "failed"
expect Program.complete({ raw: { kind: 1, ticket: 21, err: 0, contents: "", bytes: [] }, deliver: delay_task.deliver }) == "elapsed"
expect Program.complete({ raw: { kind: 1, ticket: 21, err: 1, contents: "", bytes: [] }, deliver: delay_task.deliver }) == "busy"
expect Program.complete({ raw: { kind: 3, ticket: 22, err: 0, contents: "pasted", bytes: [] }, deliver: clipboard_task.deliver }) == "pasted"

## A component's own message type, which knows nothing about the application
## that embeds it.
ChildMessage : [Loaded(Str), LoadFailed, Elapsed, Overloaded]

## The embedding application's message type, which wraps the component's.
ParentMessage : [Child(ChildMessage)]

child_small_file_message : Try(Str, Program.SmallFileError) -> ChildMessage
child_small_file_message = |result|
	match result {
		Ok(contents) => Loaded(contents)
		Err(_) => LoadFailed
	}

child_delay_message : Try({}, [Busy]) -> ChildMessage
child_delay_message = |result|
	match result {
		Ok({}) => Elapsed
		Err(Busy) => Overloaded
	}

mapped_small_task = Program.normalize(
	Program.read_small_file("child.txt", child_small_file_message).map(|child| Child(child)),
)

mapped_delay_task = Program.normalize(
	Program.delay(5, child_delay_message).map(|child| Child(child)),
)

## Mapping a task composes its callback, so the host's raw completion still
## reaches the component's decoder and the message that comes back out is the
## parent's. Nothing about the request travelled differently: these deliver
## through the same `normalize`/`complete` round trip an unmapped task takes.
expect Program.complete({ raw: { kind: 0, ticket: 30, err: 0, contents: "hello", bytes: [] }, deliver: mapped_small_task.deliver }) == Child(Loaded("hello"))
expect Program.complete({ raw: { kind: 0, ticket: 31, err: 1, contents: "", bytes: [] }, deliver: mapped_small_task.deliver }) == Child(LoadFailed)
expect Program.complete({ raw: { kind: 1, ticket: 32, err: 0, contents: "", bytes: [] }, deliver: mapped_delay_task.deliver }) == Child(Elapsed)

## The terminal `Err(Busy)` a saturated host answers with is a component
## message like any other, so it survives the lift too.
expect Program.complete({ raw: { kind: 1, ticket: 33, err: 1, contents: "", bytes: [] }, deliver: mapped_delay_task.deliver }) == Child(Overloaded)

## What a component returns, before its parent knows anything about it.
child_update : Program.Update(U64, ChildMessage)
child_update =
	Program.static(7)
		.with_action(SetClipboardText("child"))
		.with_task(Program.delay(9, child_delay_message))
		.with_task(Program.read_small_file("child.txt", child_small_file_message))

parent_update : Program.Update(U64, ParentMessage)
parent_update = child_update.map_msg(|child| Child(child))

## `map_msg` touches only the messages. The value, the actions, and the tasks'
## requests and order are all the component's.
expect parent_update.fields().value == 7
expect List.len(parent_update.fields().actions) == 1
expect List.map(parent_update.fields().tasks, Program.task_shape) == [Delay({ millis: 9 }), ReadSmallFile({ path: "child.txt" })]

## Deliver every task a lifted update carries, from the list the platform
## adapter would hand the host. `raw` is the completion the host answers with.
lifted_deliveries : Program.Update(U64, ChildMessage), Program.CompletionFromHost -> List(ParentMessage)
lifted_deliveries = |update, raw|
	List.map(
		update.map_msg(|child| Child(child)).fields().tasks,
		|task| Program.complete({ raw: raw, deliver: Program.normalize(task).deliver }),
	)

## A lifted update's tasks still deliver, and deliver the parent's message
## rather than the component's -- including the terminal `Err` case.
expect
	lifted_deliveries(
		Program.static(7).with_task(Program.delay(9, child_delay_message)),
		{ kind: 1, ticket: 34, err: 0, contents: "", bytes: [] },
	)
		== [Child(Elapsed)]

expect
	lifted_deliveries(
		Program.static(7).with_task(Program.read_small_file("child.txt", child_small_file_message)),
		{ kind: 0, ticket: 35, err: 0, contents: "saved", bytes: [] },
	)
		== [Child(Loaded("saved"))]

expect
	lifted_deliveries(
		Program.static(7).with_task(Program.read_small_file("child.txt", child_small_file_message)),
		{ kind: 0, ticket: 36, err: 3, contents: "", bytes: [] },
	)
		== [Child(LoadFailed)]

## An update with no tasks has nothing to lift, and lifting it is still legal.
expect lifted_deliveries(Program.static(7), { kind: 1, ticket: 37, err: 0, contents: "", bytes: [] }) == []

## `TaskShape` is ordinary data, so `==` works on it where it cannot work on a
## `Task`. This is the assertion an app's own tests are meant to make.
expect Program.task_shape(Program.read_small_file("save.json", string_result_message)) == ReadSmallFile({ path: "save.json" })
expect Program.task_shape(Program.read_file("level.bin", |_| "file")) == ReadFile({ path: "level.bin" })
expect Program.task_shape(Program.delay(250, unit_result_message)) == Delay({ millis: 250 })
expect Program.task_shape(Program.screenshot("scene.png", |_| "screenshot")) == Screenshot({ path: "scene.png" })
expect Program.task_shape(Program.read_clipboard(|_| "clipboard")) == ReadClipboard
expect Program.task_shape(Program.list_dir("assets", |_| "listed")) == ListDir({ path: "assets" })

# --- Directory listings -----------------------------------------------------

## The encoding the host writes, spelled out: a kind byte, a name, a NUL, and
## the next entry straight after it.
listing_sample : List(U8)
listing_sample =
	List.concat(
		List.concat([dir_entry_file], List.concat(Str.to_utf8("a.txt"), [0])),
		List.concat([dir_entry_dir], List.concat(Str.to_utf8("nested"), [0])),
	)

expect
	decode_listing(listing_sample)
		== [
			{ name: "a.txt", kind: File },
			{ name: "nested", kind: Dir },
		]

## An empty directory is no bytes, which is no entries rather than a failure.
expect decode_listing([]) == []

## An entry kind the host has not defined is `Other` rather than a crash: it is
## how symbolic links, devices and sockets already arrive.
expect decode_listing([9, 120, 0]) == [{ name: "x", kind: Other }]

## A name that is not UTF-8 still names something, so it is replaced rather than
## dropped -- a walk that skipped such entries would silently miss files.
expect List.len(decode_listing([dir_entry_file, 0xff, 0])) == 1

## A truncated listing ends at the last whole entry. The host always writes the
## terminator, so this is about `decode_listing` being total, not about input
## that occurs.
expect decode_listing(List.concat(listing_sample, [dir_entry_file, 122])) == decode_listing(listing_sample)

## An entry with an empty name is still an entry.
expect decode_listing([dir_entry_dir, 0]) == [{ name: "", kind: Dir }]

expect list_error(1) == NotFound
expect list_error(read_err_not_a_directory) == NotADirectory
expect list_error(read_err_busy) == Busy
expect list_error(4) == Unavailable
expect list_error(read_err_too_large) == TooLarge
expect list_error(2) == ReadFailed

## Every code the host can send decodes to something, and only `0` means success
## -- which never reaches here.
expect List.all([1, 2, 3, 4, 5, 6, 7, 8, 200], |code| list_error_is_named(code))

list_error_is_named : U8 -> Bool
list_error_is_named = |code|
	match list_error(code) {
		NotFound => Bool.True
		NotADirectory => Bool.True
		Busy => Bool.True
		Unavailable => Bool.True
		TooLarge => Bool.True
		ReadFailed => Bool.True
	}

## The equality discriminates, rather than agreeing with everything.
expect Program.task_shape(Program.delay(250, unit_result_message)) != Delay({ millis: 251 })
expect Program.task_shape(Program.read_small_file("a.txt", string_result_message)) != Program.task_shape(Program.read_small_file("b.txt", string_result_message))

## Mapping rewrites the callback and nothing else, so the shape is an identity
## a parent can assert on without knowing the component's message type.
expect Program.task_shape(Program.delay(250, unit_result_message).map(|inner| Loaded(inner))) == Delay({ millis: 250 })
expect Program.task_shape(Program.read_clipboard(|_| "clipboard").map(|inner| Loaded(inner))) == ReadClipboard

## A file is arbitrary bytes and a `Str` is UTF-8. Only the read that answers
## with a string can report this, which is why the two reads no longer share one
## error type.
expect small_file_error(read_err_not_utf8) == NotUtf8
expect small_file_error(1) == NotFound
expect small_file_error(2) == ReadFailed
expect small_file_error(4) == Unavailable
expect small_file_error(read_err_too_large) == TooLarge
expect read_error(1) == NotFound
expect read_error(2) == ReadFailed
expect read_error(4) == Unavailable
expect read_error(read_err_too_large) == TooLarge
expect screenshot_error(2) == PathEscapesOutputDir
expect screenshot_error(99) == WriteFailed
expect screenshot_error(3) == AlreadyPending
expect clipboard_error(4) == Unavailable

## Another process decides how much text the clipboard holds, so the frame
## thread refuses to copy an unbounded one rather than stalling on it.
expect clipboard_error(read_err_too_large) == TooLarge

## Saturation is its own answer everywhere it can happen. A clipboard the host
## would not read yet is not an `Unavailable` one, and a screenshot it would
## not start is not one this app already had outstanding. Each of those would
## send an app looking for a fault that is not there, instead of asking again
## next cycle.
expect clipboard_error(read_err_busy) == Busy
expect small_file_error(read_err_busy) == Busy
expect read_error(read_err_busy) == Busy
expect screenshot_error(10) == Busy

## A screenshot the worker had no room for is refused rather than encoded on
## the frame thread. Both of these mean the file was not written, and the
## difference between them is whether asking again is worth anything.
expect screenshot_error(11) == Unavailable
expect Program.capture_from_host({ status: 0, err: 0, frames: 0, dropped: 0, bytes: 0 }) == Idle
expect Program.capture_from_host({ status: 1, err: 0, frames: 12, dropped: 1, bytes: 0 }) == Active({ frames: 12, dropped: 1 })
expect Program.capture_from_host({ status: 2, err: 8, frames: 3, dropped: 0, bytes: 0 }) == Failed({ frames: 3, reason: WriteFailed })
expect Program.capture_from_host({ status: 2, err: 0, frames: 3, dropped: 0, bytes: 0 }) == Failed({ frames: 3, reason: Unknown })

## A recording that finished is not one that never ran. Both would have been
## `Idle` before, which left an app waiting for its capture with nothing to
## wait on.
expect Program.capture_from_host({ status: 3, err: 0, frames: 300, dropped: 4, bytes: 98_304 }) == Finished({ frames: 300, bytes: 98_304 })

## A start the host would not arm is reported too, because an action has no
## other way to say so.
expect Program.capture_from_host({ status: 2, err: 2, frames: 0, dropped: 0, bytes: 0 }) == Failed({ frames: 0, reason: PathEscapesOutputDir })

## A resource-free texture with the dimensions the upload tests need. Its handle
## never resolves to a host resource, which is fine: nothing here uploads.
four_by_four : Texture
four_by_four = { ..Texture.stub, width: 4, height: 4 }

## One upload of exactly 64 bytes: sixteen pixels covering a four-by-four
## texture, which is what `check_uploads` wants a whole-texture upload to be.
sixty_four_byte_upload : Program.Action
sixty_four_byte_upload = Assets.update_texture(four_by_four, sixteen_pixels)

## Apply the platform's placement rule over a whole list the way `main.roc`
## does, and report which action indices ran.
applied_indices : List(Program.Action), U64 -> List(U64)
applied_indices = |actions, budget| {
	var $charged = 0
	var $applied = []
	var $index = 0
	for action in actions {
		placement = place_upload_within(action, $charged, budget)
		$charged = placement.charged
		if placement.apply {
			$applied = List.append($applied, $index)
		}
		$index = $index + 1
	}
	$applied
}

## An upload, two more that no longer fit, and non-uploads interleaved with all
## three so the order is observable.
mixed_actions : List(Program.Action)
mixed_actions = [
	Program.exit(0),
	sixty_four_byte_upload,
	sixty_four_byte_upload,
	Window.set_target_fps(30),
	sixty_four_byte_upload,
]

## An upload is charged for what its pixels cost and carries the total on.
expect place_upload_within(sixty_four_byte_upload, 0, 128) == { apply: Bool.True, charged: 64 }
expect place_upload_within(sixty_four_byte_upload, 64, 128) == { apply: Bool.True, charged: 128 }

## Exactly the budget still fits; one byte past it does not.
expect place_upload_within(sixty_four_byte_upload, 65, 128) == { apply: Bool.False, charged: 129 }

## A refused upload does not just decline itself. It carries a total no later
## upload can fit under, so a cycle cannot upload its small textures and drop
## its big one -- what an app gets is a prefix of what it asked for, which is
## the only version of this an app can reason about.
expect place_upload_within(sixty_four_byte_upload, 129, 128) == { apply: Bool.False, charged: 129 }

## Actions that are not uploads run whatever the budget has done, and never
## change the running total. An exhausted budget must not silently stop an app
## from exiting, pausing its music, or moving its cursor.
expect place_upload_within(Program.exit(2), 129, 128) == { apply: Bool.True, charged: 129 }
expect place_upload_within(Capture.stop, 0, 128) == { apply: Bool.True, charged: 0 }

## With room for one upload, the first lands, the second and third are skipped,
## and both non-uploads still run in their original positions.
expect applied_indices(mixed_actions, 64) == [0, 1, 3]

## With room for all three, every action runs.
expect applied_indices(mixed_actions, 192) == [0, 1, 2, 3, 4]

## `check_uploads` is an exact prediction of that, not an approximation: it
## stops at the same first refusal the platform stops uploading at.
expect check_uploads_from(mixed_actions, 0, 0, 64) == Err(UploadBudgetExceeded)
expect check_uploads_from(mixed_actions, 0, 0, 192) == Ok({})

## A whole-texture upload whose pixel list does not match its texture is a
## programmer error rather than a budget problem, and is reported as one no
## matter how much budget is left.
expect check_uploads_from([Assets.update_texture(four_by_four, [])], 0, 0, 4096) == Err(PixelCountMismatch)

## Shapes are what an app asserts `update` returned. Every one of these is
## plain data, so `==` works on them; the equivalent `Action` values cannot be
## compared at all, because equality would have to look inside a host resource.
expect Program.action_shape(Program.exit(3)) == Exit(3)
expect Program.action_shape(Mouse.set_cursor(PointingHand)) == SetCursor(4)
expect Program.action_shape(Mouse.set_cursor_mode(Locked)) == SetCursorMode(Locked)
expect Program.action_shape(Window.set_clipboard_text("copied")) == SetClipboardText("copied")
expect Program.action_shape(Keys.set_exit_key(NoExitKey)) == SetExitKey(NoExitKey)
expect Program.action_shape(Window.set_size({ width: 640, height: 480 })) == SetWindowSize({ width: 640, height: 480 })
expect Program.action_shape(Window.set_window_min_size({ width: 320, height: 240 })) == SetWindowMinSize({ width: 320, height: 240 })
expect Program.action_shape(Window.set_target_fps(30)) == SetTargetFps(30)
expect Program.action_shape(Audio.set_master_volume(0.25)) == SetMasterVolume(0.25)
expect Program.action_shape(Capture.set_virtual_mouse(Capture.at({ x: 10, y: 20 }))) == SetVirtualMouse(Virtual({ x: 10, y: 20, left: Bool.False, middle: Bool.False, right: Bool.False, wheel: 0 }))
expect Program.action_shape(Capture.stop) == StopRecording
expect Program.action_shape(Capture.start(Capture.default)) == StartRecording(Capture.default)

## A texture keeps its dimensions and loses its handle, and the pixels become
## the one number a pure test can check them by.
expect Program.action_shape(sixty_four_byte_upload) == UpdateTexture({ texture: { width: 4, height: 4 }, pixel_count: 16 })
expect
	Program.action_shape(Assets.update_texture_region(four_by_four, { x: 1, y: 2, width: 2, height: 1, pixels: [] }))
		== UpdateTextureRegion({ texture: { width: 4, height: 4 }, x: 1, y: 2, width: 2, height: 1, pixel_count: 0 })

expect Program.action_shape(Assets.set_texture_filter(four_by_four, Bilinear)) == SetTextureFilter({ texture: { width: 4, height: 4 }, filter: Bilinear })
expect Program.action_shape(Assets.set_texture_wrap(four_by_four, MirrorClamp)) == SetTextureWrap({ texture: { width: 4, height: 4 }, wrap: MirrorClamp })

## Every `ActionShape` variant, written as data. The variants that carry a
## sound or a music stream in `Action` reach here with nothing left to carry,
## which is the trade: a shape says what was asked for, never of what.
every_shape : List(Program.ActionShape)
every_shape = [
	Exit(0),
	SetCursor(4),
	SetCursorMode(Hidden),
	SetClipboardText("copied"),
	SetExitKey(NoExitKey),
	SetWindowSize({ width: 640, height: 480 }),
	SetWindowMinSize({ width: 320, height: 240 }),
	SetTargetFps(30),
	PlaySound({ volume: 1, pitch: 0.8, pan: 0 }),
	StopSound,
	PauseSound,
	ResumeSound,
	PlayMusic,
	StopMusic,
	PauseMusic,
	ResumeMusic,
	SetMusicVolume(0.5),
	SetMusicPitch(1.25),
	SetMusicPan(-0.25),
	SetMusicLooping(Bool.True),
	SeekMusic(12.5),
	SetMasterVolume(0.8),
	UpdateTexture({ texture: { width: 4, height: 4 }, pixel_count: 16 }),
	UpdateTextureRegion({ texture: { width: 4, height: 4 }, x: 1, y: 2, width: 2, height: 1, pixel_count: 2 }),
	SetTextureFilter({ texture: { width: 4, height: 4 }, filter: Bilinear }),
	SetTextureWrap({ texture: { width: 4, height: 4 }, wrap: MirrorClamp }),
	SetVirtualMouse(Real),
	StartRecording(Capture.default),
	StopRecording,
]

## Derived equality reaches every variant, including the ones whose `Action`
## counterpart holds a host resource. This is the acceptance test for shapes:
## if this compiles and passes, an app can assert on what its `update` returned.
expect every_shape == every_shape

## One variant per `Action` variant, and no equality that quietly says yes.
expect List.len(every_shape) == 29
expect (every_shape == List.append(every_shape, StopRecording)) == Bool.False

## A whole cycle's actions, reduced and compared in one expression -- the form
## the `ActionShape` documentation recommends, checked here so the
## recommendation cannot go stale.
expect
	List.map(mixed_actions, Program.action_shape)
		== [
			Exit(0),
			UpdateTexture({ texture: { width: 4, height: 4 }, pixel_count: 16 }),
			UpdateTexture({ texture: { width: 4, height: 4 }, pixel_count: 16 }),
			SetTargetFps(30),
			UpdateTexture({ texture: { width: 4, height: 4 }, pixel_count: 16 }),
		]
