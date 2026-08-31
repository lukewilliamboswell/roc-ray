## Moving arena hazards, their lanes, and collision bodies.
import rr.Color
import rr.Math

Hazard := {
	center : Math.Vec2,
	span : F32,
	lane : Lane,
	offset : F32,
	radius : F32,
	color : Color.Rgba,
}.{
	Lane := [Horizontal, Vertical]

	## Returns the hazard position for the shared animation phase.
	pos : Hazard, F32 -> Math.Vec2
	pos = |hazard, phase| {
		amount = ping_pong(wrap_unit(phase + hazard.offset))
		match hazard.lane {
			Vertical => { x: hazard.center.x, y: hazard.center.y - hazard.span * 0.5 + hazard.span * amount }
			Horizontal => { x: hazard.center.x - hazard.span * 0.5 + hazard.span * amount, y: hazard.center.y }
		}
	}

	## Returns the first endpoint of the visible hazard lane.
	lane_start : Hazard -> Math.Vec2
	lane_start = |hazard|
		match hazard.lane {
			Vertical => { x: hazard.center.x, y: hazard.center.y - hazard.span * 0.5 }
			Horizontal => { x: hazard.center.x - hazard.span * 0.5, y: hazard.center.y }
		}

	## Returns the second endpoint of the visible hazard lane.
	lane_end : Hazard -> Math.Vec2
	lane_end = |hazard|
		match hazard.lane {
			Vertical => { x: hazard.center.x, y: hazard.center.y + hazard.span * 0.5 }
			Horizontal => { x: hazard.center.x + hazard.span * 0.5, y: hazard.center.y }
		}

	## Reports whether another circle touches this moving hazard.
	hit_by : Hazard, Math.Circle, F32 -> Bool
	hit_by = |hazard, other, phase| Math.circle_overlaps(other, hazard_circle(hazard, phase))
}

## Returns the private circular collision body for a moving hazard.
hazard_circle : Hazard, F32 -> Math.Circle
hazard_circle = |hazard, phase| Math.circle(hazard.pos(phase), hazard.radius)

## Wraps an animation phase into the unit interval.
wrap_unit : F32 -> F32
wrap_unit = |value| if value >= 1 value - 1 else if value < 0 value + 1 else value

## Maps a wrapped phase to a back-and-forth lane amount.
ping_pong : F32 -> F32
ping_pong = |phase| if phase < 0.5 phase * 2 else (1 - phase) * 2
