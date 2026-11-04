// MetaScript JSON2 — Recursive Descent Parser
//
// Pure MetaScript. Returns Result<JsonValue, string>.
// Depth-limited to prevent stack overflow.
//
// All scan positions are BYTE offsets (consistent with HTTP/JSON wire
// semantics). We read the input's bytes through one `asBytes` view, slice
// with `byteSlice`, and copy raw bytes during string parsing — that keeps
// UTF-8 multibyte content intact and prevents the position from drifting
// against `byteLength`.

import { JsonKind, JsonValue } from "./types";
import { jsonNull, jsonBool, jsonNumber, jsonString, jsonArray, jsonObject, jsonInt } from "./builder";
import {
	EncodingBytes, EncodingIndex, newEncodingOutput, freshEncodingOutputBytes,
} from "std/core/encoding/output";

const DEPTH_LIMIT: int32 = 1000;

const exactMantissaDigits: int32 = 15;
const exactPowersOfTen: float64[] = [
	1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
	1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
];

type Bytes = Readonly<Span<uint8>>;
type ParseResult = Result<JsonValue, string>;

// ===== Public API =====

export function parseJson(input: string): Result<JsonValue, string> {
	const b = input.asBytes();
	let pos = skipWs(b, 0);
	const value = try parseValue(input, b, pos, 0);
	pos = skipWs(b, pos);
	if (pos < b.length) {
		return Result.err(`Unexpected character at position ${pos}`);
	}
	return Result.ok(value);
}

// ===== Scanning Helpers =====

function skipWs(b: Bytes, pos: int32): int32 {
	let p = pos;
	const len = b.length;
	while (p < len) {
		const ch = b[p];
		if (ch != " ".code && ch != "\t".code && ch != "\n".code && ch != "\r".code) return p;
		p = p + 1;
	}
	return p;
}

function isDigit(ch: uint8): boolean {
	return ch >= "0".code && ch <= "9".code;
}

function digitValue(ch: uint8): int32 {
	return (ch as int32) - "0".code;
}

function charAt(input: string, pos: int32): string {
	const lead = input.byteAt(pos);
	const width = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1;
	const end = pos + width;
	return input.byteSlice(pos, end < input.byteLength ? end : input.byteLength);
}

function messageAt(msg: string, pos: int32): string {
	return `${msg} at position ${pos}`;
}

function errorAt(msg: string, pos: int32): ParseResult {
	return Result.err(messageAt(msg, pos));
}

// ===== Value Parser =====

function parseValue(input: string, b: Bytes, ref pos: int32, depth: int32): ParseResult {
	if (depth > DEPTH_LIMIT) return errorAt("Maximum nesting depth exceeded", pos);
	if (pos >= b.length) return errorAt("Unexpected end of input", pos);

	const ch = b[pos];
	if (ch == "\"".code) {
		const text = try parseString(input, b, pos);
		return Result.ok(jsonString(text));
	}
	if (ch == "{".code) return parseObject(input, b, pos, depth);
	if (ch == "[".code) return parseArray(input, b, pos, depth);
	if (ch == "t".code) {
		if (!skipLiteral(b, pos, "true")) return errorAt("Expected 'true'", pos);
		return Result.ok(jsonBool(true));
	}
	if (ch == "f".code) {
		if (!skipLiteral(b, pos, "false")) return errorAt("Expected 'false'", pos);
		return Result.ok(jsonBool(false));
	}
	if (ch == "n".code) {
		if (!skipLiteral(b, pos, "null")) return errorAt("Expected 'null'", pos);
		return Result.ok(jsonNull());
	}
	if (ch == "-".code || isDigit(ch)) return parseNumber(input, b, pos);
	return errorAt(`Unexpected character '${charAt(input, pos)}'`, pos);
}

// ===== Literal Parser =====

function skipLiteral(b: Bytes, ref pos: int32, expected: string): boolean {
	const width = expected.byteLength;
	if (pos + width > b.length) return false;
	for (let i = 0; i < width; i = i + 1) {
		if ((b[pos + i] as int32) != expected.byteAt(i)) return false;
	}
	pos = pos + width;
	return true;
}

// ===== Number Parser =====

