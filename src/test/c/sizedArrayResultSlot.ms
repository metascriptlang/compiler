// A value whose C form is an array returns through the caller's result slot, so indexing a call
// result reads a live location. Runtime behaviour: corpus `sizedArrayCallResultIndex`.

import { compileToC } from "../helpers";

test "a returned sized array is written into the caller's result slot before it is indexed" {
	const c = compileToC(`
function pick(i: int32): uint64[4] {
	let t: uint64[4] = [10, 20, 30, 40];
	t[0] = t[0] + (i as uint64);
	return t;
}
function main(): void { console.log(pick(1)[1]); }
`);
	assert c.ok;
	assert c.value.contains("msSizedArray_uint64_t_4* __result, int32_t i)");
	assert !c.value.contains("msSizedArrayAccess(pick__");
}

test "a small sized array, an alias of one and a closure result take the result slot too" {
	const c = compileToC(`
type Row = uint8[4];
function small(i: int32): Row { return [i as uint8, 2, 3, 4]; }
function main(): void {
	const f = (i: int32): uint8[4] => small(i + 1);
	console.log(small(1)[1] + f(2)[0]);
}
`);
	assert c.ok;
	assert c.value.contains("msSizedArray_uint8_t_4* __result, int32_t i)");
	assert !c.value.contains("msSizedArrayAccess(small__");
	assert !c.value.contains("msSizedArrayAccess((");
}
