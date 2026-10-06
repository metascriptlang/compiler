import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { Bag, Path, resetBag, resetNames, resetPath, namesOf } from "../box/box";
import { refill } from "./logic";

const bag: Bag = { items: [7, 8] };
const path: Path = { pts: [{ label: "a", x: 1 }] };
const names = namesOf<int32>(7);
resetBag(bag);
resetNames(names);
resetPath(path);
refill(bag);
console.log(`HCR-CELL start ${bag.items.length} ${names.list.length} ${path.pts.length}`);
const edit = readFile("../logicEdit.ms");
if (!edit.ok || !writeFile("logic.ms", edit.value).ok) {
	console.log("HCR-CELL cannot write logic.ms");
	exit(1);
}
const deadline = performance.now() + 120000;
let done = false;
while (!done && performance.now() < deadline) {
	const kind = reload();
	if (kind == ReloadKind.Reloaded) {
		refill(bag);
		console.log(`HCR-CELL reloaded ${lastReload().modules.join(",")} ${bag.items.length}`);
		done = true;
	} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
		console.log(`HCR-CELL ${reloadKindName(kind)} ${lastReload().reason}`);
		done = true;
	} else {
		await sleepAsync(20);
	}
}
if (!done) console.log("HCR-CELL timed out");