// Only ever called for a 19-digit integer — the digit COUNT already decides every
// other case, and the count is known from the scan positions without touching the
// string. (std cannot import src, so this mirrors the checker's own bound check.)
function int64FitsAtLimitWidth(b: Bytes, digitStart: int32, negative: boolean): boolean {
	const limit = negative ? "9223372036854775808" : "9223372036854775807";
	for (let i = 0; i < 19; i = i + 1) {
		const a = b[digitStart + i] as int32;
		const l = limit.byteAt(i);
		if (a < l) return true;
		if (a > l) return false;
	}
	return true;
}

// The digits accumulate into `mantissa` during the grammar scan. A mantissa of
// at most 15 digits and a power of ten up to 1e22 are both exact doubles, so one
// multiply or divide rounds once and gives the correctly rounded value; every
// other number goes through parseFloat on its text.
function parseNumber(input: string, b: Bytes, ref pos: int32): ParseResult {
	const start = pos;
	const len = b.length;
	let p = start;

	const negative = b[p] == "-".code;
	if (negative) p = p + 1;

	// Integer part. The grammar is `zero / (digit1-9 *DIGIT)` — a leading zero
	// may not be followed by another digit, so `01` is not a number.
	if (p >= len || !isDigit(b[p])) return errorAt("Invalid number", start);
	const intStart = p;
	const firstDigit = b[p];
	let mantissa: int64 = 0;
	while (p < len && isDigit(b[p])) {
		if (p - intStart < exactMantissaDigits) mantissa = mantissa * 10 + digitValue(b[p]);
		p = p + 1;
	}
	const intDigits = p - intStart;
	if (firstDigit == "0".code && intDigits > 1) {
		return errorAt("Leading zeros are not allowed in a number", intStart);
	}

	// Decimal part — the dot must be followed by at least one digit.
	let isFloat = false;
	let fracDigits = 0;
	if (p < len && b[p] == ".".code) {
		isFloat = true;
		p = p + 1;
		const fracStart = p;
		while (p < len && isDigit(b[p])) {
			if (intDigits + p - fracStart < exactMantissaDigits) {
				mantissa = mantissa * 10 + digitValue(b[p]);
			}
			p = p + 1;
		}
		fracDigits = p - fracStart;
		if (fracDigits == 0) return errorAt("Expected a digit after '.'", p);
	}

	// Exponent part — same rule after the optional sign.
	let exponent = 0;
	if (p < len && (b[p] == "e".code || b[p] == "E".code)) {
		isFloat = true;
		p = p + 1;
		let exponentNegative = false;
		if (p < len && (b[p] == "+".code || b[p] == "-".code)) {
			exponentNegative = b[p] == "-".code;
			p = p + 1;
		}
		const expStart = p;
		while (p < len && isDigit(b[p])) {
			if (exponent < 100000) exponent = exponent * 10 + digitValue(b[p]);
			p = p + 1;
		}
		if (p == expStart) return errorAt("Expected a digit in the exponent", p);
		if (exponentNegative) exponent = -exponent;
	}
	pos = p;

	const digits = intDigits + fracDigits;
	if (!isFloat && digits <= exactMantissaDigits) {
		return Result.ok(jsonInt(negative && mantissa != 0 ? -mantissa : mantissa));
	}
	const scale = exponent - fracDigits;
	if (isFloat && digits <= exactMantissaDigits && scale >= -22 && scale <= 22) {
		const exact = mantissa as float64;
		const magnitude = scale < 0
			? exact / exactPowersOfTen[-scale]
			: exact * exactPowersOfTen[scale];
		return Result.ok(jsonNumber(negative ? -magnitude : magnitude));
	}

	const numStr = input.byteSlice(start, p);
	// An integer wider than int64 has no exact carrier here: `parseInt` clamps to
	// INT64_MAX, which would hand back a wrong value labelled Int. Fall back to the
	// float carrier, which is what the JS engine does with the same input, so both
	// backends agree. Exact digits for these need the RawNumber carrier.
	let fitsI64 = true;
	if (!isFloat) {
		if (digits > 19) { fitsI64 = false; }
		else if (digits == 19) { fitsI64 = int64FitsAtLimitWidth(b, intStart, negative); }
	}
	if (isFloat || !fitsI64) return Result.ok(jsonNumber(parseFloat(numStr)));
	return Result.ok(jsonInt(numStr.parseInt()));
}

// ===== String Parser =====

