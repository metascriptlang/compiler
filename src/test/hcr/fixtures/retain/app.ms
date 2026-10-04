import { readFile, writeFile } from "std/fs";
import { exit } from "std/process";
import { reload, lastReload, ReloadKind } from "std/hcr";
import { work } from "./logic";

function install(name: string): void {
	const edit = readFile(name);
	if (!edit.ok || !writeFile("logic.ms", edit.value).ok) {
		console.log(`RETAIN cannot install ${name}`);
		exit(1);
	}
}

const edits = ["e1.txt", "e2.txt", "e3.txt"];
let next = 0;
console.log(`RETAIN start ${work(1)}`);
install(edits[next]);
const deadline = performance.now() + 180000;
let done = false;
while (!done && performance.now() < deadline) {
	const kind = reload();
	if (kind == ReloadKind.Reloaded) {
		const r = lastReload();
		console.log(`RETAIN gen ${r.generations} ${r.retainedBytes > 0 ? "bytes" : "none"} ${work(1)}`);
		next += 1;
		if (next < edits.length) install(edits[next]); else done = true;
	} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
		console.log(`RETAIN unexpected ${lastReload().reason}`);
		done = true;
	} else {
		await sleepAsync(20);
	}
}
if (!done) console.log("RETAIN timed out");
