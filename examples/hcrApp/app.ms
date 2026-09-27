import { reload, reloadKindName, HcrReloadKind } from "std/hcr";
import { tick, message } from "./logic";

console.log(message());
while (true) {
	const frame = tick();
	const outcome = reload();
	if (outcome.kind == HcrReloadKind.Reloaded) {
		console.log(`frame ${frame}: ${message()}`);
	} else if (outcome.kind != HcrReloadKind.NoChange && outcome.kind != HcrReloadKind.Pending) {
		console.log(`frame ${frame}: ${reloadKindName(outcome.kind)} ${outcome.reason}`);
	}
	await sleepAsync(16);
}
