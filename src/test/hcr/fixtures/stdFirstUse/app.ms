import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { label } from "./logic";

console.log(`HCR-STD start ${label()}`);
for (const edit of ["upper.txt", "error.txt", "path.txt"]) {
	const source = readFile(edit);
	if (!source.ok || !writeFile("logic.ms", source.value).ok) {
		console.log(`HCR-STD cannot apply ${edit}`);
		exit(1);
	}
	const deadline = performance.now() + 120000;
	let done = false;
	while (!done && performance.now() < deadline) {
		const kind = reload();
		if (kind == ReloadKind.Reloaded) {
			console.log(`HCR-STD reloaded ${label()}`);
			done = true;
		} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
			console.log(`HCR-STD ${reloadKindName(kind)} ${lastReload().reason}`);
			exit(0);
		} else {
			await sleepAsync(20);
		}
	}
	if (!done) {
		console.log(`HCR-STD timed out on ${edit}`);
		exit(0);
	}
}
