// MetaScript JSON2 — Serializer
//
// Two-path: compact (stringify) and pretty (stringifyPretty).
// Recursive dispatch via match on value.kind.

import { JsonKind, JsonValue } from "./types";
import { jsonNull, jsonBool, jsonNumber, jsonInt, jsonString, jsonArray, jsonObject } from "./builder";

// ===== Compact Stringify =====
// color=false: {"key":"value","n":3}  (standard JSON)
// color=true:  { key: "value", n: 3 } (colored console output, unquoted keys)

@compilerFunc
export function stringify(value: JsonValue, color: boolean = false): string {
	let out = "";
	appendJson(out, value, color);
	return out;
}

function appendJson(ref out: string, value: JsonValue, color: boolean): void {
	if (value == null) {
		out += color ? "\x1b[2mnull\x1b[0m" : "null";
		return;
	}
	match (value.kind) {
		JsonKind.Bool => {
			if (color) out += "\x1b[36m";
			out += value.boolVal ? "true" : "false";
			if (color) out += "\x1b[0m";
		},
		JsonKind.Number => {
			if (color) out += "\x1b[33m";
			out += jsonNumberStr(value.numVal);
			if (color) out += "\x1b[0m";
		},
		JsonKind.String => {
			if (color) out += "\x1b[32m";
			appendEscaped(out, value.strVal);
			if (color) out += "\x1b[0m";
		},
		JsonKind.Array => {
			out += "[";
			let i = 0;
			while (i < value.items.length) {
				if (i > 0) out += color ? ", " : ",";
				appendJson(out, value.items[i], color);
				i = i + 1;
			}
			out += "]";
		},
		JsonKind.Object => {
			out += color ? "{ " : "{";
			let i = 0;
			while (i < value.keys.length) {
				if (i > 0) out += color ? ", " : ",";
				if (color) {
					out += value.keys[i];
					out += ": ";
				} else {
					appendEscaped(out, value.keys[i]);
					out += ":";
				}
				appendJson(out, value.values[i], color);
				i = i + 1;
			}
			out += color ? " }" : "}";
		},
		JsonKind.Int => {
			if (color) out += "\x1b[33m";
			out += value.intVal.toString();
			if (color) out += "\x1b[0m";
		},
		JsonKind.Null => { out += color ? "\x1b[2mnull\x1b[0m" : "null"; },
		_ => { out += color ? "\x1b[2mnull\x1b[0m" : "null"; },
	};
}

// ===== Pretty Stringify =====

export function stringifyPretty(value: JsonValue, indent: number): string {
	let out = "";
	appendPretty(out, value, indent, 0);
	return out;
}

function appendPretty(ref out: string, value: JsonValue, indent: number, depth: number): void {
	if (value == null) {
		out += "null";
		return;
	}
	match (value.kind) {
		JsonKind.Bool => { out += value.boolVal ? "true" : "false"; },
		JsonKind.Number => { out += jsonNumberStr(value.numVal); },
		JsonKind.Int => { out += value.intVal.toString(); },
		JsonKind.String => { appendEscaped(out, value.strVal); },
		JsonKind.Array => {
			if (value.items.length == 0) {
				out += "[]";
				return;
			}
			out += "[\n";
			let i = 0;
			while (i < value.items.length) {
				if (i > 0) out += ",\n";
				appendIndent(out, indent * (depth + 1));
				appendPretty(out, value.items[i], indent, depth + 1);
				i = i + 1;
			}
			out += "\n";
			appendIndent(out, indent * depth);
			out += "]";
		},
		JsonKind.Object => {
			if (value.keys.length == 0) {
				out += "{}";
				return;
			}
			out += "{\n";
			let i = 0;
			while (i < value.keys.length) {
				if (i > 0) out += ",\n";
				appendIndent(out, indent * (depth + 1));
				appendEscaped(out, value.keys[i]);
				out += ": ";
				appendPretty(out, value.values[i], indent, depth + 1);
				i = i + 1;
			}
			out += "\n";
			appendIndent(out, indent * depth);
			out += "}";
		},
		_ => { out += "null"; },
	};
}

function appendIndent(ref out: string, total: number): void {
	let i = 0;
	while (i < total) {
		out += " ";
		i = i + 1;
	}
}

// ===== String Escaping =====

function hexDigit(n: number): string {
	if (n < 10) return fromCodePoint("0".code + n);
	return fromCodePoint("a".code + n - 10);
}

// RFC 8259 §6 — JSON numbers must be finite. NaN / ±Infinity have no JSON
// representation; emit `null` (Python json default-strict convention).
// Finite check: `x - x === 0` iff x is finite (NaN−NaN = NaN, Inf−Inf = NaN).
function jsonNumberStr(v: number): string {
	if (v - v != 0) return "null";
	return v.toString();
}

// A surrogate code point encodes as ED A0..BF xx in WTF-8; well-formed UTF-8
// never produces that pair, so this signature identifies exactly the code
// points that have no valid UTF-8 encoding and must leave as \uXXXX escapes.
const WTF8_SURROGATE_LEAD: int32 = 237;

