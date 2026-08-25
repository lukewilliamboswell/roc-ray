## Domain data for Cave Climb. Keeping these shapes together makes the world
## model readable without mixing it with asset loading, simulation, or drawing.
import rr.Draw
import rr.Text
import rr.Math
import rr.Physics
import rr.Sprite
import rr.Tilemap

Cave := [].{
	Space := [].{
		map_to_world : Math.Vec2 -> Physics.Point
		map_to_world = |point| Physics.point(point.x, 0 - point.y, 0)

		world_to_map : Physics.Point -> Math.Vec2
		world_to_map = |point| {
			coords = Physics.coords(point)
			{ x: coords.x, y: 0 - coords.y }
		}
	}

	GameState := [Playing, Won, GameOver]

	LaserSegment := { start : Physics.Point, end : Physics.Point }.{
		distance_to : LaserSegment, Physics.Point -> F32
		distance_to = |segment, point| {
			along = Physics.sub(segment.end, segment.start)
			length_squared = Physics.length_squared(along)
			if length_squared == 0 {
				Physics.distance(point, segment.start)
			} else {
				amount = Math.clamp(Physics.dot(Physics.sub(point, segment.start), along) / length_squared, 0, 1)
				Physics.distance(point, Physics.add(segment.start, Physics.scale(along, amount)))
			}
		}
	}

	LaserState := { active : Bool, segments : List(LaserSegment) }.{
		inactive : LaserState
		inactive = { active: Bool.False, segments: [] }
	}

	LaserTrace : {
		segments : List(LaserSegment),
		killed : List(U64),
		hit_player : Bool,
	}

	HookProjectile : {
		pos : Physics.Point,
		velocity : Physics.Vector,
		age : F32,
	}

	HookLatch : { anchor : Physics.Point, rest_length : F32 }

	HookState := [HookIdle, HookFlying(HookProjectile), HookLatched(HookLatch)]

	Mirror := {
		id : U64,
		pos : Physics.Point,
		length : F32,
		base_turn : F32,
		spin : F32,
	}.{
		axis : Mirror, F32 -> Physics.Vector
		axis = |mirror, phase| unit_from_turn(mirror.base_turn + phase * mirror.spin)

		normal : Mirror, F32 -> Physics.Vector
		normal = |mirror, phase| {
			components = Physics.components(mirror.axis(phase))
			Physics.normalize(Physics.vector(0 - components.y, components.x, 0))
		}

		segment : Mirror, F32 -> LaserSegment
		segment = |mirror, phase| {
			offset = Physics.scale(mirror.axis(phase), mirror.length * 0.5)
			{ start: Physics.add(mirror.pos, Physics.scale(offset, -1)), end: Physics.add(mirror.pos, offset) }
		}
	}

	MirrorHit : { point : Physics.Point, normal : Physics.Vector }

	LaserHit := [HitSolid(Physics.Point), HitMirror(MirrorHit), HitEnemy({ point : Physics.Point, id : U64 }), HitPlayer(Physics.Point), HitNone(Physics.Point)]

	ToolInput : {
		aim : Physics.Point,
		laser_down : Bool,
		hook_down : Bool,
		hook_pressed : Bool,
	}

	Gem := { id : U64, pos : Physics.Point, taken : Bool }.{
		is_available_at : Gem, Physics.Point, F32 -> Bool
		is_available_at = |gem, point, radius| !(gem.taken) and Physics.distance(gem.pos, point) <= radius
	}

	Danger := { pos : Physics.Point, radius : F32 }.{
		touches : Danger, Physics.Point, F32 -> Bool
		touches = |danger, point, point_radius| Physics.distance(danger.pos, point) <= danger.radius + point_radius
	}

	Enemy := { id : U64, pos : Physics.Point, radius : F32, alive : Bool }.{
		is_hit_at : Enemy, Physics.Point -> Bool
		is_hit_at = |enemy, point| enemy.alive and Physics.distance(enemy.pos, point) <= enemy.radius
	}

	Level : {
		tilemap : Tilemap,
		spawn : Physics.Point,
		goal : Physics.Point,
		gems : List(Gem),
		hazards : List(Danger),
		mirrors : List(Mirror),
		enemy_spawns : List(Enemy),
		checkpoints : List(Physics.Point),
		bounds : Math.Rect,
	}

	Player := {
		pos : Physics.Point,
		velocity : Physics.Vector,
		grounded : Bool,
		facing : F32,
		animation : Sprite.Animation,
		invuln : F32,
	}.{
		new : Physics.Point -> Player
		new = |pos| {
			pos,
			velocity: Physics.zero,
			grounded: Bool.False,
			facing: 1,
			animation: Sprite.animation({ frame_count: 2, fps: 8 }),
			invuln: 0,
		}
	}

	World : {
		player : Player,
		gems : List(Gem),
		collected : U64,
		enemies : List(Enemy),
		checkpoint : Physics.Point,
		lives : U64,
		state : GameState,
		phase : F32,
		flash : F32,
		laser : LaserState,
		hook : HookState,
	}

	Model : {
		font : Text.Font,
		tiles : Draw.Texture,
		characters : Draw.Texture,
		enemies_texture : Draw.Texture,
		background : Draw.Texture,
		level : Level,
		world : World,
	}

}

wrap_turn : F32 -> F32
wrap_turn = |value| if value >= 1 wrap_turn(value - 1) else if value < 0 wrap_turn(value + 1) else value

quarter_wave : F32 -> F32
quarter_wave = |amount| {
	t = Math.clamp01(amount)
	t * (2 - t)
}

sin_turn : F32 -> F32
sin_turn = |turn| {
	t = wrap_turn(turn)
	if t < 0.25 {
		quarter_wave(t * 4)
	} else if t < 0.5 {
		quarter_wave((0.5 - t) * 4)
	} else if t < 0.75 {
		0 - quarter_wave((t - 0.5) * 4)
	} else {
		0 - quarter_wave((1 - t) * 4)
	}
}

unit_from_turn : F32 -> Physics.Vector
unit_from_turn = |turn| Physics.normalize(Physics.vector(sin_turn(turn + 0.25), sin_turn(turn), 0))

expect wrap_turn(1.25) == 0.25
expect Physics.components(unit_from_turn(0)) == { x: 1, y: 0, z: 0 }
expect {
	segment : Cave.LaserSegment
	segment = { start: Physics.point_xy(0, 0), end: Physics.point_xy(10, 0) }
	segment.distance_to(Physics.point_xy(5, 3)) == 3
}
