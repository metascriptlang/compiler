import { reloadKindName } from "std/hcr";
import { change } from "./support";
import { hold, release, fresh } from "./logic";

function report(label: string, generation: string): void {
	const result = change(generation, ["logic"]);
	const names = result.modules.length > 0 ? " " + result.modules.join(",") : "";
	console.log(`HCR-LAYOUT ${label}: ${reloadKindName(result.kind)}${names} | ${result.reason}`);
}

hold();
console.log(`HCR-LAYOUT before: ${fresh()}`);
report("held", "g2");
console.log(`HCR-LAYOUT after held: ${fresh()}`);
release();
report("released", "g3");
console.log(`HCR-LAYOUT after released: ${fresh()}`);