function isWtf8SurrogateCont(b: int32): boolean {
	return b >= 160 && b <= 191;
}

function appendEscaped(ref result: string, s: string): void {
	result += "\"";
	const b = s.asBytes();
	let i = 0;
	const len = b.length;
	// Walk byte-by-byte; every escape-relevant byte is ASCII. Plain content
	// (including multi-byte UTF-8) is copied in RUNS — runs only break at
	// ASCII escape bytes so slices stay on char boundaries and multi-byte
	// sequences are never split.
	let runStart = 0;
	while (i < len) {
		const ch = b[i] as int32;
		if (ch == WTF8_SURROGATE_LEAD && i + 2 < len && isWtf8SurrogateCont(b[i + 1] as int32)) {
			if (runStart < i) result += s.byteSlice(runStart, i);
			const cp = ((ch & 15) << 12) | (((b[i + 1] as int32) & 63) << 6) | ((b[i + 2] as int32) & 63);
			result += "\\u" + hexDigit((cp >> 12) & 15) + hexDigit((cp >> 8) & 15)
				+ hexDigit((cp >> 4) & 15) + hexDigit(cp & 15);
			i = i + 3;
			runStart = i;
			continue;
		}
		if (ch == "\"".code || ch == "\\".code || ch < 32) {
			if (runStart < i) result += s.byteSlice(runStart, i);
			result += match (ch) {
				"\"".code => "\\\"",
				"\\".code => "\\\\",
				"\n".code => "\\n",
				"\r".code => "\\r",
				"\t".code => "\\t",
				8 => "\\b",
				12 => "\\f",
				_ => "\\u00" + hexDigit((ch >> 4) & 15) + hexDigit(ch & 15),
			};
			runStart = i + 1;
		}
		i = i + 1;
	}
	if (runStart == 0) result += s;
	else if (runStart < len) result += s.byteSlice(runStart, len);
	result += "\"";
}

// ===== Tests =====

test "stringify null" {
	assert stringify(jsonNull()) == "null";
}

test "stringify bool" {
	assert stringify(jsonBool(true)) == "true";
	assert stringify(jsonBool(false)) == "false";
}

test "stringify number" {
	assert stringify(jsonNumber(42)) == "42";
}

test "stringify NaN → null (RFC 8259 §6 — JSON has no NaN representation)" {
	// 0.0/0.0 produces NaN — fallback to "null" per Python json default-strict
	const nan: number = 0.0 / 0.0;
	assert stringify(jsonNumber(nan)) == "null";
}

test "stringify +Infinity → null (RFC 8259 §6 — JSON has no Infinity)" {
	const posInf: number = 1.0 / 0.0;
	assert stringify(jsonNumber(posInf)) == "null";
}

test "stringify -Infinity → null" {
	const negInf: number = -1.0 / 0.0;
	assert stringify(jsonNumber(negInf)) == "null";
}

test "stringify finite zero → 0 (not null)" {
	// Boundary — 0 should NOT trip the non-finite check
	assert stringify(jsonNumber(0.0)) == "0";
	assert stringify(jsonNumber(-0.0)) == "0";  // ±0 collapse
}

test "stringify string" {
	assert stringify(jsonString("hello")) == "\"hello\"";
}

test "stringify string with escapes" {
	assert stringify(jsonString("a\"b")) == "\"a\\\"b\"";
	assert stringify(jsonString("a\nb")) == "\"a\\nb\"";
}

test "stringify empty array" {
	const arr: JsonValue[] = [];
	assert stringify(jsonArray(arr)) == "[]";
}

test "stringify array" {
	const items: JsonValue[] = [jsonNumber(1), jsonNumber(2), jsonNumber(3)];
	assert stringify(jsonArray(items)) == "[1,2,3]";
}

test "stringify empty object" {
	const keys: string[] = [];
	const vals: JsonValue[] = [];
	assert stringify(jsonObject(keys, vals)) == "{}";
}

test "stringify object" {
	const keys: string[] = ["name", "age"];
	const vals: JsonValue[] = [jsonString("Alice"), jsonNumber(30)];
	assert stringify(jsonObject(keys, vals)) == "{\"name\":\"Alice\",\"age\":30}";
}

test "stringify nested" {
	const inner: JsonValue[] = [jsonNumber(1), jsonBool(true)];
	const keys: string[] = ["data"];
	const vals: JsonValue[] = [jsonArray(inner)];
	assert stringify(jsonObject(keys, vals)) == "{\"data\":[1,true]}";
}

// Well-formed output (ES2019 JSON.stringify): a lone surrogate has no valid
// UTF-8 encoding, so it is emitted as a \uXXXX escape rather than passed
// through as raw WTF-8. A valid pair is NOT escaped — it is a real character.
// Without this the C backend emitted invalid UTF-8 and the JS backend replaced
// the code point with U+FFFD, i.e. the two backends corrupted it differently.

test "stringify escapes a lone high surrogate" {
	assert stringify(jsonString(fromCodePoint(55296))) == "\"\\ud800\"";
}

