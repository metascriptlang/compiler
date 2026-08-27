// nim-guard: for-of loop variables over value elements are read-only views
//
// INVARIANT (Nim parampatterns.nim isAssignable: skForVar falls in the
//   arAddressableConst bucket with skParam/skLet — the for-var location is
//   never an assignable lvalue): interior mutation (elem/field write)
//   through a for-of binding whose element type is a value aggregate
//   (Vec<T>, struct, tuple, nested Vec) must be a checker error. Rebinding
//   the binding itself stays legal (fresh per-iteration local, both
//   backends agree). Ref elements (T[]) stay writable — the copy is a
//   pointer, writes alias identically on C and JS.
//
// WHAT IT CATCHES: dropping the checkForOfStmt value-elem rule lets
//   `p.x = 9` inside `for (const p of vec)` silently write a dead copy on C
//   while JS writes the collection (probe1 2026-08-28: C fieldVec=1,3 vs
//   JS fieldVec=9,9) — a C↔JS parity break in observable semantics.
//
// RED MEANS: loop vars over value elements became mutable again — the
//   silent C-swallow/JS-alias fork is back. Run /trace-nim against
//   parampatterns.isAssignable / semstmts semForVars.
//
// GUARD-CHECK-FAIL cannot mutate value-type loop variable 'p'
// GUARD-CHECK-FAIL cannot mutate value-type loop variable 'q'
// GUARD-CHECK-FAIL cannot mutate value-type loop variable 'n'
// GUARD-CHECK-FAIL cannot mutate value-type loop variable 't'

struct FPt { x: int32; y: int32; }

function mVecStruct(): void {
	const v: Vec<FPt> = [{ x: 1, y: 2 }];
	for (const p of v) { p.x = 9; }
}

function mRefArrStruct(): void {
	const v: FPt[] = [{ x: 1, y: 2 }];
	for (const q of v) { q.x = 9; }
}

function mNestedVec(): void {
	const v: Vec<Vec<int32>> = [[1]];
	for (const n of v) { n[0] = 9; }
}

function mTupleElem(): void {
	const v: Vec<[int32, int32]> = [[1, 2]];
	for (const t of v) { t[0] = 9; }
}

mVecStruct();
mRefArrStruct();
mNestedVec();
mTupleElem();
