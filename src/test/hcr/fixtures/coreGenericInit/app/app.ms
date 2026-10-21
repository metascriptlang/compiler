import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { appBox, appText, appTagged } from "./logic";
import { libBox, libText, libTagged } from "../lib/lib";

function show(stage: string): void {
	const sum = appBox().get() + libBox().get();
	console.log(`HCR-GI ${stage} V6 ${sum} ${appText().get()}${libText().get()} ${appTagged().label()} ${libTagged().label()}`);
}
show("start");
const edit = readFile("../logicEdit.ms");
if (!edit.ok || !writeFile("logic.ms", edit.value).ok) {
	console.log("HCR-GI cannot write logic.ms");
	exit(1);
}
const deadline = performance.now() + 120000;
let done = false;
while (!done && performance.now() < deadline) {
	const kind = reload();
	if (kind == ReloadKind.Reloaded) {
		console.log(`HCR-GI reloaded ${lastReload().modules.join(",")}`);
		show("after");
		done = true;
	} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
		console.log(`HCR-GI ${reloadKindName(kind)} ${lastReload().reason}`);
		done = true;
	} else {
		await sleepAsync(20);
	}
}
if (!done) console.log("HCR-GI timed out");
