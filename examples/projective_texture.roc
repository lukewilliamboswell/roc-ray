app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Host
import rr.Math
import rr.Mouse
import rr.Text

Corners : Draw.ProjectiveQuadCorners

Model : {
	texture : Assets.Texture,
	quad : Draw.ProjectiveQuad,
	corners : Corners,
	guide : Text.Prepared,
	dragging : Bool,
}

program = { init!, render! }

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
	|_host| {
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

render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, host, frame| {
	mouse = host.mouse.position()
	handle_near = Math.distance(mouse, model.corners.top_right) < 34
	dragging = host.mouse.button_down(Left) and (model.dragging or (host.mouse.button_pressed(Left) and handle_near))
	host.set_cursor!(if handle_near or dragging ResizeAll else Arrow)

	candidate = if host.key_pressed(KeyR) {
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

	next = match Draw.ProjectiveQuad.from_corners(candidate) {
		Ok(quad) => { ..model, quad, corners: candidate, dragging }
		Err(_) => { ..model, dragging }
	}

	frame.clear!(Color.from_hex_rgb(0x101827))
	frame.projective_texture!({
		texture: next.texture,
		source: next.texture.rect(),
		quad: next.quad,
		tint: Color.white,
	})

	# Overlay points go through the same homography as the texture.
	center = next.quad.project({ x: 0.5, y: 0.5 })
	frame.circle!({ center, radius: 7, style: Draw.filled_and_outlined(Color.from_hex_rgb(0xffd166), Color.black, 2) })
	frame.line!({ start: next.corners.top_left, end: next.corners.top_right, stroke: Draw.stroke(Color.with_alpha(Color.white, 170), 2) })
	frame.line!({ start: next.corners.top_right, end: next.corners.bottom_right, stroke: Draw.stroke(Color.with_alpha(Color.white, 170), 2) })
	frame.line!({ start: next.corners.bottom_right, end: next.corners.bottom_left, stroke: Draw.stroke(Color.with_alpha(Color.white, 170), 2) })
	frame.line!({ start: next.corners.bottom_left, end: next.corners.top_left, stroke: Draw.stroke(Color.with_alpha(Color.white, 170), 2) })
	frame.circle!({ center: next.corners.top_right, radius: 13, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x2f80ed), Color.white, 3) })
	next.guide.draw!(frame, { pos: { x: 400, y: 565 }, color: Color.ray_white, align: Text.align_top_center })

	Ok(next)
}
