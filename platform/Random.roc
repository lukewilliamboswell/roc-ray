## Random module - pure pseudo-random numbers for simulation.
##
## Gameplay randomness belongs in the model, not in an effect. Seed a generator
## once during startup, keep it in the model, and advance it inside `update`:
## the draw is immediate, so a serve or a spawn happens on the frame that needed
## it rather than a frame later, and a run reproduces exactly from its seed.
##
## Deliberately *not* a fresh seed on every step. That would make a sequence
## depend on frame rate and on how many idle frames went by, which is the
## opposite of what a simulation wants.
##
## Real entropy is a different thing and stays an effect -- ask for it once in
## `init!` and seed from it. Tests pass a fixed seed instead.
##
## The algorithm is SplitMix64. Roc has no scalar shift on `U64`, so the shifts
## are written as division and multiplication by powers of two: for an unsigned
## value those are exactly logical shift right and shift left.

## The generator's state. Copy it, keep it in a model, thread it through -- it
## is a plain value with no identity.
RandomGenerator := U64.{
	is_eq : _
}

Random := [].{

	## A generator's state.
	Generator : RandomGenerator

	## A drawn value paired with the generator to use next.
	Draw(value) : { value : value, next : Generator }

	## Start a generator from a seed. The same seed always gives the same
	## sequence, which is what makes a run reproducible.
	from_seed : U64 -> Generator
	from_seed = |seed| RandomGenerator.(seed)

	## Draw the next raw value, and the generator to use next.
	##
	## Threading the generator through rather than mutating it is what keeps
	## `update` pure: a draw is a value, not an effect.
	next_u64 : Generator -> Draw(U64)
	next_u64 = |RandomGenerator.(state)| {
		stepped = state.plus_wrap(golden_gamma)
		mixed_once = stepped.bitwise_xor(stepped // 0x40000000).times_wrap(0xBF58476D1CE4E5B9)
		mixed_twice = mixed_once.bitwise_xor(mixed_once // 0x8000000).times_wrap(0x94D049BB133111EB)
		{
			value: mixed_twice.bitwise_xor(mixed_twice // 0x80000000),
			next: RandomGenerator.(stepped),
		}
	}

	## Draw an integer in `[lowest, highest]`, inclusive at both ends.
	##
	## A `highest` below `lowest` yields `lowest` rather than crashing, matching
	## how the host's own generator treats an empty range.
	in_range : Generator, I32, I32 -> Draw(I32)
	in_range = |generator, lowest, highest|
		if highest <= lowest {
			{ value: lowest, next: generator }
		} else {
			drawn = next_u64(generator)
			# Fold the draw into a non-negative I32 first, so the range maths
			# stays in I32 and needs no U64 conversion: this Roc has no I32
			# widening to U64. Taking the low 31 bits keeps it non-negative.
			folded = U64.to_i32_wrap(drawn.value % 2_147_483_648)
			span = highest - lowest + 1
			{ value: lowest + folded % span, next: drawn.next }
		}

	## Draw a fraction in `[0, 1)`.
	fraction : Generator -> Draw(F32)
	fraction = |generator| {
		drawn = next_u64(generator)
		# 24 bits is the most an F32 represents exactly.
		{ value: U64.to_f32(drawn.value % 16_777_216) / 16_777_216, next: drawn.next }
	}
}

## The SplitMix64 increment: the odd 64-bit approximation of the golden ratio.
golden_gamma : U64
golden_gamma = 0x9E3779B97F4A7C15

expect Random.from_seed(7) == Random.from_seed(7)

## The same seed replays the same sequence -- the property the whole design
## rests on, and what makes a run reproducible from its seed alone.
expect Random.next_u64(Random.from_seed(42)).value == Random.next_u64(Random.from_seed(42)).value

## Different seeds diverge immediately.
expect Random.next_u64(Random.from_seed(1)).value != Random.next_u64(Random.from_seed(2)).value

## Advancing gives a different draw, so the generator really is threaded through
## rather than being redrawn from the same state.
expect Random.next_u64(Random.next_u64(Random.from_seed(9)).next).value != Random.next_u64(Random.from_seed(9)).value

## A drawn integer stays inside its range.
expect Random.in_range(Random.from_seed(3), -5, 5).value >= -5
expect Random.in_range(Random.from_seed(3), -5, 5).value <= 5
expect Random.in_range(Random.from_seed(88), 0, 3).value <= 3

## An empty or inverted range yields its lower bound rather than crashing.
expect Random.in_range(Random.from_seed(3), 4, 4).value == 4
expect Random.in_range(Random.from_seed(3), 9, 2).value == 9

## A fraction stays in [0, 1).
expect Random.fraction(Random.from_seed(11)).value >= 0
expect Random.fraction(Random.from_seed(11)).value < 1
