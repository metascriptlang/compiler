// note: Locks TS left-to-right evaluation order for assignment statements
// whose RHS lowers to statements on C. `arr[idx()] = cnd() ? ta() : tb()`
// must evaluate the target reference FIRST (idx), then the RHS (cnd, then the
// taken arm) — ES AssignmentExpression order. Pre-fix, conditionalExprLower
// hoisted the RHS ternary machinery ABOVE the statement, so the condition and
// taken arm ran before the LHS index: C printed CAL/cBM/CAl where JS (native,
// the spec lane) prints LCA/McB/lCA. Covers array-index, member-through-call
// (getBox().v), and compound `+=` targets, including one whose taken arm
// writes the very cell being compounded: TS reads the old value (c0=3), where
// C read the new one (c0=52) until the target read moved ahead of the RHS.

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
const cell: int32[] = [1];
function tw(): int32 { order = order + "W"; cell[0] = 50; return 2; }

function main(): void {
	const arr: int32[] = [0];
	arr[idx()] = cnd() ? ta() : tb();
	getBox().v = cnd2() ? ta() : tb();
	arr[idx2()] += cnd() ? ta() : tb();
	cell[idx()] += cnd() ? tw() : tb();
	console.log(`seam3 order=${order} a0=${arr[0]} bv=${box.v} c0=${cell[0]}`);
}
main();
