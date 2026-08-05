// JSON Accessors — extension methods on JsonValue
//
// Convention-based protocol methods (compiler synthesizes implicit calls):
//   value.asString() / asNumber() / asBoolean() / asInt32()  — coercion (Phase 2 protocol)
//   value.getDynamicField("key")                              — dynamic field (Phase 1 protocol)
// Direct call still works for explicit invocation.
// Other accessors:
//   value.at(idx), value.length

import { JsonKind, JsonValue } from "./types";
import { jsonNull } from "./builder";

// ===== Type Accessors (coercion protocol — `as<TargetType>`) =====

export function asString(this v: JsonValue, def: string = ""): string {
	if (v !== null && v.kind === JsonKind.String) return v.strVal;
	return def;
}

// Bridge Int↔Number: parser stores `30` as JsonKind.Int (intVal slot) and
// `30.5` as JsonKind.Number (numVal slot). Coercion accepts EITHER variant
// for asNumber / asInt* — the JSON wire type "number" doesn't distinguish.
export function asNumber(this v: JsonValue, def: number = 0): number {
	if (v === null) return def;
	return match (v.kind) {
		JsonKind.Number => v.numVal,
		JsonKind.Int    => v.intVal as number,
		_ => def,
	};
}

export function asBoolean(this v: JsonValue, def: boolean = false): boolean {
	if (v !== null && v.kind === JsonKind.Bool) return v.boolVal;
	return def;
}

export function asInt32(this v: JsonValue, def: int32 = 0): int32 {
	if (v === null) return def;
	return match (v.kind) {
		JsonKind.Int    => v.intVal as int32,
		JsonKind.Number => v.numVal as int32,
		_ => def,
	};
}

// Read int64 directly from either variant. Macros emit calls to this for
// sized-int fields when decoding; runtime branch covers parser's int/number
// split so user struct fields don't read uninitialized slots.
export function asInt64(this v: JsonValue, def: int64 = 0 as int64): int64 {
	if (v === null) return def;
	return match (v.kind) {
		JsonKind.Int    => v.intVal,
		JsonKind.Number => v.numVal as int64,
		_ => def,
	};
}

// ===== Collection Accessors =====

export function at(this v: JsonValue, idx: number): JsonValue {
	if (v !== null && v.kind === JsonKind.Array && idx >= 0 && idx < v.items.length) {
		return v.items[idx];
	}
	return jsonNull();
}

export function length(this v: JsonValue): number {
	if (v === null) return 0;
	return match (v.kind) {
		JsonKind.Array  => v.items.length,
		JsonKind.Object => v.keys.length,
		_ => 0,
	};
}

// ===== Strict (req*) accessors — fail-loud typed decode =====
//
// Same coercion rules as as*, but a kind mismatch APPENDS an error naming
// the field instead of silently returning the default. jsonValueToStructE
// emits these; the facade turns a non-empty errs into Result.err. Missing
// field and JSON null are indistinguishable here (both arrive as the
// jsonNull sentinel) — the message says "got null" for both.

export function kindName(k: JsonKind): string {
	return match (k) {
		JsonKind.Null => "null",
		JsonKind.Bool => "boolean",
		JsonKind.Number => "number",
		JsonKind.String => "string",
		JsonKind.Array => "array",
		JsonKind.Object => "object",
		JsonKind.Int => "int",
		_ => "unknown",
	};
}

function pushKindErr(errs: string[], pfx: string, field: string, expected: string, v: JsonValue): void {
	const got = v === null ? "null" : kindName(v.kind);
	errs.push("field '" + pfx + field + "': expected " + expected + ", got " + got);
}

export function reqString(this v: JsonValue, pfx: string, field: string, errs: string[]): string {
	if (v !== null && v.kind === JsonKind.String) return v.strVal;
	pushKindErr(errs, pfx, field, "string", v);
	return "";
}

export function reqBoolean(this v: JsonValue, pfx: string, field: string, errs: string[]): boolean {
	if (v !== null && v.kind === JsonKind.Bool) return v.boolVal;
	pushKindErr(errs, pfx, field, "boolean", v);
	return false;
}

