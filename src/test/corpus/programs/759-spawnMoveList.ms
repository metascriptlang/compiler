// @xfail(raiser): raiser runtime error: Unknown host function: msSpawn
// @skip-js: spawn has no js lowering (421/422 family); { move } rides the same
//   C-only lowering, so there is no js spelling of this shape yet.
// @stdout: moved v=9 cfg=8
// @stdout: timeout v=6
// @stdout: rebound v=12

// PARALOCK Amendment M: spawn(fn, { move: [x] }) hands x to the thunk on the
// parent thread at the spawn site. The thunk owns and writes it; unmoved
// captures stay read-only borrows; a rebound parent binding is a fresh value.

interface Counter { n: int32; }
interface Config { size: int32; }

function movedWrite(): int32 {
	const c: Counter = { n: 0 };
	const cfg: Config = { size: 8 };
	const f = spawn(() => { c.n = 1; return c.n + cfg.size; }, { move: [c] });
	const v = await f;
	console.log("moved v=" + v + " cfg=" + cfg.size);
	return v;
}

function movedWithTimeout(): int32 {
	const c: Counter = { n: 5 };
	const v = await spawn(() => { c.n = c.n + 1; return c.n; }, { move: [c], timeout: 4000 });
	console.log("timeout v=" + v);
	return v;
}

function movedThenRebound(): int32 {
	let c: Counter = { n: 1 };
	const f = spawn(() => { c.n = 10; return c.n; }, { move: [c] });
	c = { n: 2 };
	const v = await f + c.n;
	console.log("rebound v=" + v);
	return v;
}

function main(): int32 {
	movedWrite();
	movedWithTimeout();
	movedThenRebound();
	return 0;
}

process.exit(main());
