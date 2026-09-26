// bug333 — an array element type first met while lifting another array's hooks got no hooks
//
// Symptom:    `Vec<[Vec<Pt>, int32]>` returned from a function and never spelled
//             as `Vec<Pt>` in the module: PtArrayDestroy/Copy/Sink/WasMoved were
//             never emitted, and a length-checked for-of (flow lane stmt-lowering-15)
//             made the compiler fail to build itself.
//
// Root cause: generateArrayHooks walked lctx.seqElemTypes with for-of while
//             arrayOp -> registerSeqElement pushed to it from the loop body; the
//             entries pushed during the walk were skipped.
//
// Fix:        the walk is an index worklist that runs until the list stops growing,
//             the reference idiom for a seq that grows while it is processed.

import { compileToC } from "../helpers";

test "bug333: a Vec<T> reached only through a tuple element gets its hooks" {
	const src = `
struct B333Pt { s: string; n: int32; }
type Row = [Vec<B333Pt>, int32];
function rows(): Vec<Row> { return []; }
function run(): void {
	const r = rows();
	console.log(r.length);
}
run();
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("void B333PtArrayDestroy(B333PtArray* self);");
		assert c.value.contains("void B333PtArraySink(B333PtArray* dest, B333PtArray* src);");
	}
}

test "bug333: a Vec<T> reached only through a generic struct element gets its hooks" {
	const src = `
struct B333Qt { s: string; n: int32; }
struct Pair<T> { a: T; k: int32; }
function rows(): Vec<Pair<Vec<B333Qt>>> { return []; }
function run(): void {
	const r = rows();
	console.log(r.length);
}
run();
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("void B333QtArrayDestroy(B333QtArray* self);");
		assert c.value.contains("void B333QtArrayCopy(B333QtArray* dest, B333QtArray* src);");
	}
}
