import {
	EncodingIndex, emptyEncoding, newEncodingOutput, newDecodingOutput,
	freshEncodingOutputBytes,
} from "./output";

when (c) {
	@include("runtime/core/base64.h");
	extern function msBase64Encode(data: Readonly<Ptr<uint8>>, length: int64, out: Ptr<uint8>, url: int32): void;
	extern function msBase64Decode(text: Readonly<Ptr<uint8>>, length: int64, out: Ptr<uint8>, limit: int64, standardOnly: int32): int64;
	extern function msBase64EncodeScalar(data: Readonly<Ptr<uint8>>, length: int64, out: Ptr<uint8>, url: int32): void;

	extern function uninitText(length: int64): string from "msStringNewUninit";
	extern const textLengthMax: uint64 from "MS_LEN_MAX";
	extern function markAscii(text: string): void from "msStringMarkAscii";

	function base64Text(data: Readonly<Span<uint8>>): string {
		const length = ((data.length as int64) + 2) / 3 * 4;
		if ((length as uint64) > textLengthMax) return newEncodingOutput(length);
		let result = uninitText(length);
		msBase64Encode(data as Readonly<Ptr<uint8>>, data.length as int64, freshEncodingOutputBytes(result), 0);
		markAscii(result);
		return result;
	}

	function decodesWhole(text: Readonly<Span<uint8>>, out: Ptr<uint8>, length: int64): boolean {
		return msBase64Decode(text as Readonly<Ptr<uint8>>, text.length as int64, out, length, 1) == length;
	}

	@inline
	function fillHex(data: Readonly<Span<uint8>>, out: Ptr<uint8>): void {
		const input = data as Readonly<Ptr<uint8>>;
		const digits = "0123456789abcdef".asBytes() as Readonly<Ptr<uint8>>;
		const length = data.length as int64;
		for (let i: int64 = 0; i < length; i++) {
			const byte = input[i] as int32;
			out[i << 1] = digits[byte >> 4];
			out[(i << 1) | 1] = digits[byte & 15];
		}
	}
}

@inline
export function encodeHex(this data: Readonly<Span<uint8>>): string {
	if (data.length == 0) return emptyEncoding;
	let result = newEncodingOutput((data.length as int64) * 2);
	const bytes = freshEncodingOutputBytes(result);
	when (c) {
		fillHex(data, bytes);
	} else {
		const digits = "0123456789abcdef".asBytes();
		const inputLength = data.length as EncodingIndex;
		for (let i: EncodingIndex = 0; i < inputLength; i++) {
			const byte = data[i];
			bytes[i * 2] = digits[byte >> 4];
			bytes[i * 2 + 1] = digits[byte & 15];
		}
	}
	when (c) { return result; } else { return result.asString(); }
}

@inline
export function hexDigitValue(byte: uint8): int32 {
	const digit = (byte as int32) - "0".code;
	if ((digit as uint32) < 10) return digit;
	const letter = ((byte as int32) | 32) - "a".code;
	if ((letter as uint32) < 6) return letter + 10;
	return -1;
}

export function decodeHex(this text: string): uint8[] {
	const bytes = text.asBytes();
	const byteCount = bytes.length as int64;
	if (byteCount % 2 != 0) return [];
	const result = newDecodingOutput(byteCount / 2);
	const out: Span<uint8> = result;
	const inputLength = byteCount as EncodingIndex;
	for (let i: EncodingIndex = 0; i < inputLength; i += 2) {
		const hi = hexDigitValue(bytes[i]);
		const lo = hexDigitValue(bytes[i + 1]);
		if (hi < 0 || lo < 0) return [];
		out[i / 2] = ((hi << 4) | lo) as uint8;
	}
	return result;
}

