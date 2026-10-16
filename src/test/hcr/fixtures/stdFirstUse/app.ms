import { readFile, writeFile } from "std/fs";
import { exit, platform } from "std/process";
import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { label } from "./logic";

const ext = platform == "windows" ? ".dll" : platform == "darwin" ? ".dylib" : ".so";
const corePath = `out/hcr/app.core${ext}`;
const initialCore = readFile(corePath);
if (!initialCore.ok) exit(1);
console.log(`HCR-STD start ${label()}`);
for (const edit of ["upper.txt", "error.txt", "path.txt", "hash.txt", "blake.txt", "ed25519.txt", "deflate.txt", "inflate.txt", "json.txt", "watch.txt"]) {
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
			const currentCore = readFile(corePath);
			if (!currentCore.ok || currentCore.value != initialCore.value) {
				console.log("HCR-STD core bytes changed");
				exit(1);
			}
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
