import { reloadKindName } from "std/hcr";
import { change } from "./support";
import { Counter } from "./logic";

function show(label: string): void {
	const first = Counter();
	const second = Counter();
	console.log(`HCR-PASS ${label}: ${first} ${second} | ${refreshLog()}`);
}

show("start");
const result = change("g2", ["logic"]);
console.log(`HCR-PASS g2: ${reloadKindName(result.kind)} ${result.modules.join(",")} | ${refreshLog()}`);
show("after reload");
