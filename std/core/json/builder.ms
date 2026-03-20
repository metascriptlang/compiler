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

// ===== Tests =====

test "construct null" {
	const v = jsonNull();
	assert v.kind === JsonKind.Null;
}

test "construct bool" {
	const t = jsonBool(true);
	assert t.kind === JsonKind.Bool;
	assert t.boolVal === true;
}

test "construct number" {
	const v = jsonNumber(42);
	assert v.kind === JsonKind.Number;
	assert v.numVal === 42;
}

test "construct string" {
	const v = jsonString("hello");
	assert v.kind === JsonKind.String;
	assert v.strVal === "hello";
}

test "construct array" {
	const items: JsonValue[] = [jsonNumber(1), jsonNumber(2)];
	const v = jsonArray(items);
	assert v.kind === JsonKind.Array;
	assert v.items.length === 2;
}

test "construct object" {
	const keys: string[] = ["name", "age"];
	const vals: JsonValue[] = [jsonString("Alice"), jsonNumber(30)];
	const v = jsonObject(keys, vals);
	assert v.kind === JsonKind.Object;
	assert v.keys.length === 2;
	assert v.keys[0] === "name";
}