// A string without an escape is one slice of the input. One with an escape is
// validated and measured first, then decoded into an output of exactly that
// many bytes.
function parseString(input: string, b: Bytes, ref pos: int32): Result<string, string> {
	const start = pos + 1;
	const len = b.length;
	let p = start;
	while (p < len) {
		const ch = b[p];
		if (ch == "\"".code) {
			pos = p + 1;
			return Result.ok(input.byteSlice(start, p));
		}
		if (ch == "\\".code) return parseEscapedString(input, b, pos);
		// U+0000..U+001F must be escaped; a raw one ends the string per the grammar.
		if (ch < 32) {
			return Result.err(messageAt("Raw control character in string — must be escaped", p));
		}
		p = p + 1;
	}
	return Result.err(messageAt("Unterminated string", pos));
}

function parseEscapedString(input: string, b: Bytes, ref pos: int32): Result<string, string> {
	const start = pos + 1;
	const len = b.length;
	let p = start;
	let size: int64 = 0;
	while (p < len) {
		const ch = b[p];
		if (ch == "\"".code) break;
		if (ch < 32) {
			return Result.err(messageAt("Raw control character in string — must be escaped", p));
		}
		if (ch != "\\".code) {
			size = size + 1;
			p = p + 1;
			continue;
		}
		p = p + 1;
		if (p >= len) return Result.err(messageAt("Unexpected end of string", p));
		const esc = b[p];
		if (esc == "u".code) {
			if (p + 4 >= len) return Result.err(messageAt("Invalid unicode escape", p));
			const codePoint = hexAt(b, p + 1);
			if (codePoint < 0) return Result.err(messageAt("Invalid unicode escape", p));
			const paired = pairedCodePoint(b, p, codePoint);
			size = size + utf8Width(paired >= 0 ? paired : codePoint);
			p = p + (paired >= 0 ? 11 : 5);
			continue;
		}
		if (unescapedByte(esc) < 0) {
			return Result.err(messageAt(`Invalid escape '\\${charAt(input, p)}'`, p));
		}
		size = size + 1;
		p = p + 1;
	}
	if (p >= len) return Result.err(messageAt("Unterminated string", pos));
	const end = p;
	pos = end + 1;

	let out = newEncodingOutput(size);
	const bytes = freshEncodingOutputBytes(out);
	let o: EncodingIndex = 0;
	p = start;
	while (p < end) {
		const ch = b[p];
		if (ch != "\\".code) {
			bytes[o] = ch;
			o = o + 1;
			p = p + 1;
			continue;
		}
		const esc = b[p + 1];
		if (esc == "u".code) {
			const codePoint = hexAt(b, p + 2);
			const paired = pairedCodePoint(b, p + 1, codePoint);
			o = writeUtf8(bytes, o, paired >= 0 ? paired : codePoint);
			p = p + (paired >= 0 ? 12 : 6);
			continue;
		}
		bytes[o] = unescapedByte(esc) as uint8;
		o = o + 1;
		p = p + 2;
	}
	when (c) { return Result.ok(out); } else { return Result.ok(out.asString()); }
}

function unescapedByte(esc: uint8): int32 {
	return match (esc as int32) {
		"\"".code => "\"".code,
		"\\".code => "\\".code,
		"/".code => "/".code,
		"b".code => 8,
		"f".code => 12,
		"n".code => 10,
		"r".code => 13,
		"t".code => 9,
		_ => -1,
	};
}

// The four hex digits at `at`, or -1 when one is not a hex digit.
function hexAt(b: Bytes, at: int32): int32 {
	let result = 0;
	for (let i = at; i < at + 4; i = i + 1) {
		const ch = b[i] as int32;
		result = result * 16;
		if (ch >= "0".code && ch <= "9".code) { result = result + (ch - "0".code); }
		else if (ch >= "a".code && ch <= "f".code) { result = result + 10 + (ch - "a".code); }
		else if (ch >= "A".code && ch <= "F".code) { result = result + 10 + (ch - "A".code); }
		else { return -1; }
	}
	return result;
}

// The code point a UTF-16 surrogate pair spells when the `\u` escape whose `u`
// sits at `u` holds `high` and is followed by a low-surrogate escape; else -1.
function pairedCodePoint(b: Bytes, u: int32, high: int32): int32 {
	if (high < 55296 || high > 56319 || u + 10 >= b.length) return -1;
	if (b[u + 5] != "\\".code || b[u + 6] != "u".code) return -1;
	const low = hexAt(b, u + 7);
	if (low < 56320 || low > 57343) return -1;
	return 65536 + ((high - 55296) * 1024) + (low - 56320);
}

