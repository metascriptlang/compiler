// MetaScript JSON — Recursive Descent Parser
//
// Pure MetaScript implementation. Returns Result<JsonValue, string> with
// error position on failure. Optimized: uses charCodeAt for scanning,
// append() for string building, manual integer parsing fast path.

import { jsonNull, jsonBool, jsonNumber, jsonString, jsonArray, jsonObject, jsonObjectFromKV } from "./builder";
import { fromCodePoint } from "std/core/string";

// ===== Internal Types =====

interface ParseResult {
	node: JsonValue;
	pos: number;
}

type JsonResult = Result<ParseResult, string>;

// ===== Scanning Helpers =====

function skipWhitespace(input: string, pos: number): number {
	let p = pos;
	const len = input.byteLength();
	while (p < len) {
		const ch = input.charCodeAt(p);
		if (ch !== " ".code && ch !== "\t".code && ch !== "\n".code && ch !== "\r".code) break;
		p = p + 1;
	}
	return p;
}

function isDigit(ch: number): boolean {
	return ch >= "0".code && ch <= "9".code;
}

function hexDigit(ch: number): number {
	if (ch >= 48 && ch <= 57) return ch - 48;       // '0'-'9'
	if (ch >= 97 && ch <= 102) return 10 + ch - 97;  // 'a'-'f'
	if (ch >= 65 && ch <= 70) return 10 + ch - 65;   // 'A'-'F'
	return -1;
}

function parseHex4(input: string, pos: number): number {
	let result = 0;
	let i = 0;
	while (i < 4) {
		const d = hexDigit(input.charCodeAt(pos + i));
		if (d < 0) return -1;
		result = result * 16 + d;
		i = i + 1;
	}
	return result;
}

// ===== Literal Parsing =====

function parseLiteral(input: string, pos: number, expected: string, value: JsonValue): JsonResult {
	if (pos + expected.length > input.byteLength()) {
		return Result.err("expected '" + expected + "' at position " + pos);
	}
	let i = 0;
	while (i < expected.length) {
		if (input.charCodeAt(pos + i) !== expected.charCodeAt(i)) {
			return Result.err("expected '" + expected + "' at position " + pos);
		}
		i = i + 1;
	}
	return Result.ok({ node: value, pos: pos + expected.length });
}

// ===== String Parsing =====

function parseString(input: string, pos: number): JsonResult {
	// pos points at opening "
	let p = pos + 1;
	const len = input.byteLength();

	// Fast scan: look for closing " without any escapes
	let hasEscape = false;
	let scanP = p;
	while (scanP < len) {
		const ch = input.charCodeAt(scanP);
		if (ch === "\"".code) break;
		if (ch === "\\".code) {
			hasEscape = true;
			scanP = scanP + 2;
		} else {
			scanP = scanP + 1;
		}
	}

	if (scanP >= len) {
		return Result.err("unterminated string at position " + pos);
	}

	// Fast path: no escapes — single slice
	if (!hasEscape) {
		const s = input.slice(p, scanP);
		return Result.ok({ node: jsonString(s), pos: scanP + 1 });
	}

	// Slow path: rebuild with escape handling using append()
	let result = "";
	let runStart = p;
	p = p; // restart from after opening quote
	while (p < len) {
		const ch = input.charCodeAt(p);
		if (ch === "\"".code) {
			// Flush remaining run
			if (runStart < p) {
				result.append(input.slice(runStart, p));
			}
			return Result.ok({ node: jsonString(result), pos: p + 1 });
		}
		if (ch === "\\".code) {
			// Flush run before escape
			if (runStart < p) {
				result.append(input.slice(runStart, p));
			}
			p = p + 1;
			if (p >= len) {
				return Result.err("unterminated escape at position " + p);
			}
			const esc = input.charCodeAt(p);
			if (esc === "\"".code) {
				result.append("\"");
			} else if (esc === "\\".code) {
				result.append("\\");
			} else if (esc === "/".code) {
				result.append("/");
			} else if (esc === "n".code) {
				result.append("\n");
			} else if (esc === "r".code) {
				result.append("\r");
			} else if (esc === "t".code) {
				result.append("\t");
			} else if (esc === "b".code) {
				result.append("\b");
			} else if (esc === "f".code) {
				result.append("\f");
			} else if (esc === "u".code) {
				// \uXXXX — 4 hex digits
				if (p + 4 >= len) {
					return Result.err("incomplete unicode escape at position " + p);
				}
				const hex = parseHex4(input, p + 1);
				if (hex < 0) {
					return Result.err("invalid unicode escape at position " + p);
				}
				p = p + 4; // skip 4 hex digits (loop adds 1 more below)
				// Surrogate pair: \uD800-\uDBFF followed by \uDC00-\uDFFF
				if (hex >= 0xD800 && hex <= 0xDBFF) {
					if (p + 2 < len && input.charCodeAt(p + 1) === "\\".code && input.charCodeAt(p + 2) === "u".code) {
						const low = parseHex4(input, p + 3);
						if (low >= 0xDC00 && low <= 0xDFFF) {
							const cp = 0x10000 + ((hex - 0xD800) * 1024) + (low - 0xDC00);
							result.append(fromCodePoint(cp));
							p = p + 6; // skip \uXXXX
						} else {
							result.append(fromCodePoint(hex));
						}
					} else {
						result.append(fromCodePoint(hex));
					}
				} else {
					result.append(fromCodePoint(hex));
				}
			} else {
				// Lenient fallback: emit the escaped char as-is
				result.append(input.charAt(p));
			}
			p = p + 1;
			runStart = p;
		} else {
			p = p + 1;
		}
	}
	return Result.err("unterminated string at position " + pos);
}

