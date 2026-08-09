app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.9.0/3sKTYuHvxSV77dDyZrxuUYgfrAarL6ZtasWMPeH32udh.tar.zst" }

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Input
import rr.Math
import rr.Mouse
import rr.Program
import rr.Text

Corners : Draw.ProjectiveQuadCorners

Model : {
	texture : Assets.Texture,
	quad : Draw.ProjectiveQuad,
	corners : Corners,
	guide : Text.Prepared,
	dragging : Bool,
}

program = { init!, update, render! }

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
		texture = Assets.Texture.generate_checked!({
			width: 512,
			height: 512,
			checks_x: 10,
			checks_y: 10,
			color_a: Color.from_hex_rgb(0xd9edf7),
			color_b: Color.from_hex_rgb(0x27445b),
		})?
		texture.set_filter!(Bilinear)
		quad = Draw.ProjectiveQuad.from_corners(initial_corners)?
		guide = Text.from("Drag the top-right handle | R resets").size(18).prepare!()?
		Ok({ texture, quad, corners: initial_corners, guide, dragging: Bool.False })
	},
)

Msg : []

update : Model, Program.Step(Msg) -> Try(Program.Next(Model, Msg), [Exit(I64), ..])
update = |model, step| {
	dragged = drag_corner(model, step.input)
	Ok({ model: dragged.model, actions: dragged.actions, tasks: [] })
}

## Fold one frame of pointer input into the quad.
##
## The cursor shape is a host effect rather than model state, and `update` is
## pure, so this hands the change back as an action instead of applying it. The
## platform runs it before `render!` draws, which is when it used to happen.
drag_corner : Model, Input.Snapshot -> { model : Model, actions : List(Program.Action) }
drag_corner = |model, input| {
	mouse = input.mouse.position()
	handle_near = Math.distance(mouse, model.corners.top_right) < 34
	dragging = input.mouse.button_down(Left) and (model.dragging or (input.mouse.button_pressed(Left) and handle_near))
	actions = [Mouse.set_cursor(if handle_near or dragging ResizeAll else Arrow)]

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
		Ok(quad) => { model: { ..model, quad, corners: candidate, dragging }, actions }
		Err(_) => { model: { ..model, dragging }, actions }
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x101827))
	frame.projective_texture!({
		texture: model.texture,
		source: model.texture.rect(),
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
