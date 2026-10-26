// LSP response JSON by string concatenation with comma tracking; never walks an object graph.

import { lspJsonString, lspJsonNumber, lspJsonBool } from "./protocol";

export interface JsonBuilder {
	parts: string[];
	count: int32;
	isArray: boolean;
}

export function jsonObj(): JsonBuilder {
	return { parts: ["{"], count: 0, isArray: false };
}

export function jsonArr(): JsonBuilder {
	return { parts: ["["], count: 0, isArray: true };
}

function jItem(b: JsonBuilder, raw: string): void {
	if (b.count > 0) b.parts.push(",");
	b.parts.push(raw);
	b.count = b.count + 1;
}

// Embeds pre-formatted JSON from another builder or raw text.
export function jRaw(b: JsonBuilder, key: string, raw: string): void {
	jItem(b, "\"" + key + "\":" + raw);
}

export function jStr(b: JsonBuilder, key: string, val: string): void {
	jRaw(b, key, lspJsonString(val));
}

export function jNum(b: JsonBuilder, key: string, val: float64): void {
	jRaw(b, key, lspJsonNumber(val));
}

export function jBool(b: JsonBuilder, key: string, val: boolean): void {
	jRaw(b, key, lspJsonBool(val));
}

export function jStrIf(b: JsonBuilder, key: string, val: string): void {
	if (val.length > 0) jStr(b, key, val);
}

export function jRawIf(b: JsonBuilder, key: string, raw: string): void {
	if (raw.length > 0) jRaw(b, key, raw);
}

export function jStrItem(b: JsonBuilder, val: string): void {
	jItem(b, lspJsonString(val));
}

export function jEnd(b: JsonBuilder): string {
	b.parts.push(b.isArray ? "]" : "}");
	return b.parts.join("");
}

test "empty object" {
	assert jEnd(jsonObj()) == "{}";
}

test "empty array" {
	assert jEnd(jsonArr()) == "[]";
}

test "single string field" {
	const b = jsonObj();
	jStr(b, "name", "hello");
	assert jEnd(b) == "{\"name\":\"hello\"}";
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
	assert r.charAt(0) == "{";
	assert r.charAt(r.length - 1) == "}";
}

test "nested objects via jRaw" {
	const inner = jsonObj();
	jNum(inner, "line", 0);
	jNum(inner, "character", 5);
	const b = jsonObj();
	jRaw(b, "start", jEnd(inner));
	assert jEnd(b) == "{\"start\":{\"line\":0,\"character\":5}}";
}

test "array with items" {
	const a = jsonArr();
	jItem(a, "1");
	jItem(a, "2");
	jItem(a, "3");
	assert jEnd(a) == "[1,2,3]";
}

test "array with string items" {
	const a = jsonArr();
	jStrItem(a, "a");
	jStrItem(a, "b");
	assert jEnd(a) == "[\"a\",\"b\"]";
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

test "string escaping" {
	const b = jsonObj();
	jStr(b, "msg", "hello \"world\"\nnewline");
	const r = jEnd(b);
	assert r.indexOf("\\\"world\\\"") >= 0;
	assert r.indexOf("\\n") >= 0;
}
