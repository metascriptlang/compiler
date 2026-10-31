// @stdout: comptime 4 97 98 0 255
// @stdout: runtime 4 97 98 0 255
// @stdout: after-invalid 9 0 255 195 40 0 128 10 13 127
// @stdout: empty 0
// @stdout: every-byte 256 same true
import { readFileBytes, writeFileBytes, remove } from "std/fs";

function roundTrip(path: string, bytes: uint8[]): string {
	const written = writeFileBytes(path, bytes);
	if (!written.ok) return "write failed";
	const blob = readFileBytes(path);
	remove(path);
	if (!blob.ok) return "read failed";
	let text = `${blob.value.length}`;
	for (const b of blob.value) text += ` ${b}`;
	return text;
}

const atCompileTime = @comptime { return roundTrip("readFileBytesKeepsRawBytes.comptime.bin", [97, 98, 0, 255]); };
console.log(`comptime ${atCompileTime}`);
console.log(`runtime ${roundTrip("readFileBytesKeepsRawBytes.runtime.bin", [97, 98, 0, 255])}`);
console.log(`after-invalid ${roundTrip("readFileBytesKeepsRawBytes.invalid.bin", [0, 255, 195, 40, 0, 128, 10, 13, 127])}`);
console.log(`empty ${roundTrip("readFileBytesKeepsRawBytes.empty.bin", [])}`);

const every: uint8[] = [];
for (let i = 0; i < 256; i++) every.push(i as uint8);
const everyBack = roundTrip("readFileBytesKeepsRawBytes.every.bin", every);
let expected = "256";
for (const b of every) expected += ` ${b}`;
console.log(`every-byte ${everyBack.split(" ")[0]} same ${everyBack == expected}`);
