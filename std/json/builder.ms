// MetaScript JSON — Builders + Accessors
//
// Constructor helpers (jsonNull, jsonBool, etc.) and extension methods
// (get, at, asString, etc.) for ergonomic JSON manipulation.

import { JsonKind, JsonValue } from "./types";

// ===== Constructors =====

export function jsonNull(): JsonValue {
	return new JsonValue(JsonKind.Null, false, 0, "", [], [], []);
}

export function jsonBool(b: boolean): JsonValue {
	return new JsonValue(JsonKind.Bool, b, 0, "", [], [], []);
}

export function jsonNumber(n: number): JsonValue {
	return new JsonValue(JsonKind.Number, false, n, "", [], [], []);
}

export function jsonString(s: string): JsonValue {
	return new JsonValue(JsonKind.String, false, 0, s, [], [], []);
}

export function jsonArray(items: JsonValue[]): JsonValue {
	return new JsonValue(JsonKind.Array, false, 0, "", items, [], []);
}

export function jsonObjectFromKV(keys: string[], vals: JsonValue[]): JsonValue {
	return new JsonValue(JsonKind.Object, false, 0, "", [], keys, vals);
}

export function jsonObject(): JsonValue {
	return new JsonValue(JsonKind.Object, false, 0, "", [], [], []);
}

// ===== Accessor Extension Methods =====

export function get(this v: JsonValue, key: string): JsonValue {
	if (v.kind !== JsonKind.Object) return jsonNull();
	let i = 0;
	while (i < v.objKeys.length) {
		if (v.objKeys[i] === key) return v.objVals[i];
		i = i + 1;
	}
	return jsonNull();
}

export function at(this v: JsonValue, idx: number): JsonValue {
	if (v.kind !== JsonKind.Array) return jsonNull();
	if (idx < 0 || idx >= v.arrVal.length) return jsonNull();
	return v.arrVal[idx];
}

export function asString(this v: JsonValue): string {
	return v.strVal;
}

export function asNumber(this v: JsonValue): number {
	return v.numVal;
}

export function asBool(this v: JsonValue): boolean {
	return v.boolVal;
}

export function isNull(this v: JsonValue): boolean {
	return v.kind === JsonKind.Null;
}

export function len(this v: JsonValue): number {
	if (v.kind === JsonKind.Array) return v.arrVal.length;
	if (v.kind === JsonKind.Object) return v.objKeys.length;
	if (v.kind === JsonKind.String) return v.strVal.length;
	return 0;
}

// ===== Mutator Extension Methods =====

export function set(this v: JsonValue, key: string, val: JsonValue): void {
	if (v.kind !== JsonKind.Object) return;
	let i = 0;
	while (i < v.objKeys.length) {
		if (v.objKeys[i] === key) {
			v.objVals[i] = val;
			return;
		}
		i = i + 1;
	}
	v.objKeys.push(key);
	v.objVals.push(val);
}

export function push(this v: JsonValue, item: JsonValue): void {
	if (v.kind !== JsonKind.Array) return;
	v.arrVal.push(item);
}

// ===== Tests =====

test "jsonNull" {
	const v = jsonNull();
	assert v.kind === JsonKind.Null;
	assert v.isNull();
}

test "jsonBool true" {
	const v = jsonBool(true);
	assert v.kind === JsonKind.Bool;
	assert v.asBool() === true;
}

test "jsonBool false" {
	const v = jsonBool(false);
	assert v.kind === JsonKind.Bool;
	assert v.asBool() === false;
}

test "jsonNumber" {
	const v = jsonNumber(3.14);
	assert v.kind === JsonKind.Number;
	assert v.asNumber() === 3.14;
}

test "jsonString" {
	const v = jsonString("hello");
	assert v.kind === JsonKind.String;
	assert v.asString() === "hello";
}

test "jsonArray and at" {
	const a = jsonArray([jsonNumber(10), jsonNumber(20), jsonNumber(30)]);
	assert a.kind === JsonKind.Array;
	assert a.len() === 3;
	assert a.at(0).asNumber() === 10;
	assert a.at(1).asNumber() === 20;
	assert a.at(2).asNumber() === 30;
	assert a.at(5).isNull();
	assert a.at(-1).isNull();
}

test "jsonObject and get" {
	const obj = jsonObject();
	obj.set("hello", jsonString("world"));
	assert obj.kind === JsonKind.Object;
	assert obj.len() === 1;
	assert obj.get("hello").asString() === "world";
	assert obj.get("missing").isNull();
}

test "set on object" {
	const obj = jsonObject();
	obj.set("a", jsonNumber(1));
	assert obj.len() === 1;
	assert obj.get("a").asNumber() === 1;

	// Overwrite
	obj.set("a", jsonNumber(2));
	assert obj.len() === 1;
	assert obj.get("a").asNumber() === 2;

	// Add second key
	obj.set("b", jsonString("hi"));
	assert obj.len() === 2;
	assert obj.get("b").asString() === "hi";
}

test "push on array" {
	const arr = jsonArray([]);
	arr.push(jsonNumber(1));
	arr.push(jsonNumber(2));
	assert arr.len() === 2;
	assert arr.at(0).asNumber() === 1;
	assert arr.at(1).asNumber() === 2;
}

test "len for different types" {
	assert jsonNull().len() === 0;
	assert jsonBool(true).len() === 0;
	assert jsonNumber(42).len() === 0;
	assert jsonString("abc").len() === 3;
	assert jsonArray([jsonNull(), jsonNull()]).len() === 2;
}

test "nested access" {
	const inner = jsonObject();
	inner.set("x", jsonNumber(42));
	const outer = jsonObject();
	outer.set("nested", inner);
	assert outer.get("nested").get("x").asNumber() === 42;
}

test "get on non-object returns null" {
	assert jsonNumber(5).get("key").isNull();
	assert jsonString("hi").get("key").isNull();
}

test "at on non-array returns null" {
	assert jsonNumber(5).at(0).isNull();
	assert jsonString("hi").at(0).isNull();
}

test "push on non-array is no-op" {
	const v = jsonNumber(5);
	v.push(jsonNull());
	assert v.kind === JsonKind.Number;
}

test "set on non-object is no-op" {
	const v = jsonNumber(5);
	v.set("key", jsonNull());
	assert v.kind === JsonKind.Number;
}
