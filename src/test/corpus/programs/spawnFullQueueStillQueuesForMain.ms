// @stdout: held ok=true
// @stdout: fillers ok=true
// @stdout: late resolver ok=true
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: JS runs every task on the one thread, so no wait blocks a worker
// note: every pool worker spins on a flag and one spawned task sits unclaimed at the head of the queue; 300 spawn-and-await rounds then leave claimed slots behind it, which must not count against the queue's capacity. A spawn from the main thread is queued, never run inline on it: the task spawned last awaits a promise that only main resolves, after the spawn returns, so running it inline would block main on its own later code.
import { cpuCount } from "std/os";
import { lockedUpdate, lockedRead } from "std/core/promise";

struct Flags { release: boolean; started: int32; }
const flags = new Locked<Flags>({ release: false, started: 0 });

function hold(): int32 {
	lockedUpdate(flags, (f: Flags): Flags => ({ release: f.release, started: f.started + 1 }));
	while (!lockedRead(flags, (f: Flags): boolean => f.release)) {}
	return 1;
}

const workers = cpuCount();
const holders: Promise<int32>[] = [];
for (let i = 0; i < workers; i++) holders.push(spawn(() => hold()));
while (lockedRead(flags, (f: Flags): int32 => f.started) < workers) {}

const parked = spawn(() => 2 as int32);

let sum = 0;
for (let k = 0; k < 300; k++) {
	const h = spawn(() => 1 as int32);
	sum += await h;
}

function lateRound(): int32 {
	let resolveLate: (v: int32) => void = (v: int32): void => {};
	const gate = new Promise<int32>((res) => { resolveLate = res; });
	const late = spawn(() => await gate);
	resolveLate(7);
	return await late;
}
const lateValue = lateRound();

lockedUpdate(flags, (f: Flags): Flags => ({ release: true, started: f.started }));
let heldOk = true;
for (const h of holders) heldOk = heldOk && (await h) == 1;
const parkedValue = await parked;
console.log(`held ok=${heldOk && parkedValue == 2}`);
console.log(`fillers ok=${sum == 300}`);
console.log(`late resolver ok=${lateValue == 7}`);
