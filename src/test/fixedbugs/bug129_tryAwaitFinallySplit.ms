// bug129 — an `await` inside a try body was never split across the state machine
//
// Symptom:    `async function f() { try { const n = await w; } finally { … } }`
//             failed the C build with `expected expression` on
//             `/* unsupported expression: kind=YieldExpr */` — the YieldExpr
//             asyncDesugar produces survived every later pass and reached
//             codegen. Any actor/async body wrapped in try/finally (the
//             boundary-release wrapper does exactly that) was unbuildable.
// Root cause: src/transform/lowering/generatorLower.ms — splitStmts pushed a
//             try WITH a finally through unsplit ("V1-skip until the
//             finallyPath port"), so the yield inside it was never turned
//             into a state transition.
// Fix:        splitTryFinally: the try body splits into states, the finally
//             body is inlined at every exit — normal completion, exception
//             landing (then re-raise), and any break/continue/return crossing
//             the try (tracked by StateCollector.finallyStack).
//
// Corpus sibling: src/test/corpus/programs/420-tryAwaitLowering.ms pins the
// same shape across every lane (the js lane fixes the expected value).

async function tryFinallyAwait(): Promise<int32> {
	let acc = 0;
	try {
		const w = spawn(() => 1);
		const n = await w;
		acc = acc + n;
	} finally {
		acc = acc + 7;
	}
	return acc;
}

async function tryCatchFinallyAwait(): Promise<int32> {
	let acc = 0;
	try {
		const w = spawn(() => 2);
		const n = await w;
		acc = acc + n;
	} catch (e) {
		acc = acc + 100;
	} finally {
		acc = acc + 30;
	}
	return acc;
}

async function finallyRunsOnThrow(): Promise<int32> {
	let acc = 0;
	try {
		const w = spawn(() => 4);
		const n = await w;
		acc = acc + n;
		throw "boom";
	} catch (e) {
		acc = acc + 200;
	} finally {
		acc = acc + 1000;
	}
	return acc;
}

async function loopBreakCrossesFinally(): Promise<int32> {
	let acc = 0;
	while (true) {
		try {
			const w = spawn(() => 3);
			const n = await w;
			acc = acc + n;
			break;
		} finally {
			acc = acc + 50;
		}
	}
	return acc;
}

test "bug129: finally runs after an awaited try body" {
	const acc = await tryFinallyAwait();
	assert acc === 8;
}

test "bug129: try/catch/finally with an await takes the normal path" {
	const acc = await tryCatchFinallyAwait();
	assert acc === 32;
}

test "bug129: finally runs when the try body throws after an await" {
	const acc = await finallyRunsOnThrow();
	assert acc === 1204;
}

test "bug129: a break out of the loop still runs the finally" {
	const acc = await loopBreakCrossesFinally();
	assert acc === 53;
}