function utf8Width(codePoint: int32): int64 {
	if (codePoint < 0x80) return 1;
	if (codePoint < 0x800) return 2;
	if (codePoint < 0x10000) return 3;
	return 4;
}

function writeUtf8(bytes: EncodingBytes, at: EncodingIndex, cp: int32): EncodingIndex {
	if (cp < 0x80) {
		bytes[at] = cp as uint8;
		return at + 1;
	}
	if (cp < 0x800) {
		bytes[at] = (0xC0 | (cp >> 6)) as uint8;
		bytes[at + 1] = (0x80 | (cp & 0x3F)) as uint8;
		return at + 2;
	}
	if (cp < 0x10000) {
		bytes[at] = (0xE0 | (cp >> 12)) as uint8;
		bytes[at + 1] = (0x80 | ((cp >> 6) & 0x3F)) as uint8;
		bytes[at + 2] = (0x80 | (cp & 0x3F)) as uint8;
		return at + 3;
	}
	bytes[at] = (0xF0 | (cp >> 18)) as uint8;
	bytes[at + 1] = (0x80 | ((cp >> 12) & 0x3F)) as uint8;
	bytes[at + 2] = (0x80 | ((cp >> 6) & 0x3F)) as uint8;
	bytes[at + 3] = (0x80 | (cp & 0x3F)) as uint8;
	return at + 4;
}

// ===== Array Parser =====

function parseArray(input: string, b: Bytes, ref pos: int32, depth: int32): ParseResult {
	const start = pos;
	const len = b.length;
	pos = skipWs(b, pos + 1);
	const items: JsonValue[] = [];

	if (pos < len && b[pos] == "]".code) {
		pos = pos + 1;
		return Result.ok(jsonArray(items));
	}

	while (pos < len) {
		pos = skipWs(b, pos);
		const elem = try parseValue(input, b, pos, depth + 1);
		items.push(elem);
		pos = skipWs(b, pos);

		if (pos >= len) return errorAt("Unterminated array", start);
		const ch = b[pos];
		if (ch == "]".code) {
			pos = pos + 1;
			return Result.ok(jsonArray(items));
		}
		if (ch != ",".code) {
			return errorAt("Expected ',' or ']' in array", pos);
		}
		pos = pos + 1;
	}
	return errorAt("Unterminated array", start);
}

// ===== Object Parser =====

function parseObject(input: string, b: Bytes, ref pos: int32, depth: int32): ParseResult {
	const start = pos;
	const len = b.length;
	pos = skipWs(b, pos + 1);
	const keys: string[] = [];
	const values: JsonValue[] = [];

	if (pos < len && b[pos] == "}".code) {
		pos = pos + 1;
		return Result.ok(jsonObject(keys, values));
	}

	while (pos < len) {
		pos = skipWs(b, pos);
		if (pos >= len || b[pos] != "\"".code) {
			return errorAt("Expected string key", pos);
		}
		const key = try parseString(input, b, pos);
		pos = skipWs(b, pos);

		if (pos >= len || b[pos] != ":".code) {
			return errorAt("Expected ':'", pos);
		}
		pos = skipWs(b, pos + 1);

		const value = try parseValue(input, b, pos, depth + 1);
		// Duplicate key: last one wins, first position kept (JS parity —
		// engine objects cannot hold two entries for one key).
		let existing = -1;
		for (let ki = 0; ki < keys.length; ki = ki + 1) {
			if (keys[ki] == key) {
				existing = ki;
				break;
			}
		}
		if (existing >= 0) {
			values[existing] = value;
		} else {
			keys.push(key);
			values.push(value);
		}
		pos = skipWs(b, pos);

		if (pos >= len) return errorAt("Unterminated object", start);
		const ch = b[pos];
		if (ch == "}".code) {
			pos = pos + 1;
			return Result.ok(jsonObject(keys, values));
		}
		if (ch != ",".code) {
			return errorAt("Expected ',' or '}' in object", pos);
		}
		pos = pos + 1;
	}
	return errorAt("Unterminated object", start);
}

// ===== Tests =====

test "parse null" {
	const r = parseJson("null");
	assert r.ok;
	assert r.value.kind == JsonKind.Null;
}

test "parse true" {
	const r = parseJson("true");
	assert r.ok;
	assert r.value.kind == JsonKind.Bool;
	assert r.value.boolVal == true;
}

test "parse false" {
	const r = parseJson("false");
	assert r.ok;
	assert r.value.kind == JsonKind.Bool;
	assert r.value.boolVal == false;
}

