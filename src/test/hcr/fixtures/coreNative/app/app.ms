import { writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { nativeSum } from "../box/box";
import { label } from "./logic";

console.log(`HCR-NATIVE start ${nativeSum()} ${label()}`);
for (let step = 2; step <= 3; step += 1) {
	const header = step == 3 ? writeFile("../box/shared.h", `#define HCR_NATIVE_REV ${Date.now()}\n`).ok : true;
	if (!header || !writeFile("logic.ms", `export function label(): string {\n\treturn "v${step}";\n}\n`).ok) {
		console.log("HCR-NATIVE cannot write the edit");
		exit(1);
	}
	const deadline = performance.now() + 120000;
	let done = false;
	while (!done && performance.now() < deadline) {
		const kind = reload();
		if (kind == ReloadKind.Reloaded) {
			console.log(`HCR-NATIVE reloaded ${lastReload().modules.join(",")} ${label()}`);
			done = true;
		} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
			console.log(`HCR-NATIVE ${reloadKindName(kind)} ${lastReload().reason}`);
			done = true;
		} else {
			await sleepAsync(20);
		}
	}
	if (!done) console.log("HCR-NATIVE timed out");
}
