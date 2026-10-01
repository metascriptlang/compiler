import { reloadKindName } from "std/hcr";
import { change } from "./support";
import { snapshot, bump, version } from "./logic";


function exceptionControl(): boolean {
	try {
		throw new Error("initial exception control");
	} catch (e) {
		return true;
	}
	return false;
}
function show(label: string): void {
	console.log(`HCR-VARS ${label}: v${version()} ${snapshot()}`);
}

function load(generation: string): void {
	const result = change(generation, ["logic"]);
	console.log(`HCR-VARS ${generation}: ${reloadKindName(result.kind)} ${result.modules.join(",")}`);
	if (generation == "g5") {
		console.log(`HCR-VARS reset report: count ${result.reason.contains("logic::count")} memo ${result.reason.contains("logic::memo")}`);
	}
}

console.log(`HCR-VARS exception control: ${exceptionControl()}`);
bump();
show("start");
load("g2");
show("added");
bump();
show("mutated");
load("g3");
show("removed");
bump();
load("g4");
show("reintroduced");
load("g5");
show("reset");
bump();
load("g6");
show("after integer initializer throws");
load("g7");
show("after string initializer throws");
load("g8");
show("after recovery");
