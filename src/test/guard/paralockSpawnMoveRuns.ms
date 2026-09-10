// nim-guard: spawn { move } — the moved value is owned by the thunk and
//   writable there; unmoved captures stay borrowed.
//
// INVARIANT (PARALOCK Amendment M): the thunk writes through the moved
//   binding, reads the borrowed one, and the result crosses back through the
//   handle. The move happens on the parent thread at the spawn site, and the
//   thunk's own env owns the value — the parent's slot going dead cannot null
//   it out from under the child.
//
// WHAT IT CATCHES: the IIFE lowering losing the box on the thunk's return, or
//   the thunk reading the parent's (now dead) env slot instead of its own.
//   Proven red on the pre-M binary (2026-09-10): it does not understand the
//   move list, so the write through `c` is rejected as a captured-borrow write.
//
// RED MEANS: a moved capture reads null, the return is not boxed (C compile
//   error), a rebound parent binding is confused with the moved one, or the
//   sole-owner rule (E148) rejects a binding that IS fresh: a call result, a
//   `new`, an array built by push, a graph moved as a whole, or a binding local
//   to a lambda.

interface Counter { n: int32; }
interface Config { size: int32; }

function movedWrite(): int32 {
	const c: Counter = { n: 0 };
	const cfg: Config = { size: 8 };
	const f = spawn(() => { c.n = 1; return c.n + cfg.size; }, { move: [c] });
	return await f + cfg.size;
}

function movedWithTimeout(): int32 {
	const c: Counter = { n: 5 };
	return await spawn(() => { c.n = c.n + 1; return c.n; }, { move: [c], timeout: 4000 });
}

function movedThenRebound(): int32 {
	let c: Counter = { n: 1 };
	const f = spawn(() => { c.n = 10; return c.n; }, { move: [c] });
	c = { n: 2 };
	return await f + c.n;
}

function makeCounter(n: int32): Counter {
	return { n: n };
}

function movedFromCall(): int32 {
	const c = makeCounter(3);
	const f = spawn(() => { c.n = c.n + 1; return c.n; }, { move: [c] });
	return await f;
}

function movedBuiltArray(): int32 {
	const buf: int32[] = [];
	for (let i = 0; i < 4; i += 1) buf.push(i);
	const f = spawn(() => { buf.push(4); let s = 0; for (const x of buf) s += x; return s; }, { move: [buf] });
	return await f;
}

interface Box { c: Counter; }

function movedGraphTogether(): int32 {
	const a: Box = { c: { n: 1 } };
	const b: Counter = { n: 2 };
	a.c = b;
	const f = spawn(() => { b.n = 5; return a.c.n; }, { move: [a, b] });
	return await f;
}

function movedInsideLambda(): int32 {
	const run = (): int32 => {
		const c: Counter = { n: 0 };
		const f = spawn(() => { c.n = 3; return c.n; }, { move: [c] });
		return await f;
	};
	return run();
}

function main(): int32 {
	const a = movedWrite();
	const b = movedWithTimeout();
	const d = movedThenRebound();
	const e = movedFromCall();
	const g = movedBuiltArray();
	const h = movedGraphTogether();
	const k = movedInsideLambda();
	if (a != 17) { throw "GUARD RED: movedWrite"; }
	if (b != 6) { throw "GUARD RED: movedWithTimeout"; }
	if (d != 12) { throw "GUARD RED: movedThenRebound"; }
	if (e != 4) { throw "GUARD RED: movedFromCall"; }
	if (g != 10) { throw "GUARD RED: movedBuiltArray"; }
	if (h != 5) { throw "GUARD RED: movedGraphTogether"; }
	if (k != 3) { throw "GUARD RED: movedInsideLambda"; }
	console.log("GUARD-OK");
	return 0;
}

process.exit(main());
