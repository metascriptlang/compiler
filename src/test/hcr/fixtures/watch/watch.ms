import { mkdir, writeFile } from "std/fs";
import { watch, nextChanges, closeWatch, msIoRunOnce, FsChanges, FsWatch } from "std/fs/watch";

function waitBatch(w: FsWatch): FsChanges {
	let got: FsChanges | null = null;
	nextChanges(w).then((c: FsChanges): void => { got = c; });
	const start = performance.now();
	while (got == null && performance.now() - start < 5000) msIoRunOnce(50);
	if (got == null) return { paths: [], rescan: false, ended: false };
	return got!;
}

function seenAfterWrite(w: FsWatch, root: string, name: string): boolean {
	writeFile(`${root}/${name}`, `export const name = "${name}";`);
	while (true) {
		const batch = waitBatch(w);
		if (batch.ended || (batch.paths.length == 0 && !batch.rescan)) return false;
		if (batch.rescan || batch.paths.includes(name)) return true;
	}
}

mkdir("tree");
mkdir("tree/sub");
const missing = watch("missing");
console.log(`WATCH missing: ${missing.ok ? "opened" : missing.error.message}`);
const opened = watch("tree");
if (!opened.ok) {
	console.log(`WATCH open: ${opened.error.message}`);
} else {
	const w = opened.value;
	console.log(`WATCH write before the first wait: ${seenAfterWrite(w, "tree", "first.ms")}`);
	console.log(`WATCH write in a subdirectory: ${seenAfterWrite(w, "tree", "sub/logic.ms")}`);
	closeWatch(w);
	console.log(`WATCH after close: ended ${waitBatch(w).ended}`);
}
mkdir("idle");
const idle = watch("idle");
if (idle.ok) {
	let armed: FsChanges | null = null;
	nextChanges(idle.value).then((c: FsChanges): void => { armed = c; });
	closeWatch(idle.value);
	const start = performance.now();
	while (armed == null && performance.now() - start < 5000) msIoRunOnce(50);
	console.log(`WATCH closed while waiting: ${armed == null ? "no completion" : `ended ${armed!.ended}`}`);
}
