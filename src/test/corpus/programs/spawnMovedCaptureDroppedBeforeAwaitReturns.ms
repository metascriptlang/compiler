// @xfail(raiser): the Raiser std declares no Date, so the busy-wait on Date.now stops at the type check with exit 1 before any task runs
// @stdout: held async ok
// @stdout: held array ok
// @stdout: no env capture ok
// @stdout: fused ok
// @serial
// @skip-js: JS has no spawn threads, so a moved capture is never dropped by a task there
// note: when `await` returns, the task has dropped the moved capture it did not return (ULTRALOCK T4), so that box's `onDestroy` has run by then even though the owner stayed busy for 100 ms between the spawn and the await, while the env-held box is still alive and is dropped by the parent later. Boxes carry their own id and the hooks set one bit per id, so a late drop of an earlier box cannot hide a miss. Old compiler (red 5/5 on the held cases): the capture stayed in the env slot and was dropped when the env was released on the owner's loop after the await. The fused await is the control: the owner destroyed the closure right after the wait, so it was green before.

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Dropped { moved: int32; env: int32; }

const dropped: Locked<Dropped> = new Locked({ moved: 0, env: 0 });

class MovedBox { v: int32; constructor(v: int32) { this.v = v; } }
class EnvBox { v: int32; constructor(v: int32) { this.v = v; } }

function onDestroy(this x: MovedBox): void {
	const t0 = Date.now();
	while (Date.now() - t0 < 50) {}
	lockedUpdate(dropped, (c: Dropped): Dropped => { return { moved: c.moved | (1 << x.v), env: c.env }; });
}

function onDestroy(this x: EnvBox): void {
	lockedUpdate(dropped, (c: Dropped): Dropped => { return { moved: c.moved, env: c.env | (1 << x.v) }; });
}

function movedHas(id: int32): boolean { return lockedRead(dropped, (c: Dropped): boolean => { return (c.moved & (1 << id)) != 0; }); }
function envHas(id: int32): boolean { return lockedRead(dropped, (c: Dropped): boolean => { return (c.env & (1 << id)) != 0; }); }

function ownerBusy(ms: number): void {
	const t1 = Date.now();
	while (Date.now() - t1 < ms) {}
}

let bad: int32 = 0;

function check(label: string, id: int32): void {
	if (!movedHas(id) || envHas(id)) {
		bad += 1;
		console.log(`${label} id=${id} moved dropped=${movedHas(id)} want true, env dropped=${envHas(id)} want false`);
	}
}

async function heldAsync(id: int32): Promise<void> {
	const m = new MovedBox(id);
	const e = new EnvBox(id);
	const f = spawn(() => { let s: int32 = 0; for (let r = 0; r < 20000; r += 1) s = (s + m.v + e.v) % 1000003; return s; }, { move: [m] });
	ownerBusy(100);
	const r = await f;
	check("held async", id);
	if (e.v != id || r < 0) bad += 1;
}

function heldArray(id: int32): void {
	const m = new MovedBox(id);
	const e = new EnvBox(id);
	const fs = [spawn(() => { let s: int32 = 0; for (let r = 0; r < 20000; r += 1) s = (s + m.v + e.v) % 1000003; return s; }, { move: [m] })];
	ownerBusy(100);
	const r = await fs[0];
	check("held array", id);
	if (e.v != id || r < 0) bad += 1;
}

async function noEnvCapture(id: int32): Promise<void> {
	const m = new MovedBox(id);
	const f = spawn(() => { let s: int32 = 0; for (let r = 0; r < 20000; r += 1) s = (s + m.v) % 1000003; return s; }, { move: [m] });
	ownerBusy(100);
	const r = await f;
	if (!movedHas(id)) {
		bad += 1;
		console.log(`no env capture id=${id} moved dropped=false want true`);
	}
	if (r < 0) bad += 1;
}

function fused(id: int32): void {
	const m = new MovedBox(id);
	const e = new EnvBox(id);
	const r = await spawn(() => { let s: int32 = 0; for (let k = 0; k < 20000; k += 1) s = (s + m.v + e.v) % 1000003; return s; }, { move: [m] });
	check("fused", id);
	if (e.v != id || r < 0) bad += 1;
}

async function main(): Promise<void> {
	let before = bad;
	for (let i = 0; i < 4; i += 1) await heldAsync(i);
	console.log(bad == before ? "held async ok" : "held async RED");
	before = bad;
	for (let i = 4; i < 8; i += 1) heldArray(i);
	console.log(bad == before ? "held array ok" : "held array RED");
	before = bad;
	for (let i = 8; i < 12; i += 1) await noEnvCapture(i);
	console.log(bad == before ? "no env capture ok" : "no env capture RED");
	before = bad;
	for (let i = 12; i < 16; i += 1) fused(i);
	console.log(bad == before ? "fused ok" : "fused RED");
}

main();