// JSON wire has one number type; a field typed number accepts either carrier.
export function reqNumber(this v: JsonValue, pfx: string, field: string, errs: string[]): number {
	if (v !== null) {
		if (v.kind === JsonKind.Number) return v.numVal;
		if (v.kind === JsonKind.Int) return v.intVal as number;
	}
	pushKindErr(errs, pfx, field, "number", v);
	return 0;
}

// Int carrier only — a float literal for an int field is a contract breach
// (the classification is a pure function of the source text, so both
// backends reject identically).
export function reqInt64(this v: JsonValue, pfx: string, field: string, errs: string[]): int64 {
	if (v !== null && v.kind === JsonKind.Int) return v.intVal;
	pushKindErr(errs, pfx, field, "int", v);
	return 0 as int64;
}

export function reqArray(this v: JsonValue, pfx: string, field: string, errs: string[]): JsonValue {
	if (v !== null && v.kind === JsonKind.Array) return v;
	pushKindErr(errs, pfx, field, "array", v);
	return jsonNull();
}

export function reqObject(this v: JsonValue, pfx: string, field: string, errs: string[]): JsonValue {
	if (v !== null && v.kind === JsonKind.Object) return v;
	pushKindErr(errs, pfx, field, "object", v);
	return jsonNull();
}

// DU discriminator gate. Runs BEFORE the variant match: an unrecognised
// disc records an error and is coerced to the first declared variant, so
// the match itself only ever sees a known value and needs no wildcard arm.
// (A wildcard arm would have to build an object whose disc field is a
// runtime string rather than the variant's literal type — that is a third,
// unrelated anonymous type, and the union assignment stops type-checking.)
// Unknown-disc input is rejected by the facade via errs; decoding it as
// variant 0 only keeps the expression total.
// Joins decode problems into one message, dropping repeats.
//
// A nested object's handle expression is inlined once PER INNER FIELD (the
// macro emits an expression, and an expression cannot bind a local), so a
// missing intermediate object reports itself once per field below it. The
// message carries the full field path, so identical text always means the
// same problem — dropping repeats loses nothing and keeps the output
// deterministic. Removing the repeats at the source needs statement-level
// binding in the expansion, which the macro surface cannot express today.
export function joinDecodeErrors(errs: string[]): string {
	const seen: string[] = [];
	for (const e of errs) {
		let dup = false;
		for (const s of seen) {
			if (s === e) { dup = true; }
		}
		if (!dup) seen.push(e);
	}
	return seen.join("; ");
}

export function _jsonCheckDiscStr(v: string, allowed: string[], errs: string[], pfx: string, field: string): string {
	for (const a of allowed) {
		if (a === v) return v;
	}
	errs.push("field '" + pfx + field + "': unknown discriminator value '" + v + "'");
	return allowed[0];
}

export function _jsonIsNull(v: JsonValue): boolean {
	return v === null || v.kind === JsonKind.Null;
}

test "_jsonIsNull — null sentinel and absent field are null, values are not" {
	const obj = jsonObject(["a"], [jsonString("x")]);
	assert _jsonIsNull(obj.getDynamicField("missing"));
	assert _jsonIsNull(jsonNull());
	assert !_jsonIsNull(obj.getDynamicField("a"));
}

// ===== Dynamic Field Access (protocol — `getDynamicField`) =====

export function getDynamicField(this v: JsonValue, key: string): JsonValue {
	if (v !== null && v.kind === JsonKind.Object) {
		let i = 0;
		while (i < v.keys.length) {
			if (v.keys[i] === key) return v.values[i];
			i = i + 1;
		}
	}
	return jsonNull();
}

// ===== Dynamic Field Write (protocol — `setDynamicField`) =====
//
// Compiler synthesizes `j.foo = v` → `j.setDynamicField("foo", v)`.
// Replace-or-append into the parallel keys[]/values[] arrays. Non-Object kinds
// are no-op rather than throwing — common for view types like JsonValue where
// the caller often does not control kind statically. To grow an empty/null
// value into an object, use builder helpers first.
export function setDynamicField(this v: JsonValue, key: string, value: JsonValue): void {
	if (v === null || v.kind !== JsonKind.Object) return;
	let i = 0;
	while (i < v.keys.length) {
		if (v.keys[i] === key) {
			v.values[i] = value;
			return;
		}
		i = i + 1;
	}
	v.keys.push(key);
	v.values.push(value);
}

