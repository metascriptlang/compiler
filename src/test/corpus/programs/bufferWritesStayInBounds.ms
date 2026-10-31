// @stdout: 2 0 0
// @stdout: 2 44 7
// @stdout: 2 255 7
// @stdout: 2 7 7
// @stdout: 3 0 97 98
// @stdout: 2 0 0
// @stdout: 4 97 100
// A byte write outside a Buffer changes nothing and never grows it, on every backend: set, fills, writeUInt8 and write
// keep the length, a fractional index truncates, and the stored byte is the value modulo 256.
const b = Buffer.alloc(2);
b.set(5, 1);
b.set(-1, 1);
console.log(b.length, b[0], b[1]);
b.set(0, 300);
b.set(1.5, 7);
console.log(b.length, b[0], b[1]);
b.set(0, -1);
console.log(b.length, b[0], b[1]);

const filled = Buffer.alloc(2);
filled.fillBuffer(Buffer.fromArray([7]), 0, 5);
console.log(filled.length, filled[0], filled[1]);

const text = Buffer.alloc(3);
text.fillString("ab", 1, 9, "utf8");
console.log(text.length, text[0], text[1], text[2]);

const word = Buffer.alloc(2);
word.writeUInt8(1, 9);
console.log(word.length, word[0], word[1]);

const latin = Buffer.alloc(4);
latin.write("abcdefgh", 0, 8, "latin1");
console.log(latin.length, latin[0], latin[3]);
