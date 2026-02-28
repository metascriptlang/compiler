// Monomorphization Registry — tracks generic instantiations, dedup, name mangling
//
// Nim equivalent: procInstCache/typeInstCache in modulegraphs.nim,
// sameInstantiation() + genericCacheGet() in seminst.nim.

import { Type, TypeKind } from "../checker/types";
import { test, check, testGroup } from "std/testing";

// ===== Data Structures =====

// Represents one concrete instantiation key
// Example: identity<number> → { genericName: "identity", typeArgKeys: ["number"] }
export interface MonoKey {
	genericName: string;
	typeArgKeys: string[];   // DRC-safe: string[] wrapped in interface
}

// Tracks one instantiation entry
export interface MonoEntry {
	mangledName: string;         // e.g., "identity__number"
	genericName: string;         // original name
	genericParamNames: string[]; // ["T", "U"]
	concreteTypes: Type[];       // [numberType(), stringType()]
	isInstantiated: boolean;     // true after Pass 2 clones the body
}

// Wraps MonoEntry[] for DRC-safe mutation propagation (gotcha #4)
export interface MonoEntryList {
	items: MonoEntry[];
}

// The registry itself
export interface MonoRegistry {
	entries: MonoEntryList;
}

// ===== Constructors =====

export function createMonoRegistry(): MonoRegistry {
	const entries: MonoEntry[] = [];
	const list: MonoEntryList = { items: entries };
	return { entries: list };
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
	if (t.kind === TypeKind.Int32) return "int32";
	if (t.kind === TypeKind.Int64) return "int64";
	if (t.kind === TypeKind.Uint32) return "uint32";
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

// Compare two type arg key arrays for exact match (Nim: sameInstantiation)
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
// Returns the entry or null (Nim: genericCacheGet)
export function monoFindEntry(registry: MonoRegistry, genericName: string, typeArgKeys: string[]): MonoEntry {
	for (let i = 0; i < registry.entries.items.length; i += 1) {
		const entry = registry.entries.items[i];
		if (entry.genericName === genericName && sameTypeArgKeys(typeArgKeys, buildTypeArgKeys(entry.concreteTypes))) {
			return entry;
		}
	}
	return null as unknown as MonoEntry;
}

// Register a new instantiation. Returns the entry (existing if duplicate, new if not).
// Nim: addToGenericProcCache + TInstantiation creation
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
	registry.entries.items.push(entry);
	return entry;
}

// ===== Tests =====

testGroup("MonoRegistry", () => {
	test("monoTypeKey primitives", () => {
		const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
		check(monoTypeKey(num) === "number");
		const str: Type = { kind: TypeKind.String, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
		check(monoTypeKey(str) === "string");
		const b: Type = { kind: TypeKind.Boolean, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
		check(monoTypeKey(b) === "boolean");
	});

	test("monoTypeKey array", () => {
		const numT: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
		const arrT: Type = { kind: TypeKind.Array, typeName: "", typeNames: [], typeChildren: [], typeReturn: numT, typeExtra: null as unknown as Type, typeFlags: 0 };
		check(monoTypeKey(arrT) === "arr_number");
	});

	test("monoTypeKey object", () => {
		const obj: Type = { kind: TypeKind.Object, typeName: "Box", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
		check(monoTypeKey(obj) === "Box");
	});

	test("mangleMonoName single param", () => {
		const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
		const types: Type[] = [num];
		check(mangleMonoName("identity", types) === "identity__number");
	});

	test("mangleMonoName two params", () => {
		const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
		const str: Type = { kind: TypeKind.String, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
		const types: Type[] = [num, str];
		check(mangleMonoName("pair", types) === "pair__number_string");
	});

	test("registry dedup", () => {
		const reg = createMonoRegistry();
		const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
		const params: string[] = ["T"];
		const types1: Type[] = [num];
		const entry1 = monoRegister(reg, "identity", params, types1);
		check(entry1.mangledName === "identity__number");
		check(reg.entries.items.length === 1);

		// Same instantiation → dedup
		const num2: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
		const types2: Type[] = [num2];
		const entry2 = monoRegister(reg, "identity", params, types2);
		check(entry2.mangledName === "identity__number");
		check(reg.entries.items.length === 1);
	});

	test("registry different types", () => {
		const reg = createMonoRegistry();
		const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
		const str: Type = { kind: TypeKind.String, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null as unknown as Type, typeFlags: 0 };
		const params: string[] = ["T"];
		const types1: Type[] = [num];
		const types2: Type[] = [str];
		monoRegister(reg, "identity", params, types1);
		monoRegister(reg, "identity", params, types2);
		check(reg.entries.items.length === 2);
	});

	test("findEntry returns null for missing", () => {
		const reg = createMonoRegistry();
		const keys: string[] = ["number"];
		const result = monoFindEntry(reg, "nonexistent", keys);
		check(result === null);
	});
});
