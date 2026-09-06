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
	if (value == null) return color ? "\x1b[2mnull\x1b[0m" : "null";
	return match (value.kind) {
		JsonKind.Null => { return color ? "\x1b[2mnull\x1b[0m" : "null"; },
		JsonKind.Bool => {
			const s = value.boolVal ? "true" : "false";
			return color ? "\x1b[36m" + s + "\x1b[0m" : s;
		},
		JsonKind.Number => {
			const s = jsonNumberStr(value.numVal);
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
	if (value == null) return "null";
	return match (value.kind) {
		JsonKind.Null => "null",
		JsonKind.Bool => { return value.boolVal ? "true" : "false"; },
		JsonKind.Number => jsonNumberStr(value.numVal),
		JsonKind.Int => value.intVal.toString(),
		JsonKind.String => escapeString(value.strVal),
		JsonKind.Array => {
			if (value.items.length == 0) return "[]";
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
			if (value.keys.length == 0) return "{}";
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

function escapeString(s: string): string {
	let result = "\"";
	let i = 0;
	const len = s.byteLength;
	// Walk byte-by-byte; every escape-relevant byte is ASCII. Plain content
	// (including multi-byte UTF-8) is copied in RUNS — runs only break at
	// ASCII escape bytes so slices stay on char boundaries and multi-byte
	// sequences are never split.
	let runStart = 0;
	while (i < len) {
		const ch = s.byteAt(i);
		if (ch == WTF8_SURROGATE_LEAD && i + 2 < len && isWtf8SurrogateCont(s.byteAt(i + 1))) {
			if (runStart < i) result += s.byteSlice(runStart, i);
			const cp = ((ch & 15) << 12) | ((s.byteAt(i + 1) & 63) << 6) | (s.byteAt(i + 2) & 63);
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
	if (runStart < len) result += s.byteSlice(runStart, len);
	return result + "\"";
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
