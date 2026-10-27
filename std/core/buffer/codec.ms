// Buffer text codecs with the decoding rules of Node's Buffer: hex stops at the first pair that is
// not two hex digits; base64 takes both alphabets, skips any other byte and stops at `=`.

import { EncodingBytes, newEncodingOutput, freshEncodingOutputBytes } from "../../crypto/encodingOutput";
import { hexDigitValue } from "../../crypto/encoding";

const equalsSign: uint8 = 61;

function base64Value(byte: uint8): int32 {
	if (byte >= 65 && byte <= 90) return (byte as int32) - 65;
	if (byte >= 97 && byte <= 122) return (byte as int32) - 71;
	if (byte >= 48 && byte <= 57) return (byte as int32) + 4;
	if (byte == 43 || byte == 45) return 62;
	if (byte == 47 || byte == 95) return 63;
	return -1;
}

export function hexCapacity(text: Readonly<Span<uint8>>): int64 {
	return (text.length as int64) / 2;
}

export function base64Capacity(text: Readonly<Span<uint8>>): int64 {
	let n = text.length as int64;
	if (n > 0 && text[n - 1] == equalsSign) n -= 1;
	if (n > 1 && text[n - 1] == equalsSign) n -= 1;
	return (n * 3) >> 2;
}

/** Decodes hex `text` into `bytes[at..at + limit)`; returns the bytes written. */
export function writeHex(text: Readonly<Span<uint8>>, bytes: EncodingBytes, at: int64, limit: int64): int64 {
	const pairs = hexCapacity(text);
	const count = limit < pairs ? limit : pairs;
	const chunk: int64 = 64;
	let k: int64 = 0;
	while (k + chunk <= count) {
		let bad: int32 = 0;
		for (let j = k; j < k + chunk; j++) bad |= hexDigitValue(text[j * 2]) | hexDigitValue(text[j * 2 + 1]);
		if (bad < 0) break;
		for (let j = k; j < k + chunk; j++) bytes[at + j] = ((hexDigitValue(text[j * 2]) << 4) | hexDigitValue(text[j * 2 + 1])) as uint8;
		k += chunk;
	}
	while (k < count) {
		const hi = hexDigitValue(text[k * 2]);
		const lo = hexDigitValue(text[k * 2 + 1]);
		if (hi < 0 || lo < 0) break;
		bytes[at + k] = ((hi << 4) | lo) as uint8;
		k += 1;
	}
	return k;
}

/** Decodes base64 or base64url `text` into `bytes[at..at + limit)`; returns the bytes written. */
export function writeBase64(text: Readonly<Span<uint8>>, bytes: EncodingBytes, at: int64, limit: int64): int64 {
	const n = text.length as int64;
	let i: int64 = 0;
	let k: int64 = 0;
	while (i + 4 <= n && k + 3 <= limit) {
		const a = base64Value(text[i]);
		const b = base64Value(text[i + 1]);
		const c = base64Value(text[i + 2]);
		const d = base64Value(text[i + 3]);
		if ((a | b | c | d) < 0) break;
		bytes[at + k] = ((a << 2) | (b >> 4)) as uint8;
		bytes[at + k + 1] = (((b & 0x0F) << 4) | (c >> 2)) as uint8;
		bytes[at + k + 2] = (((c & 0x03) << 6) | d) as uint8;
		i += 4;
		k += 3;
	}
	let phase: int32 = 0;
	let hi: int32 = 0;
	while (i < n && k < limit) {
		const byte = text[i];
		i += 1;
		const lo = base64Value(byte);
		if (lo < 0) {
			if (byte == equalsSign) break;
			continue;
		}
		if (phase == 1) {
			bytes[at + k] = (((hi & 0x3F) << 2) | (lo >> 4)) as uint8;
			k += 1;
		} else if (phase == 2) {
			bytes[at + k] = (((hi & 0x0F) << 4) | (lo >> 2)) as uint8;
			k += 1;
		} else if (phase == 3) {
			bytes[at + k] = (((hi & 0x03) << 6) | lo) as uint8;
			k += 1;
		}
		hi = lo;
		phase = (phase + 1) & 3;
	}
	return k;
}

@inline
export function encodeBase64Url(data: Readonly<Span<uint8>>): string {
	const digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".asBytes();
	const length = data.length as int64;
	const rest = length % 3;
	let result = newEncodingOutput(length / 3 * 4 + (rest == 0 ? 0 : rest + 1));
	const bytes = freshEncodingOutputBytes(result);
	let at: int64 = 0;
	let i: int64 = 0;
	while (i + 3 <= length) {
		const triple = ((data[i] as int32) << 16) | ((data[i + 1] as int32) << 8) | (data[i + 2] as int32);
		bytes[at] = digits[(triple >> 18) & 63];
		bytes[at + 1] = digits[(triple >> 12) & 63];
		bytes[at + 2] = digits[(triple >> 6) & 63];
		bytes[at + 3] = digits[triple & 63];
		at += 4;
		i += 3;
	}
	if (rest != 0) {
		const a = data[i] as int32;
		const b = rest == 2 ? data[i + 1] as int32 : 0;
		bytes[at] = digits[a >> 2];
		bytes[at + 1] = digits[((a & 3) << 4) | (b >> 4)];
		if (rest == 2) bytes[at + 2] = digits[(b & 15) << 2];
	}
	when (c) { return result; } else { return result.asString(); }
}
