// @stdout: built length=4 71,30,c3,a9
// @stdout: file length=6 first=61
// @skip-js
// note: a Buffer made from text owns its bytes, so it stays whole after the text it came from is released and its memory reused, whether the text was built in a routine or read from a file.

import { Buffer } from "std/core/buffer";
import { rawBuffer } from "std/core/buffer/bytes";
import { readFileBytes, writeFile, removeAll, mkdir, basename, dirname } from "std/fs";
import { argv } from "std/process";

function churn(): int32 {
	const junk: string[] = [];
	for (let i = 0; i < 64; i++) junk.push("x" + i.toString() + "y");
	const rows: int32[][] = [];
	for (let i = 0; i < 64; i++) rows.push([i, i, i, i, i, i]);
	return junk.length + rows.length;
}

function bytesOf(n: int32): Buffer {
	const text = "q" + n.toString() + "é";
	return rawBuffer(text);
}

const built = bytesOf(0);
churn();
const shown: string[] = [];
for (let i = 0; i < built.length; i++) shown.push(built[i].toString(16));
console.log(`built length=${built.length} ${shown.join(",")}`);

const dir = "/tmp/mscorpusRawBuffer-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(dir);
mkdir(dir);
writeFile(`${dir}/text.txt`, "aé€");
const read = readFileBytes(`${dir}/text.txt`);
churn();
console.log(`file length=${read.ok ? read.value.length : -1} first=${read.ok && read.value.length > 0 ? read.value[0].toString(16) : "none"}`);
removeAll(dir);
