import { reload, lastReload, reloadKindName, HcrReloadKind } from "std/hcr";
import { tick, message } from "./logic";

console.log(message());
while (true) {
	const frame = tick();
	const kind = reload();
	if (kind == HcrReloadKind.Reloaded) {
		console.log(`frame ${frame}: ${message()}`);
	} else if (kind != HcrReloadKind.NoChange && kind != HcrReloadKind.Pending) {
		console.log(`frame ${frame}: ${reloadKindName(kind)} ${lastReload().reason}`);
	}
	await sleepAsync(16);
}
