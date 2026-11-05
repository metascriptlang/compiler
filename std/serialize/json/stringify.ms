// MetaScript JSON2 — Serializer
//
// Compact (stringify) and pretty (stringifyPretty) share one walk.

import { JsonKind, JsonValue } from "./types";
import { jsonNull, jsonBool, jsonNumber, jsonInt, jsonString, jsonArray, jsonObject } from "./builder";

// ===== Compact Stringify =====
// color=false: {"key":"value","n":3}  (standard JSON)
// color=true:  { key: "value", n: 3 } (colored console output, unquoted keys)

@compilerFunc
export function stringify(value: JsonValue, color: boolean = false): string {
	let out = "";
	appendTree(out, value, color, false, 0);
	return out;
}

// ===== Pretty Stringify =====

export function stringifyPretty(value: JsonValue, indent: number): string {
	let out = "";
	appendTree(out, value, false, true, indent);
	return out;
}

function appendTree(ref out: string, root: JsonValue, color: boolean, pretty: boolean, indent: number): void {
	if (!appendOpening(out, root, color, pretty)) return;
	const open: JsonValue[] = [root];
	const next: int32[] = [0];
	while (open.length > 0) {
		const depth = open.length;
		const i = next[depth - 1];
		if (i < childCount(open[depth - 1])) {
			if (i > 0) out += pretty ? ",\n" : color ? ", " : ",";
			if (pretty) appendIndent(out, indent * depth);
			next[depth - 1] = i + 1;
			if (appendChild(out, open[depth - 1], i, color, pretty)) {
				open.push(childAt(open[depth - 1], i));
				next.push(0);
			}
			continue;
		}
		if (pretty) {
			out += "\n";
			appendIndent(out, indent * (depth - 1));
		}
		out += closer(open[depth - 1].kind == JsonKind.Object, color, pretty);
		open.shrink(depth - 1);
		next.shrink(depth - 1);
	}
}

function appendChild(ref out: string, parent: JsonValue, i: int32, color: boolean, pretty: boolean): boolean {
	if (parent.kind == JsonKind.Object) {
		appendKey(out, parent.keys[i], color, pretty);
		return appendOpening(out, parent.values[i], color, pretty);
	}
	if (parent.kind == JsonKind.Array) return appendOpening(out, parent.items[i], color, pretty);
	return false;
}

function appendOpening(ref out: string, value: JsonValue, color: boolean, pretty: boolean): boolean {
	if (childCount(value) == 0) {
		appendLeaf(out, value, color);
		return false;
	}
	out += opener(value.kind == JsonKind.Object, color, pretty);
	return true;
}

function childAt(parent: JsonValue, i: int32): JsonValue {
	if (parent.kind == JsonKind.Object) return parent.values[i];
	if (parent.kind == JsonKind.Array) return parent.items[i];
	return jsonNull();
}

function childCount(value: JsonValue): int32 {
	if (value == null) return 0;
	if (value.kind == JsonKind.Array) return value.items.length;
	if (value.kind == JsonKind.Object) return value.keys.length;
	return 0;
}

function opener(isObject: boolean, color: boolean, pretty: boolean): string {
	if (!isObject) return pretty ? "[\n" : "[";
	return pretty ? "{\n" : color ? "{ " : "{";
}

function closer(isObject: boolean, color: boolean, pretty: boolean): string {
	if (!isObject) return "]";
	return color && !pretty ? " }" : "}";
}

function appendKey(ref out: string, key: string, color: boolean, pretty: boolean): void {
	if (color && !pretty) {
		out += key;
		out += ": ";
		return;
	}
	appendEscaped(out, key);
	out += pretty ? ": " : ":";
}

function appendLeaf(ref out: string, value: JsonValue, color: boolean): void {
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
		JsonKind.Int => {
			if (color) out += "\x1b[33m";
			out += value.intVal.toString();
			if (color) out += "\x1b[0m";
		},
		JsonKind.Array => { out += "[]"; },
		JsonKind.Object => { out += color ? "{  }" : "{}"; },
		_ => { out += color ? "\x1b[2mnull\x1b[0m" : "null"; },
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

test "stringify writes a tree nested past the parse limit without running out of stack" {
	let v = jsonInt(1);
	for (let i = 0; i < 3000; i = i + 1) v = jsonObject(["a"], [jsonArray([v])]);
	assert stringify(v).length == 3000 * 8 + 1;
	assert stringify(v, true).length == 3000 * 9 + 10;
	assert stringifyPretty(jsonArray([jsonArray([jsonInt(1)])]), 1) == "[\n [\n  1\n ]\n]";
}

test "stringify color mode writes empty containers as the walk opens and closes them" {
	assert stringify(jsonObject([], []), true) == "{  }";
	assert stringify(jsonArray([]), true) == "[]";
	assert stringifyPretty(jsonObject(["a"], [jsonArray([])]), 2) == "{\n  \"a\": []\n}";
}

test "stringifyPretty scalars and non-finite" {
	assert stringifyPretty(jsonNumber(0.0 / 0.0), 2) == "null";
	assert stringifyPretty(jsonInt(5), 2) == "5";
	assert stringifyPretty(jsonString("a\nb"), 4) == "\"a\\nb\"";
}
