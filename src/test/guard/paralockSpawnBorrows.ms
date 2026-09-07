// nim-guard: the spawn write ban must not eat the shapes the model allows
//
// INVARIANT (PARALOCK Amendment L, §5.3 + §9.2 E20/E147): a plain captured ref
//   is a BORROW and reading through it is legal — Principle 5 exists to keep
//   that zero-copy. And a write inside a lockedUpdate / lockedRead callback is
//   the sanctioned form of shared mutable state (I22), not an evasion of E24.
//
// WHAT IT CATCHES: an over-firing write ban. paralockSpawnWrites.ms only proves
//   the rule still rejects; nothing there goes red when the rule starts
//   rejecting correct code as well. That is this file's job, and the cost is
//   measured, not hypothetical: std/http/server.cms passes `server` into
//   eventLoopUring / listenAsyncLoopA / driveWithSweep from inside a spawn
//   thunk and every one of the ~50 uses down that call chain is a read.
//
// RED MEANS: either a legal borrow now fails to compile (the write ban lost its
//   read/write distinction, or it started rejecting a ref merely passed to a
//   callee), or the Locked exemption stopped applying and the model has no
//   spelling left for shared mutable state inside a thunk.

interface Counter { n: int32; }

interface Table { items: int32[]; }

function readOnly(c: Counter): int32 {
	return c.n;
}

// 1 — read a captured ref's field directly.
function borrowRead(): int32 {
	const c: Counter = { n: 5 };
	const f = spawn(() => { return c.n; });
	return await f;
}

// 2 — pass the captured ref to a callee that only reads it (the http shape).
function borrowThroughCallee(): int32 {
	const c: Counter = { n: 6 };
	const f = spawn(() => { return readOnly(c); });
	return await f;
}

// 3 — write under the lock: E147's exemption.
function writeUnderLock(): int32 {
	const t: Table = { items: [] };
	const gate = new Locked<int32>(0);
	const f = spawn(() => {
		lockedUpdate(gate, (v: int32): int32 => { t.items.push(9); return v + 1; });
		return 0;
	});
	const done = await f;
	return t.items.length + done;
}

function main(): int32 {
	const a = borrowRead();
	const b = borrowThroughCallee();
	const c = writeUnderLock();
	if (a != 5) { throw "GUARD RED: borrowRead"; }
	if (b != 6) { throw "GUARD RED: borrowThroughCallee"; }
	if (c != 1) { throw "GUARD RED: writeUnderLock"; }
	console.log("GUARD-OK");
	return 0;
}

process.exit(main());
