## Spark Run rendering derived only from loaded assets, level data, and world state.
import rr.Camera
import rr.App
import rr.Color
import rr.Draw
import rr.Math
import rr.Sprite
import rr.Text
import Game
import GameAssets
import Hazard
import Level
import Player
import Spark

Render := [].{

	## Draws one complete Spark Run presentation frame from the resulting world.
	draw! : Draw.Frame, GameAssets, Level, Game.World => Try({}, [ScopeLimit, ..])
	draw! = |frame, assets, level, world| {
		camera = Camera.follow(shaken_target(world), { screen: { x: screen_w, y: screen_h }, zoom: 0.82 })
		viewport = camera.viewport({ x: screen_w, y: screen_h })
		frame.clear!(Color.from_hex_rgb(0x071018))
		frame.with_camera!(
			camera,
			|world_frame| {
				draw_world!(world_frame, level, assets.characters, assets.tiles, world, viewport, assets.font)
				Ok({})
			},
		)?
		draw_hud!(frame, level, world, assets.font)
		Ok({})
	}
}

screen_w = 800.F32

screen_h = 600.F32

## Wraps a visual animation phase into the unit interval.
wrap_unit : F32 -> F32
wrap_unit = |value| if value >= 1 value - 1 else if value < 0 value + 1 else value

## Maps a wrapped visual phase to a back-and-forth amount.
ping_pong : F32 -> F32
ping_pong = |phase| if phase < 0.5 phase * 2 else (1 - phase) * 2

## Derives the camera target and deterministic screen shake from the world.
shaken_target : Game.World -> Math.Vec2
shaken_target = |world| {
	amount = world.shake
	x_phase = ping_pong(wrap_unit(world.phase * 9.7))
	y_phase = ping_pong(wrap_unit(world.phase * 13.1 + 0.31))
	{
		x: world.player.pos.x + (x_phase - 0.5) * amount,
		y: world.player.pos.y + (y_phase - 0.5) * amount,
	}
}

## Draws every camera-space arena layer in back-to-front order.
draw_world! : Draw.Frame, Level, Draw.Texture, Draw.Texture, Game.World, Math.Rect, Text.Font => {}
draw_world! = |frame, level, characters, tiles, world, viewport, font| {
	draw = App.effects().render(frame)
	draw.rectangle_gradient_v!({ x: level.bounds.x, y: level.bounds.y, width: level.bounds.width, height: level.bounds.height, color_top: Color.from_hex_rgb(0x173833), color_bottom: Color.from_hex_rgb(0x132821) })
	level.tilemap.draw_all_in!(frame, viewport)
	draw_hazard_lanes!(frame, level, world.phase)
	draw_props!(frame, level, tiles, viewport)
	draw.rectangle!({ x: level.bounds.x, y: level.bounds.y, width: level.bounds.width, height: level.bounds.height, style: Draw.outlined(Color.with_alpha(Color.white, 90), 6) })

	draw_spawn!(frame, level, font)
	draw_exit!(frame, level, world, font)
	draw_obstacles!(frame, level, tiles, viewport)
	draw_sparks!(frame, tiles, world.sparks, world.phase, viewport)
	draw_hazards!(frame, level, characters, world.phase, viewport)
	draw_burst!(frame, world)
	draw_player!(frame, characters, world.player)
}

tile_cols = 27.U64

## Maps a semantic decoration tile to its spritesheet identifier.
tile_id : Level.Tile -> U64
tile_id = |tile|
	match tile {
		TileFloor => 1
		TileBlockA => 156
		TileBlockB => 157
		TileMarker => 158
		TileRockA => 181
		TilePlantA => 183
		TilePlantB => 184
		TileFlowerA => 213
		TileFlowerB => 214
		TileCrystalA => 237
		TileCrystalB => 238
		TileSparkA => 239
		TileSparkB => 240
	}

