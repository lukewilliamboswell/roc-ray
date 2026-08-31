## Drawing helpers that depend only on `roc-ray-types`.
##
## `canonical!` consumes the shared high-level API. `Alternative` wraps the
## same handle and deliberately builds its panel from the lower-level
## `Geometry` and `Paint` receivers instead.
import rrt.Color
import rrt.App
import rrt.Drawing
import rrt.Font

DrawingAdapter := [].{

	## Draw through the canonical package-owned receivers.
	canonical! : Drawing.Effects, Font => {}
	canonical! = |draw, font| {
		draw.rounded_rectangle!({
			x: 188,
			y: 12,
			width: 120,
			height: 52,
			radius: 8,
			segments: 8,
			style: {
				fill: Fill(Color.rgba(235, 240, 255, 255)),
				stroke: Stroke({ color: Color.blue, thickness: 2 }),
			},
		})
		draw.text!({
			pos: { x: 198, y: 28 },
			text: "canonical",
			size: 16,
			spacing: 1,
			color: Color.black,
			font,
		})
	}

	## Compile the scoped adapter independently of an app's broader render
	## error row.
	scoped! : Drawing.Effects, Font => Try({}, [ScopeLimit])
	scoped! = |draw, font|
		draw.with_scissor!(
			{ x: 184, y: 8, width: 128, height: 64 },
			|scoped| {
				scoped.text!({
					pos: { x: 198, y: 28 },
					text: "scoped",
					size: 16,
					spacing: 1,
					color: Color.black,
					font,
				})
				Ok({})
			},
		)

	## A different package API over the root bundle's low-level operations.
	Alternative(frame) :: { effects : App.Effects(frame), frame : frame }.{

		from_effects : App.Effects(frame), frame -> Alternative(frame)
		from_effects = |effects, frame| Alternative.({ effects, frame })

		panel! : Alternative(frame), Font => {}
		panel! = |Alternative.({ effects, frame }), font| {
			geometry = RoundedRectangle({
				bounds: { x: 320, y: 12, width: 120, height: 52 },
				radius: 8,
				segments: 8,
			})
			effects.shape!(frame, geometry, SolidFill(Color.rgba(245, 235, 255, 255)))
			effects.shape!(frame, geometry, SolidStroke({ color: Color.rgba(125, 55, 180, 255), thickness: 2 }))
			effects.draw_text!(
				frame,
				{
					pos: { x: 330, y: 28 },
					text: "alternative",
					size: 16,
					spacing: 1,
					color: Color.black,
					font,
				},
			)
		}
	}
}
