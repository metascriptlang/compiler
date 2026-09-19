import { exit } from "std/process";
import { add, sub } from "./fixtures/reexportDirective/chain";
import { mul } from "./fixtures/reexportDirective/star";

function main(): void {
	const viaChain = add(2, 3);
	const viaChainOwn = sub(9, 4);
	const viaStar = mul(2, 3);
	console.log(`add=${viaChain} sub=${viaChainOwn} mul=${viaStar}`);
	if (viaChain != 5 || viaChainOwn != 5 || viaStar != 6) {
		console.log("FAIL: a directive of a re-export-only module was dropped");
		exit(1);
	}
	console.log("reexportOnlyModuleKeepsCompileDirective ok");
}

main();
