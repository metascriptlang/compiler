// LSP Response Builder — safe, fast JSON construction for LSP responses.
//
// Never walks object graphs. No circular reference risk. No JSON.stringify.
// Uses string concatenation with automatic comma tracking.

import { lspJsonString, lspJsonNumber, lspJsonBool } from "./protocol";

// ===== Builder Interface =====

export interface JsonBuilder {
	parts: string[];
	count: number;  // field/item count — controls comma insertion
	isArray: boolean;
}

// ===== Constructors =====

export function jsonObj(): JsonBuilder {
	return { parts: ["{"], count: 0, isArray: false };
}

export function jsonArr(): JsonBuilder {
	return { parts: ["["], count: 0, isArray: true };
}

// ===== Object Field Writers =====

export function jStr(b: JsonBuilder, key: string, val: string): void {
	if (b.count > 0) b.parts.push(",");
	b.parts.push("\"" + key + "\":" + lspJsonString(val));
	b.count = b.count + 1;
}

export function jNum(b: JsonBuilder, key: string, val: number): void {
	if (b.count > 0) b.parts.push(",");
	b.parts.push("\"" + key + "\":" + lspJsonNumber(val));
	b.count = b.count + 1;
}

export function jBool(b: JsonBuilder, key: string, val: boolean): void {
	if (b.count > 0) b.parts.push(",");
	b.parts.push("\"" + key + "\":" + lspJsonBool(val));
	b.count = b.count + 1;
}

export function jNull(b: JsonBuilder, key: string): void {
	if (b.count > 0) b.parts.push(",");
	b.parts.push("\"" + key + "\":null");
	b.count = b.count + 1;
}

// Embed pre-formatted JSON value (from another builder or raw JSON).
export function jRaw(b: JsonBuilder, key: string, raw: string): void {
	if (b.count > 0) b.parts.push(",");
	b.parts.push("\"" + key + "\":" + raw);
	b.count = b.count + 1;
}

// ===== Conditional Field Writers (skip if empty/default) =====

export function jStrIf(b: JsonBuilder, key: string, val: string): void {
	if (val.length > 0) jStr(b, key, val);
}

export function jNumIf(b: JsonBuilder, key: string, val: number, skip: number): void {
	if (val !== skip) jNum(b, key, val);
}

export function jRawIf(b: JsonBuilder, key: string, raw: string): void {
	if (raw.length > 0) jRaw(b, key, raw);
}

// ===== Array Item Writers =====

export function jItem(b: JsonBuilder, raw: string): void {
	if (b.count > 0) b.parts.push(",");
	b.parts.push(raw);
	b.count = b.count + 1;
}

export function jStrItem(b: JsonBuilder, val: string): void {
	if (b.count > 0) b.parts.push(",");
	b.parts.push(lspJsonString(val));
	b.count = b.count + 1;
}

// ===== Finalize =====

export function jEnd(b: JsonBuilder): string {
	b.parts.push(b.isArray ? "]" : "}");
	return b.parts.join("");
}

// ===== Tests =====

test "empty object" {
	assert jEnd(jsonObj()) === "{}";
}

test "empty array" {
	assert jEnd(jsonArr()) === "[]";
}

test "single string field" {
	const b = jsonObj();
	jStr(b, "name", "hello");
	assert jEnd(b) === "{\"name\":\"hello\"}";
}

test "multiple fields" {
	const b = jsonObj();
	jStr(b, "label", "foo");
	jNum(b, "kind", 6);
	jBool(b, "deprecated", false);
	const r = jEnd(b);
	assert r.indexOf("\"label\":\"foo\"") >= 0;
	assert r.indexOf("\"kind\":6") >= 0;
	assert r.indexOf("\"deprecated\":false") >= 0;
	assert r.charAt(0) === "{";
	assert r.charAt(r.length - 1) === "}";
}

test "nested objects via jRaw" {
	const inner = jsonObj();
	jNum(inner, "line", 0);
	jNum(inner, "character", 5);
	const b = jsonObj();
	jRaw(b, "start", jEnd(inner));
	assert jEnd(b) === "{\"start\":{\"line\":0,\"character\":5}}";
}

test "array with items" {
	const a = jsonArr();
	jItem(a, "1");
	jItem(a, "2");
	jItem(a, "3");
	assert jEnd(a) === "[1,2,3]";
}

test "array with string items" {
	const a = jsonArr();
	jStrItem(a, "a");
	jStrItem(a, "b");
	assert jEnd(a) === "[\"a\",\"b\"]";
}

test "conditional skip empty" {
	const b = jsonObj();
	jStr(b, "label", "x");
	jStrIf(b, "sortText", "");
	jStrIf(b, "detail", "number");
	const r = jEnd(b);
	assert r.indexOf("sortText") < 0;
	assert r.indexOf("\"detail\":\"number\"") >= 0;
}

test "null field" {
	const b = jsonObj();
	jNull(b, "result");
	assert jEnd(b) === "{\"result\":null}";
}

test "string escaping" {
	const b = jsonObj();
	jStr(b, "msg", "hello \"world\"\nnewline");
	const r = jEnd(b);
	assert r.indexOf("\\\"world\\\"") >= 0;
	assert r.indexOf("\\n") >= 0;
}
