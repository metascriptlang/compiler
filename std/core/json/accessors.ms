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

export function asNumber(this v: JsonValue, def: number = 0): number {
	if (v !== null && v.kind === JsonKind.Number) return v.numVal;
	return def;
}

export function asBoolean(this v: JsonValue, def: boolean = false): boolean {
	if (v !== null && v.kind === JsonKind.Bool) return v.boolVal;
	return def;
}

export function asInt32(this v: JsonValue, def: int32 = 0): int32 {
	if (v !== null && v.kind === JsonKind.Number) return v.numVal as int32;
	return def;
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
