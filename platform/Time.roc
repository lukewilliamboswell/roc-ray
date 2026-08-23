## Helpers for working with the cycle's simulation clock, and with the
## calendar the world outside the app keeps.
##
## Animation and physics use `input.time`, not wall time. The host samples one
## `Cycle` per call to `update!`, and every app that moves something should
## derive that movement from it: a value read from the calendar or a
## wall-clock timer is not the timeline the platform paces, replays, or holds
## to a fixed step while a capture records.
##
## For the common "move per cycle" case, use `input.time.elapsed_seconds`
## directly -- simulation seconds since the preceding input -- without touching
## the helpers below.
##
## `Timestamp` and `now!` are the other clock: what time it is in the world,
## for stamping a filename, rendering a date, or correlating a log line with
## something outside the process. It is explicitly nondeterministic, and it is
## never a substitute for `Cycle`. `now!` is legal in `init!`, `update!`, and
## tasks; it is refused in `render!`, which is given the model rather than an
## input and should draw the instant the model already decided on. It does not
## wait, so it needs no task of its own.
##
## The `Cycle` helpers live in the companion `roc-ray-types` package so
## reusable packages can depend on them without depending on this platform, and
## this module re-exports them. `Timestamp` is this platform's own: reading the
## world's clock is an effect, so it lives where the effects do.
import rrt.Time as RrtTime
import TimeHost

