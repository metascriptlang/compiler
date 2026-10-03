import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { tick, message } from "./logic";

console.log(message());
while (true) {
	const frame = tick();
	const kind = reload();
	if (kind == ReloadKind.Reloaded) {
		console.log(`frame ${frame}: ${message()}`);
	} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
		console.log(`frame ${frame}: ${reloadKindName(kind)} ${lastReload().reason}`);
	}
	await sleepAsync(16);
}
