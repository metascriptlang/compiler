import { reloadKindName } from "std/hcr";
import { quotient } from "std/solana/arithmetic";
import { change } from "./support";
import { step } from "./logic";

function run(): void {
	console.log(`HCR-INLINE g1: step ${step(3)} quotient ${quotient(-7, 2)}`);
	const result = change("g2", ["logic"]);
	console.log(`HCR-INLINE g2: ${reloadKindName(result.kind)} ${result.modules.join(",")}`);
	console.log(`HCR-INLINE after g2: step ${step(3)} quotient ${quotient(-9, 2)}`);
}

run();
