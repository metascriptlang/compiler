// @stdout: read hello
// @stdout: missing true
// @stdout: lines 2 one two
// @stdout: missing lines true
// note: the string a readFile result carries, the path and message of its error, and the strings of a readLines result are each released once with the result, on the success and the failure path.

import { argv } from "std/process";
import { readFile, readLines, writeFile, remove, basename, dirname } from "std/fs";

function main(): void {
	const base = "/tmp/mscorpusFsText-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
	const file = base + ".txt";
	writeFile(file, "hello");
	const r = readFile(file);
	console.log("read " + (r.ok ? r.value : "fail"));
	const m = readFile(base + ".absent");
	console.log("missing " + (m.ok ? "false" : (m.error.message.length > 0 ? "true" : "empty")));
	writeFile(file, "one\ntwo");
	const l = readLines(file);
	console.log("lines " + (l.ok ? l.value.length.toString() + " " + l.value[0] + " " + l.value[1] : "fail"));
	const ml = readLines(base + ".absent");
	console.log("missing lines " + (ml.ok ? "false" : "true"));
	remove(file);
}

main();
