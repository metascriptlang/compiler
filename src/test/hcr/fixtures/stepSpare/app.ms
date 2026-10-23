import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { step, lastReload, ReloadKind } from "std/hcr";
import { work } from "./logic";
import { cpuCount } from "std/os";
@include("./hold.h");
extern function holdWorker(): int32;
extern function holdWaitAll(n: int32): void;
extern function holdReleaseAll(): void;
extern function holdRearm(): void;
extern function holdRunningAfter(ms: int32): int32;
extern function holdHangAfter(seconds: int32): void;

function install(name: string): void {
	const edit = readFile(name);
	if (!edit.ok || !writeFile("logic.ms", edit.value).ok) {
		console.log(`STEP cannot install ${name}`);
		exit(1);
	}
}

// How many tasks run at once beyond the workers: a spare that no wait still wants has retired. A spare that was just
// told to retire may still take one task first, so the count waits 100 ms before it starts.
function extraRunning(): int32 {
	holdRunningAfter(100);
	holdRearm();
	const spinners: Promise<int32>[] = [];
	for (let i = 0; i <= cpuCount(); i++) spinners.push(spawn(() => holdWorker()));
	const running = holdRunningAfter(300);
	holdReleaseAll();
	for (const h of spinners) await h;
	return running - cpuCount();
}

// Every worker waits on its own sleep, so a step that queues tasks and then waits on a promise only a timer
// callback settles starts a spare; that callback crashes, unwinding past the wait that started the spare.
holdHangAfter(240);
console.log(`STEP start ${work(1)} extra=${extraRunning()}`);
const sleepers: Promise<int32>[] = [];
for (let i = 0; i < cpuCount(); i++) sleepers.push(spawn(() => { await sleepAsync(8000); return 1 as int32; }));
const queued: Promise<int32>[] = [];
install("crashSpare.txt");
const deadline = performance.now() + 180000;
let done = false;
let crashed = false;
while (!done && performance.now() < deadline) {
	let value: int32 = 0;
	const kind = step((): void => {
		value = work(1);
		if (value != 13) return;
		for (let i = 0; i < 2; i++) queued.push(spawn(() => 1 as int32));
		value = await new Promise<int32>((res) => { setTimeout(() => res(work(7)), 50); });
	});
	if (kind == ReloadKind.RolledBack && !crashed) {
		crashed = true;
		for (const h of sleepers) await h;
		let ran: int32 = 0;
		for (const h of queued) ran += await h;
		console.log(`STEP rolled back then ${work(1)} queued ran ${ran} extra=${extraRunning()}`);
		install("fixed.txt");
	} else if (kind == ReloadKind.Reloaded && crashed) {
		console.log(`STEP reloaded ${value}`);
		done = true;
	} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending && kind != ReloadKind.Reloaded) {
		console.log(`STEP unexpected ${lastReload().reason}`);
		done = true;
	} else {
		await sleepAsync(20);
	}
}
if (!done) console.log("STEP timed out");
