import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, reloadKindName, HcrReloadKind } from "std/hcr";
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
	const outcome = reload();
	if (outcome.kind == HcrReloadKind.Reloaded) {
		console.log(`HCR-RUN reloaded ${outcome.modules.join(",")} value ${value()}`);
		done = true;
	} else if (outcome.kind != HcrReloadKind.NoChange && outcome.kind != HcrReloadKind.Pending) {
		console.log(`HCR-RUN ${reloadKindName(outcome.kind)} ${outcome.reason}`);
		done = true;
	} else {
		await sleepAsync(20);
	}
}
if (!done) console.log("HCR-RUN timed out");
