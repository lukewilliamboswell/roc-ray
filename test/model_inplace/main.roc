app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Color
import rr.Draw

## A measurement app: does a large collection in the model survive a frame
## without being copied?
##
## It does, as of `nightly-2026-08-21-90da19f`. Run it under
## `ROC_RAY_ALLOC_STATS=1` and read the per-frame allocator line: writing one
## element of a million-`F32` list in the model allocates well under a hundred
## bytes a frame -- the model box, and nothing proportional to the list.
## `scripts/test_model_allocation.py` is the same measurement as a check.
##
## It did not always. Up to `nightly-2026-08-19-edec830` the same write cost
## 4,000,000 bytes a frame. The host was never the second reference: it clears
## its own slot before the call (`takeModel`), and the list's refcount measured
## at `update_for_host` entry was 1. It read 3 by the time the copy was
## allocated, both increfs from Roc-compiled code below `update_for_host`. The
## compiler's rule for `Box.unbox` was `retainsResultBorrowingArgs`
## (`src/base/LowLevel.zig`): it never consumed the box, so the box and the
## unboxed model were both live when `update` ran and `List.set` took the
## copy-on-write path (`makeUnique`, refcount != 1). The adapter branches and
## runs effects between the unbox and the rebox, so the `box_reuse` rewrite --
## which handles a straight-line `unbox -> produce -> box -> ret` -- did not
## match it. The compiler now consumes the box here, and the controls below
## agree with the headline number rather than contrasting with it.
##
## `ROC_RAY_MODEL_PATTERN` selects which pattern the frame exercises. The first
## two are what an app would really write; the rest are controls that separate
## the possible explanations for whatever the first two cost.
##   set (default) - `List.set` one element of the model's list
##   append        - grow a model list by one element a frame
##   set_fallback  - like `set`, but the `Err` branch names `model.points` again
##   set_twice     - two chained `List.set` calls: does the second one copy too?
##   set_literal   - like `set`, but rebuilding the record without `..model`
##   local_set     - set an element of a list built inside `update`, never in
##                   the model: can this compiler mutate a list in place at all?
##   noop          - return the model untouched: the frame's floor cost
Model : {
	points : List(F32),
	trail : List(F32),
	cursor : U64,
	pattern : Pattern,
}

Pattern : [SetInPlace, AppendGrowth, SetKeepingFallback, SetTwice, SetWithoutSpread, LocalSet, LocalBoxedSet, NoChange]

## Nothing arrives from the host, so nothing can perturb the measurement.
Msg : []

## One million `F32`s: 4 MiB, far enough above the frame's other traffic that a
## copy cannot hide inside it.
point_count : U64
point_count = 1_000_000

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default.with_title("Model allocation probe"),
	|startup| {
		requested =
			match App.read_env!(startup, "ROC_RAY_MODEL_PATTERN") {
				Ok(value) => value
				Err(NotFound) => "set"
			}

		Ok({
			points: List.repeat(0.0, point_count),
			trail: [],
			cursor: 0,
			pattern: parse_pattern(requested),
		})
	},
)

parse_pattern : Str -> Pattern
parse_pattern = |name|
	if name == "append" {
		AppendGrowth
	} else if name == "set_fallback" {
		SetKeepingFallback
	} else if name == "set_twice" {
		SetTwice
	} else if name == "set_literal" {
		SetWithoutSpread
	} else if name == "local_set" {
		LocalSet
	} else if name == "local_boxed" {
		LocalBoxedSet
	} else if name == "noop" {
		NoChange
	} else {
		SetInPlace
	}

