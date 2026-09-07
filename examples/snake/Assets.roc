## Snake sounds, fonts, and prepared text loaded during application startup.
import rr.Audio
import rr.Draw
import rr.Text

Assets := {
	sounds : Sounds,
	font : Text.Font,
	title : Text.Prepared,
	hint : Text.Prepared,
	over_title : Text.Prepared,
	over_hint : Text.Prepared,
}.{
	Sounds : {
		eat : Audio.Sound,
		crash_sound : Audio.Sound,
		start : Audio.Sound,
	}

	## Prepares all Snake sounds, fonts, and text before the first frame.
	load! : () => Try(Assets, [ResourceLimit, SoundGenerationFailed, ..])
	load! = || {
		font = Draw.default_font!()
		Ok({
			font,
			title: Text.from("SNAKE", font).size(30).spacing(6).prepare!()?,
			hint: Text.from("ARROWS / WASD  turn    SPACE  restart    ESC  quit", font).size(17).prepare!()?,
			over_title: Text.from("GAME OVER", font).size(40).prepare!()?,
			over_hint: Text.from("PRESS SPACE TO PLAY AGAIN", font).size(19).prepare!()?,
			sounds: {
				eat: Audio.gen_tone!({ freq: 620, ms: 70 })?,
				crash_sound: Audio.gen_tone!({ freq: 120, ms: 180 })?,
				start: Audio.gen_tone!({ freq: 360, ms: 80 })?,
			},
		})
	}
}
