// Under a for with literal bounds, an index built from the counter that stays inside a fixed array is
// read without a bounds check on C. The JS side: js/accessCheck.ms. Runtime behaviour: corpus
// `counterIndexIntoFixedArraySkipsItsCheck`, `counterIndexPastFixedArrayStops`.

import { compileToC } from "../helpers";
import { hostTargetInfo } from "../../checker/types";

test "a counter index that stays inside a sized array is read unchecked" {
	const c = compileToC(`
function f(w: uint32[64]): uint32 {
	let t: uint32 = 0;
	for (let i = 16; i < 64; i++) { t = t ^ w[i - 15] ^ w[i]; }
	return t;
}
function main(): void { let w: uint32[64] = []; console.log(f(w)); }
`, hostTargetInfo(), false, true);
	assert c.ok;
	assert c.value.contains("msSizedArrayAccessUnchecked(w_p0, (i_1_ - 15), 64)"), c.value;
	assert !c.value.contains("msSizedArrayAccess(w_p0"), c.value;
}

test "a counter index that can pass the end of the sized array is bound-checked" {
	const c = compileToC(`
function f(w: uint32[64]): uint32 {
	let t: uint32 = 0;
	for (let i = 0; i < 65; i++) { t = t ^ w[i]; }
	return t;
}
function main(): void { let w: uint32[64] = []; console.log(f(w)); }
`, hostTargetInfo(), false, true);
	assert c.ok;
	assert c.value.contains("msSizedArrayAccess(w_p0, i_1_, 64)"), c.value;
}
