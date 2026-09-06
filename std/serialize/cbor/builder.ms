// MetaScript CBOR — Constructors
//
// Builders for each CborKind variant. Mirrors std/serialize/json/builder.ms
// pattern: one constructor per variant, no validation logic — pass-through
// to the discriminated union shape.

import { Buffer } from "std/core/buffer";
import { CborKind, CborValue } from "./types";

// --- Major 0 / 1 (collapsed: sign indicates wire major) ---

export function cborInt(n: int64): CborValue {
	return { kind: CborKind.Int, intVal: n };
}

// --- Major 2 ---

export function cborBytes(b: Buffer): CborValue {
	return { kind: CborKind.Bytes, bytesVal: b };
}

// --- Major 3 ---

export function cborText(s: string): CborValue {
	return { kind: CborKind.Text, textVal: s };
}

// --- Major 4 ---

export function cborArray(items: CborValue[]): CborValue {
	return { kind: CborKind.Array, items: items };
}

// --- Major 5 ---
// Keys can be ANY CborValue per RFC 8949 §3.1; text-key shortcut
// `cborTextMap` lives further down for the common case.

export function cborMap(keys: CborValue[], values: CborValue[]): CborValue {
	return { kind: CborKind.Map, keys: keys, values: values };
}

// Convenience: build a Map from string keys (UTF-8). Keys are auto-wrapped
// in cborText. Most user-facing APIs only need string keys.
export function cborTextMap(keys: string[], values: CborValue[]): CborValue {
	const wrappedKeys: CborValue[] = [];
	for (const k of keys) {
		wrappedKeys.push(cborText(k));
	}
	return { kind: CborKind.Map, keys: wrappedKeys, values: values };
}

// --- Major 6 ---

export function cborTag(tagNum: int64, tagged: CborValue): CborValue {
	return { kind: CborKind.Tag, tagNum: tagNum, tagged: tagged };
}

// --- Major 7 ---

export function cborBool(b: boolean): CborValue {
	return { kind: CborKind.Bool, boolVal: b };
}

export function cborNull(): CborValue {
	return { kind: CborKind.Null };
}

export function cborUndefined(): CborValue {
	return { kind: CborKind.Undefined };
}

export function cborFloat(f: float64): CborValue {
	return { kind: CborKind.Float, floatVal: f };
}

// Reserved-or-application simple values (RFC 8949 §3.3).
// Bool/Null/Undefined are special-cased above; this constructor covers
// values 0..19 and 32..255. Values 20..23 collide with bool/null/undefined
// and 24..31 are reserved — caller responsible for not passing those.
export function cborSimple(n: number): CborValue {
	return { kind: CborKind.Simple, simpleVal: n };
}

// ===== Array-from-typed helpers =====
//
// Used by the typed encode macro (cborValueOf) for array fields. Per-element-
// type variants — same rationale as JSON. Atomic-element coverage only;
// struct-element arrays deferred to V2.

export function cborArrayOfStrings(arr: string[]): CborValue {
	const items: CborValue[] = [];
	for (const s of arr) items.push(cborText(s));
	return cborArray(items);
}

export function cborArrayOfBooleans(arr: boolean[]): CborValue {
	const items: CborValue[] = [];
	for (const b of arr) items.push(cborBool(b));
	return cborArray(items);
}

export function cborArrayOfNumbers(arr: number[]): CborValue {
	const items: CborValue[] = [];
	for (const n of arr) items.push(cborFloat(n));
	return cborArray(items);
}

export function cborArrayOfFloat32(arr: float32[]): CborValue {
	const items: CborValue[] = [];
	for (const x of arr) items.push(cborFloat(x as float64));
	return cborArray(items);
}

export function cborArrayOfInt8(arr: int8[]): CborValue {
	const items: CborValue[] = [];
	for (const x of arr) items.push(cborInt(x as int64));
	return cborArray(items);
}

export function cborArrayOfInt16(arr: int16[]): CborValue {
	const items: CborValue[] = [];
	for (const x of arr) items.push(cborInt(x as int64));
	return cborArray(items);
}

export function cborArrayOfInt32(arr: int32[]): CborValue {
	const items: CborValue[] = [];
	for (const x of arr) items.push(cborInt(x as int64));
	return cborArray(items);
}

export function cborArrayOfInt64(arr: int64[]): CborValue {
	const items: CborValue[] = [];
	for (const x of arr) items.push(cborInt(x));
	return cborArray(items);
}

export function cborArrayOfUint8(arr: uint8[]): CborValue {
	const items: CborValue[] = [];
	for (const x of arr) items.push(cborInt(x as int64));
	return cborArray(items);
}

