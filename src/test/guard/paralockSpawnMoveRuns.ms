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
//   error), or a rebound parent binding is confused with the moved one.

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

function main(): int32 {
	const a = movedWrite();
	const b = movedWithTimeout();
	const d = movedThenRebound();
	if (a != 17) { throw "GUARD RED: movedWrite"; }
	if (b != 6) { throw "GUARD RED: movedWithTimeout"; }
	if (d != 12) { throw "GUARD RED: movedThenRebound"; }
	console.log("GUARD-OK");
	return 0;
}

process.exit(main());