// ===== Array-extraction helpers =====
//
// Used by typed decode macro (jsonValueToStruct) for array fields. Per-
// element-type variants — symmetric with builder's jsonArrayOfX. Reads
// JsonValue.items (only when kind === Array; otherwise returns empty array).

export function jsonToStringArray(this v: JsonValue): string[] {
	const out: string[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (const item of v.items) out.push(asString(item));
	return out;
}

export function jsonToBooleanArray(this v: JsonValue): boolean[] {
	const out: boolean[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (const item of v.items) out.push(asBoolean(item));
	return out;
}

export function jsonToNumberArray(this v: JsonValue): number[] {
	const out: number[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (const item of v.items) out.push(asNumber(item));
	return out;
}

export function jsonToInt8Array(this v: JsonValue): int8[] {
	const out: int8[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (const item of v.items) out.push(asInt64(item) as int8);
	return out;
}

export function jsonToInt16Array(this v: JsonValue): int16[] {
	const out: int16[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (const item of v.items) out.push(asInt64(item) as int16);
	return out;
}

export function jsonToInt32Array(this v: JsonValue): int32[] {
	const out: int32[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (const item of v.items) out.push(asInt64(item) as int32);
	return out;
}

export function jsonToInt64Array(this v: JsonValue): int64[] {
	const out: int64[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (const item of v.items) out.push(asInt64(item));
	return out;
}

export function jsonToUint8Array(this v: JsonValue): uint8[] {
	const out: uint8[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (const item of v.items) out.push(asInt64(item) as uint8);
	return out;
}

export function jsonToUint16Array(this v: JsonValue): uint16[] {
	const out: uint16[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (const item of v.items) out.push(asInt64(item) as uint16);
	return out;
}

export function jsonToUint32Array(this v: JsonValue): uint32[] {
	const out: uint32[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (const item of v.items) out.push(asInt64(item) as uint32);
	return out;
}

export function jsonToFloat32Array(this v: JsonValue): float32[] {
	const out: float32[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (const item of v.items) out.push(asNumber(item) as float32);
	return out;
}

// ===== Tests =====

test "reqString: ok path adds no error" {
	const errs: string[] = [];
	const v: JsonValue = { kind: JsonKind.String, strVal: "hi" };
	assert reqString(v, "", "name", errs) === "hi";
	assert errs.length === 0;
}

test "reqString: wrong kind pushes named error" {
	const errs: string[] = [];
	const v: JsonValue = { kind: JsonKind.Int, intVal: 7 as int64 };
	assert reqString(v, "", "name", errs) === "";
	assert errs.length === 1;
	assert errs[0] === "field 'name': expected string, got int";
}

test "reqString: prefix lands in the message" {
	const errs: string[] = [];
	const v: JsonValue = { kind: JsonKind.Null };
	reqString(v, "addr.", "city", errs);
	assert errs[0] === "field 'addr.city': expected string, got null";
}

test "reqNumber: accepts both carriers" {
	const errs: string[] = [];
	const i: JsonValue = { kind: JsonKind.Int, intVal: 30 as int64 };
	const f: JsonValue = { kind: JsonKind.Number, numVal: 0.5 };
	assert reqNumber(i, "", "a", errs) === 30;
	assert reqNumber(f, "", "b", errs) === 0.5;
	assert errs.length === 0;
}

test "reqInt64: rejects float carrier" {
	const errs: string[] = [];
	const f: JsonValue = { kind: JsonKind.Number, numVal: 1.5 };
	reqInt64(f, "", "age", errs);
	assert errs.length === 1;
	assert errs[0] === "field 'age': expected int, got number";
}

test "reqArray/reqObject: mismatch pushes, sentinel returned" {
	const errs: string[] = [];
	const n: JsonValue = { kind: JsonKind.Int, intVal: 3 as int64 };
	const a = reqArray(n, "", "tags", errs);
	const o = reqObject(n, "", "addr", errs);
	assert a.kind === JsonKind.Null;
	assert o.kind === JsonKind.Null;
	assert errs.length === 2;
	assert errs[0] === "field 'tags': expected array, got int";
	assert errs[1] === "field 'addr': expected object, got int";
}

// ===== Strict array-extraction helpers =====
//
// Mirrors of the jsonToXArray family that report a per-element failure instead
// of coercing it to a default. `arrPath` is the path of the ARRAY field, so an
// element reads `field 'xs[1]': expected string, got int` — the same shape a
// struct element produces.

function jsonElemPath(arrPath: string, i: int32): string {
	return arrPath + "[" + i.toString() + "]";
}

export function jsonToStringArrayE(this v: JsonValue, errs: string[], arrPath: string): string[] {
	const out: string[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (let i = 0; i < v.items.length; i = i + 1) {
		out.push(reqString(v.items[i], jsonElemPath(arrPath, i), "", errs));
	}
	return out;
}

export function jsonToBooleanArrayE(this v: JsonValue, errs: string[], arrPath: string): boolean[] {
	const out: boolean[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (let i = 0; i < v.items.length; i = i + 1) {
		out.push(reqBoolean(v.items[i], jsonElemPath(arrPath, i), "", errs));
	}
	return out;
}

export function jsonToNumberArrayE(this v: JsonValue, errs: string[], arrPath: string): number[] {
	const out: number[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (let i = 0; i < v.items.length; i = i + 1) {
		out.push(reqNumber(v.items[i], jsonElemPath(arrPath, i), "", errs));
	}
	return out;
}

export function jsonToFloat32ArrayE(this v: JsonValue, errs: string[], arrPath: string): float32[] {
	const out: float32[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (let i = 0; i < v.items.length; i = i + 1) {
		out.push(reqNumber(v.items[i], jsonElemPath(arrPath, i), "", errs) as float32);
	}
	return out;
}

export function jsonToInt8ArrayE(this v: JsonValue, errs: string[], arrPath: string): int8[] {
	const out: int8[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (let i = 0; i < v.items.length; i = i + 1) {
		out.push(reqInt64(v.items[i], jsonElemPath(arrPath, i), "", errs) as int8);
	}
	return out;
}

export function jsonToInt16ArrayE(this v: JsonValue, errs: string[], arrPath: string): int16[] {
	const out: int16[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (let i = 0; i < v.items.length; i = i + 1) {
		out.push(reqInt64(v.items[i], jsonElemPath(arrPath, i), "", errs) as int16);
	}
	return out;
}

export function jsonToInt32ArrayE(this v: JsonValue, errs: string[], arrPath: string): int32[] {
	const out: int32[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (let i = 0; i < v.items.length; i = i + 1) {
		out.push(reqInt64(v.items[i], jsonElemPath(arrPath, i), "", errs) as int32);
	}
	return out;
}

export function jsonToInt64ArrayE(this v: JsonValue, errs: string[], arrPath: string): int64[] {
	const out: int64[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (let i = 0; i < v.items.length; i = i + 1) {
		out.push(reqInt64(v.items[i], jsonElemPath(arrPath, i), "", errs));
	}
	return out;
}

export function jsonToUint8ArrayE(this v: JsonValue, errs: string[], arrPath: string): uint8[] {
	const out: uint8[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (let i = 0; i < v.items.length; i = i + 1) {
		out.push(reqInt64(v.items[i], jsonElemPath(arrPath, i), "", errs) as uint8);
	}
	return out;
}

export function jsonToUint16ArrayE(this v: JsonValue, errs: string[], arrPath: string): uint16[] {
	const out: uint16[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (let i = 0; i < v.items.length; i = i + 1) {
		out.push(reqInt64(v.items[i], jsonElemPath(arrPath, i), "", errs) as uint16);
	}
	return out;
}

export function jsonToUint32ArrayE(this v: JsonValue, errs: string[], arrPath: string): uint32[] {
	const out: uint32[] = [];
	if (v === null || v.kind !== JsonKind.Array) return out;
	for (let i = 0; i < v.items.length; i = i + 1) {
		out.push(reqInt64(v.items[i], jsonElemPath(arrPath, i), "", errs) as uint32);
	}
	return out;
}
