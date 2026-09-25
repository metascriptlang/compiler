// bug212 — a float32 const entered arithmetic as the double of its source literal
//
// Symptom:    `x * STEP` with `const STEP: float32 = 0.42` differed from the same product through a
//             float32 parameter in 367 of 1000 cases; void3d's campfire moved 8 pixels.
// Root cause: module const inlining typed the literal float32, but C spelled it `0.42`, a double,
//             and the fold computed float32 chains in double.
// Fix:        a float32 literal is spelled as its float32 value with `f`; the fold leaves float32
//             arithmetic to the backend and does not retype a float32 value to another type.

const STEP212: float32 = 0.42;
const BIG212: float32 = 16777217.0;
const ONE212: float32 = 1.0;
const WIDE212: float64 = STEP212;

let step212: float32 = 0.42;
let big212: float32 = 16777217.0;

function times212(a: float32, b: float32): float32 {
	return a * b;
}

test "bug212: a float32 const multiplies as a float32" {
	for (let n = 0; n < 64; n++) {
		const x = n as float32;
		assert x * STEP212 == times212(x, step212);
	}
}

test "bug212: a float32 const chain rounds like the runtime" {
	const sum: float32 = big212 + ONE212;
	assert BIG212 + ONE212 == sum;
}

test "bug212: a float32 const widened to float64 keeps its float32 value" {
	const wide: float64 = step212;
	assert WIDE212 == wide;
	assert WIDE212 * 3.0 == wide * 3.0;
}
