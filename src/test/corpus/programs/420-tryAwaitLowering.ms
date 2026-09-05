// @stdout: try-await-lowering acc=8
// @xfail(esm): tree emit: native Promise.resolve shadowed by the emitted class Promise in _std/core/promise
// note: Regression guard for the finallyPath port (generatorLower splitTryFinally).
//   PROVEN RED: before the port, an `await` inside a try body was never split
//   across the state machine — the YieldExpr asyncDesugar produces survived every
//   later pass, C codegen emitted `/* unsupported expression: kind=YieldExpr */`
//   and the C compile died with "expected expression" on all four native lanes.
//   The split now gives the try three exits, all going through the finally: normal
//   completion routes to a landing-free finally state, a raise (including a failed
//   await's re-raising resume read at the try's exit state) lands on a
//   finally-then-rethrow state, and a break/continue/return crossing the try
//   inlines the finally first. Minimal repro — no actor, no move, no DRC, one plain
//   async function. The JS backend has a native state machine and always ran this,
//   so the js lane pins the expected value (acc=8: 1 from the awaited spawn, 7 from
//   the finally) and the native lanes are compared against a value, not a guess.
async function f(): Promise<int32> {
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
function main(): void {
	const acc = await f();
	console.log(`try-await-lowering acc=${acc}`);
}
main();
