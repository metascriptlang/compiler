// MetaScript JSON2 — Recursive Descent Parser
//
// Pure MetaScript. Returns Result<JsonValue, string>.
// Depth-limited to prevent stack overflow.
//
// All scan positions are BYTE offsets (consistent with HTTP/JSON wire
// semantics). We read with `byteAt`, slice with `byteSlice`, and append
// raw bytes during string parsing — that keeps UTF-8 multibyte content
// intact and prevents the position from drifting against `byteLength`.

import { JsonKind, JsonValue } from "./types";
import { jsonNull, jsonBool, jsonNumber, jsonString, jsonArray, jsonObject, jsonInt } from "./builder";
// fromCodePoint is exported from std/core/string prelude — available globally

const DEPTH_LIMIT: number = 1000;

type ParseOk = { node: JsonValue, pos: number };
type ParseResult = Result<ParseOk, string>;

// ===== Public API =====

export function parseJson(input: string): Result<JsonValue, string> {
	let pos = skipWs(input, 0);
	const result = parseValue(input, pos, 0);
	if (!result.ok) return Result.err(result.error);
	pos = skipWs(input, result.value.pos);
	if (pos < input.byteLength) {
		return Result.err(`Unexpected character at position ${pos}`);
	}
	return Result.ok(result.value.node);
}

// ===== Scanning Helpers =====

function skipWs(input: string, pos: number): number {
	let p = pos;
	const len = input.byteLength;
	while (p < len) {
		const ch = input.byteAt(p);
		if (ch !== " ".code && ch !== "\t".code && ch !== "\n".code && ch !== "\r".code) return p;
		p = p + 1;
	}
	return p;
}

function errorAt(msg: string, pos: number): ParseResult {
	return Result.err(`${msg} at position ${pos}`);
}

// ===== Value Parser =====

function parseValue(input: string, pos: number, depth: number): ParseResult {
	if (depth > DEPTH_LIMIT) return errorAt("Maximum nesting depth exceeded", pos);
	if (pos >= input.byteLength) return errorAt("Unexpected end of input", pos);

	const ch = input.byteAt(pos);
	return match (ch) {
		"\"".code => parseString(input, pos),
		"{".code => parseObject(input, pos, depth),
		"[".code => parseArray(input, pos, depth),
		"t".code => parseLiteral(input, pos, "true", jsonBool(true)),
		"f".code => parseLiteral(input, pos, "false", jsonBool(false)),
		"n".code => parseLiteral(input, pos, "null", jsonNull()),
		_ => {
			if (ch === "-".code || (ch >= "0".code && ch <= "9".code)) {
				return parseNumber(input, pos);
			}
			return errorAt(`Unexpected character '${input.byteSlice(pos, pos + 1)}'`, pos);
		},
	};
}

// ===== Literal Parser =====

function parseLiteral(input: string, pos: number, expected: string, value: JsonValue): ParseResult {
	const expectedLen = expected.byteLength as number;
	if (pos + expectedLen > input.byteLength) {
		return errorAt(`Expected '${expected}'`, pos);
	}
	if (input.byteSlice(pos, pos + expectedLen) !== expected) {
		return errorAt(`Expected '${expected}'`, pos);
	}
	return Result.ok({ node: value, pos: pos + expectedLen });
}

// ===== Number Parser =====

function parseNumber(input: string, pos: number): ParseResult {
	let p = pos;
	const len = input.byteLength;

	// Optional minus
	if (p < len && input.byteAt(p) === "-".code) p = p + 1;

	// Integer part
	if (p >= len || input.byteAt(p) < "0".code || input.byteAt(p) > "9".code) {
		return errorAt("Invalid number", pos);
	}
	while (p < len && input.byteAt(p) >= "0".code && input.byteAt(p) <= "9".code) {
		p = p + 1;
	}

	// Decimal part
	let isFloat = false;
	if (p < len && input.byteAt(p) === ".".code) {
		isFloat = true;
		p = p + 1;
		while (p < len && input.byteAt(p) >= "0".code && input.byteAt(p) <= "9".code) {
			p = p + 1;
		}
	}

	// Exponent part
	if (p < len && (input.byteAt(p) === "e".code || input.byteAt(p) === "E".code)) {
		isFloat = true;
		p = p + 1;
		if (p < len && (input.byteAt(p) === "+".code || input.byteAt(p) === "-".code)) {
			p = p + 1;
		}
		while (p < len && input.byteAt(p) >= "0".code && input.byteAt(p) <= "9".code) {
			p = p + 1;
		}
	}

	const numStr = input.byteSlice(pos, p);
	return Result.ok({
		node: isFloat ? jsonNumber(parseFloat(numStr)) : jsonInt(numStr.parseInt()),
		pos: p,
	});
}

