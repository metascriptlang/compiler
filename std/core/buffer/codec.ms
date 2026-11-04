// Buffer text codecs with the decoding rules of Node's Buffer: hex stops at the first pair that is
// not two hex digits; base64 takes both alphabets, skips any other byte and stops at `=`.

import { hexDigitValue, encodeBase64, encodeHex } from "../encoding";
import { EncodingBytes, newEncodingOutput, freshEncodingOutputBytes } from "../encoding/output";

const equalsSign: uint8 = 61;

export const utf8Encoding: int32 = 0;
export const hexEncoding: int32 = 1;
export const base64Encoding: int32 = 2;
export const base64UrlEncoding: int32 = 3;
export const latin1Encoding: int32 = 4;
export const asciiEncoding: int32 = 5;
export const ucs2Encoding: int32 = 6;

export function encodingOf(name: string): int32 {
	if (name == "utf8") return utf8Encoding;
	if (name.equalsIgnoreCase("utf8") || name.equalsIgnoreCase("utf-8")) return utf8Encoding;
	if (name.equalsIgnoreCase("hex")) return hexEncoding;
	if (name.equalsIgnoreCase("base64")) return base64Encoding;
	if (name.equalsIgnoreCase("base64url")) return base64UrlEncoding;
	if (name.equalsIgnoreCase("latin1") || name.equalsIgnoreCase("binary")) return latin1Encoding;
	if (name.equalsIgnoreCase("ascii")) return asciiEncoding;
	if (name.equalsIgnoreCase("ucs2") || name.equalsIgnoreCase("ucs-2") ||
			name.equalsIgnoreCase("utf16le") || name.equalsIgnoreCase("utf-16le")) {
		return ucs2Encoding;
	}
	return -1;
}

export function textEncoding(name: string): int32 {
	return name.length == 0 ? utf8Encoding : sliceEncoding(name);
}

export function sliceEncoding(name: string): int32 {
	const encoding = encodingOf(name);
	if (encoding < 0) throw new TypeError(`Unknown encoding: ${name}`);
	return encoding;
}

export function encodedLength(text: string, encoding: int32): number {
	if (encoding == latin1Encoding || encoding == asciiEncoding) return text.length;
	if (encoding == ucs2Encoding) return text.length * 2;
	if (encoding == hexEncoding) return Math.floor(text.length / 2);
	if (encoding == base64Encoding || encoding == base64UrlEncoding) {
		let n = text.length;
		if (n > 0 && text.charCodeAt(n - 1) == 61) n -= 1;
		if (n > 1 && text.charCodeAt(n - 1) == 61) n -= 1;
		return Math.floor(n * 3 / 4);
	}
	return text.byteLength;
}

@inline
function isContinuation(byte: uint8): boolean {
	return (byte & 0xC0) == 0x80;
}

@inline
function sequenceWidth(lead: uint8): int64 {
	if (lead < 0xC0) return 1;
	if (lead < 0xE0) return 2;
	return lead < 0xF0 ? 3 : 4;
}

@inline
export function isEncodedSurrogate(text: Readonly<Span<uint8>>, at: int64, end: int64): boolean {
	return text[at] == 0xED && at + 2 < end && (text[at + 1] & 0xE0) == 0xA0;
}

export function utf8Fit(text: Readonly<Span<uint8>>, limit: int64): int64 {
	const length = text.length as int64;
	if (length <= limit) return length;
	let start = limit;
	while (start > 0 && limit - start < 3 && isContinuation(text[start])) start -= 1;
	return start + sequenceWidth(text[start]) <= limit ? limit : start;
}

function codePointAt(text: Readonly<Span<uint8>>, at: int64, width: int64): int32 {
	const lead = text[at] as int32;
	if (width == 1) return lead;
	const second = (text[at + 1] & 0x3F) as int32;
	if (width == 2) return ((lead & 0x1F) << 6) | second;
	const third = (text[at + 2] & 0x3F) as int32;
	if (width == 3) return ((lead & 0x0F) << 12) | (second << 6) | third;
	return ((lead & 0x07) << 18) | (second << 12) | (third << 6) | ((text[at + 3] & 0x3F) as int32);
}

