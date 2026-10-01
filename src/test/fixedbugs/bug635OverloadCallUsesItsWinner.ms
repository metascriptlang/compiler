// Symptom: a call to an overloaded function was lowered against the first declared overload: a struct argument was cast to that overload's `Span` (C `used type 'msSpan_int32_t' where arithmetic or pointer type is required`), a call from the first overload to the second became a self tail call (a C type error, an endless loop on JS), and an `int32[]` argument never reached a `Span<int32>` overload although a lone `Span<int32>` parameter takes it.
// Root cause: spanLower and tailCallLower read the callee's base symbol, not the overload the checker chose (`resolvedOverloadIdx`); overload scoring related `Span` to a value array but not to `T[]`.
// Fix: both passes take the chosen overload (`overloadWinner`, the idiom restParamLower and borrowLower already used), as Nim's call resolution rebinds the callee to the chosen proc; `T[]` relates to `Span<T>` in scoring as it does in assignment.
// Runtime on every lane: corpus 670.
import { compileToC } from "../helpers";

function emit(src: string): string {
	const r = compileToC(src);
	return r.ok ? r.value : "error: " + r.error;
}

test "bug635: a struct argument is not coerced to the first overload's Span" {
	const out = emit(`
struct Box { value: int32; }
function pick(values: Span<int32>): int32 { return values.length as int32; }
function pick(box: Box): int32 { return box.value; }
const box: Box = { value: 9 };
console.log(pick(box));
`);
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf("(msSpan_int32_t)(box", 0) < 0, out;
}

test "bug635: a call from the first overload to the second is not a self tail call" {
	const out = emit(`
struct Box { value: int32; }
struct Crate { weight: int32; }
function pick(box: Box): int32 {
	const crate: Crate = { weight: box.value * 2 };
	return pick(crate);
}
function pick(crate: Crate): int32 { return crate.weight; }
const box: Box = { value: 9 };
console.log(pick(box));
`);
	assert out.indexOf("error:", 0) < 0, out;
	assert out.indexOf("__tcl", 0) < 0, out;
}

test "bug635: an int32[] argument reaches a Span<int32> overload" {
	const out = emit(`
struct Box { value: int32; }
function pick(box: Box): int32 { return box.value; }
function pick(values: Span<int32>): int32 { return values.length as int32; }
const xs: int32[] = [1, 2, 3];
console.log(pick(xs));
`);
	assert out.indexOf("error:", 0) < 0, out;
}
