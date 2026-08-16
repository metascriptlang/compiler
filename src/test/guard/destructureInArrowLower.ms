// nim-guard: destructuring decls are lowered in EVERY expression-position fn body
//
// INVARIANT (Nim): the transformation walk reaches every nested proc body
//   uniformly. Nim's `transf.transform` funnels through `transformSons` (recurse
//   ALL sons) and descends nested procs via `transformBody` (transf.nim:127); Nim
//   never leaves an `nkVarTuple` unlowered — codegen itself lowers it
//   (`genVarTuple` -> `lowerTupleUnpacking`, ccgstmts.nim:103). MS lowers
//   destructuring in an EARLY pass (`destructuringLower`, pass 8) via the shared
//   `walkExpandBlocksHooked`, and codegen has NO fallback (`DestructuringDecl`
//   hits `/* unsupported stmt */`), so that early walk MUST be complete.
// NIM-REF: §1 "Statement-expansion walk: uniform child traversal" — sibling of
//   "Lambda lifting: uniform child traversal" (row 76). Verdict
//   DIVERGE-INCOMPLETE -> SAME: `walkExpandBlocksHooked`'s `_ => {}` default never
//   descended into fn bodies sitting in expression position (VariableDecl.init,
//   ExprStmt, ReturnStmt, call args), so a `const [a,b] = …` inside such an arrow
//   survived to codegen. Restored to a generic `mapChildren` recurse, MS's analog
//   of Nim's `for i in 0..<n.len`.
//
// WHAT IT CATCHES: a destructuring `const [a,b] = f()` inside an arrow that is
//   NOT a plain statement-position declaration — bound in a var init, capturing
//   (lifted), or passed as a call argument. Pre-fix these fell to the walker's
//   no-op default -> `destructuringLower` never expanded them -> codegen emitted
//   `/* unsupported stmt: DestructuringDecl */` and the destructured names were
//   used but never produced -> C `use of undeclared identifier`.
//
// RED MEANS: an expression-position arrow body stopped being walked by the
//   statement-expansion passes -> a destructure it holds is dropped. This probe
//   FAILS TO BUILD ("unsupported stmt: DestructuringDecl" / undeclared identifier)
//   or throws on a wrong value. Run /trace-nim on walkExpandBlocksHooked
//   (transform/walker.ms).
//   Proven RED on the pre-fix binary; GREEN post-fix.
//
// No RC balance directive — the signal is build-failure / wrong-value-throw.

function pair(): [number, number] { return [3, 4]; }

function withCb(cb: () => number): number { return cb(); }

function main(): void {
	// (1) non-lifted arrow bound in a var initializer
	const g = (): number => { const [a, b] = pair(); return a + b; };
	if (g() !== 7) { throw "GUARD RED: destructure in non-lifted var-init arrow dropped"; }

	// (2) capturing (lifted) arrow — writes a destructured value to an outer local
	let sum = 0;
	const compute = (): void => { const [a, b] = pair(); sum = a + b; };
	compute();
	if (sum !== 7) { throw "GUARD RED: destructure in lifted (capturing) arrow dropped"; }

	// (3) arrow passed as a CALL ARGUMENT (the mapArray(list, (v,i)=>{…}) shape)
	const viaArg = withCb(() => { const [a, b] = pair(); return a * b; });
	if (viaArg !== 12) { throw "GUARD RED: destructure in call-arg arrow dropped"; }

	console.log("destructureInArrowLower ok");
}

main();
