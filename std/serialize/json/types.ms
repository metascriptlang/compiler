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

// ===== Tests =====

test "JsonKind values" {
	assert JsonKind.Null === 0;
	assert JsonKind.Bool === 1;
	assert JsonKind.Number === 2;
	assert JsonKind.String === 3;
	assert JsonKind.Array === 4;
	assert JsonKind.Object === 5;
	assert JsonKind.Int === 6;
}
