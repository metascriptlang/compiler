// @ledger-slack(msStringArrayRefCell): 2
// std/process argv module-init allocates 2 string arrays never destroyed at
// exit — TESTGAP T6 (probed: bare `import { argv }` program shows 2/0).
// Parity program — std fs I/O floor: write → stat → read roundtrip, append,
// copy, lines roundtrip, dir tree (ensureDir/readDir/rename/remove/removeAll),
// and the Result error path (readFile of a missing path → IoErrorKind).
// Workdir derives from basename(argv[0]) so concurrent lane cells (c/orc/
// danger) never collide; paths are never printed — output stays byte-equal.

import { argv } from "std/process";
import {
	readFile, writeFile, appendFile, copyFile, readLines, writeLines,
	exists, isFile, isDir, fileSize, mkdir, readDir, rename, remove,
	removeAll, ensureDir, basename,
} from "std/fs";
import { IoErrorKind } from "std/io/errors";

function main(): void {
	const dir = "/tmp/mscorpus507-" + basename(argv[0]);
	const ra = removeAll(dir);
	if (!ra.ok) { console.log("preclean=fail"); return; }
	const md = mkdir(dir);
	console.log("mkdir=" + (md.ok ? "ok" : "fail"));

	const f1 = dir + "/a.txt";
	const w = writeFile(f1, "hello\nworld");
	console.log("write=" + (w.ok ? "ok" : "fail"));
	console.log("exists=" + (exists(f1) ? "y" : "n"));
	console.log("isFile=" + (isFile(f1) ? "y" : "n"));
	console.log("isDirOnFile=" + (isDir(f1) ? "y" : "n"));
	console.log("size=" + fileSize(f1).toString());

	const r = readFile(f1);
	if (!r.ok) { console.log("read=fail"); return; }
	console.log("read=" + r.value);

	const ap = appendFile(f1, "!\n?");
	console.log("append=" + (ap.ok ? "ok" : "fail"));
	const r2 = readFile(f1);
	if (!r2.ok) { console.log("reread=fail"); return; }
	console.log("appended=" + r2.value.byteLength().toString());

	const f2 = dir + "/b.txt";
	const cp = copyFile(f1, f2);
	console.log("copy=" + (cp.ok ? "ok" : "fail"));
	const rc = readFile(f2);
	console.log("copyEq=" + (rc.ok && rc.value === r2.value ? "y" : "n"));

	const f3 = dir + "/lines.txt";
	const wl = writeLines(f3, ["alpha", "beta", "gamma"]);
	console.log("writeLines=" + (wl.ok ? "ok" : "fail"));
	const rl = readLines(f3);
	if (!rl.ok) { console.log("readLines=fail"); return; }
	console.log("lines=" + rl.value.length.toString() + ":" + rl.value.join("|"));

	const ed = ensureDir(dir + "/deep/nest");
	console.log("ensureDir=" + (ed.ok ? "ok" : "fail"));
	console.log("nestIsDir=" + (isDir(dir + "/deep/nest") ? "y" : "n"));

	const entries = readDir(dir);
	entries.sort();
	console.log("entries=" + entries.join(","));

	const f4 = dir + "/c.txt";
	const rn = rename(f2, f4);
	console.log("rename=" + (rn.ok ? "ok" : "fail"));
	console.log("oldGone=" + (exists(f2) ? "n" : "y"));
	console.log("newThere=" + (exists(f4) ? "y" : "n"));

	const rm = remove(f4);
	console.log("remove=" + (rm.ok ? "ok" : "fail"));
	console.log("removedGone=" + (exists(f4) ? "n" : "y"));

	const miss = readFile(dir + "/nope.txt");
	if (miss.ok) { console.log("missRead=unexpected"); return; }
	console.log("missKind=" + (miss.error.kind === IoErrorKind.NotFound ? "notFound" : "other"));

	const fin = removeAll(dir);
	console.log("cleanup=" + (fin.ok ? "ok" : "fail"));
	console.log("dirGone=" + (exists(dir) ? "n" : "y"));
}

main();
