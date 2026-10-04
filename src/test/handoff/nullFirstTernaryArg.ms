import { compileToCWithStd } from "../helpers";

// bug662 — `flag ? null : b` as a call argument arrived as the address of a void* temp
//
// Symptom:    `show(flag ? null : b)` with `show(b: Box | null)` printed "box" for a null
//             argument on C (JS correct); the emitted C declared the ternary temp `void*`
//             from the null arm and passed `&(temp)` where the callee takes the collapsed
//             pointer by value.
// Root cause: fitSlot had no rule for a null literal flowing into a flat `Ref T | null`
//             union (only Maybe carriers retype), so fitConditionalArms returned the null
//             arm's Null type for the whole ternary; fixed in src/checker/fit.ms by
//             retyping the literal to the union (sigmatch.nim tyNil/allowsNil).

function cFor(expr: string): string {
	const c = compileToCWithStd(`class Box { v: int32 = 0; }
		function show(b: Box | null): string { return b == null ? "null" : "box"; }
		function viaArg(flag: boolean, b: Box | null): string {
			return show(${expr});
		}
		viaArg(true, new Box());`);
	if (!c.ok) return "COMPILE-ERROR: " + c.error;
	return c.value;
}

test "nullFirstTernaryArg: a null-first ternary argument keeps the union type, not void*" {
	const c = cFor("flag ? null : b");
	assert !c.includes("COMPILE-ERROR");
	assert !c.includes("void* dollartern");
	assert !c.includes("void* _clit");
}
