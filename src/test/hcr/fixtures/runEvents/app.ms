import { reload, ReloadKind } from "std/hcr";
import { value } from "./logic";
import { Box, make } from "./model";

const box: Box = make();
console.log(`EVENTS start ${value()} ${box.n}`);
let seen = "";
while (true) {
	const kind = reload();
	if (kind == ReloadKind.Reloaded && seen != value()) {
		seen = value();
		console.log(`EVENTS reloaded ${value()}`);
	}
	await sleepAsync(20);
}