// ===== Number Parsing =====

function parseNumber(input: string, pos: number): JsonResult {
	let p = pos;
	const len = input.byteLength();

	// Fast path: try to parse as integer directly
	let negative = false;
	if (p < len && input.charCodeAt(p) === "-".code) {
		negative = true;
		p = p + 1;
	}

	if (p >= len || !isDigit(input.charCodeAt(p))) {
		return Result.err("expected digit at position " + p);
	}

	// Leading zero check
	if (input.charCodeAt(p) === "0".code && p + 1 < len && isDigit(input.charCodeAt(p + 1))) {
		return Result.err("leading zeros not allowed at position " + p);
	}

	// Read integer part
	let intVal: number = 0;
	let isFloat = false;
	while (p < len && isDigit(input.charCodeAt(p))) {
		intVal = intVal * 10 + (input.charCodeAt(p) - "0".code);
		p = p + 1;
	}

	// Fractional part — fall back to parseFloat for precision
	if (p < len && input.charCodeAt(p) === ".".code) {
		isFloat = true;
		p = p + 1;
		if (p >= len || !isDigit(input.charCodeAt(p))) {
			return Result.err("expected digit after '.' at position " + p);
		}
		while (p < len && isDigit(input.charCodeAt(p))) {
			p = p + 1;
		}
	}

	// Exponent
	if (p < len && (input.charCodeAt(p) === "e".code || input.charCodeAt(p) === "E".code)) {
		isFloat = true;
		p = p + 1;
		if (p < len && (input.charCodeAt(p) === "+".code || input.charCodeAt(p) === "-".code)) {
			p = p + 1;
		}
		if (p >= len || !isDigit(input.charCodeAt(p))) {
			return Result.err("expected digit in exponent at position " + p);
		}
		while (p < len && isDigit(input.charCodeAt(p))) {
			p = p + 1;
		}
	}

	// Integer fast path: no slice + parseFloat needed
	if (!isFloat) {
		const num = negative ? -intVal : intVal;
		return Result.ok({ node: jsonNumber(num), pos: p });
	}

	// Float: use slice + parseFloat for IEEE-754 precision
	const numStr = input.slice(pos, p);
	const num = numStr.parseFloat();
	return Result.ok({ node: jsonNumber(num), pos: p });
}

// ===== Array Parsing =====

function parseArray(input: string, pos: number): JsonResult {
	let p = pos + 1; // skip [
	p = skipWhitespace(input, p);

	// Empty array
	if (p < input.byteLength() && input.charCodeAt(p) === "]".code) {
		return Result.ok({ node: jsonArray([]), pos: p + 1 });
	}

	const items: JsonValue[] = [];
	while (p < input.byteLength()) {
		const elem = try parseValue(input, p);
		items.push(elem.node);
		p = skipWhitespace(input, elem.pos);

		if (p >= input.byteLength()) {
			return Result.err("unterminated array at position " + pos);
		}
		if (input.charCodeAt(p) === ",".code) {
			p = skipWhitespace(input, p + 1);
		} else if (input.charCodeAt(p) === "]".code) {
			return Result.ok({ node: jsonArray(items), pos: p + 1 });
		} else {
			return Result.err("expected ',' or ']' at position " + p);
		}
	}
	return Result.err("unterminated array at position " + pos);
}

