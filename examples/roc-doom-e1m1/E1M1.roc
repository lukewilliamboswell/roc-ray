## Pure integration boundary for the generated Freedoom E1M1 slice. The map
## asset is owned and decoded once by RocDoomMap; this module only derives domain
## views from that validated nominal value.
import RocDoomMap
import RocDoomWorld

E1M1 := [].{
	Derived : {
		map : RocDoomMap.Map,
		player_start : RocDoomMap.PlayerStart,
		blockers : List(RocDoomMap.BlockingSegment),
		surfaces : List(RocDoomMap.SurfacePolygon),
		walls : List(RocDoomMap.WallSpan),
		spawned : RocDoomWorld.Spawned,
	}

	## Derive the render, collision, and gameplay views for one skill setting.
	## Unsupported editor thing types remain ignored by RocDoomWorld.spawn.
	derive : RocDoomWorld.Skill -> Try(Derived, [PlayerStartMissing, MultiplePlayerStarts])
	derive = |skill| {
		map = RocDoomMap.e1m1
		player_start = map.player_start()?
		raw = map.raw()
		Ok({
			map,
			player_start,
			blockers: map.blocking_segments(),
			surfaces: map.surface_polygons(),
			walls: map.wall_spans(),
			spawned: RocDoomWorld.spawn(raw.things, skill),
		})
	}
}

expect {
	derived = E1M1.derive(Medium) ?? crash "validated E1M1 has one player start"
	spawn_start = derived.spawned.player_start ?? crash "RocDoomWorld player start missing"
	List.len(derived.surfaces) == 1364
		and List.len(derived.walls) > 100
		and List.len(derived.blockers) > 100
		and List.len(derived.spawned.actors) > 0
		and List.len(derived.spawned.pickups) > 0
		and derived.player_start.position == { x: spawn_start.x, y: spawn_start.y }
}

expect {
	easy = E1M1.derive(Easy) ?? crash "E1M1 integration failed"
	hard = E1M1.derive(Hard) ?? crash "E1M1 integration failed"
	# Geometry is skill-independent while thing flags may vary the spawn set.
	List.len(easy.surfaces) == List.len(hard.surfaces)
		and List.len(easy.blockers) == List.len(hard.blockers)
		and List.len(easy.spawned.actors) > 0
		and List.len(hard.spawned.actors) > 0
}