// ===== String Parser =====

function parseString(input: string, pos: number): ParseResult {
	if (input.byteAt(pos) !== "\"".code) return errorAt("Expected '\"'", pos);
	let p = pos + 1;
	const len = input.byteLength;
	let result = "";

	// Plain bytes are copied in RUNS (runStart..p), never one byte at a time:
	// a single-byte slice inside a multi-byte UTF-8 sequence is not
	// representable as a string on the Bun host. Runs only break at ASCII
	// bytes (quote/backslash), so every slice stays on character boundaries.
	let runStart = p;
	while (p < len) {
		const ch = input.byteAt(p);
		if (ch === "\"".code) {
			if (runStart < p) result += input.byteSlice(runStart, p);
			return Result.ok({ node: jsonString(result), pos: p + 1 });
		}
		if (ch === "\\".code) {
			if (runStart < p) result += input.byteSlice(runStart, p);
			p = p + 1;
			if (p >= len) return errorAt("Unexpected end of string", p);
			const esc = input.byteAt(p);
			match (esc) {
				"\"".code => { result += "\""; },
				"\\".code => { result += "\\"; },
				"/".code => { result += "/"; },
				"b".code => { result += "\b"; },
				"f".code => { result += "\f"; },
				"n".code => { result += "\n"; },
				"r".code => { result += "\r"; },
				"t".code => { result += "\t"; },
				"u".code => {
					if (p + 4 >= len) return errorAt("Invalid unicode escape", p);
					const hex = input.byteSlice(p + 1, p + 5);
					const codePoint = parseHex(hex);
					if (codePoint < 0) return errorAt("Invalid unicode escape", p);
					// Handle UTF-16 surrogate pairs
					if (codePoint >= 55296 && codePoint <= 56319 && p + 10 < len) {
						if (input.byteAt(p + 5) === "\\".code && input.byteAt(p + 6) === "u".code) {
							const hex2 = input.byteSlice(p + 7, p + 11);
							const low = parseHex(hex2);
							if (low >= 56320 && low <= 57343) {
								const full = 65536 + ((codePoint - 55296) * 1024) + (low - 56320);
								result += fromCodePoint(full);
								p = p + 10;
								p = p + 1;
								runStart = p;
								continue;
							}
						}
					}
					result += fromCodePoint(codePoint);
					p = p + 4;
				},
				_ => { return errorAt(`Invalid escape '\\${input.byteSlice(p, p + 1)}'`, p); },
			};
			// Escape consumed — the next plain run starts after it.
			runStart = p + 1;
		}
		p = p + 1;
	}
	return errorAt("Unterminated string", pos);
}

function parseHex(s: string): number {
	let result = 0;
	let i = 0;
	const len = s.byteLength;
	while (i < len) {
		const ch = s.byteAt(i);
		result = result * 16;
		if (ch >= "0".code && ch <= "9".code) { result = result + (ch - "0".code); }
		else if (ch >= "a".code && ch <= "f".code) { result = result + 10 + (ch - "a".code); }
		else if (ch >= "A".code && ch <= "F".code) { result = result + 10 + (ch - "A".code); }
		else { return -1; }
		i = i + 1;
	}
	return result;
}

// ===== Array Parser =====

function parseArray(input: string, pos: number, depth: number): ParseResult {
	let p = pos + 1; // skip [
	p = skipWs(input, p);
	const items: JsonValue[] = [];

	if (p < input.byteLength && input.byteAt(p) === "]".code) {
		return Result.ok({ node: jsonArray(items), pos: p + 1 });
	}

	while (p < input.byteLength) {
		p = skipWs(input, p);
		const elem = try parseValue(input, p, depth + 1);
		items.push(elem.node);
		p = skipWs(input, elem.pos);

		if (p >= input.byteLength) return errorAt("Unterminated array", pos);
		const ch = input.byteAt(p);
		if (ch === "]".code) {
			return Result.ok({ node: jsonArray(items), pos: p + 1 });
		}
		if (ch !== ",".code) {
			return errorAt("Expected ',' or ']' in array", p);
		}
		p = p + 1;
	}
	return errorAt("Unterminated array", pos);
}

// ===== Object Parser =====

