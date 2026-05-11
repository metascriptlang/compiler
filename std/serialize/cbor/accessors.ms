// CBOR Accessors — extension methods on CborValue
//
// Convention-based protocol methods (compiler synthesizes implicit calls):
//   value.asString() / asNumber() / asBoolean() / asInt32() / asInt64()
//   value.getDynamicField("key")          — text-keyed map lookup (text → CborValue)
// Direct call still works for explicit invocation.
// Other accessors:
//   value.at(idx), value.length
//
// Mirrors std/serialize/json/accessors.ms — same protocol surface so user
// code that consumes UntypedTree<X> values via `v.foo.asString()` works
// identically across JSON and CBOR.

import { CborKind, CborValue } from "./types";
import { cborNull } from "./builder";

// ===== Type accessors (coercion protocol — `as<TargetType>`) =====

export function asString(this v: CborValue, def: string = ""): string {
	if (v !== null && v.kind === CborKind.Text) return v.textVal;
	return def;
}

// CBOR's Int variant covers both major 0 (unsigned) and major 1 (negative)
// — wire type "integer". Float is a distinct variant. asNumber accepts
// both Int and Float; asInt* accepts only Int (numeric truncation of float
// is lossy and the user almost never wants it implicitly).
export function asNumber(this v: CborValue, def: number = 0): number {
	if (v === null) return def;
	return match (v.kind) {
		CborKind.Int   => v.intVal as number,
		CborKind.Float => v.floatVal,
		_ => def,
	};
}

export function asBoolean(this v: CborValue, def: boolean = false): boolean {
	if (v !== null && v.kind === CborKind.Bool) return v.boolVal;
	return def;
}

export function asInt32(this v: CborValue, def: int32 = 0): int32 {
	if (v !== null && v.kind === CborKind.Int) return v.intVal as int32;
	return def;
}

export function asInt64(this v: CborValue, def: int64 = 0 as int64): int64 {
	if (v !== null && v.kind === CborKind.Int) return v.intVal;
	return def;
}

// ===== Collection accessors =====

export function at(this v: CborValue, idx: number): CborValue {
	if (v !== null && v.kind === CborKind.Array && idx >= 0 && idx < v.items.length) {
		return v.items[idx];
	}
	return cborNull();
}

export function length(this v: CborValue): number {
	if (v === null) return 0;
	return match (v.kind) {
		CborKind.Array => v.items.length,
		CborKind.Map   => v.keys.length,
		CborKind.Bytes => v.bytesVal.byteLength,
		CborKind.Text  => v.textVal.byteLength,
		_ => 0,
	};
}

// ===== Dynamic field access (protocol — `getDynamicField`) =====
//
// CBOR maps allow ANY key type per RFC 8949. This accessor finds the FIRST
// pair whose key is a Text matching `key`. Non-text-keyed pairs are skipped.
// Untyped tree consumers (`v.foo.bar.asString()`) can only reach text-keyed
// pairs through this protocol; other key types require manual
// `v.keys[i] / v.values[i]` indexing.

export function getDynamicField(this v: CborValue, key: string): CborValue {
	if (v !== null && v.kind === CborKind.Map) {
		let i = 0;
		while (i < v.keys.length) {
			const k = v.keys[i];
			if (k.kind === CborKind.Text && k.textVal === key) return v.values[i];
			i = i + 1;
		}
	}
	return cborNull();
}

// ===== Tag access =====
//
// `tagNumber()` and `untag()` give cheap access to a tagged value's number
// and inner item. Returns `cborNull()` for non-Tag input — caller can chain
// `v.untag().asString()` to reach the inner text payload safely.

export function tagNumber(this v: CborValue, def: int64 = -1 as int64): int64 {
	if (v !== null && v.kind === CborKind.Tag) return v.tagNum;
	return def;
}

export function untag(this v: CborValue): CborValue {
	if (v !== null && v.kind === CborKind.Tag) return v.tagged;
	return cborNull();
}

// ===== Array-extraction helpers =====
// Used by typed decode macro (cborValueToStruct) for array fields.