// ===== Object Parsing =====

function parseObject(input: string, pos: number): JsonResult {
	let p = pos + 1; // skip {
	p = skipWhitespace(input, p);

	// Empty object
	if (p < input.byteLength() && input.charCodeAt(p) === "}".code) {
		return Result.ok({ node: jsonObject(), pos: p + 1 });
	}

	const keys: string[] = [];
	const vals: JsonValue[] = [];
	while (p < input.byteLength()) {
		// Key must be a string
		if (input.charCodeAt(p) !== "\"".code) {
			return Result.err("expected string key at position " + p);
		}
		const keyResult = try parseString(input, p);
		// Push key immediately — DRC may free keyResult.node on next iteration
		keys.push(keyResult.node.strVal);
		p = skipWhitespace(input, keyResult.pos);

		// Expect colon
		if (p >= input.byteLength() || input.charCodeAt(p) !== ":".code) {
			return Result.err("expected ':' at position " + p);
		}
		p = skipWhitespace(input, p + 1);

		// Value
		const valResult = try parseValue(input, p);
		vals.push(valResult.node);
		p = skipWhitespace(input, valResult.pos);

		if (p >= input.byteLength()) {
			return Result.err("unterminated object at position " + pos);
		}
		if (input.charCodeAt(p) === ",".code) {
			p = skipWhitespace(input, p + 1);
		} else if (input.charCodeAt(p) === "}".code) {
			return Result.ok({ node: jsonObjectFromKV(keys, vals), pos: p + 1 });
		} else {
			return Result.err("expected ',' or '}' at position " + p);
		}
	}
	return Result.err("unterminated object at position " + pos);
}

// ===== Value Dispatch =====

function parseValue(input: string, pos: number): JsonResult {
	const p = skipWhitespace(input, pos);
	if (p >= input.byteLength()) {
		return Result.err("unexpected end of input");
	}

	const ch = input.charCodeAt(p);
	if (ch === "\"".code) return parseString(input, p);
	if (ch === "{".code) return parseObject(input, p);
	if (ch === "[".code) return parseArray(input, p);
	if (ch === "t".code) return parseLiteral(input, p, "true", jsonBool(true));
	if (ch === "f".code) return parseLiteral(input, p, "false", jsonBool(false));
	if (ch === "n".code) return parseLiteral(input, p, "null", jsonNull());
	if (ch === "-".code || isDigit(ch)) return parseNumber(input, p);
	return Result.err("unexpected character at position " + p);
}

// ===== Public API =====

export function parseJson(input: string): Result<JsonValue, string> {
	if (input.byteLength() === 0) {
		return Result.err("unexpected end of input");
	}
	const result = parseValue(input, 0);
	if (!result.ok) return Result.err(result.error);
	const endPos = skipWhitespace(input, result.value.pos);
	if (endPos < input.byteLength()) {
		return Result.err("unexpected content after value at position " + endPos);
	}
	return Result.ok(result.value.node);
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
	assert r.value.kind === JsonKind.Bool;
	assert r.value.boolVal === false;
}

test "parse integer" {
	const r = parseJson("42");
	assert r.ok;
	assert r.value.kind === JsonKind.Number;
	assert r.value.numVal === 42;
}

test "parse zero" {
	const r = parseJson("0");
	assert r.ok;
	assert r.value.numVal === 0;
}

test "parse negative number" {
	const r = parseJson("-7");
	assert r.ok;
	assert r.value.numVal === -7;
}

test "parse float" {
	const r = parseJson("3.14");
	assert r.ok;
	assert r.value.numVal === 3.14;
}

test "parse exponent" {
	const r = parseJson("1e10");
	assert r.ok;
	assert r.value.numVal === 1e10;
}

test "parse negative exponent" {
	const r = parseJson("5e-3");
	assert r.ok;
	assert r.value.numVal === 5e-3;
}

test "parse simple string" {
	const r = parseJson("\"hello\"");
	assert r.ok;
	assert r.value.kind === JsonKind.String;
	assert r.value.strVal === "hello";
}

test "parse empty string" {
	const r = parseJson("\"\"");
	assert r.ok;
	assert r.value.strVal === "";
}

