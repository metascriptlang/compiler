import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { greet } from "greeter";

console.log(`HCR-DEP start ${greet()}`);
const edit = readFile("../greeterEdit.ms");
if (!edit.ok || !writeFile("../greeter/index.ms", edit.value).ok) {
	console.log("HCR-DEP cannot write the dependency");
	exit(1);
}
const deadline = performance.now() + 120000;
let done = false;
while (!done && performance.now() < deadline) {
	const kind = reload();
	if (kind == ReloadKind.Reloaded) {
		console.log(`HCR-DEP reloaded greeter ${lastReload().modules.includes("greeter/index")} ${greet()}`);
		done = true;
	} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
		console.log(`HCR-DEP ${reloadKindName(kind)} ${lastReload().reason}`);
		done = true;
	} else {
		await sleepAsync(20);
	}
}
if (!done) console.log("HCR-DEP timed out");
