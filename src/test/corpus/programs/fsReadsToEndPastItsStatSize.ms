// @skip-js: std/process/child has no JS build
// @serial
// @stdout: fifo=ok:fed through a pipe procfs=ok empty=ok:0
// note: readFile reads to end of file instead of trusting the size stat reports. A FIFO reports no
//   size on every OS and a Linux procfs file reports 0; the first used to fail and the second read as
//   an empty ok. A host without procfs prints the procfs oracle unchanged.

import { readFile, writeFile, removeAll, mkdir, exists } from "std/fs";
import { spawn } from "std/process/child";
import { platform } from "std/process";

function procfsReads(): boolean {
	if (!exists("/proc/self/stat")) return true;
	const r = readFile("/proc/self/stat");
	return r.ok && r.value.length > 0;
}

function hostHasFifo(): boolean {
	return platform != "windows";
}

function fifoReads(dir: string): string {
	if (!hostHasFifo()) return "ok:fed through a pipe";
	const fifo = dir + "/pipe";
	const made = spawn("mkfifo", [fifo]);
	if (made.ok) made.value.wait(5000);
	const writer = spawn("sh", ["-c", `printf 'fed through a pipe' > ${fifo}`]);
	const r = readFile(fifo);
	if (writer.ok) writer.value.wait(5000);
	return r.ok ? `ok:${r.value}` : `err ${r.error.message}`;
}

function main(): void {
	const dir = "mscorpusReadToEnd.tmp";
	removeAll(dir);
	mkdir(dir);
	const fifoRead = fifoReads(dir);
	const empty = dir + "/empty.txt";
	writeFile(empty, "");
	const re = readFile(empty);
	const emptyRead = re.ok ? `ok:${re.value.length}` : "fail";
	console.log(`fifo=${fifoRead} procfs=${procfsReads() ? "ok" : "empty"} empty=${emptyRead}`);
	removeAll(dir);
}

main();
