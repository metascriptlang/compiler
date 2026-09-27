import { reload, reloadKindName } from "std/hcr";
import { hit } from "./logic";

function positive(n: int32): boolean {
	return n > 0;
}

if (!positive(hit()) || !positive(hit())) console.log("HCR-LIFT short");
console.log(`HCR-LIFT hits ${hit()} ${reloadKindName(reload().kind)}`);
