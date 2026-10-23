import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { step, lastReload, ReloadKind } from "std/hcr";
import { work } from "./logic";
import { cpuCount } from "std/os";
@include("./hold.h");
extern function holdWorker(): int32;
extern function holdWaitAll(n: int32): void;
extern function holdReleaseAll(): void;
extern function holdFrameLeft(): int32;
extern function holdHangAfter(seconds: int32): void;
extern function holdRearm(): void;

function category(reason: string): string {
	if (reason.contains("fatal runtime error")) return "fatal";
	if (reason.contains("uncaught exception: boom")) return "exception";
	if (reason.contains("overflow") || reason.contains("segmentation") || reason.contains("access violation")) return "fault";
	return `other(${reason})`;
}

function install(name: string): void {
	const edit = readFile(name);
	if (!edit.ok || !writeFile("logic.ms", edit.value).ok) {
		console.log(`STEP cannot install ${name}`);
		exit(1);
	}
}

function mustNotThrow(n: int32): int32 {
	if (n > 1000) throw new Error("never");
	return n;
}

const edits = ["crashIndex.txt", "crashRecurse.txt", "crashThrow.txt", "crashInTask.txt", "crashNested.txt", "fixed.txt"];
// crashInTask crashes inside a spawned task that the loop thread runs itself, because every worker is held;
// crashNested one task deeper.
const heldEdits = ["crashInTask.txt", "crashNested.txt"];
let held: Promise<int32>[] = [];
let next = 0;
holdHangAfter(240);
console.log(`STEP start ${work(mustNotThrow(1))}`);
install(edits[next]);
const deadline = performance.now() + 180000;
let done = false;
while (!done && performance.now() < deadline) {
	let value: int32 = 0;
	const kind = step((): void => { value = work(1); });
	if (kind == ReloadKind.RolledBack) {
		const frameLeft = holdFrameLeft();
		if (held.length > 0) {
			holdReleaseAll();
			for (const h of held) await h;
			held = [];
		}
		console.log(`STEP rolled back ${lastReload().modules.join(",")} ${category(lastReload().reason)} then ${work(1)} frame=${frameLeft}`);
		next += 1;
		install(edits[next]);
		if (heldEdits.includes(edits[next])) {
			holdRearm();
			for (let i = 0; i < cpuCount(); i++) held.push(spawn(() => holdWorker()));
			holdWaitAll(cpuCount());
		}
	} else if (kind == ReloadKind.Reloaded) {
		console.log(`STEP reloaded ${value}`);
		done = next == edits.length - 1;
	} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
		console.log(`STEP unexpected ${lastReload().reason}`);
		done = true;
	} else {
		await sleepAsync(20);
	}
}
if (!done) console.log("STEP timed out");
