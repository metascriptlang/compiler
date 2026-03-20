// MetaScript JSON — Stringify
//
// Serializes JsonValue to JSON string. Uses index-based loops
// (not for-of) for safety with JsonEntry[] containing class pointers.

import { parseJson } from "./parser";
// ===== Helpers =====

const HEX_CHARS: string = "0123456789abcdef";

function hexChar(n: number): string {
	return HEX_CHARS.charAt(n);
}

// ===== String Escaping =====

function escapeString(s: string): string {
	const len = s.length;

	// Fast check: any chars needing escape?
	let needsEscape = false;
	let i = 0;
	while (i < len) {
		const ch = s.charCodeAt(i);
		if (ch === "\"".code || ch === "\\".code || ch < 32) {
			needsEscape = true;
			break;
		}
		i = i + 1;
	}

	if (!needsEscape) return "\"" + s + "\"";

	// Slow path: run-based escape with append()
	let result = "\"";
	let runStart = 0;
	i = 0;
	while (i < len) {
		const ch = s.charCodeAt(i);
		if (ch === "\"".code || ch === "\\".code || ch < 32) {
			// Flush safe run
			if (runStart < i) {
				result.append(s.slice(runStart, i));
			}
			if (ch === "\"".code) {
				result.append("\\\"");
			} else if (ch === "\\".code) {
				result.append("\\\\");
			} else if (ch === "\n".code) {
				result.append("\\n");
			} else if (ch === "\r".code) {
				result.append("\\r");
			} else if (ch === "\t".code) {
				result.append("\\t");
			} else if (ch === "\b".code) {
				result.append("\\b");
			} else if (ch === "\f".code) {
				result.append("\\f");
			} else {
				// Control characters: \u00XX
				result.append("\\u00");
				result.append(hexChar(ch / 16));
				result.append(hexChar(ch % 16));
			}
			runStart = i + 1;
		}
		i = i + 1;
	}
	// Flush trailing safe run
	if (runStart < len) {
		result.append(s.slice(runStart, len));
	}
	result.append("\"");
	return result;
}

// ===== Array/Object Stringify =====

function stringifyArray(value: JsonValue): string {
	let result = "[";
	let i = 0;
	const len = value.arrVal.length;
	while (i < len) {
		if (i > 0) result.append(",");
		result.append(stringify(value.arrVal[i]));
		i = i + 1;
	}
	result.append("]");
	return result;
}

function stringifyObject(value: JsonValue): string {
	let result = "{";
	let i = 0;
	const len = value.objKeys.length;
	while (i < len) {
		if (i > 0) result.append(",");
		result.append(escapeString(value.objKeys[i]));
		result.append(":");
		result.append(stringify(value.objVals[i]));
		i = i + 1;
	}
	result.append("}");
	return result;
}

// ===== Public API =====

export function stringify(value: JsonValue): string {
	if (value.kind === JsonKind.Null) return "null";
	if (value.kind === JsonKind.Bool) {
		if (value.boolVal) return "true";
		return "false";
	}
	if (value.kind === JsonKind.Number) return "" + value.numVal;
	if (value.kind === JsonKind.String) return escapeString(value.strVal);
	if (value.kind === JsonKind.Array) return stringifyArray(value);
	if (value.kind === JsonKind.Object) return stringifyObject(value);
	return "null";
}

// ===== Tests =====

import { jsonNull, jsonBool, jsonNumber, jsonString, jsonArray, jsonObject, jsonObjectFromKV } from "./builder";

test "stringify null" {
	assert stringify(jsonNull()) === "null";
}

test "stringify true" {
	assert stringify(jsonBool(true)) === "true";
}

test "stringify false" {
	assert stringify(jsonBool(false)) === "false";
}

test "stringify integer" {
	assert stringify(jsonNumber(42)) === "42";
}

test "stringify float" {
	assert stringify(jsonNumber(3.14)) === "3.14";
}

test "stringify simple string" {
	assert stringify(jsonString("hello")) === "\"hello\"";
}

test "stringify string with quotes" {
	assert stringify(jsonString("say \"hi\"")) === "\"say \\\"hi\\\"\"";
}

test "stringify string with newline" {
	assert stringify(jsonString("a\nb")) === "\"a\\nb\"";
}

test "stringify string with backslash" {
	assert stringify(jsonString("a\\b")) === "\"a\\\\b\"";
}

test "stringify string with tab" {
	assert stringify(jsonString("a\tb")) === "\"a\\tb\"";
}

test "stringify empty array" {
	assert stringify(jsonArray([])) === "[]";
}

test "stringify array" {
	assert stringify(jsonArray([jsonNumber(1), jsonNumber(2)])) === "[1,2]";
}

test "stringify empty object" {
	assert stringify(jsonObject()) === "{}";
}

test "stringify object" {
	const obj = jsonObjectFromKV(["a"], [jsonNumber(1)]);
	assert stringify(obj) === "{\"a\":1}";
}

test "stringify nested" {
	const inner = jsonArray([jsonBool(true), jsonNull()]);
	const obj = jsonObjectFromKV(["x"], [inner]);
	assert stringify(obj) === "{\"x\":[true,null]}";
}

test "roundtrip simple object" {
	const input = "{\"name\":\"MetaScript\",\"version\":1}";
	const r = parseJson(input);
	assert r.ok;
	assert stringify(r.value) === input;
}

test "roundtrip array" {
	const input = "[1,2,3]";
	const r = parseJson(input);
	assert r.ok;
	assert stringify(r.value) === input;
}

test "roundtrip nested" {
	const input = "{\"a\":{\"b\":[1,true,null,\"hi\"]}}";
	const r = parseJson(input);
	assert r.ok;
	assert stringify(r.value) === input;
}

test "roundtrip escaped string" {
	const input = "{\"msg\":\"hello\\nworld\"}";
	const r = parseJson(input);
	assert r.ok;
	assert stringify(r.value) === input;
}
