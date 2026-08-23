## Pure pseudorandom generators supplied by
## [`kili-ilo/roc-random`](https://github.com/kili-ilo/roc-random).
##
## Seed a `State` once during `init!`, retain it in the model, and pass the
## returned state into the next draw. Keeping simulation randomness in model
## state makes draws immediate during `update!` and reproduces a run from its
## initial seed.
##
## ```roc
## generation = Random.step(model.rng, Random.bounded_i32(0, 799))
## Ok({ ..model, rng: generation.state, x: generation.value })
## ```
##
## `App.entropy!` is the one thing that makes a run differ from the last one:
## seed from it for a run that should vary, and from a constant for one that
## must reproduce.
##
## This module is a platform-facing facade only. `State`, `Generator` and
## `Generation` are the package's own types, re-exported here, and the PCG
## implementation, the unbiased bounded generators, and the combinators all
## live in the external package.
import rand.Random as PackageRandom

Random := [].{

	## State threaded through successive pseudorandom generations. This is
	## `roc-random`'s own `State`, re-exported.
	State : PackageRandom.State

	## A pure generator that transforms a state into a value and its next state.
	## This is `roc-random`'s own `Generator`, re-exported.
	Generator(value) : PackageRandom.Generator(value)

	## A generated value paired with the state for the next draw. This is
	## `roc-random`'s own `Generation`, re-exported.
	Generation(value) : PackageRandom.Generation(value)

	## Initialize the default PCG sequence from a seed.
	seed : U32 -> State
	seed = PackageRandom.seed

	## Initialize an independent PCG sequence from a seed and sequence ID.
	seed_variant : U32, U32 -> State
	seed_variant = PackageRandom.seed_variant

	## Run a generator from a state.
	step : State, Generator(value) -> Generation(value)
	step = PackageRandom.step

	## Run another generator from a previous generation's output state.
	next : Generation(_), Generator(value) -> Generation(value)
	next = PackageRandom.next

	## Construct a generator that always returns `value` without advancing.
	static : value -> Generator(value)
	static = PackageRandom.static

	## Transform the output of a generator.
	map : Generator(a), (a -> b) -> Generator(b)
	map = PackageRandom.map

	## Combine two generators in sequence.
	map2 : Generator(a), Generator(b), (a, b -> c) -> Generator(c)
	map2 = PackageRandom.map2

	## Choose a subsequent generator from the output of the first.
	chain : Generator(a), (a -> Generator(b)) -> Generator(b)
	chain = PackageRandom.chain

	## Generate a list of `length` values.
	list : Generator(a), U64 -> Generator(List(a))
	list = PackageRandom.list

	## Generate a shuffled copy of a list.
	shuffle : List(a) -> Generator(List(a))
	shuffle = PackageRandom.shuffle

	## Generate either Boolean value with equal probability.
	bool : Generator(Bool)
	bool = PackageRandom.bool

	## Generate a `U8` across the type's full range.
	u8 : Generator(U8)
	u8 = PackageRandom.u8

	## Generate an `I8` across the type's full range.
	i8 : Generator(I8)
	i8 = PackageRandom.i8

	## Generate a `U16` across the type's full range.
	u16 : Generator(U16)
	u16 = PackageRandom.u16

	## Generate an `I16` across the type's full range.
	i16 : Generator(I16)
	i16 = PackageRandom.i16

	## Generate a `U32` across the type's full range.
	u32 : Generator(U32)
	u32 = PackageRandom.u32

	## Generate an `I32` across the type's full range.
	i32 : Generator(I32)
	i32 = PackageRandom.i32

	## Generate a `U64` across the type's full range.
	u64 : Generator(U64)
	u64 = PackageRandom.u64

	## Generate an `I64` across the type's full range.
	i64 : Generator(I64)
	i64 = PackageRandom.i64

	## Generate a `U8` between two inclusive bounds, without modulo bias.
	bounded_u8 : U8, U8 -> Generator(U8)
	bounded_u8 = PackageRandom.bounded_u8

	## Generate an `I8` between two inclusive bounds, without modulo bias.
	bounded_i8 : I8, I8 -> Generator(I8)
	bounded_i8 = PackageRandom.bounded_i8

	## Generate a `U16` between two inclusive bounds, without modulo bias.
	bounded_u16 : U16, U16 -> Generator(U16)
	bounded_u16 = PackageRandom.bounded_u16

	## Generate an `I16` between two inclusive bounds, without modulo bias.
	bounded_i16 : I16, I16 -> Generator(I16)
	bounded_i16 = PackageRandom.bounded_i16

	## Generate a `U32` between two inclusive bounds, without modulo bias.
	bounded_u32 : U32, U32 -> Generator(U32)
	bounded_u32 = PackageRandom.bounded_u32

	## Generate an `I32` between two inclusive bounds, without modulo bias.
	bounded_i32 : I32, I32 -> Generator(I32)
	bounded_i32 = PackageRandom.bounded_i32

	## Generate a `U64` between two inclusive bounds, without modulo bias.
	bounded_u64 : U64, U64 -> Generator(U64)
	bounded_u64 = PackageRandom.bounded_u64

	## Generate an `I64` between two inclusive bounds, without modulo bias.
	bounded_i64 : I64, I64 -> Generator(I64)
	bounded_i64 = PackageRandom.bounded_i64

	## Generate an `F32` in `[low, high)`.
	f32 : F32, F32 -> Generator(F32)
	f32 = PackageRandom.f32

	## Generate an `F64` in `[low, high)`.
	f64 : F64, F64 -> Generator(F64)
	f64 = PackageRandom.f64

	## Choose between the required first value and any following choices.
	choice : a, List(a) -> Generator(a)
	choice = PackageRandom.choice

	## Choose an item from a nonempty list, or report `ListWasEmpty`.
	choice_try : List(a) -> Try(Generator(a), [ListWasEmpty])
	choice_try = PackageRandom.choice_try

	## Choose between weighted values. Weights must be finite and nonnegative.
	choice_weighted : (a, F64), List((a, F64)) -> Generator(a)
	choice_weighted = PackageRandom.choice_weighted

	## Choose from a weighted list, or report `ListWasEmpty`.
	choice_weighted_try : List((a, F64)) -> Try(Generator(a), [ListWasEmpty])
	choice_weighted_try = PackageRandom.choice_weighted_try
}
