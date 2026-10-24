import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { put } from "./shapes";
import { go } from "./caller";

console.log(`HCR-OV start ${go()} ${put(7)}`);
const edit = readFile("shapesEdit.ms");
if (!edit.ok || !writeFile("shapes.ms", edit.value).ok) {
	console.log("HCR-OV cannot write shapes.ms");
	exit(1);
}
const deadline = performance.now() + 120000;
let done = false;
while (!done && performance.now() < deadline) {
	const kind = reload();
	if (kind == ReloadKind.Reloaded) {
		console.log(`HCR-OV reloaded ${lastReload().modules.join(",")}`);
		console.log(`HCR-OV after ${go()} ${put(7)}`);
		done = true;
	} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
		console.log(`HCR-OV ${reloadKindName(kind)} ${lastReload().reason}`);
		done = true;
	} else {
		await sleepAsync(20);
	}
}
if (!done) console.log("HCR-OV timed out");
