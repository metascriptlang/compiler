// nim-guard: the spawn write ban must not eat the shapes the model allows
//
// INVARIANT (PARALOCK Amendment L §5.3 + §9.2 E20, Amendment N): a plain
//   captured ref is a BORROW and reading through it is legal — Principle 5
//   exists to keep that zero-copy. And a write to the payload of a Locked<T>
//   inside its lockedUpdate callback is the sanctioned form of shared mutable
//   state (I22), not an evasion of E24.
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
//   callee), or the Locked payload stopped being writable and the model has no
//   spelling left for shared mutable state inside a thunk.

interface Counter { n: int32; }

function readOnly(c: Readonly<Counter>): int32 {
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

// 3 — write under the lock: the payload is the one writable location.
struct Hits { n: int32; }
function writeUnderLock(): int32 {
	const cell = new Locked<Hits>({ n: 0 });
	const f = spawn(() => {
		lockedUpdate(cell, (h: Hits): Hits => { return { n: h.n + 1 }; });
		return 0;
	});
	const done = await f;
	return lockedRead(cell, (h: Hits): int32 => h.n) + done;
}

// 4 — a POD struct copy is the thunk's own value: writing it touches nothing shared.
struct Pt { x: int32; y: int32; }
interface Holder { pos: Pt; }
function podCopyWrite(): int32 {
	const h: Holder = { pos: { x: 1, y: 2 } };
	const f = spawn(() => { let p = h.pos; p.x = 5; return p.x; });
	return await f;
}

// 5 — an extension declared on the read-only view is callable through it.
class Tally { n: int32 = 3; }
function peek(this t: Readonly<Tally>): int32 { return t.n; }
function readonlyExtCall(): int32 {
	const t = new Tally();
	const direct = t.peek();
	const f = spawn(() => { return t.peek(); });
	return await f + direct;
}

function main(): int32 {
	const a = borrowRead();
	const b = borrowThroughCallee();
	const c = writeUnderLock();
	const d = podCopyWrite();
	const e = readonlyExtCall();
	if (a != 5) { throw "GUARD RED: borrowRead"; }
	if (b != 6) { throw "GUARD RED: borrowThroughCallee"; }
	if (c != 1) { throw "GUARD RED: writeUnderLock"; }
	if (d != 5) { throw "GUARD RED: podCopyWrite"; }
	if (e != 6) { throw "GUARD RED: readonlyExtCall"; }
	console.log("GUARD-OK");
	return 0;
}

process.exit(main());
