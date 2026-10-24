import { reload } from "std/hcr";
import { countArgs } from "./tools";

function f(a: int32, b: int32): int32 {
	return a + b;
}

reload();
console.log(`HCR-MH B2 ${countArgs(f(1, 2))}`);
