// bug121 — int64 reaching a `number` slot is never marked, so JS leaks a BigInt
//
// Symptom:    on the js lane every `number`-typed slot fed by an int64 value
//             carried a raw BigInt: `TypeError: Cannot mix BigInt and other
//             types` at the first arithmetic (loud), and `BigInt === Number`
//             answering false at a comparison (SILENT). C was immune only
//             because C converts int64 → double implicitly. Found through
//             std `string.parseInt()` (returns int64) in neon's terminal host.
// Root cause: fitNode marks the 64-bit representation boundary with a
//             HiddenStdConv, but the predicate guarding the widening leg keyed
//             on the TARGET KIND (`target is Int64/Uint64`) instead of on the
//             rank ladder — and integerRank already ranks floats above int64
//             (Int64 7, Uint64 8, Float32 9, Number/Float64 10). So the EXIT
//             leg of that same boundary (64-bit → float slot) matched neither
//             isWideningInt64Conv nor isNarrowingIntConv, the checker planted
//             no node, and lowerBigIntJS had nothing to consume.
// Fix:        isWideningInt64Conv (types.ms) guards on "one side is 64-bit"
//             and keeps the existing rank comparison. Both consumers already
//             handled the case: bigConvert's `isFloatKind(dstK)` row emits a
//             bare Number(x), C's generic HiddenStdConv emits the cast it was
//             doing implicitly, and rangeCheckInject returns no check for a
//             float target. Nothing below the checker changed — docs/JS-NUMERIC
//             §P4 puts the conv-node funnel checker-side, per the reference's
//             genConv.

import { compileToC, compileToJS } from "../helpers";

const b121 = `
function takesNum(x: number): number { return x * 2.0; }
function viaReturn(v: int64): number { return v; }
function b121(): void {
	const raw: int64 = 3;
	const viaDecl: number = raw;
	console.log(viaDecl + viaReturn(raw) + takesNum(raw));
}
b121();
`;

// The non-64 leg must stay unmarked: int32 → number changes no representation
// on either backend, and marking it would move emitted JS that P4 pinned.
const b121narrow = `
function b121n(): void {
	const small: int32 = 3;
	const wide: number = small;
	console.log(wide);
}
b121n();
`;

test "bug121: int64 into a number slot materializes Number() on js" {
	const out = compileToJS(b121);
	assert out.ok;
	if (out.ok) {
		assert out.value.contains("Number(raw)");
		assert out.value.contains("Number(v)");
	}
}

test "bug121: int32 into a number slot stays untouched on js" {
	const out = compileToJS(b121narrow);
	assert out.ok;
	if (out.ok) {
		assert !out.value.contains("Number(small)");
	}
}

test "bug121: the c lane still compiles the same conversions" {
	const out = compileToC(b121);
	assert out.ok;
}
