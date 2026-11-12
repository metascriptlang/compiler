// @stdout: 30 77 9 65535 5
// note: an index into a fixed array that cannot leave it (a constant inside the array, a uint8 into 256 or more elements, a uint16 into 65536 or more) is read and written without a run-time check and gives the same values as a checked one.

let small: int32[3] = [10, 20, 30];
let bytes: uint32[256] = [];
let words: uint16[65536] = [];

function byByte(b: uint8): uint32 {
	return bytes[b];
}

function byWord(w: uint16): uint16 {
	return words[w];
}

function lastSmall(): int32 {
	return small[2];
}

for (let i = 0; i < 256; i++) bytes[i] = (i as uint32) * 7 + 2;
for (let i = 0; i < 65536; i++) words[i] = i as uint16;
small[1] = 5;
bytes[1] = 9;

console.log(`${lastSmall()} ${byByte(255) - 1710} ${byByte(1)} ${byWord(65535)} ${small[1]}`);
