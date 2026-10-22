import { reloadKindName } from "std/hcr";
import { change } from "./support";
import { $Box, $step, Box, step } from "./logic";

function load(generation: string): void {
	const result = change(generation, ["logic"]);
	console.log(`HCR-DOLLAR ${generation}: ${reloadKindName(result.kind)} ${result.modules.join(",")} [${result.reason}]`);
}

function run(): void {
	const heldDollar: () => int32 = $step;
	const heldPlain: () => int32 = step;
	const boxes = `${new $Box().a} ${new Box().a}`;
	console.log(`HCR-DOLLAR g1: $step ${heldDollar()} step ${heldPlain()} boxes ${boxes}`);
	load("g2");
	console.log(`HCR-DOLLAR after g2: $step ${heldDollar()} step ${heldPlain()} direct ${$step()} ${step()}`);
	load("g3");
	load("g4");
}

run();
