import { change } from "./support";
import { measure } from "./logic";
import { fill, holder, label } from "./state";

function show(step: string): void {
	fill(1);
	console.log(`HCR-BORROW ${step}: ${measure(label)} ${measure(holder.name)}`);
}

show("start");
const result = change("g2", ["logic"]);
console.log(`HCR-BORROW g2: ${result.modules.join(",")}`);
show("after");