## Returns the source rectangle for one decoration tile.
tile_source : Level.Tile -> Math.Rect
tile_source = |tile| {
	index = tile_id(tile) - 1
	Sprite.sheet_frame({ frame_size: { x: 64, y: 64 }, row: index // tile_cols, col: index % tile_cols })
}

## Builds a positioned tile sprite from the shared tile texture.
tile_sprite : Draw.Texture, Level.Tile, Math.Vec2, F32 -> Sprite.Sprite
tile_sprite = |tiles, tile, pos, scale|
	Sprite.from_texture(tiles)
		.source(
			tile_source(tile),
		)
		.pos(
			pos,
		)
		.scale(
			scale,
		)

## Draws one tile sprite from its top-left position.
draw_tile! : Draw.Frame, Draw.Texture, Level.Tile, Math.Vec2, F32 => {}
draw_tile! = |frame, tiles, tile, pos, scale| tile_sprite(tiles, tile, pos, scale).draw!(frame)

## Draws one centered and rotated tile sprite.
draw_tile_centered! : Draw.Frame, Draw.Texture, Level.Tile, Math.Vec2, F32, F32 => {}
draw_tile_centered! = |frame, tiles, tile, pos, scale, rotation| tile_sprite(tiles, tile, pos, scale).centered().rotation(rotation).draw!(frame)

## Draws the marked player spawn point.
draw_spawn! : Draw.Frame, Level, Text.Font => {}
draw_spawn! = |frame, level, font| {
	draw = App.effects().render(frame)
	draw.circle_gradient!({ center: level.spawn, radius: 72, color_inner: Color.with_alpha(Color.from_hex_rgb(0x2a9d8f), 120), color_outer: Color.with_alpha(Color.from_hex_rgb(0x2a9d8f), 0) })
	draw.circle!({ center: level.spawn, radius: 42, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x2a9d8f), Color.white, 4) })
	Text.from("START", font)
		.size(18)
		.draw!(frame, { pos: { x: level.spawn.x, y: level.spawn.y + 63 }, color: Color.with_alpha(Color.white, 190), align: (Top, Center) })
}

## Draws the locked or open exit and its label.
draw_exit! : Draw.Frame, Level, Game.World, Text.Font => {}
draw_exit! = |frame, level, world, font| {
	draw = App.effects().render(frame)
	is_open = world.gate.is_open()
	color = if is_open Color.from_hex_rgb(0xf9c74f) else Color.from_hex_rgb(0x576066)
	halo = if is_open Color.with_alpha(color, 95) else Color.with_alpha(Color.black, 70)
	draw.circle_gradient!({ center: level.exit_center, radius: 82 + world.gate_flash * 28, color_inner: halo, color_outer: Color.with_alpha(color, 0) })
	draw.circle!({ center: level.exit_center, radius: level.exit_radius, style: Draw.filled_and_outlined(Color.with_alpha(color, 190), Color.white, 4) })
	Text.from(if is_open "EXIT OPEN" else "LOCKED EXIT", font)
		.size(19)
		.draw!(frame, { pos: { x: level.exit_center.x, y: level.exit_center.y + 74 }, color: Color.white, align: (Top, Center) })
}

## Draws one solid obstacle and its decorative tile.
draw_obstacle! : Draw.Frame, Draw.Texture, Level.Obstacle => {}
draw_obstacle! = |frame, tiles, obstacle| {
	draw = App.effects().render(frame)
	rect = obstacle.rect
	draw.rounded_rectangle!({ x: rect.x, y: rect.y, width: rect.width, height: rect.height, radius: 14, segments: 8, style: Draw.filled_and_outlined(Color.with_alpha(Color.from_hex_rgb(0x23342d), 235), Color.from_hex_rgb(0xa3b18a), 4) })
	draw_tile_centered!(frame, tiles, obstacle.tile, obstacle.center(), 1.25, obstacle.rotation)
}