## Rewrite one element of the model's list, or append one, and bump the cursor.
##
## Every branch uses the ordinary record-update spread an app would write,
## except `SetWithoutSpread`, which exists to price the spread itself.
update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input|
	match model.pattern {
		SetInPlace =>
			Ok({ ..model, points: set_point(model.points, model.cursor), cursor: model.cursor + 1 })

		AppendGrowth =>
			Ok({ ..model, trail: List.append(model.trail, marker(model.cursor)), cursor: model.cursor + 1 })

		SetKeepingFallback =>
		# The same write, except that the failure branch names the original
		# list again. If that second mention is what forces a copy, this
		# pattern costs a full list and `SetInPlace` does not.
			Ok({
				..model,
				points: match List.set(model.points, model.cursor % point_count, marker(model.cursor)) {
					Ok(updated) => updated
					Err(OutOfBounds) => model.points
				},
				cursor: model.cursor + 1,
			})

		SetTwice =>
		# Two writes to the same list. One list's worth of allocation means
		# the first write copied and the second mutated the copy in place;
		# two means no write here is ever in place.
			Ok({
				..model,
				points: set_point(set_point(model.points, model.cursor), model.cursor + 1),
				cursor: model.cursor + 1,
			})

		SetWithoutSpread =>
		# The same write, spelled without `..model`, to price the spread.
			Ok({
				points: set_point(model.points, model.cursor),
				trail: model.trail,
				cursor: model.cursor + 1,
				pattern: model.pattern,
			})

		LocalSet =>
		# The model is untouched. The list written here is built in this
		# scope and dropped in it, so it can only ever have one reference:
		# whatever this costs beyond the `List.repeat` is what an in-place
		# write costs when uniqueness is not in doubt.
			Ok({ ..model, cursor: model.cursor + 1, trail: local_write(model.cursor) })

		LocalBoxedSet =>
		# `LocalSet` with one difference: the list is boxed and unboxed before
		# it is written, the way the platform adapter reaches the model. One
		# list's worth of allocation means the round trip through `Box` is
		# free; two means unboxing leaves the box holding a second reference.
			Ok({ ..model, cursor: model.cursor + 1, trail: local_boxed_write(model.cursor) })

		NoChange =>
			Ok(model)
		}

## `List.set` with the failed write discarded rather than falling back to the
## list it was given, so the original is mentioned exactly once.
set_point : List(F32), U64 -> List(F32)
set_point = |points, cursor|
	match List.set(points, cursor % point_count, marker(cursor)) {
		Ok(updated) => updated
		Err(OutOfBounds) => []
	}

## Build a list, write one element of it, and keep only its first element, so
## the whole list is local to one call.
local_write : U64 -> List(F32)
local_write = |cursor| {
	fresh = List.repeat(0.0, point_count)
	written = set_point(fresh, cursor)
	match List.first(written) {
		Ok(value) => [value]
		Err(ListWasEmpty) => []
	}
}

## `local_write` with the list taken through a `Box` first, as the platform
## adapter takes the model: box it, hand the box to a function, and write to
## what that function unboxes.
##
## The unboxing is deliberately behind a call boundary. A box created and
## unboxed in one scope is elided by the compiler -- measured, it costs nothing
## at all -- and eliding it would answer a question nobody asked.
local_boxed_write : U64 -> List(F32)
local_boxed_write = |cursor| {
	written = write_through_box(Box.box(List.repeat(0.0, point_count)), cursor)
	match List.first(written) {
		Ok(value) => [value]
		Err(ListWasEmpty) => []
	}
}

## Unbox a list and write to it, exactly as `update_for_host!` unboxes the
## model and hands it to `update!`, with the box still in scope.
write_through_box : Box(List(F32)), U64 -> List(F32)
write_through_box = |boxed, cursor| set_point(Box.unbox(boxed), cursor)

## A value that differs frame to frame, so a write cannot be optimized away.
marker : U64 -> F32
marker = |cursor| U64.to_f32(cursor % 1024) * 0.5

## Trivial on purpose: the frame's cost should be the model's, not the drawing's.
render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, frame| {
	frame.clear!(Color.from_hex_rgb(0x101820))
	frame.rectangle!({ x: 10, y: 10, width: 20, height: 20, style: Draw.filled(Color.white) })

	Ok({})
}
