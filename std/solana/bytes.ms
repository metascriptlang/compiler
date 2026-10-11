export struct Bytes {
	address: uint64;
	length: uint64;
}

export function isUtf8(bytes: Readonly<Span<uint8>>, length: int32): boolean {
	let at = 0;
	while (at < length) {
		const lead = bytes[at];
		if (lead < 0x80) { at = at + 1; continue; }
		let width = 0;
		let low: uint8 = 0x80;
		let high: uint8 = 0xbf;
		if (lead >= 0xc2 && lead <= 0xdf) { width = 2; }
		else if (lead >= 0xe0 && lead <= 0xef) {
			width = 3;
			if (lead == 0xe0) { low = 0xa0; }
			if (lead == 0xed) { high = 0x9f; }
		} else if (lead >= 0xf0 && lead <= 0xf4) {
			width = 4;
			if (lead == 0xf0) { low = 0x90; }
			if (lead == 0xf4) { high = 0x8f; }
		} else { return false; }
		if (at + width > length) { return false; }
		if (bytes[at + 1] < low || bytes[at + 1] > high) { return false; }
		for (let next = 2; next < width; next++) {
			if (bytes[at + next] < 0x80 || bytes[at + next] > 0xbf) { return false; }
		}
		at = at + width;
	}
	return true;
}

function utf8Of(values: uint8[], length: int32): boolean {
	const padded: uint8[] = new Array(8);
	for (let i = 0; i < values.length; i++) { padded[i] = values[i]; }
	return isUtf8(padded, length);
}

test "isUtf8 accepts ASCII and well-formed two, three and four byte sequences" {
	assert utf8Of([0x68, 0x69], 2);
	assert utf8Of([0xc2, 0x80], 2);
	assert utf8Of([0xdf, 0xbf], 2);
	assert utf8Of([0xe0, 0xa0, 0x80], 3);
	assert utf8Of([0xed, 0x9f, 0xbf], 3);
	assert utf8Of([0xef, 0xbf, 0xbf], 3);
	assert utf8Of([0xf0, 0x90, 0x80, 0x80], 4);
	assert utf8Of([0xf4, 0x8f, 0xbf, 0xbf], 4);
	assert utf8Of([0x61, 0xc3, 0xa9, 0xe2, 0x82, 0xac], 6);
}

test "isUtf8 refuses overlong forms, surrogates, values above U+10FFFF and stray bytes" {
	assert !utf8Of([0xc0, 0x80], 2);
	assert !utf8Of([0xc1, 0xbf], 2);
	assert !utf8Of([0xe0, 0x80, 0x80], 3);
	assert !utf8Of([0xf0, 0x80, 0x80, 0x80], 4);
	assert !utf8Of([0xed, 0xa0, 0x80], 3);
	assert !utf8Of([0xf4, 0x90, 0x80, 0x80], 4);
	assert !utf8Of([0xf5, 0x80, 0x80, 0x80], 4);
	assert !utf8Of([0x80], 1);
	assert !utf8Of([0xff], 1);
	assert !utf8Of([0xc2, 0x41], 2);
	assert !utf8Of([0xe2, 0x82, 0x41], 3);
}

test "isUtf8 refuses a sequence cut at the length boundary and ignores bytes past it" {
	assert !utf8Of([0xc3, 0xa9], 1);
	assert !utf8Of([0xe2, 0x82, 0xac], 2);
	assert !utf8Of([0xf0, 0x9f, 0x98, 0x80], 3);
	assert utf8Of([0x61, 0xc3, 0xa9], 3);
	assert utf8Of([0x61, 0xff, 0xff], 1);
	assert utf8Of([0x61, 0xc3, 0xa9, 0x80], 3);
}

test "isUtf8 accepts length 0 whatever the bytes hold" {
	assert utf8Of([0xff, 0xff], 0);
}
