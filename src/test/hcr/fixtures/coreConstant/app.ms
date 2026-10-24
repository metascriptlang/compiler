import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { area, wide } from "./geo";

console.log(`HCR-CC start ${area(1)} ${wide()}`);
const edit = readFile("scaleEdit.ms");
if (!edit.ok || !writeFile("scale.ms", edit.value).ok) {
	console.log("HCR-CC cannot write scale.ms");
	exit(1);
}
const deadline = performance.now() + 120000;
let done = false;
while (!done && performance.now() < deadline) {
	const kind = reload();
	if (kind == ReloadKind.Reloaded) {
		console.log(`HCR-CC reloaded ${lastReload().modules.join(",")}`);
		console.log(`HCR-CC after ${area(1)} ${wide()}`);
		done = true;
	} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
		console.log(`HCR-CC ${reloadKindName(kind)} ${lastReload().reason}`);
		done = true;
	} else {
		await sleepAsync(20);
	}
}
if (!done) console.log("HCR-CC timed out");
