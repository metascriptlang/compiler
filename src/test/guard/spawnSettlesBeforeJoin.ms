// guard: a task has settled its captures when `await` returns
//
// INVARIANT (ULTRALOCK T4): when `await` returns, the task has dropped the moved capture it did
//   not return, and it holds the parent's env as a view: the env-held value is still alive right
//   after the await and is dropped once, by the parent, when the routine leaves. Counted by
//   onDestroy hooks through a Locked cell, because the task's drop runs on a worker thread. Axes:
//   a held handle awaited later and an await of the spawn itself, in a sync routine.
//
// RED MEANS: a moved capture is still alive right after its await (the worker left it in the
//   env slot), or the env-held value was dropped by the task side (the worker counted the env),
//   or either was dropped twice.
//
// GUARD-BALANCE MovedBox
// GUARD-BALANCE EnvBox
// GUARD-TSAN

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Counts { moved: int32; env: int32; }

const counts: Locked<Counts> = new Locked({ moved: 0, env: 0 });

class MovedBox { v: int32; constructor(v: int32) { this.v = v; } }
class EnvBox { v: int32; constructor(v: int32) { this.v = v; } }

function onDestroy(this x: MovedBox): void {
	lockedUpdate(counts, (c: Counts): Counts => { return { moved: c.moved + 1, env: c.env }; });
}

function onDestroy(this x: EnvBox): void {
	lockedUpdate(counts, (c: Counts): Counts => { return { moved: c.moved, env: c.env + 1 }; });
}

function movedNow(): int32 { return lockedRead(counts, (c: Counts): int32 => { return c.moved; }); }
function envNow(): int32 { return lockedRead(counts, (c: Counts): int32 => { return c.env; }); }

let bad: int32 = 0;

function check(label: string, i: int32, movedWant: int32, envWant: int32): void {
	const mv = movedNow();
	const ev = envNow();
	if (mv != movedWant || ev != envWant) {
		bad += 1;
		if (bad <= 4) console.log(`${label} i=${i} moved=${mv} want ${movedWant} env=${ev} want ${envWant}`);
	}
}

function heldSync(i: int32): void {
	const m = new MovedBox(i);
	const e = new EnvBox(i);
	const mv = movedNow();
	const ev = envNow();
	const f = spawn(() => { let s: int32 = 0; for (let r = 0; r < 20000; r += 1) s = (s + m.v + e.v) % 1000003; return s; }, { move: [m] });
	const r = await f;
	check("held sync", i, mv + 1, ev);
	if (e.v != i || r < 0) bad += 1;
}

function fusedSync(i: int32): void {
	const m = new MovedBox(i);
	const e = new EnvBox(i);
	const mv = movedNow();
	const ev = envNow();
	const r = await spawn(() => { let s: int32 = 0; for (let k = 0; k < 20000; k += 1) s = (s + m.v + e.v) % 1000003; return s; }, { move: [m] });
	check("fused sync", i, mv + 1, ev);
	if (e.v != i || r < 0) bad += 1;
}

function main(): void {
	for (let i = 0; i < 100; i += 1) {
		const ev = envNow();
		heldSync(i);
		fusedSync(i);
		check("after the routines left", i, 2 * (i + 1), ev + 2);
	}
	if (bad == 0) console.log("GUARD-OK");
	else {
		console.log(`bad=${bad}`);
		process.exit(1);
	}
}

main();
