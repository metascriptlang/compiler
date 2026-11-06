// @stdout: 3 2 1
// @exit: 0

import { Buffer } from "std/core/buffer";

function size<D extends string | uint8[]>(d: D): int64 {
	return typeof d == "string" ? d.asBytes().length : d.length;
}

function spelled(n: int32): uint8[] & { __brand: "Buffer" } {
	return Buffer.alloc(n);
}

async function later(n: int32): Promise<uint8[] & { __brand: "Buffer" }> {
	return Buffer.alloc(n);
}

const named: Buffer = Buffer.alloc(3);
console.log(size(named), size(spelled(2)), size(await later(1)));
