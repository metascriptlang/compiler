import { reloadKindName } from "std/hcr";
import { change } from "./support";
import { runA } from "./a";
import { runB } from "./b";
import { hitCount } from "./cell";

function show(label: string): void {
	const a = runA();
	const b = runB();
	console.log(`HCR-GENERIC ${label}: ${a} ${b} hits ${hitCount()}`);
}

function load(generation: string, moduleIds: string[]): void {
	const result = change(generation, moduleIds);
	result.modules.sort();
	console.log(`HCR-GENERIC ${generation}: ${reloadKindName(result.kind)} ${result.modules.join(",")}`);
}

show("start");
load("g2", ["a", "b"]);
show("new instances");
load("g3", ["b"]);
show("second consumer");
load("g4", ["cell"]);
show("private helper edit");
