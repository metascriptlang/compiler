// bug039 — expression-bodied curried arrow with outer captures failed compile
//
// Symptom:    A function returning a curried arrow chain where the OUTER
//             arrow captures from the enclosing function:
//                 function makeCurried(x: int32): (y: int32) => (z: int32) => int32 {
//                     return (y) => (z) => (x + y + z) as int32;
//                 }
//             Failed at the C compile step with:
//                 error: no member named 'y' in struct dollarEnv_makeCurried_arrow2_3_
//                 error: returning 'int' from a function with incompatible result type 'msClosure'
//                 error: use of undeclared identifier '_envP'
//             Identical pattern with a block body (`return (y) => { return (z) => ... }`)
//             always worked — confirming the failure was tied to the
//             expression-body syntax.
//
// Root cause: src/transform/lowering/lambdaLifting.ms had a special-case
//             "shortcut" branch in `liftCapturingClosureBody` that fired
//             when the outer arrow's body was itself an Arrow/FuncExpr.
//             Two coupled defects:
//               (1) The shortcut called `walkOrLift(body)` and bypassed
//                   `setupSharedEnv` for the OUTER arrow — so when its
//                   captures (e.g. `x`, plus `y` referenced by the inner
//                   arrow) needed an env struct, none was allocated.
//               (2) The same call frame's `lifter()` (liftArrow) read body
//                   from `node.data.arrowBody` rather than the local `body`
//                   param — so even if the body had been transformed via the
//                   shortcut, the lifter constructed the lifted FunctionDecl
//                   from the stale, untransformed inner arrow, emitting
//                   `return 0 /* unlowered ArrowFunction */`.
//
// Fix:        src/transform/lowering/lambdaLifting.ms
//             - Added `normalizeArrowBodies` pre-pass invoked at the top of
//               `lowerLambda`. Walks the program once and wraps every
//               `ArrowFn(body=Arrow|FuncExpr)` into
//               `ArrowFn(body=BlockStmt([Return(arrow)]))` so subsequent
//               detection + lifting see only block-bodied arrows.
//             - Deleted the now-dead shortcut branch in
//               `liftCapturingClosureBody` and simplified its return type
//               from `{ result, replacedBody }` to `Node`.
//             - Removed the `allowBodyClosureShortcut` parameter — no
//               caller needs it anymore.
//             The bug class disappears at the source: the precondition
//             (expression-bodied arrow returning Arrow/FuncExpr) can no
//             longer reach the lifting code path.
//
// Reference:  Nim has no expression-bodied lambdas — all lambda bodies are
//             statement lists. The normalize pre-pass makes MS's lambda
//             lifter operate on the same canonical form Nim achieves
//             natively (lambdalifting.nim:743 liftCapturedVars sees only
//             statement-list bodies after the parser).

function bug039_makeCurried(x: int32): (y: int32) => (z: int32) => int32 {
	return (y) => (z) => (x + y + z) as int32;
}

function bug039_makeTriple(x: int32): (y: int32) => (z: int32) => (w: int32) => int32 {
	return (y) => (z) => (w) => (x + y + z + w) as int32;
}

test "bug039: curried arrow with outer capture compiles and runs" {
	const f = bug039_makeCurried(100 as int32);
	const g = f(20 as int32);
	assert g(3 as int32) === 123;
}

test "bug039: triple-nested curried arrow with outer capture" {
	const f = bug039_makeTriple(1000 as int32);
	const g = f(100 as int32);
	const h = g(10 as int32);
	assert h(1 as int32) === 1111;
}

test "bug039: distinct env per top-level call (no shared state)" {
	// Each `bug039_makeCurried` invocation must allocate its own outer env
	// so two curry chains don't alias their captures.
	const f1 = bug039_makeCurried(100 as int32);
	const f2 = bug039_makeCurried(200 as int32);
	const g1 = f1(20 as int32);
	const g2 = f2(20 as int32);
	assert g1(3 as int32) === 123;
	assert g2(3 as int32) === 223;
}
