// Monomorphization naming — type-argument keys and mangled instance names

import { Type, TypeKind, TypeFlag, SymbolKind } from "../ast/node";
import { makeSymbol } from "../checker/symbol";
import { hashToBase36 } from "std/hash";
import { nominalTypeKey, hasTypeIdentity, isMaybeType, representedPayload, isBrandDistinct, peelTransparentInstance } from "../checker/types";

// Field-name + field-type signature for a nameless struct. Named field types key
// by name and stop, so a cycle (which always passes through a named type in
// surface syntax) cannot recurse forever.
function monoStructuralKey(t: Readonly<Type>): string {
	let key = "";
	for (let i = 0; i < t.typeNames.length; i += 1) {
		if (i > 0) key = key + ",";
		key = key + t.typeNames[i] + ":";
		key = key + (i < t.typeChildren.length ? monoTypeKey(t.typeChildren[i]) : "void");
	}
	return key;
}

function monoOwnerPath(t: Readonly<Type>): string {
	if (t.sym != null) return t.sym.modulePath;
	if (t.typeName == "") return "";
	if (t.kind == TypeKind.Struct && t.typeNames.length > 0 && !hasTypeIdentity(t)) return "";
	nominalTypeKey(t);
	return "";
}

// Declaring module of the generic a GenericInstance instantiates. The instance
// itself carries no symbol (it is built structurally), but its `typeExtra` still
// points at the declared base type, which the collect pass stamped with the
// declaring symbol — the same identity monoOwnerPath reads for a named struct.
function monoGenericOwner(gi: Readonly<Type>): string {
	let base: Readonly<Type | null> = gi.typeExtra;
	let hops = 0;
	while (base != null && hops < 8
			&& (base.kind == TypeKind.Ref || base.kind == TypeKind.Ptr || base.kind == TypeKind.GenericInstance)) {
		base = base.kind == TypeKind.GenericInstance ? base.typeExtra : base.typeReturn;
		hops = hops + 1;
	}
	if (base != null) return monoOwnerPath(base);
	return "";
}

// The BASE of a monomorphized name, qualified by the module that declared the
// generic. Two modules may declare same-named generics, and an instance name is
// the C identity of its struct, its DRC hooks and its TypeInfo — so it has to
// carry the declaring module exactly like a named struct type ARGUMENT already
// does above (`Name_<hash(owner)>`), like a proc name (mangleProcName) and like
// the pending-instance dedup key. An unknown owner (test contexts, builtins
// that are never declared) keeps the bare spelling.
export function monoBaseName(baseName: string, ownerPath: string): string {
	if (baseName == "" || ownerPath == "") return baseName;
	return baseName + "_" + hashToBase36(ownerPath);
}

export function monoRoutineBaseName(baseName: string, ownerPath: string, disamb: int32): string {
	const qualified = monoBaseName(baseName, ownerPath);
	if (disamb <= 0) return qualified;
	return qualified + "_u" + disamb.toString();
}

// One spelling of "the name of this generic instance", shared by checker,
// analyzer, transform and codegen so the struct, its hooks and every call site
// cannot drift apart.
export function monoInstanceName(gi: Readonly<Type>): string {
	return monoInstanceNameOf(gi.typeName, monoGenericOwner(gi), gi.typeChildren);
}

export function monoInstanceNameOf(genericName: string, ownerPath: string, typeArgs: Readonly<Type[]>): string {
	return mangleMonoName(monoBaseName(genericName, ownerPath), typeArgs);
}

// Output spelling only; checked type arguments decide instance identity.
export function monoTypeKey(t: Readonly<Type | null>): string {
	if (t == null) return "null";
	const key = monoTypeKeyBody(t);
	return t.typeFlags.has(TypeFlag.IsReadonly) ? "ro_" + key : key;
}

function monoDeclaredName(t: Readonly<Type>): string {
	const disamb = t.sym != null ? t.sym.disamb : 0;
	return disamb == 0 ? t.typeName : t.typeName + "_u" + String(disamb);
}

