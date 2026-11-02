// Parity program: a sized `new Array<T>(n)` and Buffer.alloc are zero-filled, exactly n long and
// still growable; bytes written through fs and read back are unchanged at 0, 1 and 65536 bytes
// (on js that is the Array to Uint8Array and back conversion pair).
//
// @stdout: alloc 0 1 65536 zero=true
// @stdout: bytes 0 1 65536 zero=true
// @stdout: numbers 0 1 70000 zero=true
// @stdout: grow 65537 7 0
// @stdout: round 0 0 true
// @stdout: round 1 1 true
// @stdout: round 65536 65536 true
// @exit: 0

import { Buffer } from "std/core/buffer";
import { argv } from "std/process";
import { readFileBytes, writeFileBytes, mkdir, removeAll, basename, dirname } from "std/fs";

function allZero(b: Buffer): boolean {
	for (let i = 0; i < b.length; i++) if (b[i] != 0) return false;
	return true;
}
function allZeroBytes(b: uint8[]): boolean {
	for (let i = 0; i < b.length; i++) if (b[i] != 0) return false;
	return true;
}
function allZeroNumbers(b: number[]): boolean {
	for (let i = 0; i < b.length; i++) if (b[i] != 0) return false;
	return true;
}

const a0 = Buffer.alloc(0);
const a1 = Buffer.alloc(1);
const big = Buffer.alloc(65536);
console.log(`alloc ${a0.length} ${a1.length} ${big.length} zero=${allZero(a0) && allZero(a1) && allZero(big)}`);

const b0 = new Array<uint8>(0);
const b1 = new Array<uint8>(1);
const bigBytes = new Array<uint8>(65536);
console.log(`bytes ${b0.length} ${b1.length} ${bigBytes.length} zero=${allZeroBytes(b0) && allZeroBytes(b1) && allZeroBytes(bigBytes)}`);

const n0 = new Array<number>(0);
const n1 = new Array<number>(1);
const nBig = new Array<number>(70000);
console.log(`numbers ${n0.length} ${n1.length} ${nBig.length} zero=${allZeroNumbers(n0) && allZeroNumbers(n1) && allZeroNumbers(nBig)}`);

big.push(7);
console.log(`grow ${big.length} ${big[65536]} ${big[0]}`);

const dir = "/tmp/mscorpusBufferRoundTrip-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(dir);
mkdir(dir);
for (const size of [0, 1, 65536]) {
	const src = Buffer.alloc(size);
	for (let i = 0; i < size; i++) src[i] = ((i * 7 + 3) & 255) as uint8;
	const path = `${dir}/b${size}.bin`;
	writeFileBytes(path, src);
	const back = readFileBytes(path);
	let same = back.ok && back.value.length == size;
	if (back.ok) for (let i = 0; i < size; i++) if (back.value[i] != src[i]) same = false;
	console.log(`round ${size} ${back.ok ? back.value.length : -1} ${same}`);
}
removeAll(dir);