@inline
export function encodeBase64(this data: Readonly<Span<uint8>>): string {
	if (data.length == 0) return emptyEncoding;
	when (c) {
		return base64Text(data);
	} else {
		let result = newEncodingOutput(((data.length as int64) + 2) / 3 * 4);
		const bytes = freshEncodingOutputBytes(result);
		const digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".asBytes();
		let at: EncodingIndex = 0;
		const inputLength = data.length as EncodingIndex;
		const fullLength = inputLength - inputLength % 3;
		let i: EncodingIndex = 0;
		while (i < fullLength) {
			const triple = ((data[i] as int32) << 16) |
				((data[i + 1] as int32) << 8) | (data[i + 2] as int32);
			bytes[at] = digits[(triple >> 18) & 63];
			bytes[at + 1] = digits[(triple >> 12) & 63];
			bytes[at + 2] = digits[(triple >> 6) & 63];
			bytes[at + 3] = digits[triple & 63];
			at += 4;
			i += 3;
		}
		const remaining = inputLength - i;
		if (remaining != 0) {
			const a = data[i] as int32;
			const b = remaining == 2 ? data[i + 1] as int32 : 0;
			bytes[at] = digits[a >> 2];
			bytes[at + 1] = digits[((a & 3) << 4) | (b >> 4)];
			bytes[at + 2] = remaining == 2 ? digits[(b & 15) << 2] : "=".code as uint8;
			bytes[at + 3] = "=".code as uint8;
		}
		return result.asString();
	}
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

export function decodeBase64(this text: string): uint8[] {
	const bytes = text.asBytes();
	const byteCount = bytes.length as int64;
	if (byteCount == 0 || byteCount % 4 != 0) return [];
	const inputLength = byteCount as EncodingIndex;
	let length = byteCount / 4 * 3;
	if (bytes[inputLength - 1] == "=".code) length -= 1;
	if (bytes[inputLength - 2] == "=".code) {
		if (bytes[inputLength - 1] != "=".code) return [];
		length -= 1;
	}
	const result = newDecodingOutput(length);
	when (c) {
		const decoded: Span<uint8> = result;
		if (!decodesWhole(bytes, decoded as Ptr<uint8>, length)) return [];
		return result;
	} else {
		const outputLength = length as EncodingIndex;
		const finalGroup = inputLength - 4;
		let at: EncodingIndex = 0;
		for (let i: EncodingIndex = 0; i < inputLength; i += 4) {
			const padded = i == finalGroup;
			const a = base64Digit(bytes[i] as int32);
			const b = base64Digit(bytes[i + 1] as int32);
			const c = padded && bytes[i + 2] == "=".code ? 0 : base64Digit(bytes[i + 2] as int32);
			const d = padded && bytes[i + 3] == "=".code ? 0 : base64Digit(bytes[i + 3] as int32);
			if (a < 0 || b < 0 || c < 0 || d < 0) return [];
			const triple = (a << 18) | (b << 12) | (c << 6) | d;
			if (at < outputLength) { result[at] = ((triple >> 16) & 255) as uint8; at += 1; }
			if (at < outputLength) { result[at] = ((triple >> 8) & 255) as uint8; at += 1; }
			if (at < outputLength) { result[at] = (triple & 255) as uint8; at += 1; }
		}
		return result;
	}
}

when (c) {
	export function decodeHexString(this text: string): string {
		const data = text.asBytes();
		const count = data.length as int64;
		if (count == 0 || count % 2 != 0) return emptyEncoding;
		let result = newEncodingOutput(count / 2);
		const bytes = freshEncodingOutputBytes(result);
		for (let i: int64 = 0; i < count; i += 2) {
			const hi = hexDigitValue(data[i]);
			const lo = hexDigitValue(data[i + 1]);
			if (hi < 0 || lo < 0) return emptyEncoding;
			bytes[i / 2] = ((hi << 4) | lo) as uint8;
		}
		return result;
	}

	export function decodeBase64String(this text: string): string {
		const data = text.asBytes();
		const count = data.length as int64;
		if (count == 0 || count % 4 != 0) return emptyEncoding;
		let length = count / 4 * 3;
		if (data[count - 1] == "=".code) length -= 1;
		if (data[count - 2] == "=".code) {
			if (data[count - 1] != "=".code) return emptyEncoding;
			length -= 1;
		}
		let result = newEncodingOutput(length);
		return decodesWhole(data, freshEncodingOutputBytes(result), length) ? result : emptyEncoding;
	}
}

test "encoding index preserves wide positions" {
	let position: EncodingIndex = 2147483646;
	position += 4;
	assert (position as int64) == 2147483650;
}

test "encoding output owns its writable bytes" {
	let output = newEncodingOutput(2);
	const bytes = freshEncodingOutputBytes(output);
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
	test "encoding output rejects lengths past the string length limit" {
		for (const bit of [31, 32, 60, 61, 62]) {
			const length = (1 as int64) << (bit as int64);
			let rejected = false;
			try {
				newEncodingOutput(length);
			} catch (error) {
				rejected = error instanceof RangeError;
			}
			assert rejected;
		}
	}
}

test "hex codec preserves every byte" {
	const bytes: uint8[] = [];
	for (let i = 0; i < 256; i++) bytes.push(i as uint8);
	const encoded = bytes.encodeHex();
	const decoded = encoded.decodeHex();
	assert encoded.length == 512;
	assert decoded.length == 256;
	for (let i = 0; i < decoded.length; i++) assert decoded[i] == bytes[i];
	assert "AaFf00".decodeHex().encodeHex() == "aaff00";
}

test "hex encoder matches known answers at every block edge" {
	const all: uint8[] = [];
	for (let i = 0; i < 256; i++) all.push(i as uint8);
	const known = all.encodeHex();
	assert known.length == 512;
	assert known.startsWith("000102030405");
	assert known.endsWith("fafbfcfdfeff");
	for (const size of [0, 1, 63, 64, 65, 1048576]) {
		const bytes: uint8[] = [];
		for (let i = 0; i < size; i++) bytes.push(((i * 7 + i / 251) % 256) as uint8);
		const encoded = bytes.encodeHex();
		assert encoded.length == size * 2;
		const decoded = encoded.decodeHex();
		assert decoded.length == size;
		for (let i = 0; i < size; i++) assert decoded[i] == bytes[i];
		if (size > 1) assert encoded.substring(2, 4) == "07";
	}
}

test "hex decoder keeps empty odd and invalid input behavior" {
	for (const text of ["", "0", "000", "gg", "00gg", "00 0", "\0f", "é"]) {
		assert text.decodeHex().length == 0;
	}
}

test "base64 codec matches RFC 4648 tails" {
	const plain = ["", "f", "fo", "foo", "foob", "fooba", "foobar"];
	const encoded = ["", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"];
	for (let i = 0; i < plain.length; i++) {
		assert plain[i].asBytes().encodeBase64() == encoded[i];
		assert encoded[i].decodeBase64().asString() == plain[i];
	}
	assert "hé😀".asBytes().encodeBase64() == "aMOp8J+YgA==";
}

test "base64 codec preserves binary data across all tail lengths" {
	const bytes: uint8[] = [];
	for (let length = 0; length < 259; length++) {
		const decoded = bytes.encodeBase64().decodeBase64();
		assert decoded.length == bytes.length;
		for (let i = 0; i < decoded.length; i++) assert decoded[i] == bytes[i];
		bytes.push((length % 256) as uint8);
	}
}

test "base64 decoder keeps existing alphabet and length behavior" {
	for (const text of ["", "Zg", " Zg==", "Zg==\n", "====", "_w==", "AAA?", "AA\0A"]) {
		assert text.decodeBase64().length == 0;
	}
	assert "/w==".decodeBase64().encodeHex() == "ff";
	assert "AB==".decodeBase64().encodeHex() == "00";
	assert "AAAA".decodeBase64().encodeHex() == "000000";
	assert "AAAAAA==".decodeBase64().encodeHex() == "00000000";
}

test "base64 decoder accepts padding only at the end of the final group" {
	for (const text of ["AA=A", "AA==AAAA", "AAA=AAAA", "AB=C", "A=AA", "AAAA=AAA", "AA=AAAAA"]) {
		assert text.decodeBase64().length == 0;
	}
}

when (c) {
	test "base64 string decoder accepts padding only at the end of the final group" {
		for (const text of ["AA=A", "AA==AAAA", "AAA=AAAA", "AB=C", "A=AA", "AAAA=AAA", "AA=AAAAA"]) {
			assert text.decodeBase64String() == "";
		}
		assert "AAAAAA==".decodeBase64String().length == 4;
		assert "AAA=".decodeBase64String().length == 2;
	}
}

function patternBytes(length: int64): uint8[] {
	const bytes: uint8[] = [];
	for (let i: int64 = 0; i < length; i++) bytes.push(((i * 37 + 11) & 255) as uint8);
	return bytes;
}

function withByteAt(text: string, at: int64, byte: string): string {
	return `${text.slice(0, at as int32)}${byte}${text.slice((at + 1) as int32)}`;
}

test "base64 round-trips every length 0..64 and large sizes" {
	const lengths: int64[] = [];
	for (let n: int64 = 0; n <= 64; n++) lengths.push(n);
	for (const n of [95 as int64, 96, 97, 1000, 4097, 65541, 1048576]) lengths.push(n);
	for (const n of lengths) {
		const data = patternBytes(n);
		const text = data.encodeBase64();
		assert (text.length as int64) == (n + 2) / 3 * 4;
		assert text.endsWith("==") == (n % 3 == 1);
		assert text.endsWith("=") == (n % 3 != 0);
		assert text.decodeBase64().encodeHex() == data.encodeHex();
	}
}

test "base64 strict decoder rejects a stray byte anywhere in a long text" {
	const text = patternBytes(300).encodeBase64();
	for (const at of [0 as int64, 5, 31, 32, 63, 64, 100, 250, 395]) {
		for (const byte of ["-", "_", "*", "=", " ", "\n"]) {
			assert withByteAt(text, at, byte).decodeBase64().length == 0;
		}
		assert withByteAt(text, at, "A").decodeBase64().length == 300;
	}
	assert "+/+/".repeat(40).decodeBase64().encodeHex() == "fbffbf".repeat(40);
}

when (c) {
	test "base64 encode matches the scalar kernel at every length" {
		for (let n: int64 = 0; n < 300; n++) {
			const data = patternBytes(n);
			if (n == 0) continue;
			let expected = newEncodingOutput((n + 2) / 3 * 4);
			const span: Readonly<Span<uint8>> = data;
			msBase64EncodeScalar(span as Readonly<Ptr<uint8>>, n, freshEncodingOutputBytes(expected), 0);
			assert data.encodeBase64() == expected;
		}
	}

	test "base64 string decoder matches the array decoder across lengths" {
		for (let n: int64 = 1; n < 200; n++) {
			const text = patternBytes(n).encodeBase64();
			assert text.decodeBase64String().asBytes().encodeHex() == text.decodeBase64().encodeHex();
			assert withByteAt(text, n / 2, "-").decodeBase64String() == "";
		}
	}
}
