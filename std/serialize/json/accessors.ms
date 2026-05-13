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
