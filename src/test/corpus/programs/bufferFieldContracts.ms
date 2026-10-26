// @skip-js: the js Buffer throws or reads undefined outside the bounds; the C Buffer returns 0 or the offset and writes nothing
// @xfail(raiser): error: Undefined variable 'Buffer'
// @stdout: bounds entries=1620 digest=484407731
// @stdout: byteLength rejects=96 rejectedMessages=96 accepted=48 unexpected=0 untouched=true
// @stdout: search entries=264 digest=713819505
// @stdout: ranges entries=224 digest=615181003
// @stdout: strings entries=2880 digest=331562034

let log = "";
let entries: int32 = 0;

function note(value: number): void {
	log += `${value},`;
	entries += 1;
}

function noteBytes(value: Buffer): void {
	for (let i: int32 = 0; i < value.byteLength(); i++) log += `${value.byteAt(i)}.`;
	log += ";";
	entries += 1;
}

function section(name: string): void {
	let digest: number = 0;
	for (let i: int32 = 0; i < log.length; i++) digest = (digest * 131 + log.charCodeAt(i)) % 1000000007;
	console.log(`${name} entries=${entries} digest=${digest}`);
	log = "";
	entries = 0;
}

function patterned(length: int32, salt: int32): Buffer {
	const value = Buffer.alloc(length);
	for (let i: int32 = 0; i < length; i++) value.set(i, (i * 73 + salt * 19 + 11) & 255);
	return value;
}

const OFFSETS: number[] = [-9, -1, -0.5, 0, 0.75, 2.5, 3, 4, 5, 6, 7, 8, 9, 100, 4611686018427387904];

function checkFieldBounds(): void {
	for (const length of [0, 1, 4, 8]) {
		const value = patterned(length, 1);
		for (const at of OFFSETS) {
			note(value.readUInt8(at));
			note(value.readInt8(at));
			note(value.readUInt16LE(at));
			note(value.readInt16BE(at));
			note(value.readUInt32BE(at));
			note(value.readInt32LE(at));
			note(value.readFloatLE(at));
			note(value.readDoubleBE(at));
			log += `${value.readBigUInt64LE(at)} ${value.readBigInt64BE(at)};`;
			for (const width of [1, 2, 6]) {
				note(value.readUIntLE(at, width));
				note(value.readIntBE(at, width));
			}
			const out = patterned(length, 2);
			note(out.writeUInt8(511, at));
			note(out.writeInt16LE(-2, at));
			note(out.writeUInt32BE(4294967296 + 258, at));
			note(out.writeDoubleLE(1.25, at));
			note(out.writeFloatBE(-3.5, at));
			note(out.writeBigInt64LE(-3n, at));
			for (const width of [1, 3, 6]) {
				note(out.writeUIntBE(258, at, width));
				note(out.writeIntLE(-258, at, width));
			}
			out.set(at, 300);
			noteBytes(out);
		}
	}
	section("bounds");
}

function checkSearchBounds(): void {
	const empty = Buffer.alloc(0);
	const hay = patterned(12, 3);
	const needle = Buffer.alloc(3);
	hay.copyTo(needle, 0, 4, 7);
	for (const from of [-20, -1, 0, 3.9, 4, 5, 9, 10, 11, 12, 1000]) {
		for (const byte of [hay.byteAt(4), hay.byteAt(11), 256 + hay.byteAt(0), -1]) {
			note(hay.indexOf(byte, from));
			note(hay.lastIndexOf(byte, from));
			note(empty.indexOf(byte, from));
			note(empty.lastIndexOf(byte, from));
		}
		note(hay.indexOfBuffer(needle, from));
		note(hay.lastIndexOfBuffer(needle, from));
		note(hay.indexOfBuffer(empty, from));
		note(hay.lastIndexOfBuffer(empty, from));
		note(empty.indexOfBuffer(empty, from));
		note(empty.lastIndexOfBuffer(needle, from));
		note(needle.indexOfBuffer(hay, from));
		note(needle.lastIndexOfBuffer(hay, from));
	}
	section("search");
}

