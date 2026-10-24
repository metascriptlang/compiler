// @xfail(raiser): the Raiser std declares no Date, so the busy-wait on Date.now stops at the type check with exit 1 before any task runs
// @stdout: group ok
// @stdout: cyclic ok
// @serial
// @skip-js: JS has no spawn threads, so a moved capture is never dropped by a task there
// note: `Promise.all` over two held handles returns only after each task has dropped its moved capture (ULTRALOCK T4), and the same holds for a moved capture of a cyclic class whose task breaks the ring: its `onDestroy` has run when the await returns, with the owner busy for 100 ms between the spawn and the await. Old compiler (red 5/5): the captures stayed in the env slots and were dropped when the envs were released on the owner's loop after the await.

import { lockedUpdate, lockedRead } from "std/core/promise";

const dropped: Locked<int32> = new Locked(0);

class MovedBox { v: int32; constructor(v: int32) { this.v = v; } }

class Ring {
	next: Ring | null = null;
	v: int32;
	constructor(v: int32) { this.v = v; }
}

function onDestroy(this x: MovedBox): void {
	const t0 = Date.now();
	while (Date.now() - t0 < 50) {}
	lockedUpdate(dropped, (c: int32): int32 => { return c + 1; });
}

function onDestroy(this x: Ring): void {
	lockedUpdate(dropped, (c: int32): int32 => { return c + 1; });
}

function droppedNow(): int32 { return lockedRead(dropped, (c: int32): int32 => { return c; }); }

function ownerBusy(ms: number): void {
	const t1 = Date.now();
	while (Date.now() - t1 < ms) {}
}

async function groupOfTwo(i: int32): Promise<int32> {
	const a = new MovedBox(i);
	const b = new MovedBox(i + 1);
	const before = droppedNow();
	const fa = spawn(() => { let s: int32 = 0; for (let r = 0; r < 20000; r += 1) s = (s + a.v) % 1000003; return s; }, { move: [a] });
	const fb = spawn(() => { let s: int32 = 0; for (let r = 0; r < 20000; r += 1) s = (s + b.v) % 1000003; return s; }, { move: [b] });
	ownerBusy(100);
	const rs = await Promise.all([fa, fb]);
	return droppedNow() - before + rs.length * 0;
}

async function ringDropped(i: int32): Promise<int32> {
	const head = new Ring(i);
	head.next = head;
	const before = droppedNow();
	const f = spawn(() => {
		head.next = null;
		return head.v;
	}, { move: [head] });
	ownerBusy(100);
	const r = await f;
	return droppedNow() - before + r * 0;
}

async function main(): Promise<void> {
	let badGroup = 0;
	let badRing = 0;
	for (let i = 0; i < 4; i += 1) {
		const g = await groupOfTwo(i);
		if (g != 2) { badGroup += 1; console.log(`group dropped=${g} want 2`); }
		const c = await ringDropped(i);
		if (c != 1) { badRing += 1; console.log(`ring dropped=${c} want 1`); }
	}
	console.log(badGroup == 0 ? "group ok" : "group RED");
	console.log(badRing == 0 ? "cyclic ok" : "cyclic RED");
}

main();
