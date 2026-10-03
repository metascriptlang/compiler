// bug638 — `x ?? y` into a wider union did not build on C
//
// Symptom:    `const b: number | string = pick() ?? "x"` with `pick(): number | string | null`,
//             and `const r: int32 | string = n ?? "y"` with `n: int32 | null`, failed in clang
//             ("used type 'msUnion_…' where arithmetic or pointer type is required"); JS printed
//             the right values.
// Root cause: the checker fitted the fallback to the joined type only when the join was
//             nullable, and the lowering read the present value at its payload type, so C
//             cast a string or an int32 straight to the union struct.
// Fix:        the fallback is fitted to a union join as a ternary branch is, and the lowering
//             widens the present value into the union as a try expression's ok value is.

import { compileToC, compileToJS } from "../helpers";

const pickUnion = "function pick(k: int32): number | string | null { if (k == 0) return null; return \"row\"; }\n";
const pickInt = "function pickInt(k: int32): int32 | null { if (k == 0) return null; return 5; }\n";

test "bug638: the fallback is built into the union's string member" {
	const r = compileToC(pickUnion + "function f(): string { const b: number | string = pick(0) ?? \"fallback\"; return b as string; }\n");
	assert r.ok, r.ok ? "" : r.error;
	assert r.value.contains(", 8)}"), r.value;
	assert !r.value.contains(", 8)))"), r.value;
}

test "bug638: the present value is widened into the union's int member" {
	const r = compileToC(pickInt + "function f(): int32 { const r: int32 | string = pickInt(1) ?? \"y\"; return r as int32; }\n");
	assert r.ok, r.ok ? "" : r.error;
	assert r.value.contains("._tag=0, .v0="), r.value;
	assert r.value.contains("._tag=1, .v1="), r.value;
}

test "bug638: JS keeps both operands as they are" {
	const r = compileToJS(pickInt + "function f(): int32 { const r: int32 | string = pickInt(1) ?? \"y\"; return r as int32; }\n");
	assert r.ok, r.ok ? "" : r.error;
	assert r.value.contains("\"y\""), r.value;
}