function checkRangeBounds(): void {
	const ranges: number[][] = [[-5, 3], [2, 2], [5, 2], [3, 100], [-1, -1], [1.5, 4.5], [0, 12]];
	for (const range of ranges) {
		const out = patterned(12, 4);
		out.fill(258, range[0], range[1]);
		noteBytes(out);
		out.fillBuffer(patterned(1, 5), range[0], range[1]);
		noteBytes(out);
		out.fillBuffer(patterned(5, 6), range[0], range[1]);
		noteBytes(out);
		out.fillBuffer(Buffer.alloc(0), range[0], range[1]);
		noteBytes(out);
		for (const encoding of ["hex", "HEX", "hexadecimal", "base64", "base64url", "utf8", ""]) {
			out.fillString("a", range[0], range[1], encoding);
			noteBytes(out);
			out.fillString("QUJD", range[0], range[1], encoding);
			noteBytes(out);
			out.fillString("", range[0], range[1], encoding);
			noteBytes(out);
		}
		const target = patterned(8, 7);
		note(out.copyTo(target, range[0], range[0], range[1]));
		note(out.copyTo(target, range[1], 0, 12));
		note(Buffer.alloc(0).copyTo(target, 0, 0, 5));
		note(out.copyTo(Buffer.alloc(0), 0, 0, 5));
		noteBytes(target);
		note(target.copyTo(target, 2, 0, 6));
		noteBytes(target);
	}
	section("ranges");
}

function checkWriteBounds(): void {
	const encodings: string[] = ["utf8", "UTF-8", "utf8x", "latin1", "Binary", "ascii", "hex", "Hex", "base64", "base64url", "ucs2", ""];
	const texts: string[] = ["", "héllo€", "QUJDRA==", "00ff7Gab", "Q", "Q="];
	for (const encoding of encodings) {
		for (const text of texts) {
			for (const at of [-1, 0, 2.5, 7, 8]) {
				for (const limit of [-1, 0, 3, 100]) {
					const out = patterned(8, 8);
					note(out.write(text, at, limit, encoding));
					noteBytes(out);
				}
			}
		}
	}
	section("strings");
}

function checkByteLength(): void {
	const reads: ((value: Buffer, width: number) => number)[] = [
		(value, width) => value.readUIntLE(2, width),
		(value, width) => value.readUIntBE(2, width),
		(value, width) => value.readIntLE(2, width),
		(value, width) => value.readIntBE(2, width),
	];
	const writes: ((value: Buffer, width: number) => number)[] = [
		(value, width) => value.writeUIntLE(1, 2, width),
		(value, width) => value.writeUIntBE(1, 2, width),
		(value, width) => value.writeIntLE(-1, 2, width),
		(value, width) => value.writeIntBE(-1, 2, width),
	];
	let rejects: int32 = 0;
	let rejectedMessages: int32 = 0;
	let accepted: int32 = 0;
	let unexpected: int32 = 0;
	let untouched = true;
	for (const length of [0, 8]) {
		for (const call of reads.concat(writes)) {
			for (const width of [-1, 0, 7, 2.5, NaN, Infinity]) {
				const value = patterned(length, 9);
				const before = patterned(length, 9);
				try {
					call(value, width);
				} catch (error) {
					rejects += 1;
					if (error.message.startsWith('The value of "byteLength" is out of range. It must be ')) {
						rejectedMessages += 1;
					}
				}
				if (value != before) untouched = false;
			}
			for (const width of [1, 3, 6]) {
				try {
					call(patterned(length, 9), width);
					accepted += 1;
				} catch (error) {
					unexpected += 1;
				}
			}
		}
	}
	console.log(
		`byteLength rejects=${rejects} rejectedMessages=${rejectedMessages} accepted=${accepted} unexpected=${unexpected} untouched=${untouched}`,
	);
}

checkFieldBounds();
checkByteLength();
checkSearchBounds();
checkRangeBounds();
checkWriteBounds();
