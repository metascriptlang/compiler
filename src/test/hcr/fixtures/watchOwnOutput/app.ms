import { reload, ReloadKind } from "std/hcr";
import { value } from "./sub/logic";

console.log(`OWN start ${value()}`);
let said = false;
while (true) {
	if (reload() == ReloadKind.Reloaded && !said) {
		console.log(`OWN reloaded ${value()}`);
		said = true;
	}
	await sleepAsync(20);
}
