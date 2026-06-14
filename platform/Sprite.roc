## Sprite module - pure helpers for texture sprites and simple animations.
##
## Drawing still goes through Draw/Assets. This module provides a compact
## game-facing shape for sprites, spritesheet frame rectangles, and animation
## state.
import Assets
import Color
import Draw
import Math

Sprite := [].{

	Sprite : {
		texture : Assets.Texture,
		source : Math.Rect,
		pos : Math.Vec2,
		origin : Math.Vec2,
		rotation : F32,
		scale : Math.Vec2,
		tint : Color,
	}

	Animation : {
		frame : U64,
		frame_count : U64,
		fps : F32,
		elapsed : F32,
	}

	from_texture : Assets.Texture -> Sprite
	from_texture = |texture| {
		texture,
		source: Assets.rect(texture),
		pos: Math.zero,
		origin: Math.zero,
		rotation: 0,
		scale: { x: 1, y: 1 },
		tint: Color.white,
	}

	with_source : Sprite, Math.Rect -> Sprite
	with_source = |sprite, source| {
		texture: sprite.texture,
		source,
		pos: sprite.pos,
		origin: sprite.origin,
		rotation: sprite.rotation,
		scale: sprite.scale,
		tint: sprite.tint,
	}

	with_pos : Sprite, Math.Vec2 -> Sprite
	with_pos = |sprite, pos| {
		texture: sprite.texture,
		source: sprite.source,
		pos,
		origin: sprite.origin,
		rotation: sprite.rotation,
		scale: sprite.scale,
		tint: sprite.tint,
	}

	with_origin : Sprite, Math.Vec2 -> Sprite
	with_origin = |sprite, origin| {
		texture: sprite.texture,
		source: sprite.source,
		pos: sprite.pos,
		origin,
		rotation: sprite.rotation,
		scale: sprite.scale,
		tint: sprite.tint,
	}

	with_origin_center : Sprite -> Sprite
	with_origin_center = |sprite| {
		Sprite.with_origin(
			sprite,
			{
				x: sprite.source.width * sprite.scale.x * 0.5,
				y: sprite.source.height * sprite.scale.y * 0.5,
			},
		)
	}

	with_rotation : Sprite, F32 -> Sprite
	with_rotation = |sprite, rotation| {
		texture: sprite.texture,
		source: sprite.source,
		pos: sprite.pos,
		origin: sprite.origin,
		rotation,
		scale: sprite.scale,
		tint: sprite.tint,
	}

	with_scale_xy : Sprite, Math.Vec2 -> Sprite
	with_scale_xy = |sprite, scale| {
		texture: sprite.texture,
		source: sprite.source,
		pos: sprite.pos,
		origin: sprite.origin,
		rotation: sprite.rotation,
		scale,
		tint: sprite.tint,
	}

	with_scale : Sprite, F32 -> Sprite
	with_scale = |sprite, amount| Sprite.with_scale_xy(sprite, { x: amount, y: amount })

	with_tint : Sprite, Color -> Sprite
	with_tint = |sprite, tint| {
		texture: sprite.texture,
		source: sprite.source,
		pos: sprite.pos,
		origin: sprite.origin,
		rotation: sprite.rotation,
		scale: sprite.scale,
		tint,
	}

	to_texture_draw : Sprite -> Draw.TextureDraw
	to_texture_draw = |sprite| {
		texture: sprite.texture,
		source: sprite.source,
		dest: {
			x: sprite.pos.x,
			y: sprite.pos.y,
			width: sprite.source.width * sprite.scale.x,
			height: sprite.source.height * sprite.scale.y,
		},
		origin: sprite.origin,
		rotation: sprite.rotation,
		tint: sprite.tint,
	}

	draw! : Sprite => {}
	draw! = |sprite| Draw.texture!(Sprite.to_texture_draw(sprite))

	## Return a source rectangle for a regular grid spritesheet.
	sheet_frame : { frame_size : Math.Vec2, row : U64, col : U64 } -> Math.Rect
	sheet_frame = |cfg| {
		x: U64.to_f32(cfg.col) * cfg.frame_size.x,
		y: U64.to_f32(cfg.row) * cfg.frame_size.y,
		width: cfg.frame_size.x,
		height: cfg.frame_size.y,
	}

	animation : { frame_count : U64, fps : F32 } -> Animation
	animation = |cfg| {
		frame: 0,
		frame_count: cfg.frame_count,
		fps: cfg.fps,
		elapsed: 0,
	}

	step : Animation, F32 -> Animation
	step = |animation_state, dt| {
		if animation_state.frame_count <= 1 or animation_state.fps <= 0 {
			animation_state
		} else {
			period = 1 / animation_state.fps
			elapsed = animation_state.elapsed + dt
			if elapsed >= period {
				{
					frame: (animation_state.frame + 1) % animation_state.frame_count,
					frame_count: animation_state.frame_count,
					fps: animation_state.fps,
					elapsed: elapsed - period,
				}
			} else {
				{
					frame: animation_state.frame,
					frame_count: animation_state.frame_count,
					fps: animation_state.fps,
					elapsed,
				}
			}
		}
	}

	source : Animation, { frame_size : Math.Vec2, row : U64 } -> Math.Rect
	source = |animation_state, cfg| {
		frame = if animation_state.frame_count == 0 0 else animation_state.frame % animation_state.frame_count
		Sprite.sheet_frame({ frame_size: cfg.frame_size, row: cfg.row, col: frame })
	}

}

expect Sprite.sheet_frame({ frame_size: { x: 16, y: 24 }, row: 2, col: 3 }) == Math.rect(48, 48, 16, 24)
expect (Sprite.step(Sprite.animation({ frame_count: 4, fps: 10 }), 0.11)).frame == 1