@inline
function putUnit(bytes: EncodingBytes, at: int64, unit: int32, step: int64): int64 {
	bytes[at] = (unit & 0xFF) as uint8;
	if (step == 2) bytes[at + 1] = ((unit >> 8) & 0xFF) as uint8;
	return at + step;
}

export function writeText(text: Readonly<Span<uint8>>, bytes: EncodingBytes, at: int64, limit: int64, encoding: int32): int64 {
	if (encoding == utf8Encoding) {
		const count = utf8Fit(text, limit);
		let i: int64 = 0;
		while (i < count) {
			if (isEncodedSurrogate(text, i, count)) {
				bytes[at + i] = 0xEF;
				bytes[at + i + 1] = 0xBF;
				bytes[at + i + 2] = 0xBD;
				i += 3;
			} else {
				bytes[at + i] = text[i];
				i += 1;
			}
		}
		return count;
	}
	const step: int64 = encoding == ucs2Encoding ? 2 : 1;
	const length = text.length as int64;
	const end = at + limit;
	let i: int64 = 0;
	let k = at;
	while (i < length && k + step <= end) {
		const natural = sequenceWidth(text[i]);
		const width = i + natural <= length ? natural : 1;
		const point = codePointAt(text, i, width);
		if (point < 0x10000) {
			k = putUnit(bytes, k, point, step);
		} else {
			k = putUnit(bytes, k, 0xD7C0 + (point >> 10), step);
			if (k + step > end) break;
			k = putUnit(bytes, k, 0xDC00 | (point & 0x3FF), step);
		}
		i += width;
	}
	return k - at;
}

@inline
function unitAt(data: Readonly<Span<uint8>>, index: int64): int32 {
	return (data[index << 1] as int32) | ((data[(index << 1) + 1] as int32) << 8);
}

@inline
function pairsAt(data: Readonly<Span<uint8>>, index: int64, units: int64): boolean {
	const unit = unitAt(data, index);
	return unit >= 0xD800 && unit < 0xDC00 && index + 1 < units && (unitAt(data, index + 1) & 0xFC00) == 0xDC00;
}

export function ucs2Text(data: Readonly<Span<uint8>>): string {
	const units = (data.length as int64) >> 1;
	let size: int64 = 0;
	let i: int64 = 0;
	while (i < units) {
		const unit = unitAt(data, i);
		if (pairsAt(data, i, units)) {
			size += 4;
			i += 2;
		} else {
			size += unit < 0x80 ? 1 : unit < 0x800 ? 2 : 3;
			i += 1;
		}
	}
	let result = newEncodingOutput(size);
	const bytes = freshEncodingOutputBytes(result);
	let at: int64 = 0;
	i = 0;
	while (i < units) {
		let point = unitAt(data, i);
		if (pairsAt(data, i, units)) {
			point = 0x10000 + ((point - 0xD800) << 10) + (unitAt(data, i + 1) - 0xDC00);
			bytes[at] = (0xF0 | (point >> 18)) as uint8;
			bytes[at + 1] = (0x80 | ((point >> 12) & 0x3F)) as uint8;
			bytes[at + 2] = (0x80 | ((point >> 6) & 0x3F)) as uint8;
			bytes[at + 3] = (0x80 | (point & 0x3F)) as uint8;
			at += 4;
			i += 2;
		} else if (point < 0x80) {
			bytes[at] = point as uint8;
			at += 1;
			i += 1;
		} else if (point < 0x800) {
			bytes[at] = (0xC0 | (point >> 6)) as uint8;
			bytes[at + 1] = (0x80 | (point & 0x3F)) as uint8;
			at += 2;
			i += 1;
		} else {
			bytes[at] = (0xE0 | (point >> 12)) as uint8;
			bytes[at + 1] = (0x80 | ((point >> 6) & 0x3F)) as uint8;
			bytes[at + 2] = (0x80 | (point & 0x3F)) as uint8;
			at += 3;
			i += 1;
		}
	}
	when (c) { return result; } else { return result.asString(); }
}

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

