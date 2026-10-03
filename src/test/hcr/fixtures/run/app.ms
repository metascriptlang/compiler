import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { value } from "./logic";

console.log(`HCR-RUN start value ${value()}`);
const edit = readFile("edit.txt");
if (!edit.ok || !writeFile("logic.ms", edit.value).ok) {
	console.log("HCR-RUN cannot write logic.ms");
	exit(1);
}
const deadline = performance.now() + 120000;
let done = false;
while (!done && performance.now() < deadline) {
	const kind = reload();
	if (kind == ReloadKind.Reloaded) {
		console.log(`HCR-RUN reloaded ${lastReload().modules.join(",")} value ${value()}`);
		done = true;
	} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
		console.log(`HCR-RUN ${reloadKindName(kind)} ${lastReload().reason}`);
		done = true;
	} else {
		await sleepAsync(20);
	}
}
if (!done) console.log("HCR-RUN timed out");
