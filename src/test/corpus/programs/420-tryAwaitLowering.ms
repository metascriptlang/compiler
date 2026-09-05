// @stdout: try-await-lowering acc=8
// @xfail(c): OPEN BUG (async lowering) — an `await` inside a try body is never
//   split across the state machine: the YieldExpr asyncDesugar produces survives
//   every later pass and reaches C codegen, which emits
//   `/* unsupported expression: kind=YieldExpr */` and the C compile dies with
//   "expected expression". Proven on both the current compiler and the one that
//   predates the 418 fix, so the gap predates all of that work. This program is
//   the PREREQUISITE for 419: the async half of the SEND-class release is gated
//   off precisely because the release wrapper puts an await inside a try. XPASS
//   here is the signal to remove that gate (actorLower lowerActorPre).
// @xfail(orc): same as c
// @xfail(danger): same as c
// @xfail(san): same as c — the build fails before anything can be instrumented
// @xfail(esm): tree emit: native Promise.resolve shadowed by the emitted class Promise in _std/core/promise
// note: Minimal repro — no actor, no move, no DRC, one plain async function.
//   The JS backend has no state machine to split, so the js lane runs it and
//   pins the expected value (acc=8: 1 from the awaited spawn, 7 from finally),
//   which is what makes the native xfail a lowering claim and not a guess.
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