when (c) {
	@include("runtime/core/base64.h");
	extern function msBase64Encode(data: Readonly<Ptr<uint8>>, length: int64, out: Ptr<uint8>, url: int32): void;
	extern function msBase64Decode(text: Readonly<Ptr<uint8>>, length: int64, out: Ptr<uint8>, limit: int64, standardOnly: int32): int64;
	extern function markAscii(text: string): void from "msStringMarkAscii";
	extern function msBase64DecodeScalar(text: Readonly<Ptr<uint8>>, length: int64, out: Ptr<uint8>, limit: int64, standardOnly: int32): int64;

	function fillBase64Url(data: Readonly<Span<uint8>>, out: Ptr<uint8>): void {
		msBase64Encode(data as Readonly<Ptr<uint8>>, data.length as int64, out, 1);
	}

	function decodeBase64Into(text: Readonly<Span<uint8>>, out: Ptr<uint8>, limit: int64): int64 {
		return msBase64Decode(text as Readonly<Ptr<uint8>>, text.length as int64, out, limit, 0);
	}

	@inline
	function hexInvalid(byte: uint8): int32 {
		const b = byte as int32;
		return (b >= 48 && b <= 57) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102) ? 0 : 1;
	}

	function decodeHexBlocks(text: Readonly<Ptr<uint8>>, out: Ptr<uint8>, count: int64): int64 {
		const chunk: int64 = 16;
		let k: int64 = 0;
		while (k + chunk <= count) {
			const end = k + chunk;
			let bad: int32 = 0;
			for (let j = k << 1; j < end << 1; j++) bad |= hexInvalid(text[j]);
			if (bad != 0) break;
			for (let j = k; j < end; j++) {
				const hi = text[j << 1] as int32;
				const lo = text[(j << 1) | 1] as int32;
				out[j] = ((((hi & 15) + 9 * (hi >> 6)) << 4) | ((lo & 15) + 9 * (lo >> 6))) as uint8;
			}
			k = end;
		}
		return k;
	}
}

/** The bytes `write` may fill from `offset`: Node's RangeError when `offset` or `length` is not an integer in 0..total, else `length` clamped to the room left. */
export function writeRoom(total: int64, offset: number, length: number): int64 {
	needWriteIndex("offset", offset, total as number);
	needWriteIndex("length", length, total as number);
	const room = total - (offset as int64);
	return (length as int64) < room ? length as int64 : room;
}

function needWriteIndex(name: string, value: number, max: number): void {
	if (Math.floor(value) != value) throw outOfRange(name, "an integer", receivedText(value));
	if (!(value >= 0 && value <= max)) throw outOfRange(name, `>= 0 && <= ${max}`, receivedText(value));
}

function outOfRange(name: string, rule: string, received: string): RangeError {
	return new RangeError(`The value of "${name}" is out of range. It must be ${rule}. Received ${received}`);
}

function groupedDigits(text: string): string {
	const start = text.startsWith("-") ? 1 : 0;
	let end = text.length;
	let groups = "";
	while (end >= start + 4) {
		groups = `_${text.slice(end - 3, end)}${groups}`;
		end -= 3;
	}
	return `${text.slice(0, end)}${groups}`;
}

export function receivedText(value: number): string {
	const text = `${value}`;
	const wide = (value > 4294967296 || value < -4294967296) && value - value == 0;
	return wide && Math.floor(value) == value ? groupedDigits(text) : text;
}

@inline
export function needBytes(length: number, offset: number, width: number): void {
	const max = length - width;
	if (!(offset >= 0 && offset <= max && Math.floor(offset) == offset)) badOffset(offset, max);
}

@noinline
function badOffset(offset: number, max: number): never {
	if (Math.floor(offset) != offset) throw outOfRange("offset", "an integer", receivedText(offset));
	if (max < 0) throw new RangeError("Attempt to access memory outside buffer bounds");
	throw outOfRange("offset", `>= 0 and <= ${max}`, receivedText(offset));
}

@inline
export function needValue(value: number, lo: number, hi: number): void {
	if (value > hi || value < lo) badValue(`>= ${lo} and <= ${hi}`, value);
}

@noinline
function badValue(rule: string, value: number): never {
	throw outOfRange("value", rule, receivedText(value));
}

@inline
export function storedInt(value: number): int64 {
	return value == value ? value as int64 : 0;
}

@inline
export function checkedInt(value: number, lo: number, hi: number): int64 {
	needValue(value, lo, hi);
	return storedInt(value);
}

@noinline
export function badByteLength(byteLength: number): never {
	const rule = Math.floor(byteLength) != byteLength ? "an integer" : ">= 1 and <= 6";
	throw outOfRange("byteLength", rule, receivedText(byteLength));
}