export function cborToStringArray(this v: CborValue): string[] {
	const out: string[] = [];
	if (v === null || v.kind !== CborKind.Array) return out;
	for (const item of v.items) out.push(asString(item));
	return out;
}

export function cborToBooleanArray(this v: CborValue): boolean[] {
	const out: boolean[] = [];
	if (v === null || v.kind !== CborKind.Array) return out;
	for (const item of v.items) out.push(asBoolean(item));
	return out;
}

export function cborToNumberArray(this v: CborValue): number[] {
	const out: number[] = [];
	if (v === null || v.kind !== CborKind.Array) return out;
	for (const item of v.items) out.push(asNumber(item));
	return out;
}

export function cborToInt8Array(this v: CborValue): int8[] {
	const out: int8[] = [];
	if (v === null || v.kind !== CborKind.Array) return out;
	for (const item of v.items) out.push(asInt64(item) as int8);
	return out;
}

export function cborToInt16Array(this v: CborValue): int16[] {
	const out: int16[] = [];
	if (v === null || v.kind !== CborKind.Array) return out;
	for (const item of v.items) out.push(asInt64(item) as int16);
	return out;
}

export function cborToInt32Array(this v: CborValue): int32[] {
	const out: int32[] = [];
	if (v === null || v.kind !== CborKind.Array) return out;
	for (const item of v.items) out.push(asInt64(item) as int32);
	return out;
}

export function cborToInt64Array(this v: CborValue): int64[] {
	const out: int64[] = [];
	if (v === null || v.kind !== CborKind.Array) return out;
	for (const item of v.items) out.push(asInt64(item));
	return out;
}

export function cborToUint8Array(this v: CborValue): uint8[] {
	const out: uint8[] = [];
	if (v === null || v.kind !== CborKind.Array) return out;
	for (const item of v.items) out.push(asInt64(item) as uint8);
	return out;
}

export function cborToUint16Array(this v: CborValue): uint16[] {
	const out: uint16[] = [];
	if (v === null || v.kind !== CborKind.Array) return out;
	for (const item of v.items) out.push(asInt64(item) as uint16);
	return out;
}

export function cborToUint32Array(this v: CborValue): uint32[] {
	const out: uint32[] = [];
	if (v === null || v.kind !== CborKind.Array) return out;
	for (const item of v.items) out.push(asInt64(item) as uint32);
	return out;
}

export function cborToFloat32Array(this v: CborValue): float32[] {
	const out: float32[] = [];
	if (v === null || v.kind !== CborKind.Array) return out;
	for (const item of v.items) out.push(asNumber(item) as float32);
	return out;
}

// ===== Tests =====
//
// Bun test-ms harness doesn't dispatch extension methods (`v.asString()`)
// through MS's `this T` resolution — same limitation that keeps JSON's
// accessors.ms test-free. So inline tests call the functions DIRECTLY
// (as `asString(v)` not `v.asString()`). End-to-end extension-method
// dispatch is validated via run-ms probes (basic / utf8 / float).

import { cborInt, cborText, cborArray, cborMap, cborTextMap, cborBool, cborTag, cborFloat } from "./builder";

test "asString on Text" {
	assert asString(cborText("hi")) === "hi";
}

test "asString on non-Text returns default" {
	assert asString(cborInt(42 as int64)) === "";
	assert asString(cborInt(42 as int64), "fallback") === "fallback";
}

test "asNumber on Int" {
	assert asNumber(cborInt(42 as int64)) === 42;
}

test "asNumber on Float" {
	assert asNumber(cborFloat(3.14)) > 3.13;
	assert asNumber(cborFloat(3.14)) < 3.15;
}

test "asNumber on non-numeric returns default" {
	assert asNumber(cborText("hi")) === 0;
	assert asNumber(cborText("hi"), 99) === 99;
}

test "asBoolean on Bool" {
	assert asBoolean(cborBool(true)) === true;
	assert asBoolean(cborBool(false)) === false;
}

