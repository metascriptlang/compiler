// MetaScript JSON2 — Serializer
//
// Two-path: compact (stringify) and pretty (stringifyPretty).
// Recursive dispatch via match on value.kind.

import { JsonKind, JsonValue } from "./types";
import { jsonNull, jsonBool, jsonNumber, jsonString, jsonArray, jsonObject } from "./builder";

// ===== Compact Stringify =====
// color=false: {"key":"value","n":3}  (standard JSON)
// color=true:  { key: "value", n: 3 } (colored console output, unquoted keys)

export function stringify(value: JsonValue, color: boolean = false): string {
	if (value === null) return color ? "\x1b[2mnull\x1b[0m" : "null";
	return match (value.kind) {
		JsonKind.Null => { return color ? "\x1b[2mnull\x1b[0m" : "null"; },
		JsonKind.Bool => {
			const s = value.boolVal ? "true" : "false";
			return color ? "\x1b[36m" + s + "\x1b[0m" : s;
		},
		JsonKind.Number => {
			const s = value.numVal.toString();
			return color ? "\x1b[33m" + s + "\x1b[0m" : s;
		},
		JsonKind.String => {
			return color ? "\x1b[32m" + escapeString(value.strVal) + "\x1b[0m" : escapeString(value.strVal);
		},
		JsonKind.Array => {
			let result = "[";
			let i = 0;
			while (i < value.items.length) {
				if (i > 0) result += color ? ", " : ",";
				result += stringify(value.items[i], color);
				i = i + 1;
			}
			return result + "]";
		},
		JsonKind.Object => {
			let result = color ? "{ " : "{";
			let i = 0;
			while (i < value.keys.length) {
				if (i > 0) result += color ? ", " : ",";
				if (color) {
					result += value.keys[i] + ": " + stringify(value.values[i], true);
				} else {
					result += escapeString(value.keys[i]) + ":" + stringify(value.values[i], false);
				}
				i = i + 1;
			}
			return result + (color ? " }" : "}");
		},
		JsonKind.Int => {
			const s = value.intVal.toString();
			return color ? "\x1b[33m" + s + "\x1b[0m" : s;
		},
		_ => "null",
	};
}

// ===== Pretty Stringify =====

export function stringifyPretty(value: JsonValue, indent: number): string {
	return prettyImpl(value, indent, 0);
}

function prettyImpl(value: JsonValue, indent: number, depth: number): string {
	if (value === null) return "null";
	return match (value.kind) {
		JsonKind.Null => "null",
		JsonKind.Bool => { return value.boolVal ? "true" : "false"; },
		JsonKind.Number => value.numVal.toString(),
		JsonKind.Int => value.intVal.toString(),
		JsonKind.String => escapeString(value.strVal),
		JsonKind.Array => {
			if (value.items.length === 0) return "[]";
			const pad = makeIndent(indent, depth + 1);
			const endPad = makeIndent(indent, depth);
			let result = "[\n";
			let i = 0;
			while (i < value.items.length) {
				if (i > 0) result += ",\n";
				result += pad + prettyImpl(value.items[i], indent, depth + 1);
				i = i + 1;
			}
			return result + "\n" + endPad + "]";
		},
		JsonKind.Object => {
			if (value.keys.length === 0) return "{}";
			const pad = makeIndent(indent, depth + 1);
			const endPad = makeIndent(indent, depth);
			let result = "{\n";
			let i = 0;
			while (i < value.keys.length) {
				if (i > 0) result += ",\n";
				result += pad + escapeString(value.keys[i]) + ": " + prettyImpl(value.values[i], indent, depth + 1);
				i = i + 1;
			}
			return result + "\n" + endPad + "}";
		},
		_ => "null",
	};
}

function makeIndent(size: number, depth: number): string {
	let result = "";
	let i = 0;
	const total = size * depth;
	while (i < total) {
		result += " ";
		i = i + 1;
	}
	return result;
}

// ===== String Escaping =====

function hexDigit(n: number): string {
	if (n < 10) return fromCodePoint("0".code + n);
	return fromCodePoint("a".code + n - 10);
}

function escapeString(s: string): string {
	let result = "\"";
	let i = 0;
	const len = s.byteLength;
	while (i < len) {
		// Walk byte-by-byte to stay aligned with byteLength. ASCII bytes match
		// JSON control chars; UTF-8 multibyte continuation bytes (0x80-0xBF)
		// and lead bytes (0xC0+) fall through to the default branch and are
		// emitted verbatim — preserving UTF-8 content end-to-end.
		const ch = s.byteAt(i);
		match (ch) {
			"\"".code => { result += "\\\""; },
			"\\".code => { result += "\\\\"; },
			"\n".code => { result += "\\n"; },
			"\r".code => { result += "\\r"; },
			"\t".code => { result += "\\t"; },
			8 => { result += "\\b"; },
			12 => { result += "\\f"; },
			_ => {
				if (ch < 32) {
					result += "\\u00" + hexDigit((ch >> 4) & 15) + hexDigit(ch & 15);
				} else {
					// Emit raw byte; ASCII renders as itself, UTF-8 multibyte
					// rebuilds verbatim across iterations.
					result += s.byteSlice(i, i + 1);
				}
			},
		};
		i = i + 1;
	}
	return result + "\"";
}

// ===== Tests =====

test "stringify null" {
	assert stringify(jsonNull()) === "null";
}

test "stringify bool" {
	assert stringify(jsonBool(true)) === "true";
	assert stringify(jsonBool(false)) === "false";
}

test "stringify number" {
	assert stringify(jsonNumber(42)) === "42";
}

test "stringify string" {
	assert stringify(jsonString("hello")) === "\"hello\"";
}

test "stringify string with escapes" {
	assert stringify(jsonString("a\"b")) === "\"a\\\"b\"";
	assert stringify(jsonString("a\nb")) === "\"a\\nb\"";
}

test "stringify empty array" {
	const arr: JsonValue[] = [];
	assert stringify(jsonArray(arr)) === "[]";
}

test "stringify array" {
	const items: JsonValue[] = [jsonNumber(1), jsonNumber(2), jsonNumber(3)];
	assert stringify(jsonArray(items)) === "[1,2,3]";
}

test "stringify empty object" {
	const keys: string[] = [];
	const vals: JsonValue[] = [];
	assert stringify(jsonObject(keys, vals)) === "{}";
}

test "stringify object" {
	const keys: string[] = ["name", "age"];
	const vals: JsonValue[] = [jsonString("Alice"), jsonNumber(30)];
	assert stringify(jsonObject(keys, vals)) === "{\"name\":\"Alice\",\"age\":30}";
}

test "stringify nested" {
	const inner: JsonValue[] = [jsonNumber(1), jsonBool(true)];
	const keys: string[] = ["data"];
	const vals: JsonValue[] = [jsonArray(inner)];
	assert stringify(jsonObject(keys, vals)) === "{\"data\":[1,true]}";
}
