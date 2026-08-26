app [target] { fuzz: platform "../../../roc-fuzz/platform/main.roc" }

## Partition invariance of the `RocDoomTrace` oracle.
##
## Each command's one-frame budget is split into 1..8 fractions of k/64 (plus an
## optional 1/4096 epsilon on one part) with the total in [64/64, 128/64).
##
## Properties:
##  T1 exact-rational model: the snapshot tic sequence must equal the sequence
##     predicted by floor(cumulative_time / tic) with exact integer arithmetic
##  T2 totals in 64..66 sixty-fourths (no epsilon) reproduce the golden trace
##  T3 single-part runs are deterministic
import fuzz.Fuzz
import RocDoomTrace

Input := { total : U8, weights : List(U8), epsilon_part : U8 }.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			total: Fuzz.u8_in(64, 127),
			weights: Fuzz.list(Fuzz.u8_in(1, 63), 7),
			epsilon_part: Fuzz.u8_in(0, 8),
		}.Fuzz
	}
}

## Split `total` sixty-fourths proportionally to `weights` (plus one implicit
## trailing weight) using integer arithmetic, dropping zero-sized parts.
parts_for : Input -> List(U64)
parts_for = |input| {
	weights = List.append(List.map(input.weights, U8.to_u64), 1)
	weight_sum = List.sum(weights)
	total = U8.to_u64(input.total)
	var $parts = []
	var $used = 0
	var $index = 0
	for w in weights {
		is_last = $index + 1 == List.len(weights)
		share = if is_last total - $used else total * w / weight_sum
		if share > 0 {
			$parts = List.append($parts, share)
		}
		$used = $used + share
		$index = $index + 1
	}
	$parts
}

fractions_for : List(U64), U8 -> List(F32)
fractions_for = |parts, epsilon_part| {
	var $index = 0
	var $out = []
	for k in parts {
		base = U64.to_f32(k) / 64
		value = if $index + 1 == U8.to_u64(epsilon_part) base + (1 / 4096) else base
		$out = List.append($out, value)
		$index = $index + 1
	}
	$out
}

## Expected snapshot tics with exact integer arithmetic (units: 1/64 tic).
## `exact` marks snapshots whose cumulative time lands exactly on a tic
## boundary; F32 remainder accumulation may defer those by one part.
Expected : { tic : U64, exact : Bool }

expected_tics : List(U64) -> List(Expected)
expected_tics = |parts| {
	var $out = []
	var $cum = 0
	var $prev = 0
	for _ in List.repeat({}, List.len(RocDoomTrace.commands)) {
		for k in parts {
			$cum = $cum + k
			tic = $cum / 64
			if tic > $prev {
				$out = List.append($out, { tic, exact: $cum % 64 == 0 })
				$prev = tic
			}
		}
	}
	$out
}

## Walk actual against expected. Returns the tic of the first deferred exact
## boundary (or 0 when the sequences agree). Crashes on any other divergence.
walk : List(U64), List(Expected), Str -> U64
walk = |actual, expected, ctx| {
	var $i = 0
	var $j = 0
	var $first_deferred = 0
	while $i < List.len(expected) or $j < List.len(actual) {
		match (List.get(expected, $i), List.get(actual, $j)) {
			(Ok(e), Ok(a)) if e.tic == a => {
				$i = $i + 1
				$j = $j + 1
			}
			(Ok(e), Ok(a)) if e.exact and a + 1 == e.tic => {
				# deferred: the part that should have ended exactly on e.tic stopped one
				# tic short; e.tic itself lands in a later part
				if $first_deferred == 0 {
					$first_deferred = e.tic
				}
				$j = $j + 1
			}
			(Ok(e), Ok(a)) if e.exact and a > e.tic => {
				# deferred: the exact boundary was missed and caught up in a later part
				if $first_deferred == 0 {
					$first_deferred = e.tic
				}
				$i = $i + 1
			}
			(Ok(e), Ok(a)) if !(e.exact) and a > e.tic and $i + 1 < List.len(expected) => {
				crash "PROPERTY: tic ${Str.inspect(e.tic)} skipped at a non-exact boundary ${ctx} expected=${Str.inspect(expected)} actual=${Str.inspect(actual)}"
			}
			(Ok(e), Ok(_)) => {
				crash "PROPERTY: tic sequence diverges at expected tic ${Str.inspect(e.tic)} ${ctx} expected=${Str.inspect(expected)} actual=${Str.inspect(actual)}"
			}
			(Ok(e), Err(_)) if e.exact => {
				# trailing exact boundary deferred past the end of the script
				if $first_deferred == 0 {
					$first_deferred = e.tic
				}
				$i = $i + 1
			}
			_ => {
				crash "PROPERTY: tic sequence length mismatch ${ctx} expected=${Str.inspect(expected)} actual=${Str.inspect(actual)}"
			}
		}
	}
	$first_deferred
}

golden : RocDoomTrace.Run
golden = RocDoomTrace.run([1.0001])