@inline
export function widthOrZero(byteLength: number): int64 {
	if (!(byteLength >= 1 && byteLength <= 6)) return 0;
	const width = byteLength as int64;
	return (width as number) == byteLength ? width : 0;
}

export function needWidth(byteLength: number): void {
	if (widthOrZero(byteLength) == 0) badByteLength(byteLength);
}

export function needWideValue(value: number, byteLength: number, isSigned: boolean): void {
	needWidth(byteLength);
	const bits = byteLength * 8;
	const span = Math.pow(2, bits);
	const lo = isSigned ? -span / 2 : 0;
	const hi = isSigned ? span / 2 - 1 : span - 1;
	if (!(value > hi || value < lo)) return;
	if (byteLength <= 4) badValue(`>= ${lo} and <= ${hi}`, value);
	badValue(isSigned ? `>= -(2 ** ${bits - 1}) and < 2 ** ${bits - 1}` : `>= 0 and < 2 ** ${bits}`, value);
}

when (!bare && !solana) {
	export function needBigValue(value: bigint, isSigned: boolean): void {
		const fits = isSigned
			? value >= -9223372036854775808n && value <= 9223372036854775807n
			: value >= 0n && value <= 18446744073709551615n;
		if (fits) return;
		const rule = isSigned ? ">= -(2n ** 63n) and < 2n ** 63n" : ">= 0n and < 2n ** 64n";
		const text = `${value}`;
		const wide = value > 4294967296n || value < -4294967296n;
		throw outOfRange("value", rule, `${wide ? groupedDigits(text) : text}n`);
	}
}