test "parse string with escapes" {
	const r = parseJson("\"hello\\nworld\"");
	assert r.ok;
	assert r.value.strVal === "hello\nworld";
}

test "parse string with escaped quote" {
	const r = parseJson("\"say \\\"hi\\\"\"");
	assert r.ok;
	assert r.value.strVal === "say \"hi\"";
}

test "parse string with backslash" {
	const r = parseJson("\"a\\\\b\"");
	assert r.ok;
	assert r.value.strVal === "a\\b";
}

test "parse string with tab" {
	const r = parseJson("\"a\\tb\"");
	assert r.ok;
	assert r.value.strVal === "a\tb";
}

test "parse empty array" {
	const r = parseJson("[]");
	assert r.ok;
	assert r.value.kind === JsonKind.Array;
	assert r.value.arrVal.length === 0;
}

test "parse array of numbers" {
	const r = parseJson("[1, 2, 3]");
	assert r.ok;
	assert r.value.arrVal.length === 3;
	assert r.value.arrVal[0].numVal === 1;
	assert r.value.arrVal[1].numVal === 2;
	assert r.value.arrVal[2].numVal === 3;
}

test "parse nested array" {
	const r = parseJson("[[1, 2], [3]]");
	assert r.ok;
	assert r.value.arrVal.length === 2;
	assert r.value.arrVal[0].arrVal.length === 2;
	assert r.value.arrVal[1].arrVal.length === 1;
}

test "parse empty object" {
	const r = parseJson("{}");
	assert r.ok;
	assert r.value.kind === JsonKind.Object;
	assert r.value.objKeys.length === 0;
}

test "parse simple object" {
	const r = parseJson("{\"name\": \"MetaScript\"}");
	assert r.ok;
	assert r.value.objKeys.length === 1;
	assert r.value.objKeys[0] === "name";
	assert r.value.objVals[0].strVal === "MetaScript";
}

test "parse object with multiple keys" {
	const r = parseJson("{\"a\": 1, \"b\": 2}");
	assert r.ok;
	assert r.value.objKeys.length === 2;
	assert r.value.objKeys[0] === "a";
	assert r.value.objVals[0].numVal === 1;
	assert r.value.objKeys[1] === "b";
	assert r.value.objVals[1].numVal === 2;
}

test "parse nested object" {
	const r = parseJson("{\"outer\": {\"inner\": 42}}");
	assert r.ok;
	assert r.value.objVals[0].objKeys[0] === "inner";
	assert r.value.objVals[0].objVals[0].numVal === 42;
}

test "parse mixed types" {
	const r = parseJson("{\"s\": \"hi\", \"n\": 1, \"b\": true, \"x\": null, \"a\": [1]}");
	assert r.ok;
	assert r.value.objKeys.length === 5;
}

test "parse with whitespace" {
	const r = parseJson("  { \"key\" : \"val\" }  ");
	assert r.ok;
	assert r.value.objKeys[0] === "key";
	assert r.value.objVals[0].strVal === "val";
}

test "error: empty input" {
	const r = parseJson("");
	assert !r.ok;
}

test "error: unterminated string" {
	const r = parseJson("\"hello");
	assert !r.ok;
}

test "error: unexpected character" {
	const r = parseJson("@");
	assert !r.ok;
}

test "error: trailing content" {
	const r = parseJson("123 abc");
	assert !r.ok;
}

test "error: leading zeros" {
	const r = parseJson("007");
	assert !r.ok;
}

test "error: unterminated array" {
	const r = parseJson("[1, 2");
	assert !r.ok;
}

test "error: unterminated object" {
	const r = parseJson("{\"a\": 1");
	assert !r.ok;
}

test "parse unicode escape ASCII" {
	const r = parseJson("\"\\u0041\"");
	assert r.ok;
	assert r.value.strVal === "A";
}

test "parse unicode escape newline" {
	const r = parseJson("\"\\u000A\"");
	assert r.ok;
	assert r.value.strVal === "\n";
}

test "parse backspace escape" {
	const r = parseJson("\"a\\bb\"");
	assert r.ok;
	assert r.value.strVal === "a\bb";
}

test "error: incomplete unicode escape" {
	const r = parseJson("\"\\u00\"");
	assert !r.ok;
}

test "error: invalid hex in unicode escape" {
	const r = parseJson("\"\\u00GG\"");
	assert !r.ok;
}
