// @skip-js: the js Buffer swaps the whole leading words of a partial-word buffer; the C Buffer leaves it unchanged
// @xfail(raiser): error: Undefined variable 'Buffer'
// @stdout: partial swap cases=71 unchanged=71

function patterned(length: int32): Buffer {
	const value = Buffer.alloc(length);
	for (let i: int32 = 0; i < length; i++) value.set(i, (i * 73 + 11) & 255);
	return value;
}

let cases: int32 = 0;
let unchanged: int32 = 0;
for (const width of [2, 4, 8]) {
	for (let length: int32 = 1; length <= 33; length++) {
		if (length % width == 0) continue;
		const value = patterned(length);
		if (width == 2) value.swap16();
		else if (width == 4) value.swap32();
		else value.swap64();
		let same = true;
		for (let i: int32 = 0; i < length; i++) {
			if (value.byteAt(i) != ((i * 73 + 11) & 255)) same = false;
		}
		if (same) unchanged += 1;
		cases += 1;
	}
}
console.log(`partial swap cases=${cases} unchanged=${unchanged}`);
