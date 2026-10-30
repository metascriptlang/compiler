// Parity program — readFile at the edges of the 8-byte ASCII word scan and of the direct read
// into the string: lengths around a word, an ill-formed byte at offset 7, 8 and 9, and a 4-byte
// sequence starting at every offset around a word boundary read as the expected text.
// Workdir derives from argv[0] so concurrent lane cells never collide.
//
// @stdout: ascii ok=true
// @stdout: fault ok=true
// @stdout: straddle ok=true
// @stdout: empty length=0
// @skip-raiser: the byte writes take Buffer, which the Raiser tier has no type for
// @exit: 0

import { argv } from "std/process";
import { readFile, writeFileBytes, mkdir, removeAll, basename, dirname } from "std/fs";

const dir = "/tmp/mscorpusFsWordBoundaries-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(dir);
mkdir(dir);
const path = `${dir}/probe.txt`;

function readUnits(bytes: number[]): number[] | null {
	if (!writeFileBytes(path, Buffer.fromArray(bytes)).ok) return null;
	const text = readFile(path);
	if (!text.ok) return null;
	const units: number[] = [];
	for (let i = 0; i < text.value.length; i++) units.push(text.value.charCodeAt(i));
	return units;
}

function pushAll(into: number[], values: number[]): void {
	for (const value of values) into.push(value);
}

function same(a: number[] | null, b: number[]): boolean {
	if (a == null || a.length != b.length) return false;
	for (let i = 0; i < b.length; i++) if (a[i] != b[i]) return false;
	return true;
}

let asciiOk = true;
for (let size = 1; size <= 20; size++) {
	const bytes: number[] = [];
	for (let i = 0; i < size; i++) bytes.push(0x61 + (i % 26));
	if (!same(readUnits(bytes), bytes)) asciiOk = false;
}
console.log(`ascii ok=${asciiOk}`);

let faultOk = true;
for (let size = 12; size <= 17; size++) {
	for (let at = 0; at < size; at++) {
		const bytes: number[] = [];
		const expected: number[] = [];
		for (let i = 0; i < size; i++) {
			bytes.push(i == at ? 0xFF : 0x61 + (i % 26));
			expected.push(i == at ? 0xFFFD : 0x61 + (i % 26));
		}
		if (!same(readUnits(bytes), expected)) faultOk = false;
	}
}
console.log(`fault ok=${faultOk}`);

let straddleOk = true;
for (let size = 12; size <= 20; size++) {
	for (let at = 0; at + 4 <= size; at++) {
		const bytes: number[] = [];
		const expected: number[] = [];
		for (let i = 0; i < size; i++) {
			if (i == at) {
				pushAll(bytes, [0xF0, 0x9F, 0x98, 0x80]);
				pushAll(expected, [0xD83D, 0xDE00]);
				i += 3;
			} else {
				bytes.push(0x61 + (i % 26));
				expected.push(0x61 + (i % 26));
			}
		}
		if (!same(readUnits(bytes), expected)) straddleOk = false;
		const cut: number[] = [];
		const cutExpected: number[] = [];
		for (let i = 0; i < size; i++) {
			if (i == at) {
				pushAll(cut, [0xF0, 0x9F, 0x98]);
				cutExpected.push(0xFFFD);
				i += 2;
			} else {
				cut.push(0x61 + (i % 26));
				cutExpected.push(0x61 + (i % 26));
			}
		}
		if (!same(readUnits(cut), cutExpected)) straddleOk = false;
	}
}
console.log(`straddle ok=${straddleOk}`);

const empty = readUnits([]);
console.log(`empty length=${empty == null ? -1 : empty.length}`);
removeAll(dir);
