import { copyFile, readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, reloadKindName } from "std/hcr";
import { tick, value } from "./logic";

function place(generation: string, name: string): void {
	if (!copyFile(`${generation}/${name}`, `run/${name}`).ok) {
		console.log(`HCR-ENGINE cannot place ${generation}/${name}`);
		exit(1);
	}
}

function truncate(generation: string, name: string): void {
	const bytes = readFile(`${generation}/${name}`);
	if (!bytes.ok || !writeFile(`run/${name}`, bytes.value.byteSlice(0, 512)).ok) {
		console.log(`HCR-ENGINE cannot truncate ${name}`);
		exit(1);
	}
}

function report(label: string): void {
	const outcome = reload();
	const names = outcome.modules.length > 0 ? " " + outcome.modules.join(",") : "";
	const reason = outcome.reason != "" ? ` (${outcome.reason})` : "";
	console.log(`HCR-ENGINE ${label}: ${reloadKindName(outcome.kind)}${names}${reason}`);
}

function show(label: string): void {
	console.log(`HCR-ENGINE ${label}: value ${value()} tick ${tick()}`);
}

show("start");
report("unchanged");

place("g2", "module.logic.dll");
place("g2", "module.dll.hcrabi");
report("body edit");
show("after body edit");

truncate("g1", "module.logic.dll");
place("g1", "module.dll.hcrabi");
report("truncated image");
report("same truncated image");
place("g1", "module.logic.dll");
report("complete image");
show("after complete image");

place("g3", "module.logic.dll");
place("g3", "module.dll.hcrabi");
report("added export, app not rebuilt");
show("after rejection");

place("g4", "module.logic.dll");
place("g4", "module.dll.hcrabi");
report("state layout changed");
show("after layout rejection");

place("g2", "module.core.dll");
place("g2", "module.dll.hcrabi");
report("core changed");
