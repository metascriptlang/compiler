// bug334 — a Vec<T> of tuples was destroyed as an array of pointers
//
// Symptom:    `const xs: Vec<[string, int32]>` panicked at scope exit ("pointer index
//             expression with base 0x2 overflowed") in msRefArrayDestroy; a POD tuple
//             element `Vec<[int32, int32]>` and a named alias `Vec<Row>` did the same.
//
// Root cause: classifyArray had no Tuple arm, so a tuple element fell through to the
//             catch-all, which assumes a void* stride and routes to msArrayRefDestroy,
//             while the lifter emits the tuple array's own hooks.
//
// Fix:        a tuple element takes the array's own named hooks when the tuple owns a
//             managed member and the stride-exact generic helpers when it does not, as
//             the reference lifts =destroy per seq type (liftdestructors fillSeqOp).

import { compileToC } from "../helpers";

test "bug334: a Vec of managed tuples is destroyed by its own array hook" {
	const src = `
function run(): void {
	const xs: Vec<[string, int32]> = [];
	xs.push(["a" + "b", 1 as int32]);
	console.log(xs.length);
}
run();
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert !c.value.contains("msArrayRefDestroy(xs_");
		assert c.value.contains("ArrayDestroy(&(xs_");
	}
}

test "bug334: a Vec of POD tuples is destroyed by the generic array helper" {
	const src = `
type B334Row = [int32, int32];
function run(): void {
	const xs: Vec<B334Row> = [];
	xs.push([1 as int32, 2 as int32]);
	console.log(xs.length);
}
run();
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert !c.value.contains("msArrayRefDestroy(xs_");
		assert c.value.contains("msArrayDestroy(xs_");
	}
}