export function cborArrayOfUint16(arr: uint16[]): CborValue {
	const items: CborValue[] = [];
	for (const x of arr) items.push(cborInt(x as int64));
	return cborArray(items);
}

export function cborArrayOfUint32(arr: uint32[]): CborValue {
	const items: CborValue[] = [];
	for (const x of arr) items.push(cborInt(x as int64));
	return cborArray(items);
}

// ===== Tests =====

test "cborInt zero" {
	const v = cborInt(0 as int64);
	assert v.kind == CborKind.Int;
	assert v.intVal == (0 as int64);
}

test "cborInt positive" {
	const v = cborInt(42 as int64);
	assert v.kind == CborKind.Int;
	assert v.intVal == (42 as int64);
}

test "cborInt negative" {
	const v = cborInt(-7 as int64);
	assert v.kind == CborKind.Int;
	assert v.intVal == (-7 as int64);
}

test "cborInt max int64" {
	// 2^63 - 1 = 9223372036854775807
	const v = cborInt(9223372036854775807 as int64);
	assert v.kind == CborKind.Int;
	assert v.intVal == (9223372036854775807 as int64);
}

test "cborText empty" {
	const v = cborText("");
	assert v.kind == CborKind.Text;
	assert v.textVal == "";
}

test "cborText utf8" {
	const v = cborText("héllo 🌍");
	assert v.kind == CborKind.Text;
	assert v.textVal == "héllo 🌍";
}

// cborBytes shape verified in encoder/decoder round-trip tests where actual
// byte buffers are constructed.

test "cborArray empty" {
	const items: CborValue[] = [];
	const v = cborArray(items);
	assert v.kind == CborKind.Array;
	assert v.items.length == 0;
}

test "cborArray nested" {
	const items: CborValue[] = [cborInt(1 as int64), cborInt(2 as int64), cborInt(3 as int64)];
	const v = cborArray(items);
	assert v.kind == CborKind.Array;
	assert v.items.length == 3;
	assert v.items[0].kind == CborKind.Int;
	assert v.items[2].kind == CborKind.Int;
	assert v.items[2].intVal == (3 as int64);
}

test "cborMap any-keyed" {
	const keys: CborValue[] = [cborInt(1 as int64), cborInt(2 as int64)];
	const vals: CborValue[] = [cborText("one"), cborText("two")];
	const v = cborMap(keys, vals);
	assert v.kind == CborKind.Map;
	assert v.keys.length == 2;
	assert v.values.length == 2;
	assert v.keys[0].kind == CborKind.Int;
	assert v.keys[0].intVal == (1 as int64);
	assert v.values[1].kind == CborKind.Text;
	assert v.values[1].textVal == "two";
}

test "cborTextMap convenience wrapper" {
	const keys: string[] = ["name", "age"];
	const vals: CborValue[] = [cborText("Alice"), cborInt(30 as int64)];
	const v = cborTextMap(keys, vals);
	assert v.kind == CborKind.Map;
	assert v.keys.length == 2;
	assert v.keys[0].kind == CborKind.Text;
	assert v.keys[0].textVal == "name";
	assert v.values[1].kind == CborKind.Int;
}

test "cborTag" {
	const tagged = cborText("2026-05-09");
	const v = cborTag(0 as int64, tagged); // tag 0 = standard datetime string
	assert v.kind == CborKind.Tag;
	assert v.tagNum == (0 as int64);
	assert v.tagged.kind == CborKind.Text;
}

test "cborBool true" {
	const v = cborBool(true);
	assert v.kind == CborKind.Bool;
	assert v.boolVal == true;
}

test "cborBool false" {
	const v = cborBool(false);
	assert v.kind == CborKind.Bool;
	assert v.boolVal == false;
}

test "cborNull" {
	const v = cborNull();
	assert v.kind == CborKind.Null;
}

test "cborUndefined" {
	const v = cborUndefined();
	assert v.kind == CborKind.Undefined;
}

test "cborFloat" {
	const v = cborFloat(3.14);
	assert v.kind == CborKind.Float;
	// allow tiny precision drift
	assert v.floatVal > 3.13 && v.floatVal < 3.15;
}

test "cborFloat zero" {
	const v = cborFloat(0.0);
	assert v.kind == CborKind.Float;
	assert v.floatVal == 0.0;
}

test "cborSimple" {
	const v = cborSimple(42);
	assert v.kind == CborKind.Simple;
	assert v.simpleVal == 42;
}