## Draws visible solid obstacles inside the camera viewport.
draw_obstacles! : Draw.Frame, Level, Draw.Texture, Math.Rect => {}
draw_obstacles! = |frame, level, tiles, viewport| {
	for obstacle in level.obstacles {
		rect = obstacle.rect
		visual_bounds = Math.rect(rect.x - 48, rect.y - 48, rect.width + 96, rect.height + 96)
		if Math.overlaps(visual_bounds, viewport) {
			draw_obstacle!(frame, tiles, obstacle)
		}
	}
}

## Draws visible non-solid level decorations.
draw_props! : Draw.Frame, Level, Draw.Texture, Math.Rect => {}
draw_props! = |frame, level, tiles, viewport| {
	for decoration in level.decorations {
		if Math.circle_rect({ center: decoration.pos, radius: 48 * decoration.scale }, viewport) {
			draw_tile_centered!(frame, tiles, decoration.tile, decoration.pos, decoration.scale, decoration.rotation)
		}
	}
}

## Draws one rotating collectible spark and its glow.
draw_spark! : Draw.Frame, Draw.Texture, Spark, F32 => {}
draw_spark! = |frame, tiles, spark, phase| {
	draw = App.effects().render(frame)
	tile = if spark.id % 2 == 0 TileSparkA else TileSparkB
	rotation = phase * 160 + U64.to_f32(spark.id) * 19
	pulse = 1 + ping_pong(wrap_unit(phase * 2 + U64.to_f32(spark.id) * 0.09)) * 0.1
	draw.circle_gradient!({ center: spark.pos, radius: Spark.radius * 2 * pulse, color_inner: Color.with_alpha(Color.from_hex_rgb(0xf9c74f), 55), color_outer: Color.with_alpha(Color.from_hex_rgb(0xf9c74f), 0) })
	draw.circle!({ center: spark.pos, radius: Spark.radius + 4 * pulse, style: Draw.outlined(Color.with_alpha(Color.white, 110), 3) })
	draw_tile_centered!(frame, tiles, tile, spark.pos, 0.72 * pulse, rotation)
}

## Draws the collectible sparks visible in the camera viewport.
draw_sparks! : Draw.Frame, Draw.Texture, List(Spark), F32, Math.Rect => {}
draw_sparks! = |frame, tiles, sparks, phase, viewport| {
	for spark in sparks {
		if Math.circle_rect({ center: spark.pos, radius: Spark.radius * 2.2 }, viewport) {
			draw_spark!(frame, tiles, spark, phase)
		}
	}
}

## Draws each hazard route and its moving glow.
draw_hazard_lanes! : Draw.Frame, Level, F32 => {}
draw_hazard_lanes! = |frame, level, phase| {
	draw = App.effects().render(frame)
	for hazard in level.hazards {
		pos = hazard.pos(phase)
		draw.line!({ start: hazard.lane_start(), end: hazard.lane_end(), stroke: Draw.stroke(Color.with_alpha(hazard.color, 48), 10) })
		draw.circle_gradient!({ center: pos, radius: hazard.radius * 1.9, color_inner: Color.with_alpha(hazard.color, 54), color_outer: Color.with_alpha(hazard.color, 0) })
	}
}

robot_source : Math.Rect
robot_source = Math.rect(458, 88, 33, 43)

## Draws one moving hazard robot and collision outline.
draw_hazard! : Draw.Frame, Draw.Texture, Hazard, F32 => {}
draw_hazard! = |frame, characters, hazard, phase| {
	draw = App.effects().render(frame)
	pos = hazard.pos(phase)
	sprite = Sprite.from_texture(characters)
		.source(
			robot_source,
		)
		.pos(
			pos,
		)
		.scale(
			1.38,
		)
		.centered()

	sprite.draw!(frame)
	draw.circle!({ center: pos, radius: hazard.radius, style: Draw.outlined(Color.with_alpha(Color.white, 170), 3) })
}

