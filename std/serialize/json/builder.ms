// MetaScript JSON — Constructors

import { JsonKind, JsonValue } from "./types";

export function jsonNull(): JsonValue {
	return { kind: JsonKind.Null };
}

export function jsonBool(v: boolean): JsonValue {
	return { kind: JsonKind.Bool, boolVal: v };
}

export function jsonNumber(n: number): JsonValue {
	return { kind: JsonKind.Number, numVal: n };
}

export function jsonString(s: string): JsonValue {
	return { kind: JsonKind.String, strVal: s };
}

export function jsonArray(items: JsonValue[]): JsonValue {
	return { kind: JsonKind.Array, items: items };
}

export function jsonObject(keys: string[], values: JsonValue[]): JsonValue {
	return { kind: JsonKind.Object, keys: keys, values: values };
}

export function jsonInt(n: int64): JsonValue {
	return { kind: JsonKind.Int, intVal: n };
}

// ===== Array-from-typed helpers =====
//
// Used by the typed encode macro (jsonValueOf) for array fields. Per-element-
// type variants avoid passing macros as values (jsonValueOf is a macro, can't
// be a function reference). Atomic-element coverage only — struct-element
// arrays deferred to V2 (need multi-decl macro to emit per-T wrapper).

// NOTE: while-loop form retained intentionally — for..of triggers a DCE bug
// where these helpers (called via macro-emitted Identifier) get pruned from
// the link, despite being typed-checked OK. Compiler bug, not idiomatic.
// TODO: refactor to for..of once DCE walks for..of-lowered bodies.

export function jsonArrayOfStrings(arr: string[]): JsonValue {
	const items: JsonValue[] = [];
	let i = 0;
	while (i < arr.length) { items.push(jsonString(arr[i])); i = i + 1; }
	return jsonArray(items);
}

export function jsonArrayOfBooleans(arr: boolean[]): JsonValue {
	const items: JsonValue[] = [];
	let i = 0;
	while (i < arr.length) { items.push(jsonBool(arr[i])); i = i + 1; }
	return jsonArray(items);
}

export function jsonArrayOfNumbers(arr: number[]): JsonValue {
	const items: JsonValue[] = [];
	let i = 0;
	while (i < arr.length) { items.push(jsonNumber(arr[i])); i = i + 1; }
	return jsonArray(items);
}

// Per-sized-int helpers — array-level `as int64[]` would reinterpret bytes
// (int32 elements 4 bytes, int64 8 bytes — alignment differs). Each helper
// widens per-element via scalar cast, which is byte-correct.

export function jsonArrayOfInt8(arr: int8[]): JsonValue {
	const items: JsonValue[] = [];
	let i = 0;
	while (i < arr.length) { items.push(jsonInt(arr[i] as int64)); i = i + 1; }
	return jsonArray(items);
}

export function jsonArrayOfInt16(arr: int16[]): JsonValue {
	const items: JsonValue[] = [];
	let i = 0;
	while (i < arr.length) { items.push(jsonInt(arr[i] as int64)); i = i + 1; }
	return jsonArray(items);
}

export function jsonArrayOfInt32(arr: int32[]): JsonValue {
	const items: JsonValue[] = [];
	let i = 0;
	while (i < arr.length) { items.push(jsonInt(arr[i] as int64)); i = i + 1; }
	return jsonArray(items);
}

export function jsonArrayOfInt64(arr: int64[]): JsonValue {
	const items: JsonValue[] = [];
	let i = 0;
	while (i < arr.length) { items.push(jsonInt(arr[i])); i = i + 1; }
	return jsonArray(items);
}

export function jsonArrayOfUint8(arr: uint8[]): JsonValue {
	const items: JsonValue[] = [];
	let i = 0;
	while (i < arr.length) { items.push(jsonInt(arr[i] as int64)); i = i + 1; }
	return jsonArray(items);
}

export function jsonArrayOfUint16(arr: uint16[]): JsonValue {
	const items: JsonValue[] = [];
	let i = 0;
	while (i < arr.length) { items.push(jsonInt(arr[i] as int64)); i = i + 1; }
	return jsonArray(items);
}

export function jsonArrayOfUint32(arr: uint32[]): JsonValue {
	const items: JsonValue[] = [];
	let i = 0;
	while (i < arr.length) { items.push(jsonInt(arr[i] as int64)); i = i + 1; }
	return jsonArray(items);
}

// Float32 needs explicit widen too — float32[] vs float64[] differ in stride.
export function jsonArrayOfFloat32(arr: float32[]): JsonValue {
	const items: JsonValue[] = [];
	let i = 0;
	while (i < arr.length) { items.push(jsonNumber(arr[i] as float64)); i = i + 1; }
	return jsonArray(items);
}

// ===== Tests =====

test "construct null" {
	const v = jsonNull();
	assert v.kind == JsonKind.Null;
}

test "construct bool" {
	const t = jsonBool(true);
	assert t.kind == JsonKind.Bool;
	assert t.boolVal == true;
}

test "construct number" {
	const v = jsonNumber(42);
	assert v.kind == JsonKind.Number;
	assert v.numVal == 42;
}

test "construct string" {
	const v = jsonString("hello");
	assert v.kind == JsonKind.String;
	assert v.strVal == "hello";
}

test "construct array" {
	const items: JsonValue[] = [jsonNumber(1), jsonNumber(2)];
	const v = jsonArray(items);
	assert v.kind == JsonKind.Array;
	assert v.items.length == 2;
}

test "construct object" {
	const keys: string[] = ["name", "age"];
	const vals: JsonValue[] = [jsonString("Alice"), jsonNumber(30)];
	const v = jsonObject(keys, vals);
	assert v.kind == JsonKind.Object;
	assert v.keys.length == 2;
	assert v.keys[0] == "name";
}
