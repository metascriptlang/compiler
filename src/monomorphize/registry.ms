// Monomorphization Registry — tracks generic instantiations, dedup, name mangling
//
// Reference implementation equivalent: generic instantiation cache.
// sameInstantiation() + genericCacheGet() in seminst.nim.

import { Type, TypeKind } from "../checker/types";

// ===== Data Structures =====

// Represents one concrete instantiation key
// Example: identity<number> → { genericName: "identity", typeArgKeys: ["number"] }
export interface MonoKey {
	genericName: string;
	typeArgKeys: string[];
}

// Tracks one instantiation entry
export interface MonoEntry {
	mangledName: string;         // e.g., "identity__number"
	genericName: string;         // original name
	genericParamNames: string[]; // ["T", "U"]
	concreteTypes: Type[];       // [numberType(), stringType()]
	isInstantiated: boolean;     // true after Pass 2 clones the body
}

// The registry itself
export interface MonoRegistry {
	entries: MonoEntry[];
}

// ===== Constructors =====

export function createMonoRegistry(): MonoRegistry {
	const entries: MonoEntry[] = [];
	return { entries };
}

// ===== Type Key Generation =====

// Produce a C-safe identifier fragment for a concrete type.
// Used for name mangling: identity<number> → "identity__number"
export function monoTypeKey(t: Type): string {
	if (t === null) return "null";
	if (t.kind === TypeKind.Number) return "number";
	if (t.kind === TypeKind.String) return "string";
	if (t.kind === TypeKind.Boolean) return "boolean";
	if (t.kind === TypeKind.Void) return "void";
	if (t.kind === TypeKind.Null) return "null";
	if (t.kind === TypeKind.Int8) return "int8";
	if (t.kind === TypeKind.Int16) return "int16";
	if (t.kind === TypeKind.Int32) return "int32";
	if (t.kind === TypeKind.Int64) return "int64";
	if (t.kind === TypeKind.Uint8) return "uint8";
	if (t.kind === TypeKind.Uint16) return "uint16";
	if (t.kind === TypeKind.Uint32) return "uint32";
	if (t.kind === TypeKind.Uint64) return "uint64";
	if (t.kind === TypeKind.Float32) return "float32";
	if (t.kind === TypeKind.Float64) return "float64";
	if (t.kind === TypeKind.Array) return "arr_" + monoTypeKey(t.typeReturn);
	if (t.kind === TypeKind.Ref) return "ref_" + monoTypeKey(t.typeReturn);
	if (t.kind === TypeKind.Ptr) return "ptr_" + monoTypeKey(t.typeReturn);
	if (t.kind === TypeKind.Object) return t.typeName;
	if (t.kind === TypeKind.Enum) return t.typeName;
	if (t.kind === TypeKind.Result) {
		return "result_" + monoTypeKey(t.typeReturn) + "_" + monoTypeKey(t.typeExtra);
	}
	if (t.kind === TypeKind.Function) {
		let key = "fn";
		for (let i = 0; i < t.typeChildren.length; i += 1) {
			key = key + "_" + monoTypeKey(t.typeChildren[i]);
		}
		key = key + "_ret_" + monoTypeKey(t.typeReturn);
		return key;
	}
	if (t.kind === TypeKind.Union) {
		let key = "union";
		for (let i = 0; i < t.typeChildren.length; i += 1) {
			key = key + "_" + monoTypeKey(t.typeChildren[i]);
		}
		return key;
	}
	if (t.kind === TypeKind.Distinct) return "distinct_" + monoTypeKey(t.typeReturn);
	return "unknown";
}

// ===== Name Mangling =====

// identity<number>     → "identity__number"
// pair<number, string> → "pair__number_string"
export function mangleMonoName(baseName: string, concreteTypes: Type[]): string {
	let result = baseName + "__";
	for (let i = 0; i < concreteTypes.length; i += 1) {
		if (i > 0) {
			result = result + "_";
		}
		result = result + monoTypeKey(concreteTypes[i]);
	}
	return result;
}

// ===== Deduplication =====

