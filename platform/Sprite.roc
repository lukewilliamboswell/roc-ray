## Sprite module - pure helpers for texture sprites and simple animations.
##
## Drawing still goes through Draw/Assets. This module provides a compact
## game-facing shape for sprites, spritesheet frame rectangles, and animation
## state.
import Assets
import Color
import Draw
import Math

Sprite := {
	texture : Assets.Texture,
	source : Math.Rect,
	pos : Math.Vec2,
	origin : Math.Vec2,
	rotation : F32,
	scale : Math.Vec2,
	tint : Color,
}.{

	source : Sprite, Math.Rect -> Sprite
	source = |sprite, source_rect| { ..sprite, source: source_rect }

	pos : Sprite, Math.Vec2 -> Sprite
	pos = |sprite, new_pos| { ..sprite, pos: new_pos }

	origin : Sprite, Math.Vec2 -> Sprite
	origin = |sprite, new_origin| { ..sprite, origin: new_origin }

	centered : Sprite -> Sprite
	centered = |sprite| {
		..sprite,
		origin: {
			x: sprite.source.width * sprite.scale.x * 0.5,
			y: sprite.source.height * sprite.scale.y * 0.5,
		},
	}

	rotation : Sprite, F32 -> Sprite
	rotation = |sprite, angle| { ..sprite, rotation: angle }

	scale_xy : Sprite, Math.Vec2 -> Sprite
	scale_xy = |sprite, new_scale| { ..sprite, scale: new_scale }

	scale : Sprite, F32 -> Sprite
	scale = |sprite, amount| { ..sprite, scale: { x: amount, y: amount } }

	tint : Sprite, Color -> Sprite
	tint = |sprite, new_tint| { ..sprite, tint: new_tint }

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
	draw! = |sprite| Draw.texture!(sprite.to_texture_draw())

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
	with_source = |sprite, source_rect| sprite.source(source_rect)

	with_pos : Sprite, Math.Vec2 -> Sprite
	with_pos = |sprite, new_pos| sprite.pos(new_pos)

	with_origin : Sprite, Math.Vec2 -> Sprite
	with_origin = |sprite, new_origin| sprite.origin(new_origin)

	with_origin_center : Sprite -> Sprite
	with_origin_center = |sprite| sprite.centered()

	with_rotation : Sprite, F32 -> Sprite
	with_rotation = |sprite, angle| sprite.rotation(angle)

	with_scale_xy : Sprite, Math.Vec2 -> Sprite
	with_scale_xy = |sprite, new_scale| sprite.scale_xy(new_scale)

	with_scale : Sprite, F32 -> Sprite
	with_scale = |sprite, amount| sprite.scale(amount)

	with_tint : Sprite, Color -> Sprite
	with_tint = |sprite, new_tint| sprite.tint(new_tint)

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
					..animation_state,
					frame: (animation_state.frame + 1) % animation_state.frame_count,
					elapsed: elapsed - period,
				}
			} else {
				{ ..animation_state, elapsed }
			}
		}
	}

	animation_source : Animation, { frame_size : Math.Vec2, row : U64 } -> Math.Rect
	animation_source = |animation_state, cfg| {
		frame = if animation_state.frame_count == 0 0 else animation_state.frame % animation_state.frame_count
		Sprite.sheet_frame({ frame_size: cfg.frame_size, row: cfg.row, col: frame })
	}

}

expect Sprite.sheet_frame({ frame_size: { x: 16, y: 24 }, row: 2, col: 3 }) == Math.rect(48, 48, 16, 24)
expect (Sprite.step(Sprite.animation({ frame_count: 4, fps: 10 }), 0.11)).frame == 1
expect {
	texture = Box.box({ handle: 1, width: 8, height: 4 })
	sprite = Sprite.from_texture(texture)
		.source(
			Math.rect(1, 2, 3, 4),
		)
		.pos(
			{ x: 5, y: 6 },
		)
		.scale(
			2,
		)
		.centered()
		.rotation(
			90,
		)
		.tint(
			Color.red,
		)

	sprite.source == Math.rect(1, 2, 3, 4)
		and sprite.pos == { x: 5, y: 6 }
			and sprite.scale == { x: 2, y: 2 }
				and sprite.origin == { x: 3, y: 4 }
					and sprite.rotation == 90
						and sprite.tint == Color.red
}
expect Sprite.animation_source(Sprite.animation({ frame_count: 4, fps: 10 }), { frame_size: { x: 16, y: 16 }, row: 2 }) == Math.rect(0, 32, 16, 16)