function monoTypeKeyBody(t: Readonly<Type>): string {
	return match (t.kind) {
		TypeKind.Number => "float64",
		TypeKind.String => "string",
		TypeKind.Boolean => "boolean",
		TypeKind.Void => "void",
		TypeKind.Null => "null",
		TypeKind.Int8 => "int8",
		TypeKind.Int16 => "int16",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => t.sym != null && t.sym.symbolKind == SymbolKind.Actor ? monoTypeKey(t.sym.symbolType) : "int64",
		TypeKind.Uint8 => "uint8",
		TypeKind.Uint16 => "uint16",
		TypeKind.Uint32 => "uint32",
		TypeKind.Uint64 => "uint64",
		TypeKind.Float32 => "float32",
		TypeKind.Float64 => "float64",
		TypeKind.Char => "char",
		TypeKind.CString => "cstring",
		TypeKind.Array => "arr_" + monoTypeKey(t.typeReturn),
		TypeKind.Ref => "ref_" + monoTypeKey(t.typeReturn),
		TypeKind.Ptr => "ptr_" + monoTypeKey(t.typeReturn),
		TypeKind.EnumLiteral => "k" + (t.kind as number).toString() + "_" + monoTypeKey(t.typeReturn) + "_" + (t.typeNames.length > 0 ? t.typeNames[0] : ""),
		TypeKind.Struct | TypeKind.Enum => {
			if (t.typeName == "") return "anon" + hashToBase36(monoStructuralKey(t));
			if (isMaybeType(t) && t.typeReturn != null && representedPayload(t.typeReturn) != t.typeReturn) return "Maybe_" + monoTypeKey(t.typeReturn);
			if (t.typeFlags.has(TypeFlag.DuVariant)) return t.typeName + "_" + hashToBase36(nominalTypeKey(t));
			const owner = monoOwnerPath(t);
			const name = monoDeclaredName(t);
			if (owner != "") return name + "_" + hashToBase36(owner);
			return name;
		},
		TypeKind.GenericInstance => {
			const seen = peelTransparentInstance(t);
			if (seen != t) return monoTypeKey(seen);
			let key = monoBaseName(t.typeName, monoGenericOwner(t));
			let i = 0;
			while (i < t.typeChildren.length) {
				key = key + "_" + monoTypeKey(t.typeChildren[i]);
				i = i + 1;
			}
			return key;
		},
		TypeKind.Alias => {
			if (t.typeReturn == null) throw new Error("internal: alias '" + t.typeName + "' has no target in monoTypeKey");
			return monoTypeKey(t.typeReturn);
		},
		TypeKind.SizedArray => "sizedArr_" + t.typeValue.toString() + "_" + monoTypeKey(t.typeReturn),
		TypeKind.Span => "span_" + monoTypeKey(t.typeReturn),
		TypeKind.Set => "set_" + monoTypeKey(t.typeReturn),
		TypeKind.Var => "var_" + monoTypeKey(t.typeReturn),
		TypeKind.Borrow => "borrow_" + monoTypeKey(t.typeReturn),
		TypeKind.Distinct => {
			if (isBrandDistinct(t)) return "brand_" + monoTypeKey(t.typeReturn) + "_" + hashToBase36(t.typeName);
			if (t.typeName == "") return "distinct_" + monoTypeKey(t.typeReturn);
			const owner = monoOwnerPath(t);
			const name = monoDeclaredName(t);
			if (owner != "") return "distinct_" + name + "_" + hashToBase36(owner);
			return "distinct_" + name;
		},
		TypeKind.Function => {
			let key = "fn";
			for (const child of t.typeChildren) {
				key = key + "_" + monoTypeKey(child);
			}
			return key + "_r_" + monoTypeKey(t.typeReturn);
		},
		TypeKind.Union => {
			if (t.typeName != "") {
				const owner = monoOwnerPath(t);
				const name = monoDeclaredName(t);
				if (owner != "") return name + "_" + hashToBase36(owner);
				return name;
			}
			let key = "union";
			for (const child of t.typeChildren) {
				key = key + "_" + monoTypeKey(child);
			}
			return key;
		},
		TypeKind.Tuple => {
			let key = "tuple";
			for (const child of t.typeChildren) {
				key = key + "_" + monoTypeKey(child);
			}
			return key;
		},
		// Keep output spelling total for the remaining concrete type kinds.
		_ => {
			let key = "k" + (t.kind as number).toString();
			if (t.typeName != "") key = key + "_" + hashToBase36(t.typeName);
			if (t.typeReturn != null) key = key + "_" + monoTypeKey(t.typeReturn);
			for (const child of t.typeChildren) key = key + "_" + monoTypeKey(child);
			return key;
		},
	};
}

