// @stdout: 1
// @stdout: 2 2
// @stdout: 305419896 6
// @stdout: 3 104 33
// @stdout: 4 -2
const raw: uint8[] = [1, 0, 0, 0];
console.log(raw.readUInt32LE(0));

const grown = Buffer.fromArray([1]);
grown.push(2);
console.log(grown.length, grown[1]);

const word = Buffer.alloc(4);
word.writeUInt32LE(0x12345678, 0);
word.push(9);
word.push(7);
console.log(word.readUInt32LE(0), word.length);

const text = Buffer.fromString("hi", "utf8");
text.push(33);
console.log(text.length, text[0], text[2]);

const signed = Buffer.alloc(2);
signed.writeInt16BE(-2, 0);
signed.push(1);
signed.push(2);
console.log(signed.length, signed.readInt16BE(0));
