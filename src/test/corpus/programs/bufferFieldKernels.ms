// @xfail(raiser): error: Undefined variable 'Buffer'
// @stdout: reads entries=1710 digest=339260849
// @stdout: bigint entries=7 digest=460703479
// @stdout: writes entries=828 digest=774397002
// @stdout: variable entries=600 digest=581789803
// @stdout: floats entries=436 digest=812692326
// @stdout: search entries=795 digest=794806609
// @stdout: fill entries=94 digest=96635134
// @stdout: strings entries=74 digest=544307510

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

function checkReads(): void {
	for (let salt: int32 = 0; salt < 3; salt++) {
		const value = patterned(19, salt);
		for (let at: int32 = 0; at < 19; at++) {
			note(value.readUInt8(at));
			note(value.readInt8(at));
			if (at + 2 <= 19) {
				note(value.readUInt16LE(at));
				note(value.readUInt16BE(at));
				note(value.readInt16LE(at));
				note(value.readInt16BE(at));
			}
			if (at + 4 <= 19) {
				note(value.readUInt32LE(at));
				note(value.readUInt32BE(at));
				note(value.readInt32LE(at));
				note(value.readInt32BE(at));
			}
			for (let width: int32 = 1; width <= 6; width++) {
				if (at + width > 19) continue;
				note(value.readUIntLE(at, width));
				note(value.readUIntBE(at, width));
				note(value.readIntLE(at, width));
				note(value.readIntBE(at, width));
			}
		}
	}
	section("reads");
}

function checkBigReads(): void {
	const value = patterned(19, 5);
	let text = "";
	for (let at: int32 = 0; at + 8 <= 19; at++) {
		text += `${value.readBigUInt64LE(at)} ${value.readBigUInt64BE(at)} ${value.readBigInt64LE(at)} ${value.readBigInt64BE(at)};`;
	}
	log += text;
	entries += 1;
	const out = Buffer.alloc(16);
	note(out.writeBigUInt64LE(18446744073709551615n, 0));
	note(out.writeBigInt64BE(-2n, 8));
	noteBytes(out);
	note(out.writeBigUInt64BE(81985529216486895n, 0));
	note(out.writeBigInt64LE(-9223372036854775808n, 8));
	noteBytes(out);
	section("bigint");
}

const INT_VALUES: int32[] = [0, 1, 127, 128, 255, 256, 4660, 65535, 305419896, -1, -128, -32768, -2147483648];

function checkWrites(): void {
	for (const value of INT_VALUES) {
		for (let at: int32 = 0; at <= 5; at++) {
			const out = Buffer.alloc(12);
			const low8 = (value & 255) as number;
			const low16 = (value & 65535) as number;
			const low32 = (value >>> 0) as number;
			const whole = value as number;
			if (value >= -128 && value <= 255) {
				note(out.writeUInt8(low8, at));
				note(out.writeInt8(whole, at));
			}
			note(out.writeUInt16LE(low16, at));
			note(out.writeUInt16BE(low16, at + 1));
			if (value >= -32768 && value <= 32767) {
				note(out.writeInt16LE(whole, at + 2));
				note(out.writeInt16BE(whole, at + 3));
			}
			noteBytes(out);
			note(out.writeUInt32LE(low32, at));
			note(out.writeUInt32BE(low32, at + 1));
			note(out.writeInt32LE(whole, at + 2));
			note(out.writeInt32BE(whole, at + 3));
			noteBytes(out);
		}
	}
	section("writes");
}

const WIDE_VALUES: number[] = [0, 1, 255, 256, 65535, 16777215, 4294967295, 1099511627775, 281474976710655, 123456789012];

function checkVariableWrites(): void {
	for (const value of WIDE_VALUES) {
		for (let width: int32 = 1; width <= 6; width++) {
			const out = Buffer.alloc(9);
			const wrapped = value % Math.pow(2, width * 8);
			note(out.writeUIntLE(wrapped, 1, width));
			noteBytes(out);
			note(out.writeUIntBE(wrapped, 2, width));
			noteBytes(out);
			const half = Math.pow(2, width * 8 - 1);
			const signed = wrapped >= half ? wrapped - half * 2 : wrapped;
			note(out.writeIntLE(signed, 0, width));
			noteBytes(out);
			note(out.writeIntBE(signed, 3, width));
			noteBytes(out);
			note(out.readIntLE(0, width));
			note(out.readIntBE(3, width));
		}
	}
	section("variable");
}