test "stringify escapes a lone low surrogate" {
	assert stringify(jsonString(fromCodePoint(57343))) == "\"\\udfff\"";
}

test "stringify escapes a lone surrogate between ascii" {
	const s = "a" + fromCodePoint(55296) + "b";
	assert stringify(jsonString(s)) == "\"a\\ud800b\"";
}

test "stringify does NOT escape a valid surrogate pair" {
	assert stringify(jsonString(fromCodePoint(128512))) == "\"\u{1F600}\"";
}

test "stringify escapes consecutive lone surrogates" {
	const s = fromCodePoint(55296) + fromCodePoint(55296);
	assert stringify(jsonString(s)) == "\"\\ud800\\ud800\"";
}

test "stringify escapes a reversed surrogate pair" {
	const s = fromCodePoint(56320) + fromCodePoint(55296);
	assert stringify(jsonString(s)) == "\"\\udc00\\ud800\"";
}

// Key ordering is a DELIBERATE divergence from the JS engine (docs/JSON.md,
// "Deliberate divergences"): JS objects float array-index keys to the front,
// JSON itself defines objects as unordered, and both our backends agree on
// insertion order. This test exists so the decision cannot be undone silently.

test "stringify keeps object keys in insertion order" {
	const keys: string[] = ["b", "2", "a", "1"];
	const vals: JsonValue[] = [jsonNumber(1), jsonNumber(2), jsonNumber(3), jsonNumber(4)];
	assert stringify(jsonObject(keys, vals)) == "{\"b\":1,\"2\":2,\"a\":3,\"1\":4}";
}

test "stringifyPretty keeps object keys in insertion order" {
	const keys: string[] = ["10", "9", "1"];
	const vals: JsonValue[] = [jsonNumber(1), jsonNumber(2), jsonNumber(3)];
	const out = stringifyPretty(jsonObject(keys, vals), 0);
	assert out.indexOf("\"10\"") < out.indexOf("\"9\""), out;
	assert out.indexOf("\"9\"") < out.indexOf("\"1\""), out;
}

test "stringify escapes every control byte form" {
	const s = "q\"b\\n\nr\rt\tb\u{8}f\u{c}z\u{0}u\u{1f}d\u{7f}";
	assert stringify(jsonString(s)) == "\"q\\\"b\\\\n\\nr\\rt\\tb\\bf\\fz\\u0000u\\u001fd\u{7f}\"";
}

test "stringify nested arrays and objects" {
	const innerKeys: string[] = ["k\"1", "k2"];
	const innerVals: JsonValue[] = [jsonArray([jsonNumber(1.5), jsonInt(-7)]), jsonNull()];
	const keys: string[] = ["a", "b"];
	const vals: JsonValue[] = [jsonObject(innerKeys, innerVals), jsonArray([jsonArray([]), jsonBool(false)])];
	assert stringify(jsonObject(keys, vals)) == "{\"a\":{\"k\\\"1\":[1.5,-7],\"k2\":null},\"b\":[[],false]}";
}

test "stringify color mode" {
	const keys: string[] = ["k"];
	const vals: JsonValue[] = [jsonArray([jsonNumber(1), jsonString("a"), jsonBool(true), jsonNull(), jsonInt(2)])];
	const want = "{ k: [\x1b[33m1\x1b[0m, \x1b[32m\"a\"\x1b[0m, \x1b[36mtrue\x1b[0m, \x1b[2mnull\x1b[0m, \x1b[33m2\x1b[0m] }";
	assert stringify(jsonObject(keys, vals), true) == want;
}

test "stringifyPretty nested with indent 2" {
	const keys: string[] = ["a", "e", "o"];
	const vals: JsonValue[] = [jsonArray([jsonNumber(1), jsonObject(["x"], [jsonString("y")])]), jsonArray([]), jsonObject([], [])];
	const want = "{\n  \"a\": [\n    1,\n    {\n      \"x\": \"y\"\n    }\n  ],\n  \"e\": [],\n  \"o\": {}\n}";
	assert stringifyPretty(jsonObject(keys, vals), 2) == want;
}

test "stringify writes a tree as deep as parse accepts" {
	let v = jsonInt(1);
	for (let i = 0; i < 1001; i = i + 1) v = jsonArray([v]);
	assert stringify(v) == "[".repeat(1001) + "1" + "]".repeat(1001);
	assert stringifyPretty(jsonArray([jsonArray([jsonInt(1)])]), 1) == "[\n [\n  1\n ]\n]";
}

test "stringify color mode writes empty containers" {
	assert stringify(jsonObject([], []), true) == "{  }";
	assert stringify(jsonArray([]), true) == "[]";
	assert stringifyPretty(jsonObject(["a"], [jsonArray([])]), 2) == "{\n  \"a\": []\n}";
}

test "stringifyPretty scalars and non-finite" {
	assert stringifyPretty(jsonNumber(0.0 / 0.0), 2) == "null";
	assert stringifyPretty(jsonInt(5), 2) == "5";
	assert stringifyPretty(jsonString("a\nb"), 4) == "\"a\\nb\"";
}