test "asBoolean default for non-Bool" {
	assert asBoolean(cborInt(0 as int64)) === false;
	assert asBoolean(cborInt(0 as int64), true) === true;
}

test "asInt32 on Int" {
	assert asInt32(cborInt(42 as int64)) === (42 as int32);
}

test "asInt32 default for non-Int" {
	assert asInt32(cborText("nope")) === (0 as int32);
	assert asInt32(cborText("nope"), 99 as int32) === (99 as int32);
}

test "asInt64 on Int" {
	assert asInt64(cborInt(1234567890123 as int64)) === (1234567890123 as int64);
}

test "asInt64 NOT pulled from Float (lossy)" {
	// Deliberately strict: asInt64 only accepts Int. Float→Int requires
	// explicit truncation by the caller.
	assert asInt64(cborFloat(42.7)) === (0 as int64);
}

test "at on Array" {
	const arr = cborArray([cborInt(10 as int64), cborInt(20 as int64), cborInt(30 as int64)]);
	assert asInt64(at(arr, 0)) === (10 as int64);
	assert asInt64(at(arr, 1)) === (20 as int64);
	assert asInt64(at(arr, 2)) === (30 as int64);
}

test "at returns null for out-of-bounds" {
	const arr = cborArray([cborInt(1 as int64)]);
	assert at(arr, 5).kind === CborKind.Null;
	assert at(arr, -1).kind === CborKind.Null;
}

test "at returns null for non-array" {
	assert at(cborInt(0 as int64), 0).kind === CborKind.Null;
}

test "length on Array" {
	assert length(cborArray([cborInt(1 as int64), cborInt(2 as int64)])) === 2;
}

test "length on Map" {
	const m = cborTextMap(["a", "b", "c"], [cborInt(1 as int64), cborInt(2 as int64), cborInt(3 as int64)]);
	assert length(m) === 3;
}

test "length on Text returns byte length" {
	assert length(cborText("hello")) === 5;
}

test "length on non-collection returns 0" {
	assert length(cborInt(42 as int64)) === 0;
	assert length(cborBool(true)) === 0;
}

test "getDynamicField on text-keyed Map" {
	const m = cborTextMap(["name", "age"], [cborText("Alice"), cborInt(30 as int64)]);
	assert asString(getDynamicField(m, "name")) === "Alice";
	assert asInt64(getDynamicField(m, "age")) === (30 as int64);
}

test "getDynamicField missing key returns null" {
	const m = cborTextMap(["a"], [cborInt(1 as int64)]);
	assert getDynamicField(m, "missing").kind === CborKind.Null;
}

test "getDynamicField on non-Map returns null" {
	assert getDynamicField(cborInt(0 as int64), "x").kind === CborKind.Null;
}

test "getDynamicField skips non-text keys" {
	// Map with int key 1 → "value". asking for "1" as text should NOT match.
	const m = cborMap([cborInt(1 as int64)], [cborText("v")]);
	assert getDynamicField(m, "1").kind === CborKind.Null;
}

test "tagNumber + untag" {
	const inner = cborText("2026-05-09");
	const tagged = cborTag(0 as int64, inner);
	assert tagNumber(tagged) === (0 as int64);
	assert untag(tagged).kind === CborKind.Text;
	assert asString(untag(tagged)) === "2026-05-09";
}

test "tagNumber default for non-Tag" {
	assert tagNumber(cborInt(0 as int64)) === (-1 as int64);
}

test "untag default for non-Tag" {
	assert untag(cborInt(0 as int64)).kind === CborKind.Null;
}

test "chained access on nested Map" {
	// { "user": { "name": "X" } }
	const inner = cborTextMap(["name"], [cborText("X")]);
	const outer = cborTextMap(["user"], [inner]);
	assert asString(getDynamicField(getDynamicField(outer, "user"), "name")) === "X";
}

test "chained access on non-existent nested key returns default" {
	const m = cborTextMap(["x"], [cborInt(1 as int64)]);
	// getDynamicField returns cborNull, asString returns "" default
	assert asString(getDynamicField(getDynamicField(m, "missing"), "deeper")) === "";
}
