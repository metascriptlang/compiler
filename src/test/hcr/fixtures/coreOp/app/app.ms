import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { flip, Look } from "./logic";
import { Style, clearStyle, sizeOf, dirName } from "../lib/lib";

const look: Look = { way: null, span: ["s", 1] };
const style: Style = { dir: "column", size: ["wide", 7] };
const before = sizeOf(style);
console.log(`HCR-OP start ${flip(look)} ${dirName(style)} ${before[0]} ${before[1]}`);
clearStyle(style);
const after = sizeOf(style);
console.log(`HCR-OP cleared ${dirName(style)} ${after[0]} ${after[1]}`);
const edit = readFile("../logicEdit.ms");
if (!edit.ok || !writeFile("logic.ms", edit.value).ok) {
	console.log("HCR-OP cannot write logic.ms");
	exit(1);
}
const deadline = performance.now() + 120000;
let done = false;
while (!done && performance.now() < deadline) {
	const kind = reload();
	if (kind == ReloadKind.Reloaded) {
		console.log(`HCR-OP reloaded ${lastReload().modules.join(",")} ${flip(look)}`);
		done = true;
	} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
		console.log(`HCR-OP ${reloadKindName(kind)} ${lastReload().reason}`);
		done = true;
	} else {
		await sleepAsync(20);
	}
}
if (!done) console.log("HCR-OP timed out");