function parseObject(input: string, pos: number, depth: number): ParseResult {
	let p = pos + 1; // skip {
	p = skipWs(input, p);
	const keys: string[] = [];
	const values: JsonValue[] = [];

	if (p < input.byteLength && input.byteAt(p) === "}".code) {
		return Result.ok({ node: jsonObject(keys, values), pos: p + 1 });
	}

	while (p < input.byteLength) {
		p = skipWs(input, p);
		if (input.byteAt(p) !== "\"".code) {
			return errorAt("Expected string key", p);
		}
		const keyResult = try parseString(input, p);
		keys.push(keyResult.node.strVal);
		p = skipWs(input, keyResult.pos);

		if (p >= input.byteLength || input.byteAt(p) !== ":".code) {
			return errorAt("Expected ':'", p);
		}
		p = skipWs(input, p + 1);

		const valResult = try parseValue(input, p, depth + 1);
		values.push(valResult.node);
		p = skipWs(input, valResult.pos);

		if (p >= input.byteLength) return errorAt("Unterminated object", pos);
		const ch = input.byteAt(p);
		if (ch === "}".code) {
			return Result.ok({ node: jsonObject(keys, values), pos: p + 1 });
		}
		if (ch !== ",".code) {
			return errorAt("Expected ',' or '}' in object", p);
		}
		p = p + 1;
	}
	return errorAt("Unterminated object", pos);
}

// ===== Tests =====

test "parse null" {
	const r = parseJson("null");
	assert r.ok;
	assert r.value.kind === JsonKind.Null;
}

test "parse true" {
	const r = parseJson("true");
	assert r.ok;
	assert r.value.kind === JsonKind.Bool;
	assert r.value.boolVal === true;
}

test "parse false" {
	const r = parseJson("false");
	assert r.ok;
	assert r.value.boolVal === false;
}

test "parse integer" {
	const r = parseJson("42");
	assert r.ok;
	assert r.value.kind === JsonKind.Int;
	if (r.value.kind === JsonKind.Int) assert r.value.intVal === (42 as int64);
}

test "parse negative" {
	const r = parseJson("-3.14");
	assert r.ok;
}

test "parse string" {
	const r = parseJson("\"hello\"");
	assert r.ok;
	assert r.value.strVal === "hello";
}

test "parse string with escapes" {
	const r = parseJson("\"a\\nb\"");
	assert r.ok;
	assert r.value.strVal === "a\nb";
}

test "parse string with utf-8 content" {
	const r = parseJson("\"vào trận → ok\"");
	assert r.ok;
	assert r.value.strVal === "vào trận → ok";
}

test "parse object with utf-8 value" {
	const r = parseJson("{\"k\":\"5s → crash\"}");
	assert r.ok;
	assert r.value.values[0].strVal === "5s → crash";
}

test "parse empty array" {
	const r = parseJson("[]");
	assert r.ok;
	assert r.value.kind === JsonKind.Array;
	assert r.value.items.length === 0;
}

test "parse array" {
	const r = parseJson("[1, 2, 3]");
	assert r.ok;
	assert r.value.kind === JsonKind.Array;
	if (r.value.kind === JsonKind.Array) {
		assert r.value.items.length === 3;
		const first = r.value.items[0];
		if (first.kind === JsonKind.Int) assert first.intVal === (1 as int64);
	}
}

test "parse empty object" {
	const r = parseJson("{}");
	assert r.ok;
	assert r.value.kind === JsonKind.Object;
	assert r.value.keys.length === 0;
}

test "parse object" {
	const r = parseJson("{\"name\": \"Alice\", \"age\": 30}");
	assert r.ok;
	assert r.value.kind === JsonKind.Object;
	if (r.value.kind === JsonKind.Object) {
		assert r.value.keys.length === 2;
		assert r.value.keys[0] === "name";
		const v0 = r.value.values[0];
		if (v0.kind === JsonKind.String) assert v0.strVal === "Alice";
		const v1 = r.value.values[1];
		if (v1.kind === JsonKind.Int) assert v1.intVal === (30 as int64);
	}
}

test "parse nested" {
	const r = parseJson("{\"data\": [1, true, null]}");
	assert r.ok;
	assert r.value.kind === JsonKind.Object;
	if (r.value.kind === JsonKind.Object) {
		const arr = r.value.values[0];
		if (arr.kind === JsonKind.Array) {
			assert arr.items.length === 3;
			const i0 = arr.items[0];
			if (i0.kind === JsonKind.Int) assert i0.intVal === (1 as int64);
			const i1 = arr.items[1];
			if (i1.kind === JsonKind.Bool) assert i1.boolVal === true;
			assert arr.items[2].kind === JsonKind.Null;
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

test "parse whitespace" {
	const r = parseJson("  { \"x\" : 1 }  ");
	assert r.ok;
	assert r.value.keys[0] === "x";
}