## Draws moving hazards visible in the camera viewport.
draw_hazards! : Draw.Frame, Level, Draw.Texture, F32, Math.Rect => {}
draw_hazards! = |frame, level, characters, phase, viewport| {
	for hazard in level.hazards {
		pos = hazard.pos(phase)
		if Math.circle_rect({ center: pos, radius: F32.max(hazard.radius + 3, 34) }, viewport) {
			draw_hazard!(frame, characters, hazard, phase)
		}
	}
}

## Returns one of eight radial collection-burst directions.
burst_dir : U64 -> Math.Vec2
burst_dir = |index|
	match index % 8 {
		0 => { x: 1, y: 0 }
		1 => { x: 0.7, y: 0.7 }
		2 => { x: 0, y: 1 }
		3 => { x: -0.7, y: 0.7 }
		4 => { x: -1, y: 0 }
		5 => { x: -0.7, y: -0.7 }
		6 => { x: 0, y: -1 }
		_ => { x: 0.7, y: -0.7 }
	}

## Draws the current collection-burst particle recursively.
draw_burst_particle! : Draw.Frame, Game.World, U64 => {}
draw_burst_particle! = |frame, world, index| {
	draw = App.effects().render(frame)
	if index >= 6 or world.burst_timer <= 0 {
		{}
	} else {
		progress = 1 - world.burst_timer / Game.burst_duration
		dir = burst_dir(index)
		pos = Math.add(world.burst_pos, Math.scale(dir, 18 + progress * 58))
		size = 6 + ping_pong(wrap_unit(world.phase * 5 + U64.to_f32(index) * 0.11)) * 3
		draw.circle!({ center: pos, radius: size, style: Draw.filled(Color.with_alpha(Color.from_hex_rgb(0xf9c74f), if world.burst_timer > 0.18 135 else 70)) })
		draw_burst_particle!(frame, world, index + 1)
	}
}

## Draws the active spark collection burst.
draw_burst! : Draw.Frame, Game.World => {}
draw_burst! = |frame, world| draw_burst_particle!(frame, world, 0)

player_source : Math.Rect
player_source = Math.rect(0, 0, 52, 43)

## Draws the player sprite, dash glow, and collision outline.
draw_player! : Draw.Frame, Draw.Texture, Player => {}
draw_player! = |frame, characters, player| {
	draw = App.effects().render(frame)
	tint = if player.invuln > 0 Color.with_alpha(Color.white, 150) else Color.white
	scale = if player.dash_active() 1.3 else 1.22
	sprite = Sprite.from_texture(characters)
		.source(
			player_source,
		)
		.pos(
			player.pos,
		)
		.scale(
			scale,
		)
		.centered()
		.rotation(
			player.rotation(),
		)
		.tint(
			tint,
		)

	draw.circle!({ center: { x: player.pos.x + 5, y: player.pos.y + 7 }, radius: Player.radius + 6, style: Draw.filled(Color.with_alpha(Color.black, 85)) })
	if player.dash_active() {
		trail_center = Math.add(player.pos, Math.scale(player.facing_dir(), -38))
		draw.circle_gradient!({ center: trail_center, radius: 44, color_inner: Color.with_alpha(Color.from_hex_rgb(0x43aa8b), 55), color_outer: Color.with_alpha(Color.from_hex_rgb(0x43aa8b), 0) })
		draw.circle_gradient!({ center: player.pos, radius: 54, color_inner: Color.with_alpha(Color.from_hex_rgb(0x43aa8b), 70), color_outer: Color.with_alpha(Color.from_hex_rgb(0x43aa8b), 0) })
	} else {
		{}
	}
	sprite.draw!(frame)
	draw.circle!({ center: player.pos, radius: Player.radius, style: Draw.outlined(Color.with_alpha(Color.white, 180), 2) })
}

