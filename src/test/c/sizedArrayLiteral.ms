// The reference builds a fixed-size array constructor by assigning through a
// subscript (ccgexprs.nim:3204 genArrayConstr); allocating storage and tracking
// a length is the SEPARATE sequence path (:1875 genSeqConstr). A sized array's
// C struct carries its storage inline as data[N] and has no len/p pair, so
// routing it through the sequence path does not typecheck at all — the symptom
// is a clang error on a missing member, not a wrong value.
//
// Both halves are asserted: a sized array must not reach the push helper, and a
// sequence must still use it.

import { compileToC } from "../helpers";

test "sized array literal assigns each element in place" {
	const c = compileToC(`
function main(): void {
	const fixed: uint8[4] = [10, 20, 30, 40];
	console.log(fixed[0]);
}
`);
	assert c.ok;
	assert c.value.contains(".data[0] = 10");
	assert c.value.contains(".data[3] = 40");
	assert !c.value.contains("msGenericArrayPush");
}

test "sequence literal keeps the push path" {
	const c = compileToC(`
function main(): void {
	const seq: uint8[] = [10, 20, 30, 40];
	console.log(seq[0]);
}
`);
	assert c.ok;
	assert c.value.contains("msGenericArrayPush");
}
