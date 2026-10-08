// @stdout: present ok=20000 missing ok=0
// @skip-raiser
// note: a std/fs call reports its failure through the runtime's last-error slot, which
//   readFile reads right after the native call. The slot was one process-wide int, so a
//   spawn worker's successful read cleared another thread's error (a missing file read
//   as ok "") and a failing read flagged another thread's success. Measured on Windows
//   before the fix: about 270 of 20000 worker reads of a present file failed per run.
//   Workdir derives from argv[0] so concurrent lane cells never share a file.

import { argv } from "std/process";
import { readFile, writeFile, removeAll, ensureDir, basename, dirname } from "std/fs";

const dir = "/tmp/mscorpusFsErrno-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(dir);
ensureDir(dir);
writeFile(`${dir}/present.txt`, "x");

function readPresent(path: string): number {
	let n = 0;
	for (let i = 0; i < 5000; i++) {
		if (readFile(path).ok) n += 1;
	}
	return n;
}

const present = `${dir}/present.txt`;
const workers: Promise<number>[] = [];
for (let w = 0; w < 4; w++) workers.push(spawn(() => readPresent(present)));
let missingOk = 0;
for (let i = 0; i < 20000; i++) {
	if (readFile(`${dir}/missing.txt`).ok) missingOk += 1;
}
let presentOk: number = 0;
for (const w of workers) presentOk += await w;
removeAll(dir);
console.log(`present ok=${presentOk} missing ok=${missingOk}`);