## Draws a normalized rounded HUD progress bar.
draw_bar! : Draw.Frame, F32, F32, F32, F32, F32, Color.Rgba => {}
draw_bar! = |frame, x, y, width, height, amount, color| {
	draw = App.effects().render(frame)
	draw.rounded_rectangle!({ x, y, width, height, radius: 5, segments: 6, style: Draw.filled(Color.with_alpha(Color.black, 130)) })
	draw.rounded_rectangle!({ x, y, width: width * Math.clamp(amount, 0, 1), height, radius: 5, segments: 6, style: Draw.filled(color) })
}

## Draws score, lives, dash charge, damage flash, and end state.
draw_hud! : Draw.Frame, Level, Game.World, Text.Font => {}
draw_hud! = |frame, level, world, font| {
	draw = App.effects().render(frame)
	is_open = world.gate.is_open()

	draw.rectangle_gradient_v!({ x: 0, y: 0, width: screen_w, height: 76, color_top: Color.with_alpha(Color.black, 220), color_bottom: Color.with_alpha(Color.black, 125) })
	draw.text!({ pos: { x: 22, y: 16 }, text: "Spark Run", size: 27, spacing: Draw.default_spacing, color: Color.white, font: font })
	draw.text!({ pos: { x: 195, y: 18 }, text: Str.concat("Sparks ", Str.concat(U64.to_str(world.score), Str.concat("/", U64.to_str(level.spark_total)))), size: 20, spacing: Draw.default_spacing, color: Color.from_hex_rgb(0xf9c74f), font: font })
	draw.text!({ pos: { x: 382, y: 18 }, text: Str.concat("Lives ", U64.to_str(world.lives)), size: 20, spacing: Draw.default_spacing, color: Color.light_gray, font: font })
	draw.text!({ pos: { x: 510, y: 18 }, text: if is_open "Gate open" else "Collect all sparks", size: 20, spacing: Draw.default_spacing, color: if is_open Color.from_hex_rgb(0x90be6d) else Color.light_gray, font: font })
	draw.fps!({ pos: { x: 735, y: 20 }, size: 18, color: Color.gray })
	draw_bar!(frame, 196, 48, 170, 9, U64.to_f32(world.score) / U64.to_f32(level.spark_total), Color.from_hex_rgb(0xf9c74f))
	draw_bar!(frame, 510, 48, 120, 9, world.player.dash_charge(), Color.from_hex_rgb(0x43aa8b))
	draw.text!({ pos: { x: 640, y: 43 }, text: if world.player.dash_ready() "SPACE dash" else "charging", size: 16, spacing: Draw.default_spacing, color: Color.light_gray, font: font })

	if world.flash > 0 {
		draw.rectangle!({ x: 0, y: 0, width: screen_w, height: screen_h, style: Draw.filled(Color.with_alpha(Color.red, if world.flash > 0.45 120 else 70)) })
	} else {
		{}
	}

	match world.state {
		Playing => {}
		Won => draw_modal!(frame, font, "All sparks recovered", "Press SPACE to run again", Color.from_hex_rgb(0x43aa8b))
		GameOver => draw_modal!(frame, font, "Spark Run ended", "Press SPACE to restart", Color.from_hex_rgb(0xf94144))
	}
}

## Draws a centered win or game-over modal.
draw_modal! : Draw.Frame, Text.Font, Str, Str, Color.Rgba => {}
draw_modal! = |frame, font, title, subtitle, accent| {
	draw = App.effects().render(frame)
	draw.rectangle!({ x: 0, y: 0, width: screen_w, height: screen_h, style: Draw.filled(Color.with_alpha(Color.black, 120)) })
	draw.rounded_rectangle!({ x: 185, y: 226, width: 430, height: 152, radius: 8, segments: 8, style: Draw.filled_and_outlined(Color.with_alpha(Color.black, 230), accent, 4) })
	Text.from(title, font).size(30).draw!(frame, { pos: { x: screen_w * 0.5, y: 276 }, color: Color.white, align: (Middle, Center) })
	Text.from(subtitle, font).size(21).draw!(frame, { pos: { x: screen_w * 0.5, y: 326 }, color: Color.light_gray, align: (Middle, Center) })
}
