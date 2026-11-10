// @stdout: q 4 n 32
// @stdout: u8 4 buffer 32
// @exit: 0

// A `new` whose class declares constructor signatures ranks them on the arguments, then checks the
// arguments again for the one it picked; an argument read through a variable an `instanceof` test
// narrowed keeps that narrowing in the second check, as in any other call.

import { Buffer } from "std/core/buffer";

class Small { size: int32 = 4; }
class Wide { bits: int32 = 256; }

class Q {
	n: number;
	constructor();
	constructor(n: number);
	constructor(n: number = 0) {
		this.n = n;
	}
}

function viaSignature(ctx: Small | Wide): number {
	if (ctx instanceof Small) return new Q(ctx.size).n;
	return new Q(ctx.bits >> 3).n;
}

function viaTypedArray(ctx: Small | Wide): number {
	if (ctx instanceof Small) return new Uint8Array(ctx.size).length;
	return new Buffer(ctx.bits >> 3).length;
}

console.log(`q ${viaSignature(new Small())} n ${viaSignature(new Wide())}`);
console.log(`u8 ${viaTypedArray(new Small())} buffer ${viaTypedArray(new Wide())}`);
