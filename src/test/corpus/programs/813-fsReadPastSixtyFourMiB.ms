// @stdout: size=67108868 read=67108868 tail=tail empty=ok:0
// @serial

// readFile returns the whole file past 64 MiB, where the C runtime used to return an empty
// string with no error, and an empty file still reads as an empty string.

import { readFile, writeFile, fileSize, removeAll, mkdir } from "std/fs";

function main(): void {
	const dir = "mscorpus813.tmp";
	removeAll(dir);
	mkdir(dir);
	const big = dir + "/big.bin";
	let body = "0123456789abcdef";
	for (let i = 0; i < 22; i++) body = body + body;
	writeFile(big, body + "tail");
	const r = readFile(big);
	const n = r.ok ? r.value.length : -1;
	const tail = r.ok ? r.value.slice(n - 4, n) : "-";
	const empty = dir + "/empty.txt";
	writeFile(empty, "");
	const re = readFile(empty);
	const emptyRead = re.ok ? `ok:${re.value.length}` : "fail";
	console.log(`size=${fileSize(big)} read=${n} tail=${tail} empty=${emptyRead}`);
	removeAll(dir);
}

main();