test "parse integer" {
	const r = parseJson("42");
	assert r.ok;
	assert r.value.kind == JsonKind.Int;
	if (r.value.kind == JsonKind.Int) assert r.value.intVal == (42 as int64);
}

test "parse negative" {
	const r = parseJson("-3.14");
	assert r.ok;
}

test "parse string" {
	const r = parseJson("\"hello\"");
	assert r.ok;
	assert r.value.kind == JsonKind.String;
	assert r.value.strVal == "hello";
}

test "parse string with escapes" {
	const r = parseJson("\"a\\nb\"");
	assert r.ok;
	assert r.value.kind == JsonKind.String;
	assert r.value.strVal == "a\nb";
}

test "parse string with utf-8 content" {
	const r = parseJson("\"vào trận → ok\"");
	assert r.ok;
	assert r.value.kind == JsonKind.String;
	assert r.value.strVal == "vào trận → ok";
}

test "parse object with utf-8 value" {
	const r = parseJson("{\"k\":\"5s → crash\"}");
	assert r.ok;
	assert r.value.kind == JsonKind.Object;
	if (r.value.kind == JsonKind.Object) {
		const v0 = r.value.values[0];
		assert v0.kind == JsonKind.String;
		if (v0.kind == JsonKind.String) assert v0.strVal == "5s → crash";
	}
}

test "parse empty array" {
	const r = parseJson("[]");
	assert r.ok;
	assert r.value.kind == JsonKind.Array;
	assert r.value.items.length == 0;
}

test "parse array" {
	const r = parseJson("[1, 2, 3]");
	assert r.ok;
	assert r.value.kind == JsonKind.Array;
	if (r.value.kind == JsonKind.Array) {
		assert r.value.items.length == 3;
		const first = r.value.items[0];
		if (first.kind == JsonKind.Int) assert first.intVal == (1 as int64);
	}
}

test "parse empty object" {
	const r = parseJson("{}");
	assert r.ok;
	assert r.value.kind == JsonKind.Object;
	assert r.value.keys.length == 0;
}

test "parse object" {
	const r = parseJson("{\"name\": \"Alice\", \"age\": 30}");
	assert r.ok;
	assert r.value.kind == JsonKind.Object;
	if (r.value.kind == JsonKind.Object) {
		assert r.value.keys.length == 2;
		assert r.value.keys[0] == "name";
		const v0 = r.value.values[0];
		if (v0.kind == JsonKind.String) assert v0.strVal == "Alice";
		const v1 = r.value.values[1];
		if (v1.kind == JsonKind.Int) assert v1.intVal == (30 as int64);
	}
}

test "parse nested" {
	const r = parseJson("{\"data\": [1, true, null]}");
	assert r.ok;
	assert r.value.kind == JsonKind.Object;
	if (r.value.kind == JsonKind.Object) {
		const arr = r.value.values[0];
		if (arr.kind == JsonKind.Array) {
			assert arr.items.length == 3;
			const i0 = arr.items[0];
			if (i0.kind == JsonKind.Int) assert i0.intVal == (1 as int64);
			const i1 = arr.items[1];
			if (i1.kind == JsonKind.Bool) assert i1.boolVal == true;
			assert arr.items[2].kind == JsonKind.Null;
		}
	}
}

test "parse error trailing" {
	const r = parseJson("42 extra");
	assert !r.ok;
}

test "parse error unterminated string" {
	const r = parseJson("\"hello");
	assert !r.ok;
}

test "parse error invalid" {
	const r = parseJson("xyz");
	assert !r.ok;
}

test "an unexpected non-ASCII character is named whole" {
	for (const ch of ["é", "€", "😀"]) {
		const r = parseJson(ch);
		assert !r.ok;
		if (!r.ok) assert r.error == `Unexpected character '${ch}' at position 0`;
	}
}

test "an unexpected non-ASCII character mid-document keeps its byte position" {
	const r = parseJson("[1, €]");
	assert !r.ok;
	if (!r.ok) assert r.error == "Unexpected character '€' at position 4";
}

test "an invalid escape of a non-ASCII character is named whole" {
	for (const ch of ["é", "€", "😀"]) {
		const r = parseJson(`"\\${ch}"`);
		assert !r.ok;
		if (!r.ok) assert r.error == `Invalid escape '\\${ch}' at position 2`;
	}
	const ascii = parseJson("\"\\x\"");
	assert !ascii.ok;
	if (!ascii.ok) assert ascii.error == "Invalid escape '\\x' at position 2";
}

