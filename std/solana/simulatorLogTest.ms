import {
	LOG_BUDGET,
	TRUNCATED_LINE,
	base58,
	base64,
	hex,
	isUtf8,
	newLogBook,
	recordLine,
	words,
} from "./simulatorLogCore";

function filled(length: int32, byte: uint8): uint8[] {
	const bytes: uint8[] = [];
	for (let index = 0; index < length; index++) { bytes.push(byte); }
	return bytes;
}

test "base58 encodes known vectors and keeps one 1 per leading zero byte" {
	assert base58([]) == "";
	assert base58([0]) == "1";
	assert base58([0, 0, 1, 2, 3]) == "11Ldp";
	assert base58([0xff]) == "5Q";
	assert base58([0x61]) == "2g";
	assert base58(filled(32, 0)) == "11111111111111111111111111111111";
	assert base58(filled(32, 0xff)) == "JEKNVnkbo3jma5nREBBJCDoXFVeKkD56V3xKrvRmWxFG";
}

function decode58(text: string): uint8[] {
	const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
	const bytes: uint8[] = [];
	let zeros = 0;
	while (zeros < text.length && text[zeros] == "1") { zeros++; }
	for (let at = zeros; at < text.length; at++) {
		let carry = alphabet.indexOf(text[at]);
		for (let index = 0; index < bytes.length; index++) {
			carry += (bytes[index] as int32) * 58;
			bytes[index] = (carry & 0xff) as uint8;
			carry = carry >> 8;
		}
		while (carry > 0) {
			bytes.push((carry & 0xff) as uint8);
			carry = carry >> 8;
		}
	}
	const decoded: uint8[] = filled(zeros, 0);
	for (let index = bytes.length - 1; index >= 0; index--) { decoded.push(bytes[index]); }
	return decoded;
}

test "base58 decodes back to the key for a low byte, a high byte, a run of zeros and a ramp" {
	const low = filled(32, 0);
	low[31] = 1;
	assert base58(low) == "11111111111111111111111111111112";
	const high = filled(32, 0);
	high[0] = 1;
	const ramp: uint8[] = [];
	for (let index = 0; index < 32; index++) { ramp.push((index * 7 + 3) as uint8); }
	const gap = ramp.slice(0, 32);
	gap[0] = 0;
	gap[1] = 0;
	for (const key of [low, high, ramp, gap, filled(32, 0xff), filled(32, 0)]) {
		assert decode58(base58(key)).length == 32;
		for (let index = 0; index < 32; index++) { assert decode58(base58(key))[index] == key[index]; }
	}
}

test "base64 pads to a multiple of four and matches known vectors" {
	assert base64([]) == "";
	assert base64([0x66]) == "Zg==";
	assert base64([0x66, 0x6f]) == "Zm8=";
	assert base64([0x66, 0x6f, 0x6f]) == "Zm9v";
	assert base64([0xff, 0xff]) == "//8=";
}

test "the log64 line prints every word as unpadded lowercase hex" {
	assert hex(0) == "0";
	assert hex(255) == "ff";
	assert words(0, 1, 0x10, 0xabc, 0xffffffffffffffff) == "Program log: 0x0, 0x1, 0x10, 0xabc, 0xffffffffffffffff";
}

test "isUtf8 accepts every sequence length and refuses overlong, surrogate, out-of-range and truncated forms" {
	assert isUtf8([]);
	assert isUtf8([0x68, 0x00, 0x69]);
	assert isUtf8([0xc3, 0xa9]);
	assert isUtf8([0xe2, 0x82, 0xac]);
	assert isUtf8([0xf0, 0x9f, 0x9a, 0x80]);
	assert isUtf8([0xf4, 0x8f, 0xbf, 0xbf]);
	assert !isUtf8([0x80]);
	assert !isUtf8([0xc0, 0x80]);
	assert !isUtf8([0xe0, 0x80, 0x80]);
	assert !isUtf8([0xed, 0xa0, 0x80]);
	assert !isUtf8([0xf4, 0x90, 0x80, 0x80]);
	assert !isUtf8([0xf8, 0x88, 0x80, 0x80, 0x80]);
	assert !isUtf8([0xc3]);
	assert !isUtf8([0xe2, 0x82]);
	assert !isUtf8([0x68, 0xc3, 0x28]);
}

test "a log book keeps lines until the budget, then one truncation line and nothing after" {
	const book = newLogBook();
	book.bytes = 100;
	recordLine(book, "first", 5);
	assert book.lines.length == 1 && book.bytes == 105;
	recordLine(book, "big", LOG_BUDGET - 105);
	assert book.lines.length == 2 && book.lines[1] == TRUNCATED_LINE && book.truncated && book.bytes == 105;
	recordLine(book, "again", LOG_BUDGET);
	assert book.lines.length == 2;
	recordLine(book, "small", 1);
	assert book.lines.length == 3 && book.lines[2] == "small";
}

test "a line that ends one byte under the budget fits and the next byte truncates" {
	const book = newLogBook();
	recordLine(book, "fits", LOG_BUDGET - 1);
	assert book.lines[0] == "fits" && !book.truncated;
	recordLine(book, "x", 1);
	assert book.lines.length == 2 && book.lines[1] == "Log truncated";
}
