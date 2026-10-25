import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { Counter, limit, bump } from "./counter";

function show(stage: string): void {
	console.log(`HCR-SF ${stage} ${limit()} ${Counter.LIMIT} ${bump()} ${Counter.total} ${Counter.label} ${Counter.computed}`);
}

show("start");
const edit = readFile("counterEdit.ms");
if (!edit.ok || !writeFile("counter.ms", edit.value).ok) {
	console.log("HCR-SF cannot write counter.ms");
	exit(1);
}
const deadline = performance.now() + 120000;
let done = false;
while (!done && performance.now() < deadline) {
	const kind = reload();
	if (kind == ReloadKind.Reloaded) {
		console.log(`HCR-SF reloaded ${lastReload().modules.join(",")}`);
		show("after");
		done = true;
	} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
		console.log(`HCR-SF ${reloadKindName(kind)} ${lastReload().reason}`);
		done = true;
	} else {
		await sleepAsync(20);
	}
}
if (!done) console.log("HCR-SF timed out");
