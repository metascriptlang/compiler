export function encodeHex(data: Readonly<Span<uint8>>): string {
	const digits = "0123456789abcdef".asBytes();
	const result: uint8[] = [];
	for (const byte of data) {
		result.push(digits[byte >> 4]);
		result.push(digits[byte & 15]);
	}
	return result.asString();
}

function hexDigit(byte: int32): int32 {
	if (byte >= "0".code && byte <= "9".code) return byte - "0".code;
	if (byte >= "a".code && byte <= "f".code) return byte - "a".code + 10;
	if (byte >= "A".code && byte <= "F".code) return byte - "A".code + 10;
	return -1;
}

export function decodeHex(text: string): uint8[] {
	const bytes = text.asBytes();
	const result: uint8[] = [];
	if (bytes.length % 2 != 0) return result;
	for (let i = 0; i < bytes.length; i += 2) {
		const hi = hexDigit(bytes[i] as int32);
		const lo = hexDigit(bytes[i + 1] as int32);
		if (hi < 0 || lo < 0) return [];
		result.push(((hi << 4) | lo) as uint8);
	}
	return result;
}

export function encodeBase64(data: Readonly<Span<uint8>>): string {
	const digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".asBytes();
	const result: uint8[] = [];
	for (let i = 0; i < data.length; i += 3) {
		const a = data[i] as int32;
		const b = i + 1 < data.length ? data[i + 1] as int32 : 0;
		const c = i + 2 < data.length ? data[i + 2] as int32 : 0;
		result.push(digits[a >> 2]);
		result.push(digits[((a & 3) << 4) | (b >> 4)]);
		result.push(i + 1 < data.length ? digits[((b & 15) << 2) | (c >> 6)] : "=".code as uint8);
		result.push(i + 2 < data.length ? digits[c & 63] : "=".code as uint8);
	}
	return result.asString();
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
	const result: uint8[] = [];
	if (bytes.length == 0 || bytes.length % 4 != 0) return result;
	let length = bytes.length / 4 * 3;
	if (bytes[bytes.length - 1] == "=".code) length -= 1;
	if (bytes[bytes.length - 2] == "=".code) length -= 1;
	for (let i = 0; i < bytes.length; i += 4) {
		const a = base64Digit(bytes[i] as int32);
		const b = base64Digit(bytes[i + 1] as int32);
		const c = bytes[i + 2] == "=".code ? 0 : base64Digit(bytes[i + 2] as int32);
		const d = bytes[i + 3] == "=".code ? 0 : base64Digit(bytes[i + 3] as int32);
		if (a < 0 || b < 0 || c < 0 || d < 0) return [];
		const triple = (a << 18) | (b << 12) | (c << 6) | d;
		if (result.length < length) result.push(((triple >> 16) & 255) as uint8);
		if (result.length < length) result.push(((triple >> 8) & 255) as uint8);
		if (result.length < length) result.push((triple & 255) as uint8);
	}
	return result;
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
