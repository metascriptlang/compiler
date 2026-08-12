// Phase contract: by the end of the native transform pipeline, a callee whose
// type is a closure is dispatched through the closure convention — no matter
// which expression shape produced it.
//
// The discriminating token is `.fn)(` — calling THROUGH the function pointer.
// Constructing a closure emits `.fn = ` and `.env = `, so those alone prove
// nothing; a raw `tmp(2)` on an msClosure struct also carries them. Measured
// pre-fix: `.fn)(` occurs 0 times and the emission is `dollartmp_1_(2)`, which
// is what clang rejects with "called object type 'msClosure' is not a function
// or function pointer".
//
// Runtime siblings: corpus 305-closureCallChain (every callee shape, all lanes)
// and fixedbugs/bug104 (the same shapes inside the test tier).

import { compileToC } from "../helpers";

const CHAINED = `
function makeAdder(k: int32): (n: int32) => int32 {
	return (n: int32): int32 => n + k;
}
function main(): void {
	const r = makeAdder(1)(2);
}
`;

test "a closure returned by a call is dispatched through its function pointer" {
	const out = compileToC(CHAINED);
	assert out.ok;
	if (out.ok) {
		// The closure is really built here — without this the next assertion
		// could pass vacuously on a program that stopped using closures.
		assert out.value.contains(".fn = ");
		assert out.value.contains(".fn)(");
	}
}

const TERNARY = `
function makeAdder(k: int32): (n: int32) => int32 {
	return (n: int32): int32 => n + k;
}
function main(): void {
	const flag = true;
	const r = (flag ? makeAdder(1) : makeAdder(2))(5);
}
`;

test "a closure selected by a ternary is dispatched through its function pointer" {
	const out = compileToC(TERNARY);
	assert out.ok;
	if (out.ok) {
		assert out.value.contains(".fn = ");
		assert out.value.contains(".fn)(");
	}
}

const NAMED = `
function helper(n: int32): int32 { return n + 1; }
function main(): void {
	const r = helper(1);
}
`;

test "a named function call stays a direct call" {
	const out = compileToC(NAMED);
	assert out.ok;
	if (out.ok) {
		assert !out.value.contains(".fn)(");
	}
}
