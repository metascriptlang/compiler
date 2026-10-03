import { reloadKindName } from "std/hcr";
import { change } from "./support";
import { LIMIT, TITLE, bump, counter } from "./logic";

function show(label: string): void {
	counter += 10;
	const advanced = bump();
	console.log(`HCR-SHARED ${label}: ${LIMIT} ${TITLE} ${counter} ${advanced}`);
}

function load(generation: string, binding: string): void {
	const result = change(generation, ["logic"]);
	const names = result.modules.length > 0 ? " " + result.modules.join(",") : "";
	console.log(`HCR-SHARED ${generation}: ${reloadKindName(result.kind)}${names}`);
	if (binding != "") {
		console.log(`HCR-SHARED binding ${binding}: app ${result.reason.contains("app")} symbol ${result.reason.contains("logic::" + binding)}`);
	}
}

show("start");
load("g2", "");
show("edited constants");
load("g3", "counter");
show("after counter type rejection");
load("g4", "TITLE");
show("after title type rejection");
load("g5", "");
show("edited constants again");
