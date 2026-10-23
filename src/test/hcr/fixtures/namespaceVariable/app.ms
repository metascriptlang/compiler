import { reloadKindName } from "std/hcr";
import { change } from "./support";
import * as logic from "./logic";

function show(label: string): void {
	logic.grow();
	console.log(`HCR-NS ${label}: ${logic.items.length} ${logic.items[logic.items.length - 1]} ${logic.pair.a} ${logic.pair.b}`);
}

function load(generation: string): void {
	const result = change(generation, ["logic"]);
	const names = result.modules.length > 0 ? " " + result.modules.join(",") : "";
	console.log(`HCR-NS ${generation}: ${reloadKindName(result.kind)}${names}`);
}

show("start");
load("g2");
show("edited");