// Compare two type arg key arrays for exact match (Standard reference pattern)
function sameTypeArgKeys(a: string[], b: string[]): boolean {
	if (a.length !== b.length) return false;
	for (let i = 0; i < a.length; i += 1) {
		if (a[i] !== b[i]) return false;
	}
	return true;
}

// Build typeArgKeys from concrete types
export function buildTypeArgKeys(concreteTypes: Type[]): string[] {
	const keys: string[] = [];
	for (let i = 0; i < concreteTypes.length; i += 1) {
		keys.push(monoTypeKey(concreteTypes[i]));
	}
	return keys;
}

// ===== Registry Operations =====

// Find an existing entry for this generic + type args combination.
// Returns the entry or null (Standard reference pattern)
export function monoFindEntry(registry: MonoRegistry, genericName: string, typeArgKeys: string[]): MonoEntry {
	for (let i = 0; i < registry.entries.length; i += 1) {
		const entry = registry.entries[i];
		if (entry.genericName === genericName && sameTypeArgKeys(typeArgKeys, buildTypeArgKeys(entry.concreteTypes))) {
			return entry;
		}
	}
	return null as unknown as MonoEntry;
}

// Register a new instantiation. Returns the entry (existing if duplicate, new if not).
// Standard reference pattern: generic cache addition.
export function monoRegister(
	registry: MonoRegistry,
	genericName: string,
	genericParamNames: string[],
	concreteTypes: Type[]
): MonoEntry {
	// Check for existing (dedup)
	const typeArgKeys = buildTypeArgKeys(concreteTypes);
	const existing = monoFindEntry(registry, genericName, typeArgKeys);
	if (existing !== null) return existing;

	// Create new entry
	const mangledName = mangleMonoName(genericName, concreteTypes);
	const entry: MonoEntry = {
		mangledName: mangledName,
		genericName: genericName,
		genericParamNames: genericParamNames,
		concreteTypes: concreteTypes,
		isInstantiated: false,
	};
	registry.entries.push(entry);
	return entry;
}

// ===== Tests =====
test "monoTypeKey primitives" {
	const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	assert monoTypeKey(num) === "number";
	const str: Type = { kind: TypeKind.String, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	assert monoTypeKey(str) === "string";
	const b: Type = { kind: TypeKind.Boolean, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	assert monoTypeKey(b) === "boolean";
}

test "monoTypeKey array" {
	const numT: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	const arrT: Type = { kind: TypeKind.Array, typeName: "", typeNames: [], typeChildren: [], typeReturn: numT, typeExtra: null as unknown as Type, typeFlags: 0 };
	assert monoTypeKey(arrT) === "arr_number";
}

test "monoTypeKey object" {
	const obj: Type = { kind: TypeKind.Object, typeName: "Box", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	assert monoTypeKey(obj) === "Box";
}

test "mangleMonoName single param" {
	const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	const types: Type[] = [num];
	assert mangleMonoName("identity", types) === "identity__number";
}

test "mangleMonoName two params" {
	const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	const str: Type = { kind: TypeKind.String, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	const types: Type[] = [num, str];
	assert mangleMonoName("pair", types) === "pair__number_string";
}

test "registry dedup" {
	const reg = createMonoRegistry();
	const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	const params: string[] = ["T"];
	const types1: Type[] = [num];
	const entry1 = monoRegister(reg, "identity", params, types1);
	assert entry1.mangledName === "identity__number";
	assert reg.entries.length === 1;

	// Same instantiation → dedup
	const num2: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	const types2: Type[] = [num2];
	const entry2 = monoRegister(reg, "identity", params, types2);
	assert entry2.mangledName === "identity__number";
	assert reg.entries.length === 1;
}

test "registry different types" {
	const reg = createMonoRegistry();
	const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	const str: Type = { kind: TypeKind.String, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
	const params: string[] = ["T"];
	const types1: Type[] = [num];
	const types2: Type[] = [str];
	monoRegister(reg, "identity", params, types1);
	monoRegister(reg, "identity", params, types2);
	assert reg.entries.length === 2;
}

test "findEntry returns null for missing" {
	const reg = createMonoRegistry();
	const keys: string[] = ["number"];
	const result = monoFindEntry(reg, "nonexistent", keys);
	assert result === null;
}
