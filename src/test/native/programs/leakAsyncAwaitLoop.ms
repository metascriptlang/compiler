// OPEN BUG (PARALOCK async cooperative path) — async function with `await`
// INSIDE a loop leaks a hidden per-await-RESUME allocation, ~32 B/iter, linear.
//
// This is the root cause of the Photon WS broadcast leak (~1 KB/msg): the recv
// loop is an async actor method that `await`s recv inside `while`. NOT Photon
// code, NOT the compiler leak-family (callHoist, closed), NOT std JSON (clean).
//
// Proven via emit-C (--passC=-O0): the per-iteration user locals are BALANCED —
// the string `s` is an async env field assigned via msStringSink (destroys-old),
// and the await future env field is destroyed each iteration. So the ~32 B/iter
// is in the async state-machine / scheduler resume machinery (stepper closure
// re-invoke + msFutureAddCallback / msPostCompletion path), not a user value.
//
// Sync loops over the same work are FLAT (see cleanLoop.ms) — it is specifically
// `await` inside the loop. maxRssMb is the honest FIXED steady-state; at 2M
// iterations the current leak (~64 MB) trips it. Drop xfail when the resume
// allocation is balanced — RSS will fall back to baseline and XPASS will fire.
//
// PARALOCK note: the fix must not change await dispatch (§6.2 lowering matrix)
// or the cooperative yield/resume contract (§7.2) — it is a missing free on the
// resume path, not a lowering change.

async function tick(x: int32): Promise<int32> { return x; }

async function run(n: int32): Promise<int32> {
	let acc = 0;
	for (let i = 0; i < n; i = i + 1) {
		const s = `payload-${i}-xxxxxxxxxxxxxxxx`;
		const v = await tick(i);
		acc = (acc + s.length + v) % 1000;
	}
	return acc as int32;
}

function main(): void {
	const r = await run(2000000 as int32);
	console.log(`leak-async-await-loop r=${r}`);
}
main();
