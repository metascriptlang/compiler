// @stdout: 1
// @stdout: 2 2
// @stdout: 305419896 6
// @stdout: 3 104 33
// @stdout: 4 -2
// note: a Buffer has a fixed length as in Node; the growable byte array is uint8[], and Buffer.from copies it once grown.
const raw: uint8[] = [1, 0, 0, 0];
console.log(Buffer.from(raw).readUInt32LE(0));

const grown: uint8[] = [1];
grown.push(2);
const grownBuf = Buffer.from(grown);
console.log(grownBuf.length, grownBuf[1]);

const word = Buffer.alloc(4);
word.writeUInt32LE(0x12345678, 0);
const wordBytes: uint8[] = [...word];
wordBytes.push(9);
wordBytes.push(7);
console.log(Buffer.from(wordBytes).readUInt32LE(0), wordBytes.length);

const text: uint8[] = [...Buffer.fromString("hi", "utf8")];
text.push(33);
console.log(text.length, text[0], text[2]);

const signed = Buffer.alloc(2);
signed.writeInt16BE(-2, 0);
const signedBytes: uint8[] = [...signed];
signedBytes.push(1);
signedBytes.push(2);
console.log(signedBytes.length, Buffer.from(signedBytes).readInt16BE(0));
