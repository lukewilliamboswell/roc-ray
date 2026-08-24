## Drag the blue corner to reshape a texture in perspective; press R to reset.
## This example shows how four editable corners place a texture in perspective,
## how to place points with the same transformation, and how `update!` changes
## the mouse cursor after calculating what the pointer is over.
app [Model, program] {
	rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst",
	roc: "nightly-2026-08-23-fb208ba",
}

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Devices
import rr.Math
import rr.Mouse
import rr.Text

Corners : Draw.ProjectiveQuadCorners

## State retained between updates: the texture and its last valid projective
## quad, the editable corner positions, drag state, prepared help text, and
## elapsed time for the handle animation. Invalid corner arrangements are not
## stored, so rendering can always use `quad` safely.
Model := {
	texture : Draw.Texture,
	quad : Draw.ProjectiveQuad,
	corners : Corners,
	guide : Text.Prepared,
	dragging : Bool,

	## Seconds since launch, so the handle can pulse and invite the drag.
	elapsed : F32,
}.{

	## Apply pointer input and return the cursor that `update!` should set.
	drag_corner : Model, Devices.Snapshot -> { model : Model, cursor : Mouse.Cursor }
	drag_corner = |model, input| {
		mouse = input.mouse.position()
		handle_near = Math.distance(mouse, model.corners.top_right) < 34
		dragging = input.mouse.button_down(Left) and (model.dragging or (input.mouse.button_pressed(Left) and handle_near))
		cursor = if handle_near or dragging ResizeAll else Arrow

		candidate = if input.key_pressed(KeyR) {
			initial_corners
		} else if dragging {
			{
				..model.corners,
				top_right: {
					x: Math.clamp(mouse.x, 360, 750),
					y: Math.clamp(mouse.y, 55, 390),
				},
			}
		} else {
			model.corners
		}

		match Draw.ProjectiveQuad.from_corners(candidate) {
			Ok(quad) => { model: { ..model, quad, corners: candidate, dragging }, cursor }
			Err(_) => { model: { ..model, dragging }, cursor }
		}
	}
}

program = { init!, update!, render! }

initial_corners : Corners
initial_corners = {
	top_left: { x: 130, y: 90 },
	bottom_left: { x: 75, y: 525 },
	bottom_right: { x: 725, y: 475 },
	top_right: { x: 610, y: 155 },
}