Time := [].{

	## When one cycle happened, and how much time it covers.
	##
	## `cycle_count` counts cycles from `0`, `simulation_nanos` is the
	## simulation clock the platform advances, `monotonic_nanos` is the host's
	## own monotonic clock at the sample, and `elapsed_seconds` is the time this
	## cycle covers, which is what animation and simulation multiply by.
	##
	## Declared in the `roc-ray-types` package's `Time` and re-exported here;
	## `App.Input` carries one as `input.time`.
	Cycle : RrtTime.Cycle

	## The cycle an app starts on: count zero, no elapsed time.
	##
	## `App.Input.for_tests` uses it, and a test that needs a second cycle says
	## so: `input.with_time({ ..Time.first_cycle, cycle_count: 1 })`.
	first_cycle : Cycle
	first_cycle = RrtTime.first_cycle

	## Convert a nanosecond duration to seconds.
	##
	## ```roc
	## expect Time.to_seconds(500_000_000) == 0.5
	## ```
	to_seconds : U64 -> F32
	to_seconds = RrtTime.to_seconds

	## Seconds elapsed between two clock samples. The second must not be earlier
	## than the first.
	##
	## Handy for deriving a delta over more than one cycle from
	## `Time.Cycle.simulation_nanos`:
	##
	## ```roc
	## dt = Time.delta_seconds(model.last_tick, input.time.simulation_nanos)
	## ```
	delta_seconds : U64, U64 -> F32
	delta_seconds = RrtTime.delta_seconds

	## An instant on the world's clock, as seconds and nanoseconds since the
	## Unix epoch.
	##
	## Always normalized: `nanosecond` is less than 1,000,000,000, and seconds
	## are floor-based, so one nanosecond before the epoch is
	## `{ seconds: -1, nanosecond: 999_999_999 }` rather than a negative
	## fraction of second zero. That is what makes ordering and differences
	## work the same on both sides of 1970.
	##
	## A timestamp carries no time zone, no calendar policy, and no
	## leap-second model. Everything this module formats is UTC; local time and
	## calendar arithmetic belong to a pure Roc package, and a `Timestamp` is
	## the value to hand it.
	Timestamp :: {
		seconds : I64,
		nanosecond : U32,
	}.{

		## Compare two of these values.
		is_eq : _

		## The Unix epoch, `1970-01-01T00:00:00Z`.
		##
		## A neutral value for a model field that has not read the clock yet,
		## and the base every other instant is measured from.
		epoch : Timestamp
		epoch = Timestamp.({ seconds: 0, nanosecond: 0 })

		## Build a timestamp from its two parts.
		##
		## `InvalidNanosecond` is a whole second or more of fractional part,
		## which is a value that does not describe an instant rather than a
		## clock that failed.
		from_parts : { seconds : I64, nanosecond : U32 } -> Try(Timestamp, [InvalidNanosecond])
		from_parts = |parts|
			if parts.nanosecond < nanos_per_second_u32 {
				Ok(Timestamp.(parts))
			} else {
				Err(InvalidNanosecond)
			}

		## Build a timestamp from signed nanoseconds since the epoch.
		##
		## `OutOfRange` is an instant further from 1970 than a signed 64-bit
		## count of seconds reaches, which is about 292 billion years either
		## way.
		from_nanos_since_epoch : I128 -> Try(Timestamp, [OutOfRange])
		from_nanos_since_epoch = |nanos| {
			whole = floor_div_i128(nanos, nanos_per_second_i128)
			fraction = nanos - whole * nanos_per_second_i128
			match (I128.to_i64_try(whole), I128.to_u32_try(fraction)) {
				(Ok(seconds), Ok(nanosecond)) => Ok(Timestamp.({ seconds: seconds, nanosecond: nanosecond }))
				_ => Err(OutOfRange)
			}
		}

		## Whole seconds since the epoch, rounded towards the epoch's past.
		seconds_since_epoch : Timestamp -> I64
		seconds_since_epoch = |Timestamp.(parts)| parts.seconds

		## The fractional nanoseconds within this timestamp's own second.
		subsecond_nanoseconds : Timestamp -> U32
		subsecond_nanoseconds = |Timestamp.(parts)| parts.nanosecond

		## Signed nanoseconds since the epoch.
		nanos_since_epoch : Timestamp -> I128
		nanos_since_epoch = |Timestamp.(parts)|
			I64.to_i128(parts.seconds) * nanos_per_second_i128 + U32.to_i128(parts.nanosecond)

		## Nanoseconds from the first instant to the second, negative when the
		## second is the earlier one.
		difference_nanos : Timestamp, Timestamp -> I128
		difference_nanos = |earlier, later| nanos_since_epoch(later) - nanos_since_epoch(earlier)

		## Format as an ISO 8601 instant in UTC, to the second.
		##
		## ```roc
		## expect Time.Timestamp.epoch.to_iso_8601() == "1970-01-01T00:00:00Z"
		## ```
		##
		## The `Z` is always literal: this platform formats UTC and nothing
		## else, so there is no offset to get wrong. Years are padded to four
		## digits, and a year before the common era is written with a leading
		## minus and as many digits as it needs.
		to_iso_8601 : Timestamp -> Str
		to_iso_8601 = |timestamp| format_calendar(timestamp, ":", NoFraction)

		## Format as an ISO 8601 instant in UTC, to the nanosecond.
		##
		## The fractional part is always nine digits, so timestamps sort as
		## strings in the same order they sort as instants.
		to_iso_8601_nanos : Timestamp -> Str
		to_iso_8601_nanos = |timestamp| format_calendar(timestamp, ":", WithFraction)

		## Format as an instant that is legal in a filename on every platform.
		##
		## The same shape as `to_iso_8601` with `-` where the colons would be,
		## because a colon cannot appear in a path on Windows:
		##
		## ```roc
		## expect Time.Timestamp.epoch.to_file_stamp() == "1970-01-01T00-00-00Z"
		## ```
		to_file_stamp : Timestamp -> Str
		to_file_stamp = |timestamp| format_calendar(timestamp, "-", NoFraction)
	}

	## Read the world's clock.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`. `render!` is
	## given the model rather than an input, and should draw the instant the
	## model already decided on.
	##
	## Two calls in one `update!` can answer differently, and an app that wants
	## one instant for a whole cycle should read it once and keep it in the model.
	## Nothing else about the platform changes with it: the calendar is explicitly
	## nondeterministic, it is not what a capture paces, and it is not what
	## animation should move on.
	now! : () => Timestamp
	now! = || Timestamp.(TimeHost.now!())
}

