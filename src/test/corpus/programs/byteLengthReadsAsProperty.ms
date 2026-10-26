// @stdout: 3 3 6 3 | 4 4 | 5 5 | 7 | 0
// note: byteLength on a Buffer, on a uint8[] and on a string is a number property, as on a node Buffer; on the raiser (and js) the extension method of the same name used to be returned as a function value, so `b.byteLength as int32` miscompiled.

class Chunk {
	byteLength: int32 = 7;
}

function lengthOf(b: Buffer): int32 {
	return b.byteLength as int32;
}

function bytesIn(a: uint8[]): int32 {
	return a.byteLength;
}

const b: Buffer = Buffer.alloc(3);
const bytes: uint8[] = [1, 2, 3, 4];
const text = "hello";
const empty: Buffer = Buffer.alloc(0);
console.log(`${b.byteLength} ${lengthOf(b)} ${b.byteLength * 2} ${b.byteLength()} | ${bytesIn(bytes)} ${bytes.byteLength} | ${text.byteLength} ${text.byteLength()} | ${new Chunk().byteLength} | ${empty.byteLength}`);
