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
				if (i > 0) result = result + (color ? ", " : ",");
				result = result + stringify(value.items[i], color);
				i = i + 1;
			}
			return result + "]";
		},
		JsonKind.Object => {
			let result = color ? "{ " : "{";
			let i = 0;
			while (i < value.keys.length) {
				if (i > 0) result = result + (color ? ", " : ",");
				if (color) {
					result = result + value.keys[i] + ": " + stringify(value.values[i], true);
				} else {
					result = result + escapeString(value.keys[i]) + ":" + stringify(value.values[i], false);
				}
				i = i + 1;
			}
			return result + (color ? " }" : "}");
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
		JsonKind.String => escapeString(value.strVal),
		JsonKind.Array => {
			if (value.items.length === 0) return "[]";
			const pad = makeIndent(indent, depth + 1);
			const endPad = makeIndent(indent, depth);
			let result = "[\n";
			let i = 0;
			while (i < value.items.length) {
				if (i > 0) result = result + ",\n";
				result = result + pad + prettyImpl(value.items[i], indent, depth + 1);
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
				if (i > 0) result = result + ",\n";
				result = result + pad + escapeString(value.keys[i]) + ": " + prettyImpl(value.values[i], indent, depth + 1);
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
		result = result + " ";
		i = i + 1;
	}
	return result;
}

// ===== String Escaping =====

function escapeString(s: string): string {
	let result = "\"";
	let i = 0;
	while (i < s.byteLength) {
		const ch = s.charCodeAt(i);
		match (ch) {
			"\"".code => { result = result + "\\\""; },
			"\\".code => { result = result + "\\\\"; },
			"\n".code => { result = result + "\\n"; },
			"\r".code => { result = result + "\\r"; },
			"\t".code => { result = result + "\\t"; },
			_ => { result = result + s.charAt(i); },
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
