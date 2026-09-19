// MetaScript JSON — Type Definitions
//
// Discriminated union JsonValueData wrapped in Ref for heap allocation.
// Memory-efficient: only active variant uses space (true C union).
// Recursive: arrays/objects contain JsonValue refs.

export enum JsonKind {
	Null,
	Bool,
	Number,
	String,
	Array,
	Object,
	Int,
}

export type JsonValueData = match (kind: JsonKind) {
	JsonKind.Null   => {},
	JsonKind.Bool   => { boolVal: boolean },
	JsonKind.Number => { numVal: number },
	JsonKind.String => { strVal: string },
	JsonKind.Array  => { items: JsonValue[] },
	JsonKind.Object => { keys: string[], values: JsonValue[] },
	JsonKind.Int    => { intVal: int64 },
};

export type JsonValue = Ref<JsonValueData>;

// ===== Type Accessors =====

export function asString(this v: JsonValue, def: string = ""): string {
	if (v != null && v.kind == JsonKind.String) return v.strVal;
	return def;
}

// Bridge Int↔Number: parser stores `30` as JsonKind.Int (intVal slot) and
// `30.5` as JsonKind.Number (numVal slot). Coercion accepts EITHER variant
// for asNumber / asInt* — the JSON wire type "number" doesn't distinguish.
export function asNumber(this v: JsonValue, def: number = 0): number {
	if (v == null) return def;
	return match (v.kind) {
		JsonKind.Number => v.numVal,
		JsonKind.Int    => v.intVal as number,
		_ => def,
	};
}

export function asBoolean(this v: JsonValue, def: boolean = false): boolean {
	if (v != null && v.kind == JsonKind.Bool) return v.boolVal;
	return def;
}

export function asInt32(this v: JsonValue, def: int32 = 0): int32 {
	if (v == null) return def;
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
	if (v == null) return def;
	return match (v.kind) {
		JsonKind.Int    => v.intVal,
		JsonKind.Number => v.numVal as int64,
		_ => def,
	};
}

// ===== Converters =====

export converter jsonToString(v: JsonValue): string { return v.asString(); }
export converter jsonToNumber(v: JsonValue): number { return v.asNumber(); }
export converter jsonToBoolean(v: JsonValue): boolean { return v.asBoolean(); }
export converter jsonToInt32(v: JsonValue): int32 { return v.asInt32(); }
export converter jsonToInt64(v: JsonValue): int64 { return v.asInt64(); }

// ===== Tests =====

test "JsonKind values" {
	assert JsonKind.Null == 0;
	assert JsonKind.Bool == 1;
	assert JsonKind.Number == 2;
	assert JsonKind.String == 3;
	assert JsonKind.Array == 4;
	assert JsonKind.Object == 5;
	assert JsonKind.Int == 6;
}
