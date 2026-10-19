import {
	EncodingIndex, newEncodingOutput, newDecodingOutput, encodingOutputBytes,
} from "./encodingOutput";

export function encodeHex(data: Readonly<Span<uint8>>): string {
	if (data.length == 0) return "";
	const digits = "0123456789abcdef".asBytes();
	let result = newEncodingOutput((data.length as int64) * 2);
	const bytes = encodingOutputBytes(result);
	let at: EncodingIndex = 0;
	for (const byte of data) {
		bytes[at] = digits[byte >> 4];
		bytes[at + 1] = digits[byte & 15];
		at += 2;
	}
	when (c) { return result; } else { return result.asString(); }
}

function hexDigit(byte: int32): int32 {
	if (byte >= "0".code && byte <= "9".code) return byte - "0".code;
	if (byte >= "a".code && byte <= "f".code) return byte - "a".code + 10;
	if (byte >= "A".code && byte <= "F".code) return byte - "A".code + 10;
	return -1;
}

export function decodeHex(text: string): uint8[] {
	const bytes = text.asBytes();
	const byteCount = bytes.length as int64;
	if (byteCount % 2 != 0) return [];
	const result = newDecodingOutput(byteCount / 2);
	const inputLength = byteCount as EncodingIndex;
	for (let i: EncodingIndex = 0; i < inputLength; i += 2) {
		const hi = hexDigit(bytes[i] as int32);
		const lo = hexDigit(bytes[i + 1] as int32);
		if (hi < 0 || lo < 0) return [];
		result[i / 2] = ((hi << 4) | lo) as uint8;
	}
	return result;
}

export function encodeBase64(data: Readonly<Span<uint8>>): string {
	if (data.length == 0) return "";
	const digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".asBytes();
	let result = newEncodingOutput(((data.length as int64) + 2) / 3 * 4);
	const bytes = encodingOutputBytes(result);
	let at: EncodingIndex = 0;
	const inputLength = data.length as EncodingIndex;
	for (let i: EncodingIndex = 0; i < inputLength; i += 3) {
		const remaining = inputLength - i;
		const a = data[i] as int32;
		const b = remaining > 1 ? data[i + 1] as int32 : 0;
		const c = remaining > 2 ? data[i + 2] as int32 : 0;
		bytes[at] = digits[a >> 2];
		bytes[at + 1] = digits[((a & 3) << 4) | (b >> 4)];
		bytes[at + 2] = remaining > 1 ? digits[((b & 15) << 2) | (c >> 6)] : "=".code as uint8;
		bytes[at + 3] = remaining > 2 ? digits[c & 63] : "=".code as uint8;
		at += 4;
	}
	when (c) { return result; } else { return result.asString(); }
}

function base64Digit(byte: int32): int32 {
	if (byte >= "A".code && byte <= "Z".code) return byte - "A".code;
	if (byte >= "a".code && byte <= "z".code) return byte - "a".code + 26;
	if (byte >= "0".code && byte <= "9".code) return byte - "0".code + 52;
	return match (byte) {
		"+".code => 62,
		"/".code => 63,
		_ => -1,
	};
}

export function decodeBase64(text: string): uint8[] {
	const bytes = text.asBytes();
	const byteCount = bytes.length as int64;
	if (byteCount == 0 || byteCount % 4 != 0) return [];
	const inputLength = byteCount as EncodingIndex;
	let length = byteCount / 4 * 3;
	if (bytes[inputLength - 1] == "=".code) length -= 1;
	if (bytes[inputLength - 2] == "=".code) length -= 1;
	const result = newDecodingOutput(length);
	const outputLength = length as EncodingIndex;
	let at: EncodingIndex = 0;
	for (let i: EncodingIndex = 0; i < inputLength; i += 4) {
		const a = base64Digit(bytes[i] as int32);
		const b = base64Digit(bytes[i + 1] as int32);
		const c = bytes[i + 2] == "=".code ? 0 : base64Digit(bytes[i + 2] as int32);
		const d = bytes[i + 3] == "=".code ? 0 : base64Digit(bytes[i + 3] as int32);
		if (a < 0 || b < 0 || c < 0 || d < 0) return [];
		const triple = (a << 18) | (b << 12) | (c << 6) | d;
		if (at < outputLength) { result[at] = ((triple >> 16) & 255) as uint8; at += 1; }
		if (at < outputLength) { result[at] = ((triple >> 8) & 255) as uint8; at += 1; }
		if (at < outputLength) { result[at] = (triple & 255) as uint8; at += 1; }
	}
	return result;
}

test "encoding index preserves wide positions" {
	let position: EncodingIndex = 2147483646;
	position += 4;
	assert (position as int64) == 2147483650;
}

test "encoding output owns its writable bytes" {
	let output = newEncodingOutput(2);
	const originalLength = output.length;
	assert originalLength == 2;
	const bytes = encodingOutputBytes(output);
	bytes[0] = 195 as uint8;
	bytes[1] = 169 as uint8;
	when (c) {
		assert output == "é";
		assert output.length == 1;
	} else {
		assert output.asString() == "é";
	}
}

test "encoding output rejects negative lengths" {
	let rejected = false;
	try {
		newEncodingOutput(-1);
	} catch (error) {
		rejected = error instanceof RangeError;
	}
	assert rejected;
}

when (c) {
	test "encoding output prepares literal storage before writes" {
		const original = "ab";
		let output = original;
		const bytes = encodingOutputBytes(output);
		bytes[0] = 99 as uint8;
		assert output == "cb";
		assert original == "ab";
	}
}

test "hex codec preserves every byte" {
	const bytes: uint8[] = [];
	for (let i = 0; i < 256; i++) bytes.push(i as uint8);
	const encoded = encodeHex(bytes);
	const decoded = decodeHex(encoded);
	assert encoded.length == 512;
	assert decoded.length == 256;
	for (let i = 0; i < decoded.length; i++) assert decoded[i] == bytes[i];
	assert encodeHex(decodeHex("AaFf00")) == "aaff00";
}

test "hex decoder keeps empty odd and invalid input behavior" {
	for (const text of ["", "0", "000", "gg", "00gg", "00 0", "\0f", "é"]) {
		assert decodeHex(text).length == 0;
	}
}

test "base64 codec matches RFC 4648 tails" {
	const plain = ["", "f", "fo", "foo", "foob", "fooba", "foobar"];
	const encoded = ["", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"];
	for (let i = 0; i < plain.length; i++) {
		assert encodeBase64(plain[i].asBytes()) == encoded[i];
		assert decodeBase64(encoded[i]).asString() == plain[i];
	}
	assert encodeBase64("hé😀".asBytes()) == "aMOp8J+YgA==";
}

test "base64 codec preserves binary data across all tail lengths" {
	const bytes: uint8[] = [];
	for (let length = 0; length < 259; length++) {
		const decoded = decodeBase64(encodeBase64(bytes));
		assert decoded.length == bytes.length;
		for (let i = 0; i < decoded.length; i++) assert decoded[i] == bytes[i];
		bytes.push((length % 256) as uint8);
	}
}

test "base64 decoder keeps existing alphabet length and padding behavior" {
	for (const text of ["", "Zg", " Zg==", "Zg==\n", "====", "_w==", "AAA?", "AA\0A"]) {
		assert decodeBase64(text).length == 0;
	}
	assert encodeHex(decodeBase64("/w==")) == "ff";
	assert encodeHex(decodeBase64("AB==")) == "00";
	assert encodeHex(decodeBase64("AA=A")) == "0000";
	assert encodeHex(decodeBase64("AA==AAAA")) == "000000000000";
}
