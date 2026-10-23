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
extern function holdFrameLeft(): int32;
extern function holdHangAfter(seconds: int32): void;

function category(reason: string): string {
	if (reason.contains("fatal runtime error")) return "fatal";
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

// Every worker is held, so the loop thread runs a task spawned before the step that the step joins, directly
// (crashJoin) or through Promise.all (crashAll); that task crashes, and the program awaits it again after the rollback.
const edits = ["crashJoin.txt", "crashAll.txt", "fixed.txt"];
let held: Promise<int32>[] = [];
let joins: Promise<int32>[] = [];
let alls: Promise<int32[]>[] = [];
let next = 0;

function arm(): void {
	install(edits[next]);
	if (edits[next] == "fixed.txt") return;
	holdRearm();
	for (let i = 0; i < cpuCount(); i++) held.push(spawn(() => holdWorker()));
	holdWaitAll(cpuCount());
	if (edits[next] == "crashJoin.txt") joins.push(spawn(() => work(7)));
	else alls.push(Promise.all([spawn(() => work(7))]));
}

holdHangAfter(240);
console.log(`STEP start ${work(1)}`);
arm();
const deadline = performance.now() + 180000;
let done = false;
while (!done && performance.now() < deadline) {
	let value: int32 = 0;
	const kind = step((): void => {
		value = work(1);
		if (value == 11) value = await joins[0];
		if (value == 12) value = (await alls[0])[0];
	});
	if (kind == ReloadKind.RolledBack) {
		const frameLeft = holdFrameLeft();
		holdReleaseAll();
		for (const h of held) await h;
		held = [];
		console.log(`STEP rolled back ${category(lastReload().reason)} then ${work(1)} frame=${frameLeft}`);
		for (const j of joins) {
			try { console.log(`STEP join resolved ${await j}`); } catch (e) { console.log(`STEP join rejected ${category(e.message)}`); }
		}
		for (const a of alls) {
			try { console.log(`STEP all resolved ${(await a)[0]}`); } catch (e) { console.log(`STEP all rejected ${category(e.message)}`); }
		}
		joins = [];
		alls = [];
		next += 1;
		arm();
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