/** Decodes hex `text` into `bytes[at..at + limit)`; returns the bytes written. */
export function writeHex(text: Readonly<Span<uint8>>, bytes: EncodingBytes, at: int64, limit: int64): int64 {
	const pairs = hexCapacity(text);
	const count = limit < pairs ? limit : pairs;
	let k: int64 = 0;
	when (c) {
		if (count >= 16) k = decodeHexBlocks(text as Readonly<Ptr<uint8>>, bytes + at, count);
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
	when (c) {
		if (text.length == 0) return 0;
		return decodeBase64Into(text, bytes + at, limit);
	} else {
		return writeBase64Portable(text, bytes, at, limit);
	}
}

function writeBase64Portable(text: Readonly<Span<uint8>>, bytes: EncodingBytes, at: int64, limit: int64): int64 {
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
	const length = data.length as int64;
	const rest = length % 3;
	let result = newEncodingOutput(length / 3 * 4 + (rest == 0 ? 0 : rest + 1));
	const bytes = freshEncodingOutputBytes(result);
	when (c) {
		if (length != 0) fillBase64Url(data, bytes);
		markAscii(result);
		return result;
	} else {
		const digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".asBytes();
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
		return result.asString();
	}
}

test "receivedText groups the digits of an integer beyond 2 ** 32" {
	assert receivedText(4294967296) == "4294967296";
	assert receivedText(4294967297) == "4_294_967_297";
	assert receivedText(-5000000000) == "-5_000_000_000";
	assert receivedText(1e21) == "1e_+21";
	assert receivedText(5000000000.5) == "5000000000.5";
}

test "encodingOf takes Node's names in any case" {
	assert encodingOf("UTF-8") == utf8Encoding;
	assert encodingOf("Binary") == latin1Encoding;
	assert encodingOf("UTF-16LE") == ucs2Encoding;
	assert encodingOf("Base64Url") == base64UrlEncoding;
	assert encodingOf("utf9") == -1;
	assert encodingOf("") == -1;
}

test "utf8Fit keeps whole characters" {
	const text = "abé中😀".asBytes();
	assert utf8Fit(text, 3) == 2;
	assert utf8Fit(text, 4) == 4;
	assert utf8Fit(text, 6) == 4;
	assert utf8Fit(text, 7) == 7;
	assert utf8Fit(text, 10) == 7;
	assert utf8Fit(text, 11) == 11;
	assert utf8Fit(text, 99) == 11;
}

test "ucs2Text joins a pair and keeps a lone surrogate" {
	const units: uint8[] = [0x61, 0x00, 0x3D, 0xD8, 0x00, 0xDE, 0x00, 0xD8, 0x62];
	const text = ucs2Text(units);
	assert text.length == 4;
	assert text.charCodeAt(0) == 0x61;
	assert text.charCodeAt(1) == 0xD83D;
	assert text.charCodeAt(2) == 0xDE00;
	assert text.charCodeAt(3) == 0xD800;
}

test "base64url encode is base64 with the url digits and no padding" {
	const data: uint8[] = [];
	for (let n = 0; n < 200; n++) {
		const expected = encodeBase64(data).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
		assert encodeBase64Url(data) == expected;
		data.push(((n * 37 + 11) & 255) as uint8);
	}
}

when (c) {
	function filled(size: int64): uint8[] {
		const bytes: uint8[] = [];
		for (let i: int64 = 0; i < size; i++) bytes.push(0xEE);
		return bytes;
	}

	function written(text: string, room: int64, at: int64, size: int64): string {
		const out = filled(size);
		const span: Span<uint8> = out;
		const count = writeBase64(text.asBytes(), span as Ptr<uint8>, at, room);
		return `${count}:${encodeHex(out)}`;
	}

	function lenient(text: string): string {
		const data = text.asBytes();
		const room = base64Capacity(data);
		const out = filled(room + 1);
		const span: Span<uint8> = out;
		const count = writeBase64(data, span as Ptr<uint8>, 0, room);
		return encodeHex(out.slice(0, count as number));
	}

	function scalarLenient(text: string, room: int64): string {
		const data = text.asBytes();
		const out = filled(room + 1);
		const span: Span<uint8> = out;
		const readable: Readonly<Span<uint8>> = data;
		const count = msBase64DecodeScalar(readable as Readonly<Ptr<uint8>>, data.length as int64, span as Ptr<uint8>, room, 0);
		return encodeHex(out.slice(0, count as number));
	}

	test "base64 Buffer decode follows Node's lenient rules" {
		assert lenient("") == "";
		assert lenient("aGVsbG8") == "68656c6c6f";
		assert lenient("aGVsbG8=") == "68656c6c6f";
		assert lenient("aGVsbG8==") == "68656c6c6f";
		assert lenient("aGVs\nbG8=") == "68656c6c6f";
		assert lenient("aGVsbG8=YWJj") == "68656c6c6f";
		assert lenient("aGVsbG8-_w") == "68656c6c6f3eff";
		assert lenient("a") == "";
		assert lenient("ab") == "69";
		assert lenient("!!!!aGVsbG8") == "68656c6c6f";
		assert lenient("aGVs bG8gd29y bGQ=") == "68656c6c6f20776f726c64";
		assert lenient("=aGVs") == "";
		assert lenient("aGV=sbG8") == "6865";
		assert lenient("+/+/") == "fbffbf";
		assert lenient("-_-_") == "fbffbf";
		assert lenient("\u00e9aGVs") == "68656c";
	}

	test "base64 Buffer decode leaves bytes past its room untouched" {
		assert written("aGVsbG8gd29ybGQ=", 4, 2, 10) == "4:eeee68656c6ceeeeeeee";
		assert written("aGVs", 8, 2, 10) == "3:eeee68656ceeeeeeeeee";
		const long = "AAAA".repeat(100);
		for (const room of [0 as int64, 1, 23, 24, 25, 47, 48, 49, 95, 96, 97]) {
			const result = written(long, room, 0, 128);
			assert result.startsWith(`${room}:${"00".repeat(room as int32)}`);
			assert result.endsWith("ee".repeat((128 - room) as int32));
		}
	}

	test "base64 Buffer decode matches the scalar kernel on noisy text" {
		const data: uint8[] = [];
		for (let n = 0; n < 260; n++) {
			const text = encodeBase64(data);
			const length = text.length;
			assert lenient(text) == encodeHex(data);
			for (const at of [0, length / 3, length / 2, length - 1]) {
				const spot = Math.floor(at) as int32;
				if (spot < 0) continue;
				for (const noise of ["\n", "*", "=", "-", "_", "\u00ff"]) {
					const noisy = `${text.slice(0, spot)}${noise}${text.slice(spot + 1)}`;
					const room = base64Capacity(noisy.asBytes());
					assert lenient(noisy) == scalarLenient(noisy, room);
				}
			}
			data.push(((n * 37 + 11) & 255) as uint8);
		}
	}
}
