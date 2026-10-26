// @xfail(raiser): error: Undefined variable 'Buffer'
// @stdout: ascii cases=1681 mismatches=0 accepted=41
// @stdout: utf8 cases=360 mismatches=0 accepted=120 signature=111111111100000000000000000000
// @stdout: reverse cases=97 mismatches=0
// @stdout: swap cases=105 mismatches=0

function bytesOf(values: int32[]): Buffer {
	const value = Buffer.alloc(values.length);
	for (let i = 0; i < values.length; i++) value.set(i, values[i]);
	return value;
}

function patterned(length: int32, salt: int32): Buffer {
	const value = Buffer.alloc(length);
	for (let i: int32 = 0; i < length; i++) value.set(i, (i * 73 + salt * 19 + 11) & 255);
	return value;
}

function asciiOracle(value: Buffer): boolean {
	for (let i: int32 = 0; i < value.byteLength(); i++) {
		if (value.byteAt(i) > 127) return false;
	}
	return true;
}

function checkAscii(): void {
	let cases: int32 = 0;
	let mismatches: int32 = 0;
	let accepted: int32 = 0;
	for (let length: int32 = 0; length <= 40; length++) {
		const clean = Buffer.alloc(length);
		for (let i: int32 = 0; i < length; i++) clean.set(i, 32 + (i % 90));
		for (let high: int32 = -1; high < length; high++) {
			for (const byte of [128, 255]) {
				if (high < 0 && byte == 255) continue;
				if (high >= 0) clean.set(high, byte);
				const got = Buffer.isAscii(clean);
				if (got != asciiOracle(clean)) mismatches += 1;
				if (got) accepted += 1;
				cases += 1;
				if (high >= 0) clean.set(high, 32 + (high % 90));
			}
		}
	}
	console.log(`ascii cases=${cases} mismatches=${mismatches} accepted=${accepted}`);
}

const UTF8_CASES: int32[][] = [
	[0x41],
	[0xC3, 0xA9],
	[0xE2, 0x82, 0xAC],
	[0xF0, 0x9F, 0x98, 0x80],
	[0xF4, 0x8F, 0xBF, 0xBF],
	[0xC2, 0x80],
	[0xDF, 0xBF],
	[0xE0, 0xA0, 0x80],
	[0xEF, 0xBF, 0xBF],
	[0xF0, 0x90, 0x80, 0x80],
	[0xC0, 0x80],
	[0xC1, 0xBF],
	[0xE0, 0x80, 0x80],
	[0xE0, 0x9F, 0xBF],
	[0xED, 0xA0, 0x80],
	[0xED, 0xBF, 0xBF],
	[0xF0, 0x80, 0x80, 0x80],
	[0xF0, 0x8F, 0xBF, 0xBF],
	[0xF4, 0x90, 0x80, 0x80],
	[0xF5, 0x80, 0x80, 0x80],
	[0xF8, 0x88, 0x80, 0x80, 0x80],
	[0xFF],
	[0x80],
	[0xBF],
	[0xC3],
	[0xE2, 0x82],
	[0xF0, 0x9F, 0x98],
	[0xC3, 0x41],
	[0xE2, 0x41, 0xAC],
	[0xF0, 0x9F, 0x41, 0x80],
];

function checkUtf8(): void {
	let cases: int32 = 0;
	let accepted: int32 = 0;
	let signature = "";
	for (const sequence of UTF8_CASES) {
		const alone = bytesOf(sequence);
		signature += Buffer.isUtf8(alone) ? "1" : "0";
		for (let prefix: int32 = 0; prefix < 12; prefix++) {
			const value = Buffer.alloc(prefix + sequence.length);
			for (let i: int32 = 0; i < prefix; i++) value.set(i, 0x61 + i);
			for (let i: int32 = 0; i < sequence.length; i++) value.set(prefix + i, sequence[i]);
			if (Buffer.isUtf8(value)) accepted += 1;
			cases += 1;
		}
	}
	const expected = "111111111100000000000000000000";
	const mismatches = signature == expected && accepted == 120 ? 0 : 1;
	console.log(`utf8 cases=${cases} mismatches=${mismatches} accepted=${accepted} signature=${signature}`);
}

function checkReverse(): void {
	let cases: int32 = 0;
	let mismatches: int32 = 0;
	const lengths: int32[] = [0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 32, 33, 255, 256, 257, 4097];
	for (let salt: int32 = 0; salt < 6; salt++) {
		for (const length of lengths) {
			if (salt > 0 && length > 300) continue;
			const value = patterned(length, salt);
			const original = patterned(length, salt);
			value.bufReverse();
			for (let i: int32 = 0; i < length; i++) {
				if (value.byteAt(i) != original.byteAt(length - 1 - i)) { mismatches += 1; break; }
			}
			cases += 1;
		}
	}
	console.log(`reverse cases=${cases} mismatches=${mismatches}`);
}

function swapOracle(value: Buffer, width: int32, index: int32): int32 {
	const base = index - index % width;
	return value.byteAt(base + width - 1 - index % width);
}

function checkSwap(): void {
	let cases: int32 = 0;
	let mismatches: int32 = 0;
	for (const width of [2, 4, 8]) {
		for (let words: int32 = 0; words <= 34; words++) {
			const length = words * width;
			const value = patterned(length, width);
			const original = patterned(length, width);
			if (width == 2) value.swap16();
			else if (width == 4) value.swap32();
			else value.swap64();
			for (let i: int32 = 0; i < length; i++) {
				if (value.byteAt(i) != swapOracle(original, width, i)) { mismatches += 1; break; }
			}
			cases += 1;
		}
	}
	console.log(`swap cases=${cases} mismatches=${mismatches}`);
}

checkAscii();
checkUtf8();
checkReverse();
checkSwap();