const FLOAT_VALUES: number[] = [0, 1.5, -2.25, 0.1, 3.4028234663852886e38, 1e-45, 1e39, 65504, -1e-40, 1 / 3];

function checkFloats(): void {
	for (const value of FLOAT_VALUES) {
		for (let at: int32 = 0; at <= 3; at++) {
			const out = Buffer.alloc(13);
			note(out.writeFloatLE(value, at));
			note(out.readFloatLE(at));
			note(out.writeFloatBE(value, at + 1));
			note(out.readFloatBE(at + 1));
			noteBytes(out);
			note(out.writeDoubleLE(value, at));
			note(out.readDoubleLE(at));
			note(out.writeDoubleBE(value, at + 1));
			note(out.readDoubleBE(at + 1));
			noteBytes(out);
		}
	}
	const raw = patterned(16, 7);
	for (let at: int32 = 0; at + 8 <= 16; at++) {
		note(raw.readDoubleLE(at));
		note(raw.readDoubleBE(at));
		note(raw.readFloatLE(at));
		note(raw.readFloatBE(at));
	}
	section("floats");
}

function checkSearch(): void {
	const hay = patterned(300, 2);
	hay.set(150, 7);
	hay.set(299, 7);
	for (const byte of [0, 7, 11, 84, 255]) {
		for (const from of [0, 1, 100, 150, 151, 298, 299]) {
			note(hay.indexOf(byte, from));
			note(hay.lastIndexOf(byte, from));
			note(hay.includes(byte, from) ? 1 : 0);
		}
	}
	for (const start of [0, 3, 17, 120, 250, 290]) {
		for (const width of [1, 2, 3, 4, 5, 8, 13, 40]) {
			if (start + width > 300) continue;
			const needle = Buffer.alloc(width);
			hay.copyTo(needle, 0, start, start + width);
			for (const from of [0, 5, start, start + 1]) {
				note(hay.indexOfBuffer(needle, from));
				note(hay.includesBuffer(needle, from) ? 1 : 0);
				if (from <= 300 - width) note(hay.lastIndexOfBuffer(needle, from));
			}
			note(hay.lastIndexOfBuffer(needle, 300 - width));
			needle.set(width - 1, (needle.byteAt(width - 1) + 1) & 255);
			note(hay.indexOfBuffer(needle, 0));
			note(hay.lastIndexOfBuffer(needle, 300 - width));
		}
	}
	section("search");
}

function checkFillCopy(): void {
	for (const start of [0, 1, 7, 20]) {
		for (const end of [1, 8, 21, 40]) {
			if (start > end) continue;
			const out = patterned(40, 1);
			out.fill(171, start, end);
			noteBytes(out);
			const pattern = patterned(5, 3);
			out.fillBuffer(pattern, start, end);
			noteBytes(out);
			out.fillBuffer(patterned(1, 4), start, end);
			noteBytes(out);
			out.fillString("abc", start, end, "utf8");
			noteBytes(out);
			out.fillString("0aff17", start, end, "hex");
			noteBytes(out);
			const target = Buffer.alloc(40);
			note(out.copyTo(target, end - start, start, end));
			noteBytes(target);
		}
	}
	const parts: Buffer[] = [patterned(3, 1), patterned(0, 2), patterned(17, 3)];
	noteBytes(Buffer.concatList(parts));
	noteBytes(Buffer.fromArray([1, 2, 255, 0, 128]));
	noteBytes(Buffer.copy(patterned(9, 6)));
	section("fill");
}

function checkWriteString(): void {
	for (const encoding of ["utf8", "latin1", "ascii", "binary"]) {
		for (const at of [0, 3, 10]) {
			for (const limit of [0, 2, 6]) {
				const out = patterned(16, 2);
				note(out.write("hello", at, limit, encoding));
				noteBytes(out);
			}
		}
	}
	const out = Buffer.alloc(8);
	note(out.write("deadBEEF00", 1, 4, "hex"));
	noteBytes(out);
	section("strings");
}

checkReads();
checkBigReads();
checkWrites();
checkVariableWrites();
checkFloats();
checkSearch();
checkFillCopy();
checkWriteString();