test "parse whitespace" {
	const r = parseJson("  { \"x\" : 1 }  ");
	assert r.ok;
	assert r.value.kind == JsonKind.Object;
	assert r.value.keys[0] == "x";
}

test "duplicate keys: last one wins (JS parity)" {
	const r = parseJson("{\"a\":1,\"a\":2}");
	assert r.ok;
	assert r.value.kind == JsonKind.Object;
	assert r.value.keys.length == 1;
	const v0 = r.value.values[0];
	if (v0.kind == JsonKind.Int) assert v0.intVal == (2 as int64);
}

test "parse keeps object keys in insertion order" {
	const r = parseJson("{\"b\":1,\"2\":2,\"a\":3,\"1\":4}");
	assert r.ok;
	assert r.value.kind == JsonKind.Object;
	assert r.value.keys[0] == "b";
	assert r.value.keys[1] == "2";
	assert r.value.keys[2] == "a";
	assert r.value.keys[3] == "1";
}

test "a parsed float equals parseFloat of its text on and off the exact path" {
	const texts = [
		"0.1", "0.3", "-0.5", "1E5", "1e22", "1e23", "123.456e-5", "4.35",
		"123456789012345.6", "999999999999999.9", "1.7976931348623157e308",
		"5e-324", "2.2250738585072014e-308", "1e-22", "3.0e-23", "7e400",
	];
	for (const text of texts) {
		const r = parseJson(text);
		assert r.ok;
		assert r.value.kind == JsonKind.Number;
		if (r.value.kind == JsonKind.Number) assert r.value.numVal == parseFloat(text);
	}
}

test "a negative zero float keeps its sign and a negative zero int has none" {
	const f = parseJson("-0.0");
	assert f.ok;
	if (f.value.kind == JsonKind.Number) assert 1.0 / f.value.numVal < 0.0;
	const i = parseJson("-0");
	assert i.ok;
	assert i.value.kind == JsonKind.Int;
	if (i.value.kind == JsonKind.Int) assert 1.0 / (i.value.intVal as number) > 0.0;
}

test "integers keep the Int carrier up to int64 and widen past it" {
	for (const text of ["123456789012345", "-123456789012345"]) {
		const r = parseJson(text);
		assert r.ok;
		assert r.value.kind == JsonKind.Int;
		if (r.value.kind == JsonKind.Int) assert r.value.intVal.toString() == text;
	}
	for (const text of ["9223372036854775807", "-9223372036854775808"]) {
		const r = parseJson(text);
		assert r.ok;
		assert r.value.kind == JsonKind.Int;
	}
	const wide = parseJson("9223372036854775808");
	assert wide.ok;
	assert wide.value.kind == JsonKind.Number;
}

test "escapes decode into the same text a literal spells" {
	const r = parseJson("\"a\\\"b\\\\c\\/d\\b\\f\\n\\r\\t caf\\u00e9 \\u4e2d \\ud83d\\ude00 end\"");
	assert r.ok;
	assert r.value.kind == JsonKind.String;
	assert r.value.strVal == "a\"b\\c/d\b\f\n\r\t café 中 😀 end";
}

test "a lone surrogate escape decodes as fromCodePoint spells it" {
	const lone = parseJson("\"x\\ud83dy\\ude00\"");
	assert lone.ok;
	assert lone.value.asString() == "x" + fromCodePoint(55357) + "y" + fromCodePoint(56832);
	const unpaired = parseJson("\"\\ud83d\\u0041\"");
	assert unpaired.ok;
	assert unpaired.value.asString() == fromCodePoint(55357) + "A";
}

test "string and object errors keep their messages and positions" {
	const raw = parseJson("\"a\\nb\u0001\"");
	assert !raw.ok;
	if (!raw.ok) assert raw.error == "Raw control character in string — must be escaped at position 5";
	const hex = parseJson("\"\\u12G4\"");
	assert !hex.ok;
	if (!hex.ok) assert hex.error == "Invalid unicode escape at position 2";
	const open = parseJson("\"ab\\n");
	assert !open.ok;
	if (!open.ok) assert open.error == "Unterminated string at position 0";
	const key = parseJson("{\"a\":1, }");
	assert !key.ok;
	if (!key.ok) assert key.error == "Expected string key at position 8";
}
