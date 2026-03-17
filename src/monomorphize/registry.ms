// Monomorphization Registry — tracks generic instantiations, dedup, name mangling
//
// Reference implementation equivalent: generic instantiation cache.
// sameInstantiation() + genericCacheGet() in reference instantiation.

import { Type, TypeKind } from "../ast/node";

// ===== Data Structures =====

// Represents one concrete instantiation key
// Example: identity<number> → { genericName: "identity", typeArgKeys: ["number"] }
export class MonoKey {
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
	return match (t.kind) {
		TypeKind.Number => "number",
		TypeKind.String => "string",
		TypeKind.Boolean => "boolean",
		TypeKind.Void => "void",
		TypeKind.Null => "null",
		TypeKind.Int8 => "int8",
		TypeKind.Int16 => "int16",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint8 => "uint8",
		TypeKind.Uint16 => "uint16",
		TypeKind.Uint32 => "uint32",
		TypeKind.Uint64 => "uint64",
		TypeKind.Float32 => "float32",
		TypeKind.Float64 => "float64",
		TypeKind.Array => `arr_${monoTypeKey(t.typeReturn)}`,
		TypeKind.Ref => `ref_${monoTypeKey(t.typeReturn)}`,
		TypeKind.Ptr => `ptr_${monoTypeKey(t.typeReturn)}`,
		TypeKind.Struct | TypeKind.Enum => t.typeName,
		TypeKind.GenericInstance => {
			let key = t.typeName;
			for (const child of t.typeChildren) {
				key = `${key}_${monoTypeKey(child)}`;
			}
			return key;
		},
		TypeKind.Distinct => `distinct_${monoTypeKey(t.typeReturn)}`,
		TypeKind.Function => {
			let key = "fn";
			for (const child of t.typeChildren) {
				key = `${key}_${monoTypeKey(child)}`;
			}
			return `${key}_ret_${monoTypeKey(t.typeReturn)}`;
		},
		TypeKind.Union => {
			let key = "union";
			for (const child of t.typeChildren) {
				key = `${key}_${monoTypeKey(child)}`;
			}
			return key;
		},
		_ => "unknown",
	};
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
	const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 };
	assert monoTypeKey(num) === "number";
	const str: Type = { kind: TypeKind.String, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 };
	assert monoTypeKey(str) === "string";
	const b: Type = { kind: TypeKind.Boolean, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 };
	assert monoTypeKey(b) === "boolean";
}

test "monoTypeKey array" {
	const numT: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 };
	const arrT: Type = { kind: TypeKind.Array, typeName: "", typeNames: [], typeChildren: [], typeReturn: numT, typeExtra: null, typeFlags: 0 };
	assert monoTypeKey(arrT) === "arr_number";
}

test "monoTypeKey object" {
	const obj: Type = { kind: TypeKind.Struct, typeName: "Box", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 };
	assert monoTypeKey(obj) === "Box";
}

test "mangleMonoName single param" {
	const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 };
	const types: Type[] = [num];
	assert mangleMonoName("identity", types) === "identity__number";
}

test "mangleMonoName two params" {
	const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 };
	const str: Type = { kind: TypeKind.String, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 };
	const types: Type[] = [num, str];
	assert mangleMonoName("pair", types) === "pair__number_string";
}

test "registry dedup" {
	const reg = createMonoRegistry();
	const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 };
	const params: string[] = ["T"];
	const types1: Type[] = [num];
	const entry1 = monoRegister(reg, "identity", params, types1);
	assert entry1.mangledName === "identity__number";
	assert reg.entries.length === 1;

	// Same instantiation → dedup
	const num2: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 };
	const types2: Type[] = [num2];
	const entry2 = monoRegister(reg, "identity", params, types2);
	assert entry2.mangledName === "identity__number";
	assert reg.entries.length === 1;
}

test "registry different types" {
	const reg = createMonoRegistry();
	const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 };
	const str: Type = { kind: TypeKind.String, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 };
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
