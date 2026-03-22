// MetaScript JSON2 — Recursive Descent Parser
//
// Pure MetaScript. Returns Result<JsonValue, string>.
// Depth-limited to prevent stack overflow.

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
		const ch = input.charCodeAt(p);
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

	const ch = input.charCodeAt(pos);
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
			return errorAt(`Unexpected character '${input.charAt(pos)}'`, pos);
		},
	};
}

// ===== Literal Parser =====

function parseLiteral(input: string, pos: number, expected: string, value: JsonValue): ParseResult {
	if (pos + expected.length > input.byteLength) {
		return errorAt(`Expected '${expected}'`, pos);
	}
	if (input.slice(pos, pos + expected.length) !== expected) {
		return errorAt(`Expected '${expected}'`, pos);
	}
	return Result.ok({ node: value, pos: pos + expected.length });
}

// ===== Number Parser =====

function parseNumber(input: string, pos: number): ParseResult {
	let p = pos;
	const len = input.byteLength;

	// Optional minus
	if (p < len && input.charCodeAt(p) === "-".code) p = p + 1;

	// Integer part
	if (p >= len || input.charCodeAt(p) < "0".code || input.charCodeAt(p) > "9".code) {
		return errorAt("Invalid number", pos);
	}
	while (p < len && input.charCodeAt(p) >= "0".code && input.charCodeAt(p) <= "9".code) {
		p = p + 1;
	}

	// Decimal part
	let isFloat = false;
	if (p < len && input.charCodeAt(p) === ".".code) {
		isFloat = true;
		p = p + 1;
		while (p < len && input.charCodeAt(p) >= "0".code && input.charCodeAt(p) <= "9".code) {
			p = p + 1;
		}
	}

	// Exponent part
	if (p < len && (input.charCodeAt(p) === "e".code || input.charCodeAt(p) === "E".code)) {
		isFloat = true;
		p = p + 1;
		if (p < len && (input.charCodeAt(p) === "+".code || input.charCodeAt(p) === "-".code)) {
			p = p + 1;
		}
		while (p < len && input.charCodeAt(p) >= "0".code && input.charCodeAt(p) <= "9".code) {
			p = p + 1;
		}
	}

	const numStr = input.slice(pos, p);
	return Result.ok({
		node: isFloat ? jsonNumber(parseFloat(numStr)) : jsonInt(numStr.parseInt()),
		pos: p,
	});
}

// ===== String Parser =====

function parseString(input: string, pos: number): ParseResult {
	if (input.charCodeAt(pos) !== "\"".code) return errorAt("Expected '\"'", pos);
	let p = pos + 1;
	const len = input.byteLength;
	let result = "";

	while (p < len) {
		const ch = input.charCodeAt(p);
		if (ch === "\"".code) {
			return Result.ok({ node: jsonString(result), pos: p + 1 });
		}
		if (ch === "\\".code) {
			p = p + 1;
			if (p >= len) return errorAt("Unexpected end of string", p);
			const esc = input.charCodeAt(p);
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
					const hex = input.slice(p + 1, p + 5);
					const codePoint = parseHex(hex);
					if (codePoint < 0) return errorAt("Invalid unicode escape", p);
					// Handle UTF-16 surrogate pairs
					if (codePoint >= 55296 && codePoint <= 56319 && p + 10 < len) {
						if (input.charCodeAt(p + 5) === "\\".code && input.charCodeAt(p + 6) === "u".code) {
							const hex2 = input.slice(p + 7, p + 11);
							const low = parseHex(hex2);
							if (low >= 56320 && low <= 57343) {
								const full = 65536 + ((codePoint - 55296) * 1024) + (low - 56320);
								result += fromCodePoint(full);
								p = p + 10;
								p = p + 1;
								continue;
							}
						}
					}
					result += fromCodePoint(codePoint);
					p = p + 4;
				},
				_ => { return errorAt(`Invalid escape '\\${input.charAt(p)}'`, p); },
			};
		} else {
			result += input.charAt(p);
		}
		p = p + 1;
	}
	return errorAt("Unterminated string", pos);
}

function parseHex(s: string): number {
	let result = 0;
	let i = 0;
	while (i < s.length) {
		const ch = s.charCodeAt(i);
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

	if (p < input.byteLength && input.charCodeAt(p) === "]".code) {
		return Result.ok({ node: jsonArray(items), pos: p + 1 });
	}

	while (p < input.byteLength) {
		p = skipWs(input, p);
		const elem = try parseValue(input, p, depth + 1);
		items.push(elem.node);
		p = skipWs(input, elem.pos);

		if (p >= input.byteLength) return errorAt("Unterminated array", pos);
		const ch = input.charCodeAt(p);
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

	if (p < input.byteLength && input.charCodeAt(p) === "}".code) {
		return Result.ok({ node: jsonObject(keys, values), pos: p + 1 });
	}

	while (p < input.byteLength) {
		p = skipWs(input, p);
		if (input.charCodeAt(p) !== "\"".code) {
			return errorAt("Expected string key", p);
		}
		const keyResult = try parseString(input, p);
		keys.push(keyResult.node.strVal);
		p = skipWs(input, keyResult.pos);

		if (p >= input.byteLength || input.charCodeAt(p) !== ":".code) {
			return errorAt("Expected ':'", p);
		}
		p = skipWs(input, p + 1);

		const valResult = try parseValue(input, p, depth + 1);
		values.push(valResult.node);
		p = skipWs(input, valResult.pos);

		if (p >= input.byteLength) return errorAt("Unterminated object", pos);
		const ch = input.charCodeAt(p);
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
	assert r.value.numVal === 42;
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

test "parse empty array" {
	const r = parseJson("[]");
	assert r.ok;
	assert r.value.kind === JsonKind.Array;
	assert r.value.items.length === 0;
}

test "parse array" {
	const r = parseJson("[1, 2, 3]");
	assert r.ok;
	assert r.value.items.length === 3;
	assert r.value.items[0].numVal === 1;
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
	assert r.value.keys.length === 2;
	assert r.value.keys[0] === "name";
	assert r.value.values[0].strVal === "Alice";
	assert r.value.values[1].numVal === 30;
}

test "parse nested" {
	const r = parseJson("{\"data\": [1, true, null]}");
	assert r.ok;
	assert r.value.values[0].items.length === 3;
	assert r.value.values[0].items[0].numVal === 1;
	assert r.value.values[0].items[1].boolVal === true;
	assert r.value.values[0].items[2].kind === JsonKind.Null;
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