// ===== Name Mangling =====

// identity<number>     → "identity__number"
// pair<number, string> → "pair__number_string"
export function mangleMonoName(baseName: string, concreteTypes: Readonly<Type[]>): string {
	return baseName + "__" + buildTypeArgKeys(concreteTypes).join("_");
}

// Build typeArgKeys from concrete types
export function buildTypeArgKeys(concreteTypes: Readonly<Type[]>): string[] {
	const keys: string[] = [];
	for (let i = 0; i < concreteTypes.length; i += 1) {
		keys.push(monoTypeKey(concreteTypes[i]));
	}
	return keys;
}

// ===== Tests =====
function declaredAt(t: Type, kind: SymbolKind, modulePath: string): Type {
	const sym = makeSymbol(t.typeName, kind, t, false);
	sym.modulePath = modulePath;
	t.sym = sym;
	return t;
}

test "monoTypeKey primitives" {
	const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	assert monoTypeKey(num) == "float64";
	const str: Type = { kind: TypeKind.String, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	assert monoTypeKey(str) == "string";
	const b: Type = { kind: TypeKind.Boolean, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	assert monoTypeKey(b) == "boolean";
}

test "monoTypeKey array" {
	const numT: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const arrT: Type = { kind: TypeKind.Array, typeName: "", typeNames: [], typeChildren: [], typeReturn: numT, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	assert monoTypeKey(arrT) == "arr_float64";
}

test "monoTypeKey object" {
	const obj = declaredAt({ kind: TypeKind.Struct, typeName: "Box", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] }, SymbolKind.Struct, "/p/box.ms");
	assert monoTypeKey(obj) == "Box_" + hashToBase36("/p/box.ms");
}

test "a generic instance over an unnamed base type has no owner to name" {
	const elem: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const base: Type = { kind: TypeKind.Array, typeName: "", typeNames: [], typeChildren: [], typeReturn: elem, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const instance: Type = { kind: TypeKind.GenericInstance, typeName: "", typeNames: [], typeChildren: [elem], typeReturn: null, typeExtra: base, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	assert monoTypeKey(instance) != "";
}

test "monoTypeKey refuses a declared-looking name that has no symbol" {
	const orphan: Type = { kind: TypeKind.Struct, typeName: "Box", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	let refused = "";
	try {
		monoTypeKey(orphan);
	} catch (e) {
		refused = e.message;
	}
	assert refused.contains("Box");
}

test "mangleMonoName single param" {
	const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const types: Type[] = [num];
	assert mangleMonoName("identity", types) == "identity__float64";
}

test "mangleMonoName two params" {
	const num: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const str: Type = { kind: TypeKind.String, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const types: Type[] = [num, str];
	assert mangleMonoName("pair", types) == "pair__float64_string";
}

test "monoTypeKey anonymous structs key apart" {
	const str: Type = { kind: TypeKind.String, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const named: Type = { kind: TypeKind.Struct, typeName: "", typeNames: ["name"], typeChildren: [str], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const tagged: Type = { kind: TypeKind.Struct, typeName: "", typeNames: ["tag"], typeChildren: [str], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	assert monoTypeKey(named) != monoTypeKey(tagged);
	assert monoTypeKey(named) != "";
}

test "monoTypeKey unhandled kinds key apart" {
	const never: Type = { kind: TypeKind.Never, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const unknown: Type = { kind: TypeKind.Unknown, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	assert monoTypeKey(never) != monoTypeKey(unknown);
	assert monoTypeKey(never) != "unknown";
}

test "monoTypeKey keys distinct types by identity" {
	const f64: Type = { kind: TypeKind.Float64, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const meters = declaredAt({ kind: TypeKind.Distinct, typeName: "Meters", typeNames: [], typeChildren: [], typeReturn: f64, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] }, SymbolKind.TypeAlias, "/p/m.ms");
	const seconds = declaredAt({ kind: TypeKind.Distinct, typeName: "Seconds", typeNames: [], typeChildren: [], typeReturn: f64, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] }, SymbolKind.TypeAlias, "/p/m.ms");
	assert monoTypeKey(meters) != monoTypeKey(seconds);
	const metersA: Type = { kind: TypeKind.Distinct, typeName: "Meters", typeNames: [], typeChildren: [], typeReturn: f64, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const metersB: Type = { kind: TypeKind.Distinct, typeName: "Meters", typeNames: [], typeChildren: [], typeReturn: f64, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const symA = makeSymbol("Meters", SymbolKind.TypeAlias, metersA, false);
	symA.modulePath = "/p/a.ms";
	metersA.sym = symA;
	const symB = makeSymbol("Meters", SymbolKind.TypeAlias, metersB, false);
	symB.modulePath = "/p/b.ms";
	metersB.sym = symB;
	assert monoTypeKey(metersA) != monoTypeKey(metersB);
	const anon: Type = { kind: TypeKind.Distinct, typeName: "", typeNames: [], typeChildren: [], typeReturn: f64, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	assert monoTypeKey(anon) == "distinct_float64";
}

test "mangleMonoName separates instantiations over distinct types" {
	const f64: Type = { kind: TypeKind.Float64, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const meters = declaredAt({ kind: TypeKind.Distinct, typeName: "Meters", typeNames: [], typeChildren: [], typeReturn: f64, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] }, SymbolKind.TypeAlias, "/p/m.ms");
	const seconds = declaredAt({ kind: TypeKind.Distinct, typeName: "Seconds", typeNames: [], typeChildren: [], typeReturn: f64, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] }, SymbolKind.TypeAlias, "/p/m.ms");
	assert mangleMonoName("show", [meters]) != mangleMonoName("show", [seconds]);
}

test "monoRoutineBaseName keys a generic routine by owner and ordinal" {
	assert monoRoutineBaseName("wrap", "/p/a.ms", 0) != monoRoutineBaseName("wrap", "/p/b.ms", 0);
	assert monoRoutineBaseName("put", "/p/a.ms", 0) != monoRoutineBaseName("put", "/p/a.ms", 1);
	assert monoRoutineBaseName("put", "/p/a.ms", 0) == monoBaseName("put", "/p/a.ms");
	assert monoRoutineBaseName("put", "", 0) == "put";
}

test "monoTypeKey keys named unions by owner" {
	const i32: Type = { kind: TypeKind.Int32, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const str: Type = { kind: TypeKind.String, typeName: "", typeNames: [], typeChildren: [], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const ua: Type = { kind: TypeKind.Union, typeName: "U", typeNames: [], typeChildren: [i32, str], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const ub: Type = { kind: TypeKind.Union, typeName: "U", typeNames: [], typeChildren: [i32, str], typeReturn: null, typeExtra: null, typeFlags: 0 as BitSet<TypeFlag>, attachedOps: [] };
	const symA = makeSymbol("U", SymbolKind.TypeAlias, ua, false);
	symA.modulePath = "/p/a.ms";
	ua.sym = symA;
	const symB = makeSymbol("U", SymbolKind.TypeAlias, ub, false);
	symB.modulePath = "/p/b.ms";
	ub.sym = symB;
	assert monoTypeKey(ua) != monoTypeKey(ub);
	assert mangleMonoName("id", [ua]) != mangleMonoName("id", [ub]);
}
