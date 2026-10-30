import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { label } from "./logic";

console.log(`HCR-BRAND start ${label()}`);
const source = readFile("logicBody.ms");
if (!source.ok || !writeFile("logic.ms", source.value).ok) exit(1);
const deadline = performance.now() + 120000;
let done = false;
while (!done && performance.now() < deadline) {
	const kind = reload();
	if (kind == ReloadKind.Reloaded) {
		console.log(`HCR-BRAND reloaded ${label()}`);
		done = true;
	} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
		console.log(`HCR-BRAND ${reloadKindName(kind)} ${lastReload().reason}`);
		exit(0);
	} else {
		await sleepAsync(20);
	}
}
if (!done) console.log("HCR-BRAND timed out");
