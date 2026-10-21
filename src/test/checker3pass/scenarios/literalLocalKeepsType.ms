import { checkOnly } from "../helpers";

const SRC_KEPT = `
type Narrow = 1 | 2 | 3;
type Wide = 1 | 2 | 3 | 4;
function readNarrow(): Narrow { return 3; }
function cast(): Narrow { const n = 2 as Narrow; return n; }
function letCast(w: Wide): Narrow { let n = w as Narrow; return n; }
function param(w: Narrow): Narrow { const n = w; return n; }
function call(): Narrow { let n = readNarrow(); return n; }
function annotated(): Narrow { const a: Narrow = 1; const n = a; return n; }
function narrowed(v: 1 | 2 | string): 1 | 2 {
	if (typeof v === "number") { const n = v; return n; }
	return 1;
}
`;

const SRC_FRESH = `
function grow(c: boolean): int32 {
	let x = 1;
	x = 70000;
	let y = c ? 1 : 2;
	y = 9;
	return x + y;
}
`;

const SRC_LET_KEEPS = `
type Narrow = 1 | 2 | 3;
function reassign(w: Narrow): Narrow { let n = w; n = 4; return n; }
`;

test "an unannotated local keeps a number-literal union that was not written in place" {
	const errors = checkOnly(SRC_KEPT).errors;
	assert errors.length == 0, "a local from an as, a parameter, a call, an annotated local or a narrowed read must keep its literal union: " + errors.join("\n");
}

test "a literal written in place still widens at an unannotated let" {
	const errors = checkOnly(SRC_FRESH).errors;
	assert errors.length == 0, "a fresh literal must widen: " + errors.join("\n");
}

test "a let typed by a literal union refuses a value outside it" {
	const text = checkOnly(SRC_LET_KEEPS).errors.join("\n");
	assert text.contains("Type '4' is not assignable to type '1 | 2 | 3'"), "a let from a Narrow parameter must refuse 4: " + text;
}
