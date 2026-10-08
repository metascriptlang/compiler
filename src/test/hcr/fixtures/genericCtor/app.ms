import { readFile, writeFile } from "std/fs";
import { reload, lastReload, ReloadKind } from "std/hcr";
import { left } from "./left";
import { right } from "./right";

when (hcr) {
	console.log("GENERIC before " + left() + " " + right());
	const edit = readFile("boxEdit.txt");
	if (!edit.ok || !writeFile("box.ms", edit.value).ok) throw new Error("cannot install constructor edit");
	const deadline = performance.now() + 60000;
	let changed = false;
	while (!changed && performance.now() < deadline) {
		const kind = reload();
		if (kind == ReloadKind.Reloaded) {
			changed = true;
			console.log("GENERIC after " + left() + " " + right());
		} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
			throw new Error("generic constructor reload failed: " + lastReload().reason);
		} else {
			await sleepAsync(20);
		}
	}
	if (!changed) throw new Error("generic constructor reload timed out");
} else {
	console.log("GENERIC plain " + left() + " " + right());
}
