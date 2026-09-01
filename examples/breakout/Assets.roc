## Breakout sounds, fonts, and prepared text loaded during application startup.
import rr.Audio
import rr.Draw
import rr.Text

Assets := {
	sounds : Sounds,
	font : Text.Font,
	title : Text.Prepared,
	hint : Text.Prepared,
	launch_line : Text.Prepared,
	won_line : Text.Prepared,
	over_line : Text.Prepared,
	restart_line : Text.Prepared,
}.{
	Sounds : {
		paddle : Audio.Sound,
		brick : Audio.Sound,
		wall : Audio.Sound,
		lose : Audio.Sound,
		start : Audio.Sound,
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
}
