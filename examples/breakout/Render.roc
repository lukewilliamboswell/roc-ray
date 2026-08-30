## Breakout assets and drawing, kept separate from its pure game rules.
import rr.Audio
import rr.Color
import rr.Draw
import rr.Math
import rr.Text
import Ball
import Bricks
import Game
import Paddle

Render := [].{
	Sounds : {
		paddle : Audio.Sound,
		brick : Audio.Sound,
		wall : Audio.Sound,
		lose : Audio.Sound,
		start : Audio.Sound,
	}

	Assets : {
		sounds : Sounds,
		font : Text.Font,
		title : Text.Prepared,
		hint : Text.Prepared,
		launch_line : Text.Prepared,
		won_line : Text.Prepared,
		over_line : Text.Prepared,
		restart_line : Text.Prepared,
	}

	## Prepares all Breakout sounds, fonts, and text before the first frame.
	load! : () => Try(Assets, [ResourceLimit, SoundGenerationFailed, ..])
	load! = || {
		font = Draw.default_font!()
		Ok({
			font,
			title: Text.from("BREAKOUT", font).size(28).spacing(5).prepare!()?,
			hint: Text.from("A / D  or  ARROWS  move    SPACE  launch    ESC  quit", font).size(17).prepare!()?,
			launch_line: Text.from("PRESS SPACE TO LAUNCH", font).size(26).prepare!()?,
			won_line: Text.from("WALL CLEARED", font).size(34).prepare!()?,
			over_line: Text.from("GAME OVER", font).size(34).prepare!()?,
			restart_line: Text.from("PRESS SPACE TO PLAY AGAIN", font).size(19).prepare!()?,
			sounds: {
				paddle: Audio.gen_tone!({ freq: 440, ms: 50 })?,
				brick: Audio.gen_tone!({ freq: 760, ms: 45 })?,
				wall: Audio.gen_tone!({ freq: 260, ms: 40 })?,
				lose: Audio.gen_tone!({ freq: 140, ms: 180 })?,
				start: Audio.gen_tone!({ freq: 520, ms: 70 })?,
			},
		})
	}

	## Draws one complete Breakout presentation frame from the resulting world.
	draw! : Draw.Frame, Assets, Game.World, F32, Bool => Try({}, [ScopeLimit, ..])
	draw! = |frame, assets, world, elapsed, demo| {
		frame.clear!(field_bottom)
		draw_background!(frame)
		draw_hud!(frame, assets, world, demo)
		draw_bricks!(frame, world.bricks)
		draw_glow!(frame, world)?
		draw_bodies!(frame, world)
		draw_state_overlay!(frame, assets, world, elapsed)
		Ok({})
	}

	## Paints the dark vertical gradient behind the cabinet.
	draw_background! : Draw.Frame => {}
	draw_background! = |frame|
		frame.rectangle_gradient_v!({ x: 0, y: 0, width: 800, height: 600, color_top: field_top, color_bottom: field_bottom })

	## Draws additive neon halos behind the paddle and ball.
	draw_glow! : Draw.Frame, Game.World => Try({}, [ScopeLimit, ..])
	draw_glow! = |frame, world|
		frame.with_blend_mode!(
			Draw.additive_blend,
			|glow_frame| {
				glow_frame.circle_gradient!({ center: Math.center(world.paddle.rect()), radius: 90, color_inner: Color.with_alpha(paddle_neon, 95), color_outer: Color.with_alpha(paddle_neon, 0) })
				glow_frame.circle_gradient!({ center: world.ball.pos, radius: 46, color_inner: Color.with_alpha(ball_neon, 95), color_outer: Color.with_alpha(ball_neon, 0) })
				Ok({})
			},
		)

	## Draws one colored brick with a bright top-edge sheen.
	draw_brick! : Draw.Frame, Bricks.Brick => {}
	draw_brick! = |frame, brick| {
		frame.rounded_rectangle!({ x: brick.rect.x, y: brick.rect.y, width: brick.rect.width, height: brick.rect.height, radius: 0.28, segments: 6, style: Draw.filled(Color.with_alpha(brick.color, 235)) })
		frame.rectangle!({ x: brick.rect.x + 5, y: brick.rect.y + 3, width: brick.rect.width - 10, height: 3, style: Draw.filled(Color.with_alpha(Color.white, 110)) })
	}

	## Draws every brick still remaining in the wall.
	draw_bricks! : Draw.Frame, List(Bricks.Brick) => {}
	draw_bricks! = |frame, bricks|
		for brick in bricks {
			draw_brick!(frame, brick)
		}

	## Draws the solid paddle and ball over their glows.
	draw_bodies! : Draw.Frame, Game.World => {}
	draw_bodies! = |frame, world| {
		paddle = world.paddle.rect()
		frame.rounded_rectangle!({ x: paddle.x, y: paddle.y, width: paddle.width, height: paddle.height, radius: 0.5, segments: 8, style: Draw.filled(paddle_neon) })
		frame.rectangle!({ x: paddle.x + 8, y: paddle.y + 3, width: paddle.width - 16, height: 3, style: Draw.filled(Color.with_alpha(Color.white, 150)) })
		frame.circle!({ center: world.ball.pos, radius: Ball.radius, style: Draw.filled(ball_neon) })
		frame.circle!({ center: { x: world.ball.pos.x - 2, y: world.ball.pos.y - 2 }, radius: Ball.radius * 0.4, style: Draw.filled(Color.with_alpha(Color.white, 210)) })
	}

	## Draws the title, score, lives, boundary, controls hint, and optional FPS.
	draw_hud! : Draw.Frame, Assets, Game.World, Bool => {}
	draw_hud! = |frame, assets, world, demo| {
		assets.title.draw!(frame, { pos: { x: 44, y: 22 }, color: paddle_neon })
		frame.text!({ pos: { x: 330, y: 26 }, text: "SCORE ${U64.to_str(world.score)}", size: 22, spacing: Draw.default_spacing, color: hud_color, font: assets.font })
		frame.text!({ pos: { x: 560, y: 26 }, text: "LIVES ${U64.to_str(world.lives)}", size: 22, spacing: Draw.default_spacing, color: hud_color, font: assets.font })
		if demo {} else frame.fps!({ pos: { x: 730, y: 28 }, size: 18, color: hint_color })
		frame.line!({ start: { x: 44, y: 58 }, end: { x: 756, y: 58 }, stroke: Draw.stroke(Color.from_hex_rgb(0x2a3566), 2) })
		assets.hint.draw!(frame, { pos: { x: 400, y: 580 }, color: hint_color, align: (Middle, Center) })
	}

	## Pulses waiting-screen text between translucent and opaque.
	prompt_alpha : F32 -> U8
	prompt_alpha = |elapsed| F32.to_u8_wrap(150 + 105 * (0.5 + 0.5 * F32.sin(elapsed * 3.4)))

	## Draws the launch prompt or the appropriate finished-match banner.
	draw_state_overlay! : Draw.Frame, Assets, Game.World, F32 => {}
	draw_state_overlay! = |frame, assets, world, elapsed|
		match world.state {
			Ready => assets.launch_line.draw!(frame, { pos: { x: 400, y: 350 }, color: Color.with_alpha(hud_color, prompt_alpha(elapsed)), align: (Middle, Center) })
			Playing => {}
			Won => draw_banner!(frame, assets, assets.won_line, Color.from_hex_rgb(0x4ce0b3), elapsed)
			GameOver => draw_banner!(frame, assets, assets.over_line, Color.from_hex_rgb(0xff4f7d), elapsed)
		}

	## Draws a won or game-over panel with its restart prompt.
	draw_banner! : Draw.Frame, Assets, Text.Prepared, Color.Rgba, F32 => {}
	draw_banner! = |frame, assets, line, accent, elapsed| {
		frame.rounded_rectangle!({ x: 190, y: 276, width: 420, height: 124, radius: 0.14, segments: 8, style: Draw.filled_and_outlined(Color.with_alpha(field_bottom, 232), Color.with_alpha(accent, 120), 2) })
		line.draw!(frame, { pos: { x: 400, y: 318 }, color: accent, align: (Middle, Center) })
		assets.restart_line.draw!(frame, { pos: { x: 400, y: 362 }, color: Color.with_alpha(hint_color, prompt_alpha(elapsed)), align: (Middle, Center) })
	}
}

field_top = Color.from_hex_rgb(0x161d3c)

field_bottom = Color.from_hex_rgb(0x05070f)

paddle_neon = Color.from_hex_rgb(0x38e8ff)

ball_neon = Color.from_hex_rgb(0xffe08a)

hud_color = Color.from_hex_rgb(0xd7e3ff)

hint_color = Color.from_hex_rgb(0x6d7aa8)
