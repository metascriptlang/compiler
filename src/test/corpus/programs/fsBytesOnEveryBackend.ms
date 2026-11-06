// Parity program — readFileBytes and writeFileBytes exist on every backend, the Raiser included,
// and carry a file's bytes unchanged. fsTextIsValidUtf8 pins ill-formed bytes but skips the
// Raiser for its Buffer constructors; this one builds no Buffer, so the Raiser cell runs.
// writeFileBytes takes a Readonly<Span<uint8>>, so a Uint8Array and its subarray write their own bytes with no copy.
// Workdir derives from argv[0] so concurrent lane cells never collide.
//
// @stdout: bytes length=6 61,c3,a9,e2,82,ac
// @stdout: copy length=6 same=true
// @stdout: typed 3,4,5 sub 4,5
// @stdout: missing ok=false
// @exit: 0

import { argv } from "std/process";
import { readFile, readFileBytes, writeFile, writeFileBytes, mkdir, removeAll, basename, dirname } from "std/fs";

const dir = "/tmp/mscorpusFsBytes-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(dir);
mkdir(dir);

const textPath = `${dir}/text.txt`;
writeFile(textPath, "aé€");
const bytes = readFileBytes(textPath);
if (bytes.ok) {
	const shown: string[] = [];
	for (let i = 0; i < bytes.value.length; i++) shown.push(bytes.value[i].toString(16));
	console.log(`bytes length=${bytes.value.length} ${shown.join(",")}`);
	const copyPath = `${dir}/copy.bin`;
	writeFileBytes(copyPath, bytes.value);
	const again = readFileBytes(copyPath);
	const original = readFile(textPath);
	const copied = readFile(copyPath);
	console.log(`copy length=${again.ok ? again.value.length : -1} same=${original.ok && copied.ok && original.value == copied.value}`);
} else {
	console.log("bytes err");
}

function listed(bytes: Readonly<Span<uint8>>): string {
	const shown: string[] = [];
	for (let i = 0; i < bytes.length; i++) shown.push(`${bytes[i]}`);
	return shown.join(",");
}

const typed = new Uint8Array(6);
for (let i = 0; i < 6; i++) typed[i] = i as uint8;
const typedPath = `${dir}/typed.bin`;
writeFileBytes(typedPath, typed.subarray(3, 6));
const typedBack = readFileBytes(typedPath);
writeFileBytes(typedPath, typed.subarray(4, 6));
const subBack = readFileBytes(typedPath);
console.log(`typed ${typedBack.ok ? listed(typedBack.value) : "err"} sub ${subBack.ok ? listed(subBack.value) : "err"}`);

console.log(`missing ok=${readFileBytes(`${dir}/missing`).ok}`);
removeAll(dir);