## The one second every conversion here is written in terms of.
nanos_per_second_u32 : U32
nanos_per_second_u32 = 1_000_000_000

nanos_per_second_i128 : I128
nanos_per_second_i128 = 1_000_000_000

seconds_per_day : I64
seconds_per_day = 86_400

## Divide rounding towards negative infinity rather than towards zero.
##
## Truncating division would put the two sides of the epoch on different
## footings: `-1 // 86_400` is `0`, which would place one second before the
## epoch on the same day as one second after it.
floor_div_i128 : I128, I128 -> I128
floor_div_i128 = |numerator, denominator| {
	quotient = numerator // denominator
	if quotient * denominator > numerator {
		quotient - 1
	} else {
		quotient
	}
}

floor_div_i64 : I64, I64 -> I64
floor_div_i64 = |numerator, denominator| {
	quotient = numerator // denominator
	if quotient * denominator > numerator {
		quotient - 1
	} else {
		quotient
	}
}

expect floor_div_i64(-1, 86_400) == -1
expect floor_div_i64(0, 86_400) == 0
expect floor_div_i64(86_400, 86_400) == 1
expect floor_div_i128(-1_000_000_001, 1_000_000_000) == -2

## Whether a formatted instant carries its fractional second.
Fraction : [NoFraction, WithFraction]

## A UTC calendar date and time of day.
Calendar : { year : I64, month : I64, day : I64, hour : I64, minute : I64, second : I64 }

