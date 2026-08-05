// note: Locks TS left-to-right evaluation order for assignment statements
// whose RHS lowers to statements on C. `arr[idx()] = cnd() ? ta() : tb()`
// must evaluate the target reference FIRST (idx), then the RHS (cnd, then the
// taken arm) — ES AssignmentExpression order. Pre-fix, conditionalExprLower
// hoisted the RHS ternary machinery ABOVE the statement, so the condition and
// taken arm ran before the LHS index: C printed CAL/cBM/CAl where JS (native,
// the spec lane) prints LCA/McB/lCA. Covers array-index, member-through-call
// (getBox().v), and compound `+=` targets. Known residual, deliberately not
// covered: a compound assign whose RHS arm MUTATES the very cell being
// compounded reads the new value on C (TS reads the old one) — needs a
// read-temp rewrite that depends on safe node cloning.

interface Box { v: int32; }

let order: string = "";
const box: Box = { v: 0 };

function idx(): int32 { order = order + "L"; return 0; }
function idx2(): int32 { order = order + "l"; return 0; }
function cnd(): boolean { order = order + "C"; return true; }
function cnd2(): boolean { order = order + "c"; return false; }
function ta(): int32 { order = order + "A"; return 7; }
function tb(): int32 { order = order + "B"; return 8; }
function getBox(): Box { order = order + "M"; return box; }

function main(): void {
	const arr: int32[] = [0];
	arr[idx()] = cnd() ? ta() : tb();
	getBox().v = cnd2() ? ta() : tb();
	arr[idx2()] += cnd() ? ta() : tb();
	console.log(`seam3 order=${order} a0=${arr[0]} bv=${box.v}`);
}
main();
