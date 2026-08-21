## Domain data for Cave Climb. Keeping these shapes together makes the world
## model readable without mixing it with asset loading, simulation, or drawing.
import rr.Draw
import rr.Math
import rr.Physics
import rr.Sprite
import rr.Tilemap

Cave := [].{

	GameState := [Playing, Won, GameOver]

	LaserSegment : { start : Physics.Point, end : Physics.Point }

	LaserState : { active : Bool, segments : List(LaserSegment) }

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

	Mirror : {
		id : U64,
		pos : Physics.Point,
		length : F32,
		base_turn : F32,
		spin : F32,
	}

	MirrorHit : { point : Physics.Point, normal : Physics.Vector }

	LaserHit := [HitSolid(Physics.Point), HitMirror(MirrorHit), HitEnemy({ point : Physics.Point, id : U64 }), HitPlayer(Physics.Point), HitNone(Physics.Point)]

	ToolInput : {
		aim : Physics.Point,
		laser_down : Bool,
		hook_down : Bool,
		hook_pressed : Bool,
	}

	Gem : { id : U64, pos : Physics.Point, taken : Bool }

	Danger : { pos : Physics.Point, radius : F32 }

	Enemy : { id : U64, pos : Physics.Point, radius : F32, alive : Bool }

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

	Player : {
		pos : Physics.Point,
		velocity : Physics.Vector,
		grounded : Bool,
		facing : F32,
		animation : Sprite.Animation,
		invuln : F32,
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
		font : Draw.Font,
		tiles : Draw.Texture,
		characters : Draw.Texture,
		enemies_texture : Draw.Texture,
		background : Draw.Texture,
		level : Level,
		world : World,
	}

}
