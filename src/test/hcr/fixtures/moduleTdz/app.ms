import { reloadKindName } from "std/hcr";
import { change } from "./support";
import { snapshot, bump, version } from "./logic";

function show(label: string): void {
	try {
		console.log(`HCR-TDZ ${label}: v${version()} ${snapshot()}`);
	} catch (e) {
		console.log(`HCR-TDZ ${label}: v${version()} threw ${(e as Error).message}`);
	}
}

function load(generation: string): void {
	const result = change(generation, ["logic"]);
	console.log(`HCR-TDZ ${generation}: ${reloadKindName(result.kind)} ${result.modules.join(",")}`);
}

bump();
show("start");
load("g2");
show("added");
bump();
load("g3");
show("reset");