init! : App.Init(Model, [ResourceLimit, TextureGenerationFailed, NonFiniteQuad, DegenerateQuad, NonConvexQuad, ProjectiveHorizon])
init! = App.init(
	App.default.with_title("Projective Texture").with_frame_pacing(Capped(120)),
	|_startup| {
		texture = Assets.generate_checked_texture!({
			width: 512,
			height: 512,
			checks_x: 10,
			checks_y: 10,
			color_a: Color.from_hex_rgb(0xd9edf7),
			color_b: Color.from_hex_rgb(0x27445b),
		})?
		Assets.set_texture_filter!(texture, Bilinear)
		quad = Draw.ProjectiveQuad.from_corners(initial_corners)?
		font = Draw.default_font!()
		guide = Text.from("Drag the blue handle to reshape the perspective  -  R resets", font).size(18).prepare!()?
		Ok({ texture, quad, corners: initial_corners, guide, dragging: Bool.False, elapsed: 0 })
	},
)

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	dragged = model.drag_corner(program_input.devices)
	Mouse.set_cursor!(dragged.cursor)
	Ok({ ..dragged.model, elapsed: model.elapsed + program_input.time.elapsed_seconds })
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	pulse = 0.5 + 0.5 * F32.sin(model.elapsed * 3)
	edge = Color.with_alpha(Color.white, 170)

	frame.rectangle_gradient_v!({ x: 0, y: 0, width: 800, height: 600, color_top: Color.from_hex_rgb(0x16223a), color_bottom: Color.from_hex_rgb(0x080c16) })
	frame.circle_gradient!({ center: { x: 400, y: 300 }, radius: 420, color_inner: Color.with_alpha(Color.from_hex_rgb(0x2f80ed), 55), color_outer: Color.with_alpha(Color.from_hex_rgb(0x2f80ed), 0) })
	frame.projective_texture!({
		texture: model.texture,
		source: { x: 0, y: 0, width: model.texture.width, height: model.texture.height },
		quad: model.quad,
		tint: Color.white,
	})

	# Overlay points go through the same homography as the texture.
	center = model.quad.project({ x: 0.5, y: 0.5 })
	frame.circle!({ center, radius: 7, style: Draw.filled_and_outlined(Color.from_hex_rgb(0xffd166), Color.black, 2) })
	# The other diagonal through the projected centre: a straight line in
	# texture space stays straight through a homography, which is what makes
	# this quad perspective-correct rather than two stretched triangles.
	frame.line!({ start: model.quad.project({ x: 0, y: 0.5 }), end: model.quad.project({ x: 1, y: 0.5 }), stroke: Draw.stroke(Color.with_alpha(Color.from_hex_rgb(0xffd166), 110), 1) })
	frame.line!({ start: model.corners.top_left, end: model.corners.top_right, stroke: Draw.stroke(edge, 2) })
	frame.line!({ start: model.corners.top_right, end: model.corners.bottom_right, stroke: Draw.stroke(edge, 2) })
	frame.line!({ start: model.corners.bottom_right, end: model.corners.bottom_left, stroke: Draw.stroke(edge, 2) })
	frame.line!({ start: model.corners.bottom_left, end: model.corners.top_left, stroke: Draw.stroke(edge, 2) })

	# The handle pulses until it is grabbed, which is the only hint the scene
	# needs about where to put the pointer.
	halo = if model.dragging 0 else 10 * pulse
	frame.circle!({ center: model.corners.top_right, radius: 15 + halo, style: Draw.filled(Color.with_alpha(Color.from_hex_rgb(0x2f80ed), 70)) })
	frame.circle!({ center: model.corners.top_right, radius: 13, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x2f80ed), Color.white, 3) })

	frame.rounded_rectangle!({ x: 150, y: 552, width: 500, height: 34, radius: 10, segments: 8, style: Draw.filled(Color.with_alpha(Color.black, 130)) })
	model.guide.draw!(frame, { pos: { x: 400, y: 559 }, color: Color.ray_white, align: Text.align_top_center })

	Ok({})
}

## A model with no host resources behind it, so the drag step can be exercised
## from an `expect`. The texture and the label are stubs; the quad has to be a
## real one, because `from_corners` is the only thing that makes them.
test_model : Draw.ProjectiveQuad -> Model
test_model = |quad| {
	texture: Draw.Texture.stub,
	quad,
	corners: initial_corners,
	guide: Text.Prepared.stub,
	dragging: Bool.False,
	elapsed: 0,
}

expect
	match Draw.ProjectiveQuad.from_corners(initial_corners) {
		Err(_) => Bool.False
		Ok(quad) => {
			model = test_model(quad)

			# Nowhere near the handle: nothing is grabbed and the cursor is plain.
			idle = model.drag_corner(Devices.none)

			# Pressing on the handle grabs it and takes the corner to the pointer.
			on_handle = Devices.none.with_mouse_position({ x: 600, y: 160 }).with_mouse_button_pressed(Left)
			grabbed = model.drag_corner(on_handle)

			# A held corner is clamped to the range that still makes a quad, so
			# dragging off the window cannot throw the perspective away.
			off_window = Devices.none.with_mouse_position({ x: 4000, y: 4000 }).with_mouse_button_down(Left)
			far = { ..model, dragging: Bool.True }.drag_corner(off_window)

			# R puts the corners back wherever the drag left them.
			moved = { ..model, corners: { ..initial_corners, top_right: { x: 500, y: 300 } } }
			reset = moved.drag_corner(Devices.none.with_key_pressed(KeyR))

			idle.cursor
				== Arrow
				and !idle.model.dragging
					and grabbed.model.dragging
						and grabbed.cursor == ResizeAll
							and grabbed.model.corners.top_right == { x: 600, y: 160 }
								and far.model.corners.top_right == { x: 750, y: 390 }
									and reset.model.corners == initial_corners
		}
	}
