import { reloadKindName } from "std/hcr";
import { change } from "./support";
import { bump } from "./state";
import { report } from "./reader";

function show(label: string): void {
	bump();
	console.log(`HCR-SHIFT ${label}: ${report()}`);
}

function load(generation: string, moduleIds: string[]): void {
	const result = change(generation, moduleIds);
	const names = result.modules.length > 0 ? " " + result.modules.join(",") : "";
	console.log(`HCR-SHIFT ${generation}: ${reloadKindName(result.kind)}${names}`);
}

show("start");
load("g2", ["reader"]);
show("reader");
load("g3", ["state"]);
show("state");
