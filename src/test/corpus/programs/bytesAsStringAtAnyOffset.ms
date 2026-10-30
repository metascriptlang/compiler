// @stdout: ascii 0 true
// @stdout: ascii 1 true
// @stdout: ascii 2 true
// @stdout: ascii 3 true
// @stdout: ascii 4 true
// @stdout: ascii 5 true
// @stdout: ascii 6 true
// @stdout: ascii 7 true
// @stdout: ascii 9 true
// @stdout: wide 0 true
// @stdout: wide 1 true
// @stdout: wide 2 true
// @stdout: wide 3 true
// @stdout: wide 4 true
// @stdout: wide 5 true
// @stdout: wide 6 true
// @stdout: wide 7 true
// @stdout: wide 9 true
// @stdout: short 3 true
// note: Readonly<Span<uint8>>.asString() decodes a view that starts at any byte offset; the ASCII word scan loads 8 bytes at an address that is not 8-aligned, which UBSan aborts in a debug C build.

function tail(view: Readonly<Span<uint8>>, from: int32): string {
	return view[from..view.length].asString();
}

const offsets = [0, 1, 2, 3, 4, 5, 6, 7, 9];

const ascii = "abcdefghijklmnopqrstuvwxyz0123456789";
const asciiBytes: Vec<uint8> = [...ascii.asBytes()];
for (const o of offsets) console.log(`ascii ${o} ${tail(asciiBytes, o) == ascii.slice(o)}`);

const wide = "abcdefghijklmnopéqrstuvwxyz€0123456789";
const wideBytes: Vec<uint8> = [...wide.asBytes()];
for (const o of offsets) console.log(`wide ${o} ${tail(wideBytes, o) == wide.slice(o)}`);

console.log(`short 3 ${tail(asciiBytes, 33) == "789"}`);