## Split an instant into its UTC calendar parts.
##
## The date half is Howard Hinnant's `civil_from_days`: era arithmetic with a
## March-based year, which is closed-form rather than a loop over months from
## 1970, so an instant far from the epoch costs the same as a recent one and a
## date before 1970 needs no separate case.
to_calendar : Time.Timestamp -> Calendar
to_calendar = |timestamp| {
	total_seconds = Time.Timestamp.seconds_since_epoch(timestamp)
	days = floor_div_i64(total_seconds, seconds_per_day)
	second_of_day = total_seconds - days * seconds_per_day

	# Shift the epoch to 0000-03-01 so leap days land at the end of the year.
	shifted = days + 719_468
	era = floor_div_i64(shifted, 146_097)
	day_of_era = shifted - era * 146_097
	year_of_era = (day_of_era - day_of_era // 1_460 + day_of_era // 36_524 - day_of_era // 146_096) // 365
	day_of_year = day_of_era - (365 * year_of_era + year_of_era // 4 - year_of_era // 100)
	month_index = (5 * day_of_year + 2) // 153
	day = day_of_year - (153 * month_index + 2) // 5 + 1
	month = if month_index < 10 {
		month_index + 3
	} else {
		month_index - 9
	}
	year = year_of_era + era * 400 + if month <= 2 {
		1
	} else {
		0
	}

	{
		year: year,
		month: month,
		day: day,
		hour: second_of_day // 3_600,
		minute: second_of_day // 60 % 60,
		second: second_of_day % 60,
	}
}

expect to_calendar(Time.Timestamp.epoch) == { year: 1970, month: 1, day: 1, hour: 0, minute: 0, second: 0 }

## A leap day, which is what the March-based year exists to get right.
expect to_calendar(Time.Timestamp.({ seconds: 1_709_164_800, nanosecond: 0 })).month == 2
expect to_calendar(Time.Timestamp.({ seconds: 1_709_164_800, nanosecond: 0 })).day == 29

## One second before the epoch is the last second of 1969, not the first second
## of 1970 with a negative sign in front of it.
expect to_calendar(Time.Timestamp.({ seconds: -1, nanosecond: 0 }))
	== { year: 1969, month: 12, day: 31, hour: 23, minute: 59, second: 59 }

format_calendar : Time.Timestamp, Str, Fraction -> Str
format_calendar = |timestamp, time_separator, fraction| {
	parts = to_calendar(timestamp)
	date = "${format_year(parts.year)}-${pad_two(parts.month)}-${pad_two(parts.day)}"
	clock = "${pad_two(parts.hour)}${time_separator}${pad_two(parts.minute)}${time_separator}${pad_two(parts.second)}"
	tail = match fraction {
		NoFraction => "Z"
		WithFraction => ".${pad_nine(Time.Timestamp.subsecond_nanoseconds(timestamp))}Z"
	}
	"${date}T${clock}${tail}"
}

## Four digits for an ordinary year, and a signed, unpadded one for a year the
## four-digit form cannot hold.
format_year : I64 -> Str
format_year = |year|
	if year < 0 {
		"-${pad_left(I64.to_str(-year), 4)}"
	} else {
		pad_left(I64.to_str(year), 4)
	}

pad_two : I64 -> Str
pad_two = |value| pad_left(I64.to_str(value), 2)

pad_nine : U32 -> Str
pad_nine = |value| pad_left(U32.to_str(value), 9)

## Left-pad with zeros, leaving anything already that long alone.
pad_left : Str, U64 -> Str
pad_left = |text, width| {
	length = Str.count_utf8_bytes(text)
	if length >= width {
		text
	} else {
		Str.concat(Str.repeat("0", width - length), text)
	}
}

expect pad_left("7", 2) == "07"
expect pad_left("123", 2) == "123"

expect Time.Timestamp.epoch.to_iso_8601() == "1970-01-01T00:00:00Z"
expect Time.Timestamp.epoch.to_file_stamp() == "1970-01-01T00-00-00Z"
expect Time.Timestamp.epoch.to_iso_8601_nanos() == "1970-01-01T00:00:00.000000000Z"

expect Time.Timestamp.({ seconds: 1_755_872_400, nanosecond: 250_000_000 }).to_iso_8601() == "2025-08-22T14:20:00Z"
expect Time.Timestamp.({ seconds: 1_755_872_400, nanosecond: 250_000_000 }).to_iso_8601_nanos()
	== "2025-08-22T14:20:00.250000000Z"

## A filename stamp differs from the instant only where a path cannot hold it.
expect Time.Timestamp.({ seconds: 1_755_872_400, nanosecond: 0 }).to_file_stamp() == "2025-08-22T14-20-00Z"

## Before the epoch, and long before four digits are enough.
expect Time.Timestamp.({ seconds: -1, nanosecond: 0 }).to_iso_8601() == "1969-12-31T23:59:59Z"
expect Time.Timestamp.({ seconds: -62_135_596_800, nanosecond: 0 }).to_iso_8601() == "0001-01-01T00:00:00Z"

## Normalization keeps a fraction inside its own second, so an instant just
## before the epoch is the last nanosecond of 1969 rather than a negative
## fraction of 1970.
expect Time.Timestamp.from_nanos_since_epoch(-1) == Ok(Time.Timestamp.({ seconds: -1, nanosecond: 999_999_999 }))
expect Time.Timestamp.from_nanos_since_epoch(1_500_000_000) == Ok(Time.Timestamp.({ seconds: 1, nanosecond: 500_000_000 }))
expect Time.Timestamp.from_parts({ seconds: 0, nanosecond: 999_999_999 }) == Ok(Time.Timestamp.({ seconds: 0, nanosecond: 999_999_999 }))
expect Time.Timestamp.from_parts({ seconds: 0, nanosecond: 1_000_000_000 }) == Err(InvalidNanosecond)

## A difference is signed, and reads the same in both directions.
expect Time.Timestamp.difference_nanos(Time.Timestamp.epoch, Time.Timestamp.({ seconds: 2, nanosecond: 500_000_000 })) == 2_500_000_000
expect Time.Timestamp.difference_nanos(Time.Timestamp.({ seconds: 2, nanosecond: 500_000_000 }), Time.Timestamp.epoch) == -2_500_000_000
expect Time.Timestamp.nanos_since_epoch(Time.Timestamp.({ seconds: -1, nanosecond: 999_999_999 })) == -1
