app [Model, program] {
	rr: platform "../../platform/main.roc",
	roc: "nightly-2026-08-21-90da19f",
}

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Devices
import rr.Math
import rr.Mouse
import rr.Text

## Drag one corner of a texture and watch the perspective follow.
##
## `Draw.ProjectiveQuad.from_corners` builds a homography from four points and
## refuses the ones that have no perspective -- degenerate, non-convex, or with
## the horizon inside the quad -- so a rejected drag simply leaves the last good
## quad in place. `quad.project` puts overlay points through that same
## homography, so the marker at the centre really is the centre of the image.
Corners : Draw.ProjectiveQuadCorners

Model : {
	texture : Draw.Texture,
	quad : Draw.ProjectiveQuad,
	corners : Corners,
	guide : Text.Prepared,
	dragging : Bool,
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
		guide = Text.from("Drag the top-right handle | R resets", font).size(18).prepare!()?
		Ok({ texture, quad, corners: initial_corners, guide, dragging: Bool.False })
	},
)

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	dragged = drag_corner(model, program_input.devices)
	Mouse.set_cursor!(dragged.cursor)
	Ok(dragged.model)
}

## Fold one frame of pointer input into the quad.
##
## The cursor shape is a host effect rather than model state. This pure step
## names the shape it wants and `update!` sets it, so the drag logic stays
## testable without a host.
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

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x101827))
	frame.projective_texture!({
		texture: model.texture,
		source: { x: 0, y: 0, width: model.texture.width, height: model.texture.height },
		quad: model.quad,
		tint: Color.white,
	})

	# Overlay points go through the same homography as the texture.
	center = model.quad.project({ x: 0.5, y: 0.5 })
	frame.circle!({ center, radius: 7, style: Draw.filled_and_outlined(Color.from_hex_rgb(0xffd166), Color.black, 2) })
	frame.line!({ start: model.corners.top_left, end: model.corners.top_right, stroke: Draw.stroke(Color.with_alpha(Color.white, 170), 2) })
	frame.line!({ start: model.corners.top_right, end: model.corners.bottom_right, stroke: Draw.stroke(Color.with_alpha(Color.white, 170), 2) })
	frame.line!({ start: model.corners.bottom_right, end: model.corners.bottom_left, stroke: Draw.stroke(Color.with_alpha(Color.white, 170), 2) })
	frame.line!({ start: model.corners.bottom_left, end: model.corners.top_left, stroke: Draw.stroke(Color.with_alpha(Color.white, 170), 2) })
	frame.circle!({ center: model.corners.top_right, radius: 13, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x2f80ed), Color.white, 3) })
	model.guide.draw!(frame, { pos: { x: 400, y: 565 }, color: Color.ray_white, align: Text.align_top_center })

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
}

expect
	match Draw.ProjectiveQuad.from_corners(initial_corners) {
		Err(_) => Bool.False
		Ok(quad) => {
			model = test_model(quad)

			# Nowhere near the handle: nothing is grabbed and the cursor is plain.
			idle = drag_corner(model, Devices.none)

			# Pressing on the handle grabs it and takes the corner to the pointer.
			on_handle = Devices.none.with_mouse_position({ x: 600, y: 160 }).with_mouse_button_pressed(Left)
			grabbed = drag_corner(model, on_handle)

			# A held corner is clamped to the range that still makes a quad, so
			# dragging off the window cannot throw the perspective away.
			off_window = Devices.none.with_mouse_position({ x: 4000, y: 4000 }).with_mouse_button_down(Left)
			far = drag_corner({ ..model, dragging: Bool.True }, off_window)

			# R puts the corners back wherever the drag left them.
			moved = { ..model, corners: { ..initial_corners, top_right: { x: 500, y: 300 } } }
			reset = drag_corner(moved, Devices.none.with_key_pressed(KeyR))

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
