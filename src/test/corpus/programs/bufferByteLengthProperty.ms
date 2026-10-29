// @xfail(raiser): error: Cannot resolve module 'std/core/buffer'
// @stdout: buffer 6 4 10 true false 2 12 6 4

import { Buffer } from "std/core/buffer";

function size(b: Buffer): number {
	return b.byteLength;
}

const text = Buffer.fromString("héllo", "utf8");
const zeros = Buffer.alloc(4);
const t: number = text.byteLength;
const z: number = zeros.byteLength;
const sum = text.byteLength + zeros.byteLength;
console.log(`buffer ${t} ${z} ${sum} ${text.byteLength > zeros.byteLength} ${zeros.byteLength == 0} ${text.byteLength - zeros.byteLength} ${zeros.byteLength * 3} ${text.byteLength()} ${size(zeros)}`);
