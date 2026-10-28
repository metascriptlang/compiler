// Parity program — std/fs text reads return valid text and binary reads keep every byte. An
// ill-formed UTF-8 sequence reads as one U+FFFD per maximal subpart on every backend (the way
// TextDecoder decodes), `readFileBytes` returns the file's bytes untouched, and `copyFile`
// copies bytes exactly. Before the change C returned the raw bytes inside a string and JS
// copied through a text decode.
// Workdir derives from argv[0] so concurrent lane cells never collide.
//
// @stdout: text length=9 units=61,fffd,62,fffd,fffd,fffd,fffd,fffd,7a
// @stdout: astral length=3 units=e9,d83d,de00
// @stdout: lines [78,fffd|79]
// @stdout: bytes length=10 61,ff,62,c3,e2,82,ed,a0,80,7a
// @stdout: all256 length=256 exact=true
// @stdout: copy exact=true
// @stdout: empty written=true text=0 bytes=0
// @stdout: proc ok=true
// @stdout: missing ok=false
// @skip-raiser: the byte reads take Buffer, which the Raiser tier has no type for
// @exit: 0

import { argv } from "std/process";
import {
	readFile, readFileBytes, readLines, writeFileBytes, copyFile, exists, mkdir, removeAll, basename, dirname,
} from "std/fs";

function units(text: string): string {
	const out: string[] = [];
	for (let i = 0; i < text.length; i++) out.push(text.charCodeAt(i).toString(16));
	return out.join(",");
}

function sameBytes(a: Buffer, b: Buffer): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
	return true;
}

const dir = "/tmp/mscorpusFsTextIsValid-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(dir);
mkdir(dir);

// a, FF, b, C3 cut by E2, E2 82 cut by ED, ED A0 80 (an encoded surrogate), z
const ill = Buffer.fromArray([0x61, 0xFF, 0x62, 0xC3, 0xE2, 0x82, 0xED, 0xA0, 0x80, 0x7A]);
const illPath = `${dir}/ill.txt`;
writeFileBytes(illPath, ill);
const text = readFile(illPath);
console.log(text.ok ? `text length=${text.value.length} units=${units(text.value)}` : "text err");

const astralPath = `${dir}/astral.txt`;
writeFileBytes(astralPath, Buffer.fromArray([0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80]));
const astral = readFile(astralPath);
console.log(astral.ok ? `astral length=${astral.value.length} units=${units(astral.value)}` : "astral err");

const linesPath = `${dir}/lines.txt`;
writeFileBytes(linesPath, Buffer.fromArray([0x78, 0xFF, 0x0A, 0x79]));
const lines = readLines(linesPath);
console.log(lines.ok ? `lines [${lines.value.map((line) => units(line)).join("|")}]` : "lines err");

const raw = readFileBytes(illPath);
if (raw.ok) {
	const shown: string[] = [];
	for (let i = 0; i < raw.value.length; i++) shown.push(raw.value[i].toString(16));
	console.log(`bytes length=${raw.value.length} ${shown.join(",")}`);
} else {
	console.log("bytes err");
}

const counted: number[] = [];
for (let i = 0; i < 256; i++) counted.push(i);
const everyByte = Buffer.fromArray(counted);
const allPath = `${dir}/all256.bin`;
writeFileBytes(allPath, everyByte);
const all = readFileBytes(allPath);
console.log(all.ok ? `all256 length=${all.value.length} exact=${sameBytes(all.value, everyByte)}` : "all256 err");

const copyPath = `${dir}/all256.copy`;
const copied = copyFile(allPath, copyPath);
const again = readFileBytes(copyPath);
console.log(`copy exact=${copied.ok && again.ok && sameBytes(again.value, everyByte)}`);

const emptyPath = `${dir}/empty.bin`;
const emptyWritten = writeFileBytes(emptyPath, Buffer.alloc(0));
const emptyText = readFile(emptyPath);
const emptyBytes = readFileBytes(emptyPath);
console.log(`empty written=${emptyWritten.ok} text=${emptyText.ok ? emptyText.value.length : -1} bytes=${emptyBytes.ok ? emptyBytes.value.length : -1}`);

const procFile = "/proc/self/status";
const proc = readFileBytes(procFile);
const procText = readFile(procFile);
console.log(`proc ok=${!exists(procFile) || (proc.ok && proc.value.length > 0 && procText.ok && procText.value.length > 0)}`);

console.log(`missing ok=${readFileBytes(`${dir}/missing`).ok}`);
removeAll(dir);
