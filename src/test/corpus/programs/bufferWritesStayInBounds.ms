// @stdout: 2 0 0
// @stdout: 2 44 7
// @stdout: 2 255 7
// @stdout: 2 7 7
// @stdout: 3 0 97 98
// @stdout: The value of "offset" is out of range. It must be >= 0 and <= 1. Received 9
// @stdout: 2 0 0
// @stdout: 4 97 100
// A byte write never grows a Buffer, on every backend: fills and write past the end keep the length, a fractional index
// truncates, `as uint8` keeps the value modulo 256, and writeUInt8 throws Node's RangeError. An indexed store outside the
// buffer stops like an array index does (std/core/typed/index.cms), so it has no line here.
const b = Buffer.alloc(2);
console.log(b.length, b[0], b[1]);
const big: int32 = 300;
b[0] = big as uint8;
b[1.5] = 7;
console.log(b.length, b[0], b[1]);
const minus: int32 = -1;
b[0] = minus as uint8;
console.log(b.length, b[0], b[1]);

const filled = Buffer.alloc(2);
filled.fillBuffer(Buffer.fromArray([7]), 0, 5);
console.log(filled.length, filled[0], filled[1]);

const text = Buffer.alloc(3);
text.fillString("ab", 1, 9, "utf8");
console.log(text.length, text[0], text[1], text[2]);

const word = Buffer.alloc(2);
try {
	word.writeUInt8(1, 9);
} catch (e) {
	console.log((e as Error).message);
}
console.log(word.length, word[0], word[1]);

const latin = Buffer.alloc(4);
latin.write("abcdefgh", 0, 4, "latin1");
console.log(latin.length, latin[0], latin[3]);
