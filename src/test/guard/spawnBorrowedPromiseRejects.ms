// A spawn's task only awaits a promise it borrows
//
// INVARIANT (ULTRALOCK V5, A3): a promise is counted and settled on the thread that made it, and
//   a borrowed view takes no count, so a task may await a borrowed promise (a wait and a read,
//   no count) but not call it: '.then', '.catch' and '.finally' on the worker would count the
//   promise beside its owner's deferred release. A settled promise is refused too, since the
//   checker cannot see that it settled. Awaiting one runs: corpus spawnEdgeLessPileUpFailsLoud.
//
// WHAT IT CATCHES: each callback verb on a borrowed promise (pending and settled), a borrowed
//   promise passed on, and a promise held inside a borrowed object.
//
// RED MEANS: one of the shapes compiled.
//
// GUARD-JS
// GUARD-CHECK-FAIL spawn's task uses 'p', a promise it only borrows, other than by awaiting it
// GUARD-CHECK-FAIL spawn's task uses 's', a promise it only borrows
// GUARD-CHECK-FAIL spawn's task uses 'h.p', a promise it only borrows

class Holder { p: Promise<int32> | null = null; }

function later(ms: int32): Promise<int32> {
	return new Promise<int32>((resolve) => { setTimeout(() => resolve(7), ms); });
}

async function now(k: int32): Promise<int32> { return k; }

async function main(): Promise<void> {
	const p = later(1);
	const a = spawn(() => { p.then((x: int32) => x + 1); return 1; }); // GUARD-REFUSED
	const b = spawn(() => { p.catch((e: Error) => 0); return 1; }); // GUARD-REFUSED
	const c = spawn(() => { p.finally(() => {}); return 1; }); // GUARD-REFUSED
	const s = now(1);
	await s;
	const d = spawn(() => { s.then((x: int32) => x + 1); return 1; }); // GUARD-REFUSED
	const h = new Holder();
	h.p = later(1);
	const e = spawn(() => { const q = h.p; if (q != null) q.then((x: int32) => x); return 1; }); // GUARD-REFUSED
	const f = spawn(() => { Promise.all([p]); return 1; }); // GUARD-REFUSED
	console.log(`${await a + await b + await c + await d + await e + await f + await p}`);
}

await main();