test : Input -> Fuzz.Outcome
test = |input| {
	parts = parts_for(input)
	total = U8.to_u64(input.total)
	fractions = fractions_for(parts, input.epsilon_part)
	has_epsilon = input.epsilon_part >= 1 and U8.to_u64(input.epsilon_part) <= List.len(parts)
	run = RocDoomTrace.run(fractions)
	actual = List.map(run.trace, |s| s.tic)
	expected = expected_tics(parts)
	ctx = "parts=${Str.inspect(parts)} fractions=${Str.inspect(fractions)} epsilon_part=${Str.inspect(input.epsilon_part)}"
	# T1: tic sequence vs exact model; deferral only at exact boundaries
	deferred = walk(actual, expected, ctx)
	if has_epsilon and deferred != 0 {
		crash "PROPERTY: epsilon run still deferred exact boundary ${Str.inspect(deferred)} ${ctx} expected=${Str.inspect(expected)} actual=${Str.inspect(actual)}"
	}
	# T2: near-unity totals reproduce the golden trace exactly
	if total <= 66 and !(has_epsilon) {
		if RocDoomTrace.checksum(run.trace) != RocDoomTrace.golden_checksum or run.trace != golden.trace {
			first = first_divergence(run.trace, golden.trace, 0)
			crash "PROPERTY: golden trace divergence ${ctx} deferred=${Str.inspect(deferred)} first=${first}"
		}
	}
	# T4: same total, single part reference: snapshots keyed by tic agree up to the
	# first deferral in either run (a deferral re-assigns a tic to the next command)
	if List.len(parts) > 1 and !(has_epsilon) {
		reference = RocDoomTrace.run([U64.to_f32(total) / 64])
		ref_deferred = walk(List.map(reference.trace, |s| s.tic), expected_tics([total]), "reference ${ctx}")
		# tic-sequence walks cannot see a deferral when the next part reaches the
		# same tic, so bound the comparison by the first exact boundary instead
		limit = min_nonzero(first_exact(expected), first_exact(expected_tics([total])))
		_ = ref_deferred
		for snap in run.trace {
			if limit == 0 or snap.tic < limit {
				match List.find_first(reference.trace, |r| r.tic == snap.tic) {
					Err(_) => {}
					Ok(r) =>
						if r != snap {
							crash "PROPERTY: same-total partition changed snapshot at tic ${Str.inspect(snap.tic)} ${ctx} candidate=${Str.inspect(snap)} reference=${Str.inspect(r)}"
						}
					}
			}
		}
	}
	# T3: determinism for single-part runs
	if List.len(fractions) == 1 {
		again = RocDoomTrace.run(fractions)
		if again.trace != run.trace {
			crash "PROPERTY: nondeterministic run ${ctx}"
		}
	}
	Fuzz.keep
}

first_exact : List(Expected) -> U64
first_exact = |expected|
	match List.find_first(expected, |e| e.exact) {
		Ok(e) => e.tic
		Err(_) => 0
	}

min_nonzero : U64, U64 -> U64
min_nonzero = |a, b| if a == 0 b else if b == 0 a else U64.min(a, b)

first_divergence : List(RocDoomTrace.Snapshot), List(RocDoomTrace.Snapshot), U64 -> Str
first_divergence = |a, b, index|
	match (List.get(a, index), List.get(b, index)) {
		(Err(_), Err(_)) => "no field divergence (lengths ${Str.inspect(List.len(a))} vs ${Str.inspect(List.len(b))})"
		(Err(_), Ok(_)) => "candidate shorter at ${Str.inspect(index)}"
		(Ok(_), Err(_)) => "candidate longer at ${Str.inspect(index)}"
		(Ok(x), Ok(y)) =>
			if x == y {
				first_divergence(a, b, index + 1)
			} else {
				"snapshot #${Str.inspect(index)} candidate=${Str.inspect(x)} golden=${Str.inspect(y)}"
			}
		}

## Exact one-frame sums (dyadic and non-dyadic) neither under- nor over-tick:
## every one of these reproduces the golden 24-tic trace without the `1.0001`
## epsilon used by the module's own expects.
expect {
	third = 1 / 3
	cases = [[1.0], [0.5, 0.5], [0.25, 0.25, 0.25, 0.25], [third, third, third], [0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1], [0.7, 0.3], [0.2, 0.8], [0.9, 0.1], [0.3, 0.3, 0.4], [1 / 64, 63 / 64], [63 / 64, 1 / 64]]
	List.all(cases, |fractions| RocDoomTrace.checksum(RocDoomTrace.run(fractions).trace) == RocDoomTrace.golden_checksum)
}

target = Fuzz.target({
	name: "doom-trace-partitions",
	test,
	show: |input| "${Str.inspect(input)} parts=${Str.inspect(parts_for(input))} fractions=${Str.inspect(fractions_for(parts_for(input), input.epsilon_part))}",
})
