import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { base } from "./lib/util";

console.log(`HCR-SUB start ${base()}`);
const edit = readFile("edit.txt");
if (!edit.ok || !writeFile("lib/util.ms", edit.value).ok) {
	console.log("HCR-SUB cannot write lib/util.ms");
	exit(1);
}
const deadline = performance.now() + 120000;
let done = false;
while (!done && performance.now() < deadline) {
	const kind = reload();
	if (kind == ReloadKind.Reloaded) {
		console.log(`HCR-SUB reloaded ${lastReload().modules.includes("lib/util")} ${base()}`);
		done = true;
	} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
		console.log(`HCR-SUB ${reloadKindName(kind)} ${lastReload().reason}`);
		done = true;
	} else {
		await sleepAsync(20);
	}
}
if (!done) console.log("HCR-SUB timed out");
