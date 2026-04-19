// Type System — utility functions for Type manipulation
// Type class + enums are defined in ast/node.ms (reference parity: single-file AST).

import { bareAfterDelim, splitTopLevel } from "../utils/string";
import { hashToBase36 as _stdHashToBase36 } from "std/hash";
import { Type, TypeKind, TypeFlag, CallingConvention, AttachedOp } from "../ast/node";

// =====================================================================
// Type Storage Schema — what each Type field means per TypeKind
// =====================================================================
// The Type struct is intentionally flat (one shape, all fields present).
// Field meaning is TypeKind-dependent. This schema is the single source
// of truth for storage access. **Do not bypass it.**
//
//   kind           — the TypeKind enum value
//   typeName       — nominal name (e.g. "Promise", "Result", struct name)
//   typeNames      — field/variant names (Struct fields, Union variants, Result ["ok","value","error"])
//   typeChildren   — type args, field types, variant types, parameter types
//   typeReturn     — function return type; alias target; alternate uninstantiated body
//   typeExtra      — second companion slot (DiscriminatedUnion enum, Result's err for GI)
//   typeFlags      — bitset of TypeFlag (IsStruct, HasAsgn, AwaitableAffine, AwaitableScopeBound, ...)
//
// ----- Awaitable types (Promise, @awaitable-annotated) -----
// Represented as: kind = GenericInstance, typeName = "Promise" | <user>,
//                 typeChildren[0] = inner T.
// All awaitables share a single surface type: `Promise<T>`. Origin is tracked
// on `typeFlags` via AwaitableAffine + AwaitableScopeBound bits (set by spawn
// and @affineAwaitable decorators). Semantic queries (isAwaitable,
// isAffineAwaitable) abstract over both representations.
//
// **DO NOT READ `.typeReturn` for awaitable unwrap.** Use `awaitedType(t)`.
// **DO NOT index `.typeChildren[0]` for awaitable unwrap.** Use `awaitedType(t)`.
// **DO NOT check `.typeName` for affine rules.** Use `isAffineAwaitable(t)`.
//
// The semantic query layer below (`peelThrough`, `isAwaitable`, `awaitedType`,
// `isAffineAwaitable`) is the ONLY supported interface. Adding a new
// awaitable-related question? Add a function here; never peek at storage from
// outside this file.
//
// ----- Other notable TypeKinds -----
//   Alias          — typeName = alias name, typeReturn = aliased target
//   Distinct       — typeName = distinct name, typeChildren[0] = base type
//   GenericInstance— typeName = base name, typeChildren = type args, typeReturn = instantiated body
//   Function       — typeChildren = param types, typeReturn = return type, typeNames = param names
//   Struct         — typeName = struct name, typeNames = field names, typeChildren = field types
//   Union          — typeChildren = variant types, typeNames[0] = discriminant (if DU)
//   Result         — typeChildren = [ok, err] (GI form also), typeReturn/typeExtra = ok/err fallbacks
//   Ref/Ptr/Borrow — typeReturn = referent type
//   Array/Span     — typeReturn = element type
//   SizedArray     — typeReturn = element, typeFlags upper bits = size
//
// =====================================================================

// ===== Target Configuration (Implementation parity) =====
// Module-level state set once at startup. Defaults to 64-bit.

let targetPtrSize: number = 8;
let targetIntSize: number = 8;

export function setTargetSizes(ptrSize: number, intSize: number): void {
	targetPtrSize = ptrSize;
	targetIntSize = intSize;
}

export function getTargetPtrSize(): number { return targetPtrSize; }
export function getTargetIntSize(): number { return targetIntSize; }


// ===== In-Place Type Upgrade (reference parity: assignType) =====
// Copies all fields from source into target, preserving target's object identity.
// This is critical for circular type resolution: forward placeholder objects are
// upgraded in-place so all existing references automatically see the resolved type.
// Reference: reference statement processing assignType(s.typ, t) — same pattern.

export function assignType(target: Type, source: Type): void {
	target.kind = source.kind;
	target.typeName = source.typeName;
	target.typeNames = source.typeNames;
	target.typeChildren = source.typeChildren;
	target.typeReturn = source.typeReturn;
	target.typeExtra = source.typeExtra;
	target.typeFlags = source.typeFlags;
	target.callConv = source.callConv;
	target.attachedOps = source.attachedOps;
}

// ===== Constructors =====

export function emptyType(): Type {
	return {
		kind: TypeKind.Unknown,
		typeName: "",
		typeNames: [],
		typeChildren: [],
		typeReturn: null,
		typeExtra: null,
		typeFlags: 0,
		callConv: CallingConvention.CcDefault,
		attachedOps: [],
	};
}

export function createPrimitive(kind: TypeKind): Type {
	const t = emptyType();
	t.kind = kind;
	return t;
}

export function createStruct(name: string, propNames: string[], propTypes: Type[], isInterface: boolean): Type {
	const t = emptyType();
	t.kind = TypeKind.Struct;
	t.typeName = name;
	t.typeNames = propNames;
	t.typeChildren = propTypes;
	if (isInterface) { t.typeFlags = TypeFlag.IsStruct as int32; }
	// Propagate HasAsgn from any managed field (Reference parity: bottom-up flag propagation)
	for (const pt of propTypes) { propagateToOwner(t, pt); }
	return t;
}

// Generate a deterministic name for an anonymous struct from its field names and types.
// Format: __anon<count>__<field1><suffix>__<field2><suffix>
// Count prefix + double-underscore separators prevent collisions between
// { x_y: 1 } (__anon1__x_yn) and { x: 1, y: 2 } (__anon2__xn__yn).
// Type suffix prevents same-name different-type collisions.
export function anonStructName(fieldNames: string[], fieldTypes: Type[]): string {
	if (fieldNames.length === 0) return "";
	let name = "__anon" + fieldNames.length;
	let i = 0;
	while (i < fieldNames.length) {
		const ft = i < fieldTypes.length ? fieldTypes[i] : null;
		let suffix = "x";
		if (ft !== null) {
			suffix = match (ft.kind) {
				TypeKind.Number | TypeKind.Float64 => "n",
				TypeKind.Float32 => "f",
				TypeKind.String => "s",
				TypeKind.Boolean => "b",
				TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 => "i",
				TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => "u",
				TypeKind.Array => {
					// Distinguish array element types to avoid struct name collision
					// (e.g., string[] field vs unknown[] field producing the same anon struct name)
					if (ft.typeReturn !== null) {
						return match (ft.typeReturn.kind) {
							TypeKind.String => "As",
							TypeKind.Number | TypeKind.Float64 => "An",
							TypeKind.Boolean => "Ab",
							_ => "x",
						};
					} else {
						return "x";
					}
				},
				_ => "x",
			};
		}
		name = name + "__" + fieldNames[i] + suffix;
		i = i + 1;
	}
	return name;
}

export function createArray(element: Type): Type {
	return {
		kind: TypeKind.Array, typeName: "", typeNames: [], typeChildren: [],
		typeReturn: element, typeExtra: null, typeFlags: TypeFlag.HasAsgn as int32,
		callConv: CallingConvention.CcDefault, attachedOps: [],
	};
}

export function createSizedArray(element: Type, size: number): Type {
	const t = emptyType();
	t.kind = TypeKind.SizedArray;
	t.typeReturn = element;
	t.typeFlags = size;
	return t;
}

export function createSpan(element: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Span;
	t.typeReturn = element;
	return t;
}

export function createFunction(paramTypes: Type[], paramNames: string[], returnType: Type): Type {
	return {
		kind: TypeKind.Function, typeName: "", typeNames: paramNames, typeChildren: paramTypes,
		typeReturn: returnType, typeExtra: null, typeFlags: TypeFlag.HasAsgn as int32,
		callConv: CallingConvention.CcDefault, attachedOps: [],
	};
}

// Standard reference parity: procedure type literals default to closure calling convention.
// Named function declarations use createFunction which defaults to the default calling convention.
export function createClosureType(paramTypes: Type[], paramNames: string[], returnType: Type): Type {
	const t = createFunction(paramTypes, paramNames, returnType);
	t.callConv = CallingConvention.CcClosure;
	return t;
}

export function createEnum(name: string, members: string[], values: number[]): Type {
	const t = emptyType();
	t.kind = TypeKind.Enum;
	t.typeName = name;
	t.typeNames = members;
	// Store enum member values as Type objects with typeFlags holding the integer value
	if (values !== null && values.length > 0) {
		const valTypes: Type[] = [];
		let i = 0;
		while (i < values.length) {
			const vt = emptyType();
			vt.kind = TypeKind.Number;
			vt.typeFlags = values[i] as int32;
			valTypes.push(vt);
			i = i + 1;
		}
		t.typeChildren = valTypes;
	}
	return t;
}


export function createResult(okType: Type, errType: Type): Type {
	const base = emptyType();
	base.kind = TypeKind.Struct;
	base.typeName = "Result";
	base.typeNames = ["ok", "value", "error"];
	base.typeChildren = [createPrimitive(TypeKind.Boolean), okType, errType];
	base.typeFlags = TypeFlag.HasAsgn as int32;
	return createGenericInstance(base, [okType, errType]);
}

export function createPromise(innerType: Type): Type {
	const base = emptyType();
	base.kind = TypeKind.Struct;
	base.typeName = "Promise";
	base.typeNames = [];
	base.typeChildren = [];
	return createGenericInstance(base, [innerType]);
}

// Affine, scope-bound `Promise<T>` produced by `spawn(...)`. Surface type is
// plain `Promise<T>` — developers never learn a second name. The affine and
// scope-bound semantics ride entirely on typeFlags (AwaitableAffine +
// AwaitableScopeBound), propagated through createGenericInstance onto every
// instance. PARALOCK R1-R6 rules read these via isAffineAwaitable; compat.ms
// implements the implicit upcast to a plain Promise (strips the flags).
export function createSpawnHandle(innerType: Type): Type {
	const base = emptyType();
	base.kind = TypeKind.Struct;
	base.typeName = "Promise";
	base.typeNames = [];
	base.typeChildren = [];
	// Flag bits = source of truth for affine + scope-bound semantics.
	// createGenericInstance propagates base.typeFlags onto the produced
	// GenericInstance so isAffineAwaitable(t) can detect spawn-origin Promises
	// anywhere they flow.
	base.typeFlags = (TypeFlag.AwaitableAffine | TypeFlag.AwaitableScopeBound) as int32;
	return createGenericInstance(base, [innerType]);
}

// Iterator<T> — return type of function* generators. Wraps yield type T.
// At runtime: { next: () => { value: T, done: boolean } }
export function createIterator(yieldType: Type): Type {
	// Build IteratorResult<T> struct: { value: T, done: boolean }
	const resultType = createStruct("IteratorResult", ["value", "done"], [yieldType, createPrimitive(TypeKind.Boolean)], false);
	// Build Iterator<T> struct: { next: () => IteratorResult<T> }
	const nextFnType = createFunction([], [], resultType);
	const iter = createStruct("Iterator", ["next"], [nextFnType], false);
	return iter;
}

export function isIterator(t: Type): boolean {
	if (t === null) return false;
	return t.typeName === "Iterator";
}

export function getIteratorNextFnType(t: Type): Type {
	if (t === null || !isIterator(t)) return null;
	if (t.typeChildren !== null && t.typeChildren.length > 0) return t.typeChildren[0];
	return null;
}

export function getIteratorYieldType(t: Type): Type {
	if (t === null) return null;
	// Iterator struct has field "next: () => IteratorResult<T>"
	// IteratorResult has field "value: T" — extract T from there
	if (t.typeChildren !== null && t.typeChildren.length > 0) {
		const nextFnType = t.typeChildren[0]; // the next() function type
		if (nextFnType !== null && nextFnType.typeReturn !== null) {
			const resultType = nextFnType.typeReturn; // IteratorResult<T>
			if (resultType.typeChildren !== null && resultType.typeChildren.length > 0) {
				return resultType.typeChildren[0]; // T (the value field)
			}
		}
	}
	return unknownType();
}

export function isResult(t: Type): boolean {
	if (t === null) return false;
	if (t.kind === TypeKind.Result) return true;
	return t.kind === TypeKind.GenericInstance && t.typeName === "Result";
}

export function getResultOkType(t: Type): Type {
	if (t === null) return null;
	if (t.kind === TypeKind.GenericInstance && t.typeChildren.length > 0) return t.typeChildren[0];
	return t.typeReturn;
}

export function getResultErrType(t: Type): Type {
	if (t === null) return null;
	if (t.kind === TypeKind.GenericInstance && t.typeChildren.length > 1) return t.typeChildren[1];
	return t.typeExtra;
}

// =====================================================================
// REPROMISE T1 — Semantic query layer for awaitable types
// =====================================================================
// Single gateway for every question about `Promise<T>` and
// @awaitable-annotated types. Callers never peek at raw storage.
//
// Key design points:
//   - `peelThrough` handles Alias/Distinct wrappers but NOT GenericInstance
//     (for awaitable shape queries, GenericInstance IS the answer).
//   - Surface is a single type name: "Promise". Origin (plain async vs
//     spawn-affine) is distinguished by AwaitableAffine + AwaitableScopeBound
//     flag bits on `typeFlags`.
//   - Future @awaitable-annotated types from stdlib plug in via the registry
//     (T2.6 — currently a stub awaiting collect-pass wiring).
// =====================================================================

// PeelFlag — bitmask controlling which Type wrappers `peelThrough` unwraps.
// Matches the reference `skipTypes` peel mask semantics.
export enum PeelFlag {
	Alias = 1,       // bit 0 — peel TypeKind.Alias
	Distinct = 2,    // bit 1 — peel TypeKind.Distinct
}

export const PEEL_ALIAS: int32 = 1;
export const PEEL_DISTINCT: int32 = 2;
export const PEEL_ALL: int32 = 3;

// Universal peeler: strip transparent wrappers per the mask.
// Does NOT peel GenericInstance — for shape queries, GenericInstance IS the answer
// (e.g. Promise<T> is a GenericInstance we want to inspect, not peel past).
// Returns the input unchanged if no layer matches the mask.
export function peelThrough(t: Type, mask: int32): Type {
	if (t === null) return null;
	let cur = t;
	// Fixed-point loop — keep peeling until no layer matches the mask.
	while (true) {
		let next: Type = cur;
		if (cur.kind === TypeKind.Alias && (mask & PEEL_ALIAS) !== 0
			&& cur.typeReturn !== null) {
			next = cur.typeReturn;
		} else if (cur.kind === TypeKind.Distinct && (mask & PEEL_DISTINCT) !== 0
			&& cur.typeChildren !== null && cur.typeChildren.length > 0
			&& cur.typeChildren[0] !== null) {
			next = cur.typeChildren[0];
		}
		if (next === cur) return cur;
		cur = next;
	}
}

// isAwaitable — the canonical "can we await this?" question.
// Returns true for `Promise<T>` (plain or affine) and @awaitable-annotated types
// (detected by the AwaitableAffine flag bit set by `createGenericInstance`).
// Peels through Alias wrappers so `type P = Promise<int>; P` still answers true.
export function isAwaitable(t: Type): boolean {
	if (t === null) return false;
	const p = peelThrough(t, PEEL_ALIAS);
	if (p === null || p.kind !== TypeKind.GenericInstance) return false;
	if (p.typeName === "Promise") return true;
	// REPROMISE T2 Stage A: @affineAwaitable-annotated types carry both bits.
	if ((p.typeFlags & (TypeFlag.AwaitableAffine as int32)) !== 0) return true;
	return false;
}

// awaitedType — the T inside an Awaitable<T>. Returns null for non-awaitables
// or shape-degenerate awaitables (e.g. typeChildren empty).
export function awaitedType(t: Type): Type {
	if (t === null) return null;
	const p = peelThrough(t, PEEL_ALIAS);
	if (!isAwaitable(p)) return null;
	if (p.typeChildren !== null && p.typeChildren.length > 0) return p.typeChildren[0];
	// Fallback for edge cases where a stub awaitable has no type arg recorded yet.
	return p.typeReturn;
}

// isAffineAwaitable — an awaitable carrying affine consumption semantics
// (spawn-origin Promises, @affineAwaitable types). Reads the flag bit set by T2.
// Used by PARALOCK R1-R6 affine checker rules.
export function isAffineAwaitable(t: Type): boolean {
	if (t === null) return false;
	const p = peelThrough(t, PEEL_ALIAS);
	if (p === null) return false;
	return (p.typeFlags & (TypeFlag.AwaitableAffine as int32)) !== 0;
}

export function createTypeRef(name: string): Type {
	const t = emptyType();
	t.kind = TypeKind.TypeReference;
	t.typeName = name;
	return t;
}

export function createUnion(types: Type[]): Type {
	const t = emptyType();
	t.kind = TypeKind.Union;
	t.typeChildren = types;
	for (const ut of types) { propagateToOwner(t, ut); }
	return t;
}

// Find which union variant contains ALL the given field names (and optionally types).
// When fieldTypes is non-empty, also checks type kind to disambiguate variants with
// same field names but different types (e.g., { value: number } vs { value: string }).
// Returns the variant index, or -1 if no variant matches.
export function findUnionVariant(unionType: Type, fieldNames: string[], fieldTypes: Type[]): number {
	if (unionType.typeChildren === null || fieldNames.length === 0) return -1;
	let vi = 0;
	while (vi < unionType.typeChildren.length) {
		const variant = unionType.typeChildren[vi];
		if (variant !== null && variant.typeNames !== null && variant.typeNames.length >= fieldNames.length) {
			let allFound = true;
			let ti = 0;
			while (ti < fieldNames.length) {
				let found = false;
				let fi = 0;
				while (fi < variant.typeNames.length) {
					if (variant.typeNames[fi] === fieldNames[ti]) {
						// When fieldTypes provided, match by type compatibility to disambiguate
						// variants with same field names but different types.
						// Reference parity: subtype check, not exact equality.
						if (fieldTypes.length > ti && fi < variant.typeChildren.length) {
							if (typesCompatibleForVariant(variant.typeChildren[fi], fieldTypes[ti])) {
								found = true;
							}
						} else {
							found = true;
						}
						fi = variant.typeNames.length;
					}
					fi = fi + 1;
				}
				if (!found) {
					allFound = false;
					ti = fieldNames.length;
				}
				ti = ti + 1;
			}
			if (allFound) return vi;
		}
		vi = vi + 1;
	}
	return -1;
}

// Compatible type matching for union variant field disambiguation.
// Reference parity: subtype checking for object fields.
// We check type-class compatibility: all numerics match, all strings match,
// all ref/ptr types match, exact kind for everything else.
function typesCompatibleForVariant(formal: Type, actual: Type): boolean {
	if (formal === null || actual === null) return false;
	if (formal.kind === actual.kind) return true;
	// Numeric family: number, int8-int64, uint8-uint64, float32, float64
	if (isNumeric(formal) && isNumeric(actual)) return true;
	// Reference family: Ref, Ptr, Borrow all compatible
	if ((formal.kind === TypeKind.Ref || formal.kind === TypeKind.Ptr || formal.kind === TypeKind.Borrow)
		&& (actual.kind === TypeKind.Ref || actual.kind === TypeKind.Ptr || actual.kind === TypeKind.Borrow)) return true;
	return false;
}

// Check if a name-only matched variant is ambiguous (another variant has the same field names).
// When ambiguous, we need property types to disambiguate (e.g. { value: number } vs { value: string }).
export function isAmbiguousVariant(unionType: Type, matchedIdx: number, fieldNames: string[]): boolean {
	if (unionType.typeChildren === null) return false;
	let vi = 0;
	while (vi < unionType.typeChildren.length) {
		if (vi !== matchedIdx) {
			const variant = unionType.typeChildren[vi];
			if (variant !== null && variant.typeNames !== null && variant.typeNames.length >= fieldNames.length) {
				let allFound = true;
				let ti = 0;
				while (ti < fieldNames.length) {
					let found = false;
					let fi = 0;
					while (fi < variant.typeNames.length) {
						if (variant.typeNames[fi] === fieldNames[ti]) { found = true; fi = variant.typeNames.length; }
						fi = fi + 1;
					}
					if (!found) { allFound = false; ti = fieldNames.length; }
					ti = ti + 1;
				}
				if (allFound) return true;
			}
		}
		vi = vi + 1;
	}
	return false;
}

// Find a field's type within a single variant struct. Returns null if not found.
export function findFieldInVariant(variant: Type, fieldName: string): Type {
	if (variant === null || variant.typeNames === null) return null;
	let i = 0;
	while (i < variant.typeNames.length) {
		if (variant.typeNames[i] === fieldName && i < variant.typeChildren.length) {
			return variant.typeChildren[i];
		}
		i = i + 1;
	}
	return null;
}

// Check if a union type is a discriminated union (has discriminant metadata).
// Discriminated unions have typeExtra (enum type) and typeNames[0] (discriminant field name).
export function isDiscriminatedUnion(t: Type): boolean {
	return t.kind === TypeKind.Union && t.typeExtra !== null && t.typeNames !== null && t.typeNames.length > 0;
}

// Get the discriminant field name from a discriminated union.
export function getDiscriminantName(t: Type): string {
	if (t.typeNames !== null && t.typeNames.length > 0) return t.typeNames[0];
	return "";
}

// Tier 2: detect if a Union type has a discriminant field matching `fieldName`.
// Returns { isStringDU, discField } — the caller can use these to pick the right
// variant-finding function (findVariantByDiscriminant vs findVariantByStringDiscriminant).
// Checks enum-based DUs first, then string-literal DUs.
export interface DiscriminantInfo {
	isStringDU: boolean;
	discField: string;
}

export function detectUnionDiscriminant(unionType: Type, fieldName: string): DiscriminantInfo {
	if (isDiscriminatedUnion(unionType) && getDiscriminantName(unionType) === fieldName) {
		return { isStringDU: false, discField: fieldName };
	}
	if (unionType.kind === TypeKind.Union) {
		const sdf = findSharedStringDiscriminant(unionType);
		if (sdf !== "" && sdf === fieldName) {
			return { isStringDU: true, discField: sdf };
		}
	}
	return { isStringDU: false, discField: "" };
}

// Find variant index by field name. Returns the first variant containing the field.
// Used for direct field access on discriminated unions (e.g., s.radius → s.v0.radius).
export function findVariantByFieldName(unionType: Type, fieldName: string): number {
	if (unionType.typeChildren === null) return -1;
	let i = 0;
	while (i < unionType.typeChildren.length) {
		const variant = unionType.typeChildren[i];
		if (variant !== null && variant.typeNames !== null) {
			for (const fn of variant.typeNames) {
				if (fn === fieldName) return i;
			}
		}
		i = i + 1;
	}
	return -1;
}

// Find variant index by discriminant enum value name (e.g. "NumLit" or "NodeKind.NumLit").
// typeNames layout: [discFieldName, key0, key1, ...] — keys start at index 1.
// Matches both qualified ("Kind.A") and unqualified ("A") against stored keys.
export function findVariantByDiscriminant(unionType: Type, enumValue: string): number {
	if (unionType.typeNames === null || unionType.typeNames.length < 2) return -1;
	const queryBare = bareAfterDelim(enumValue, ".");
	// Also handle underscore-mangled form: checkMemberExpr rewrites EnumType.Member to EnumType_Member
	const queryBareUnderscore = bareAfterDelim(enumValue, "_");
	let i = 1;
	while (i < unionType.typeNames.length) {
		const stored = unionType.typeNames[i];
		if (stored === enumValue) return i - 1;
		const storedBare = bareAfterDelim(stored, ".");
		if (storedBare === queryBare) return i - 1;
		if (storedBare === queryBareUnderscore) return i - 1;
		i = i + 1;
	}
	return -1;
}

// Tier 2: detect a string-literal discriminant field shared by every variant of the union.
// A discriminant field must:
//   - be present on every variant
//   - have a distinct StringLiteral type in each variant (so we can disambiguate)
// Returns the field name, or "" if no such field exists.
// Preference order: first matching field encountered in variant 0.
export function findSharedStringDiscriminant(unionType: Type): string {
	if (unionType.typeChildren === null || unionType.typeChildren.length < 2) return "";
	const first = unionType.typeChildren[0];
	if (first === null || first.typeNames === null) return "";
	for (let fi = 0; fi < first.typeNames.length; fi += 1) {
		if (fi >= first.typeChildren.length) continue;
		const firstFt = first.typeChildren[fi];
		if (firstFt === null || firstFt.kind !== TypeKind.StringLiteral) continue;
		const candidateName = first.typeNames[fi];
		// Check every other variant has this field as a StringLiteral with a *different* value.
		let sharedOk = true;
		const seen: string[] = [firstFt.typeName];
		for (let vi = 1; vi < unionType.typeChildren.length; vi += 1) {
			const v = unionType.typeChildren[vi];
			if (v === null || v.typeNames === null) { sharedOk = false; break; }
			let foundInV = false;
			for (let vfi = 0; vfi < v.typeNames.length; vfi += 1) {
				if (v.typeNames[vfi] !== candidateName) continue;
				if (vfi >= v.typeChildren.length) break;
				const vft = v.typeChildren[vfi];
				if (vft === null || vft.kind !== TypeKind.StringLiteral) break;
				// Reject duplicate values across variants
				let dup = false;
				for (const s of seen) { if (s === vft.typeName) { dup = true; break; } }
				if (dup) { sharedOk = false; break; }
				seen.push(vft.typeName);
				foundInV = true;
				break;
			}
			if (!foundInV) { sharedOk = false; break; }
			if (!sharedOk) break;
		}
		if (sharedOk) return candidateName;
	}
	return "";
}

// Tier 2: collect all string-literal discriminant values from a union's variants.
// Returns ["circle", "square"] for type Shape = {kind:"circle",...} | {kind:"square",...}.
export function collectStringDiscriminantValues(unionType: Type, discFieldName: string): string[] {
	const values: string[] = [];
	if (unionType.typeChildren === null) return values;
	for (const variant of unionType.typeChildren) {
		if (variant === null || variant.typeNames === null) continue;
		for (let fi = 0; fi < variant.typeNames.length; fi += 1) {
			if (variant.typeNames[fi] !== discFieldName) continue;
			if (fi >= variant.typeChildren.length) continue;
			const ft = variant.typeChildren[fi];
			if (ft !== null && ft.kind === TypeKind.StringLiteral) {
				values.push(ft.typeName);
			}
			break;
		}
	}
	return values;
}

// Tier 2: find variant index by scanning variant structs directly for a string-literal
// discriminant field matching `discFieldName` with the given literal value.
// Used when the union is string-literal based (type Shape = {kind:"a",...} | {kind:"b",...})
// and there's no enum-backed discriminant metadata on the union itself.
// Returns -1 if no variant has a StringLiteral field matching the value.
export function findVariantByStringDiscriminant(unionType: Type, discFieldName: string, litValue: string): number {
	if (unionType.typeChildren === null) return -1;
	for (let i = 0; i < unionType.typeChildren.length; i += 1) {
		const variant = unionType.typeChildren[i];
		if (variant === null || variant.typeNames === null) continue;
		for (let fi = 0; fi < variant.typeNames.length; fi += 1) {
			if (variant.typeNames[fi] !== discFieldName) continue;
			if (fi >= variant.typeChildren.length) continue;
			const ft = variant.typeChildren[fi];
			if (ft !== null && ft.kind === TypeKind.StringLiteral && ft.typeName === litValue) {
				return i;
			}
		}
	}
	return -1;
}

// Maybe<T> — Reference: Maybe/Option parity. Wrapper struct { value: T, present: bool }.
// Only for value-type structs. Ref/Ptr types are inherently nullable (NULL pointer). Cached by name.
const _maybeCache: Type[] = [];
const _maybeCacheNames: string[] = [];

export function createMaybeType(inner: Type): Type {
	// Pointer types are inherently nullable — no wrapper needed (reference parity: nullable pointers)
	if (inner.kind === TypeKind.Ref || inner.kind === TypeKind.Ptr) return inner;
	const name = inner.typeName;
	let i = 0;
	while (i < _maybeCacheNames.length) {
		if (_maybeCacheNames[i] === name) return _maybeCache[i];
		i += 1;
	}
	const t = emptyType();
	t.kind = TypeKind.Struct;
	t.typeName = "Maybe_" + name;
	t.typeNames = ["value", "present"];
	t.typeChildren = [inner, booleanType()];
	t.typeFlags = (TypeFlag.IsStruct | TypeFlag.IsMaybe) as int32;
	t.typeReturn = inner;    // store inner type for unwrapping
	propagateToOwner(t, inner);
	_maybeCache.push(t);
	_maybeCacheNames.push(name);
	return t;
}

export function createRef(inner: Type): Type {
	return {
		kind: TypeKind.Ref, typeName: "", typeNames: [], typeChildren: [],
		typeReturn: inner, typeExtra: null, typeFlags: TypeFlag.HasAsgn as int32,
		callConv: CallingConvention.CcDefault, attachedOps: [],
	};
}

export function createPtr(inner: Type): Type {
	return {
		kind: TypeKind.Ptr, typeName: "", typeNames: [], typeChildren: [],
		typeReturn: inner, typeExtra: null, typeFlags: 0 as int32,
		callConv: CallingConvention.CcDefault, attachedOps: [],
	};
}

export function createBorrow(inner: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Borrow;
	t.typeReturn = inner;
	return t;
}

export function createVar(inner: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Var;
	t.typeReturn = inner;
	return t;
}

export function createTuple(elementTypes: Type[]): Type {
	const t = emptyType();
	t.kind = TypeKind.Tuple;
	t.typeChildren = elementTypes;
	for (const et of elementTypes) { propagateToOwner(t, et); }
	return t;
}



export function createDistinct(inner: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Distinct;
	t.typeReturn = inner;
	propagateToOwner(t, inner);
	return t;
}

export function createGenericParam(name: string): Type {
	const t = emptyType();
	t.kind = TypeKind.GenericParam;
	t.typeName = name;
	return t;
}

// GenericInstance: preserves type args structurally after instantiation.
// typeChildren = type arguments, typeExtra = base type (struct/interface).
// typeReturn = EAGERLY INSTANTIATED body (concrete body after substitution).
// Enables structural unification: HashMap<K,V> vs HashMap<string,string> → K=string, V=string.
// For Ref<Struct> (interface types), unwrap to inner struct for name and flags.
export function unwrapRefBase(t: Type): Type {
	return (t !== null && t.kind === TypeKind.Ref && t.typeReturn !== null) ? t.typeReturn : t;
}

export function createGenericInstance(baseType: Type, typeArgs: Type[]): Type {
	const innerBase = unwrapRefBase(baseType);
	return {
		kind: TypeKind.GenericInstance,
		typeName: innerBase !== null ? innerBase.typeName : "",
		typeNames: [],
		typeChildren: typeArgs,
		typeReturn: null as unknown as Type,
		typeExtra: baseType,
		typeFlags: innerBase !== null ? innerBase.typeFlags : 0 as int32,
		callConv: CallingConvention.CcDefault,
		attachedOps: [],
	};
}

// Reference parity (handleGenericInvocation): eagerly instantiate
// GenericInstance body. Uses explicit param names from the parser's generic declaration
// store. Produces a fully concrete body
// stored in typeReturn for direct field access — no lazy substitution at access time.
export function instantiateGenericBody(gi: Type, declaredParams: string): void {
	if (gi.kind !== TypeKind.GenericInstance) return;
	if (gi.typeReturn !== null) return;
	if (declaredParams === "") return;
	const baseType = gi.typeExtra;
	if (baseType === null) return;
	// Unwrap Ref for interface types (interface = Ref<Struct> after refactor)
	const isRefWrapped = baseType.kind === TypeKind.Ref && baseType.typeReturn !== null;
	const innerBase = isRefWrapped ? baseType.typeReturn : baseType;
	if (innerBase.kind !== TypeKind.Struct && innerBase.kind !== TypeKind.Union) return;
	// Only instantiate if ALL type args are concrete
	let ai = 0;
	while (ai < gi.typeChildren.length) {
		if (gi.typeChildren[ai] !== null && gi.typeChildren[ai].kind === TypeKind.GenericParam) return;
		ai = ai + 1;
	}
	// Split declared param names (e.g. "K,V" → ["K", "V"])
	const paramNames = splitTopLevel(declaredParams, ",");
	if (paramNames.length === 0 || paramNames.length > gi.typeChildren.length) return;
	let body = innerBase;
	let pi = 0;
	while (pi < paramNames.length) {
		body = substituteType(body, paramNames[pi].trim(), gi.typeChildren[pi]);
		pi = pi + 1;
	}
	// Re-wrap in Ref if the base was Ref<Struct>
	gi.typeReturn = isRefWrapped ? createRef(body) : body;
}

// ===== System Types (Standard reference parity) =====
// Pre-allocated primitive types indexed by TypeKind ordinal. O(1) lookup, no allocation.
// Under Bun: module-level array initialized once. Replaces per-call createPrimitive.

const _sysTypes: Type[] = [];
function initSysTypes(): void {
	// Pre-allocate one Type per TypeKind (indices 0..Error)
	for (let i = 0; i <= (TypeKind.Error as number); i += 1) {
		_sysTypes.push(createPrimitive(i as TypeKind));
	}
	// Managed primitives get TypeFlag.HasAsgn (Reference parity: managed types have tfHasAsgn)
	_sysTypes[TypeKind.String as number].typeFlags = TypeFlag.HasAsgn;
}
initSysTypes();

export function getSysType(kind: TypeKind): Type {
	const idx = kind as number;
	if (idx >= 0 && idx < _sysTypes.length) return _sysTypes[idx];
	return createPrimitive(kind);
}

// ===== Well-Known Type Accessors =====
// Thin wrappers over getSysType for backward compatibility + readability.

export function numberType(): Type { return getSysType(TypeKind.Number); }
export function stringType(): Type { return getSysType(TypeKind.String); }
export function booleanType(): Type { return getSysType(TypeKind.Boolean); }
export function voidType(): Type { return getSysType(TypeKind.Void); }
export function nullType(): Type { return getSysType(TypeKind.Null); }
export function unknownType(): Type { return getSysType(TypeKind.Unknown); }
export function neverType(): Type { return getSysType(TypeKind.Never); }
export function errorType(): Type { return getSysType(TypeKind.Error); }
export function charType(): Type { return getSysType(TypeKind.Char); }
export function cstringType(): Type { return getSysType(TypeKind.CString); }
export function int32Type(): Type { return getSysType(TypeKind.Int32); }
export function float64Type(): Type { return getSysType(TypeKind.Float64); }

// StringLiteral: a specific string value as a type (TypeScript parity).
// Not a singleton — each unique value creates a new instance.
export function createStringLiteral(value: string): Type {
	const t = emptyType();
	t.kind = TypeKind.StringLiteral;
	t.typeName = value;
	return t;
}

export function isStringLiteral(t: Type): boolean {
	return t !== null && t.kind === TypeKind.StringLiteral;
}

// EnumLiteral: a specific enum member as a type (TypeScript parity).
// typeName = enum type name (e.g. "NodeKind").
// typeNames[0] = specific member (e.g. "BinaryExpr").
// typeReturn = back-reference to the underlying Enum Type for fast subtype checks.
export function createEnumLiteral(enumType: Type, memberName: string): Type {
	const t = emptyType();
	t.kind = TypeKind.EnumLiteral;
	t.typeName = enumType.typeName;
	t.typeNames = [memberName];
	t.typeReturn = enumType;
	return t;
}

export function isEnumLiteral(t: Type): boolean {
	return t !== null && t.kind === TypeKind.EnumLiteral;
}

// Tier 3: Conditional type — T extends U ? A : B
// typeChildren[0] = check type (T)
// typeChildren[1] = extends type (U)
// typeChildren[2] = true branch (A)
// typeChildren[3] = false branch (B)
export function createConditionalType(check: Type, extendsType: Type, trueType: Type, falseType: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Conditional;
	t.typeChildren = [check, extendsType, trueType, falseType];
	return t;
}

// Evaluate a conditional type if its check and extends types are concrete (no GenericParam).
// Returns the true/false branch, or the original type if unevaluable.
export function evaluateConditionalType(t: Type): Type {
	if (t.kind !== TypeKind.Conditional) return t;
	if (t.typeChildren.length < 4) return t;
	const check = t.typeChildren[0];
	const ext = t.typeChildren[1];
	// Defer if check type still has unresolved generic params (not yet substituted)
	if (hasGenericParams(check)) return t;
	// Tier 3: if the extends type has GenericParam (from `infer X`), use unifyType
	// to extract bindings, then substitute into the true branch.
	if (hasGenericParams(ext)) {
		const bindings = createUnifyBindings();
		unifyType(ext, check, bindings);
		if (bindings.names.length > 0) {
			// infer succeeded — substitute bindings into true branch
			let result = t.typeChildren[2];
			for (let i = 0; i < bindings.names.length; i += 1) {
				result = substituteType(result, bindings.names[i], bindings.types[i]);
			}
			return result;
		}
		// infer failed — no match, return false branch
		return t.typeChildren[3];
	}
	return isAssignableForConditional(check, ext) ? t.typeChildren[2] : t.typeChildren[3];
}

// Simplified assignability check for conditional type evaluation.
// Uses the main isAssignable but avoids circular dependency.
let _condAssignFn: (source: Type, target: Type) => boolean = null as unknown as (source: Type, target: Type) => boolean;
export function setConditionalAssignFn(fn: (source: Type, target: Type) => boolean): void {
	_condAssignFn = fn;
}
function isAssignableForConditional(source: Type, target: Type): boolean {
	if (_condAssignFn !== null) return _condAssignFn(source, target);
	return source.kind === target.kind;
}

export function isAllStringLiteralUnion(t: Type): boolean {
	if (t === null || t.kind !== TypeKind.Union) return false;
	if (t.typeChildren.length === 0) return false;
	for (const child of t.typeChildren) {
		if (child === null || child.kind !== TypeKind.StringLiteral) return false;
	}
	return true;
}

// isStringLike — true for String, StringLiteral, and Union<StringLiteral...>.
// Single source of truth: these are all msString at runtime.
export function isStringLike(t: Type): boolean {
	if (t === null) return false;
	if (t.kind === TypeKind.String || t.kind === TypeKind.StringLiteral) return true;
	return isAllStringLiteralUnion(t);
}

export function isFloatType(t: Type): boolean {
	if (t === null) return false;
	return t.kind === TypeKind.Float32 || t.kind === TypeKind.Float64;
}

// ===== Min Arity (Default Parameters) =====
// Encoded in typeFlags bits 8-15. Zero = not set = all params required.
// Stores minArity + 1 so that 0 means "not set" (backward compatible).

export function setMinArity(t: Type, minArity: number): void {
	t.typeFlags = (t.typeFlags & 0xFF) | (((minArity as int32) + 1) << 8);
}

export function getMinArity(t: Type): number {
	const encoded: int32 = (t.typeFlags >> 8) & 0xFF;
	if (encoded === 0) return t.typeChildren.length;
	return (encoded - 1) as number;
}

// ===== Attached Ops Helpers (Implementation parity) =====

export function getAttachedOp(t: Type, op: AttachedOp): string {
	const idx = op as number;
	if (t.attachedOps.length <= idx) return "";
	return t.attachedOps[idx];
}

export function setAttachedOp(t: Type, op: AttachedOp, name: string): void {
	// Grow array to fit index
	while (t.attachedOps.length <= (op as number)) {
		t.attachedOps.push("");
	}
	t.attachedOps[op as number] = name;
}

export function hasDestructor(t: Type): boolean {
	return getAttachedOp(t, AttachedOp.AttachedDestructor) !== "";
}

// ===== Tuple Type Name (reference parity: deterministic name for structural types) =====
// DJB2 hash of type structure → "msTuple_HASH". Same algorithm as C codegen
// (types.ms:genTupleType) so generated comparison functions match struct names.

export function tupleTypeName(t: Type): string {
	if (t === null || t.kind !== TypeKind.Tuple) return "";
	let key = "tuple:";
	let i = 0;
	while (i < t.typeChildren.length) {
		if (i > 0) key = key + ",";
		const child = t.typeChildren[i];
		if (child !== null) {
			key = key + typeKey(child);
		}
		i += 1;
	}
	return "msTuple_" + _stdHashToBase36(key);
}

// typeKey for tuples — matches codegen/c/types.ms:typeKey
function typeKey(t: Type): string {
	if (t === null) return "null";
	if (t.typeName !== "" && t.kind !== TypeKind.Tuple) return t.typeName;
	return match (t.kind) {
		TypeKind.Number => "number",
		TypeKind.String => "string",
		TypeKind.Boolean => "boolean",
		TypeKind.Void => "void",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint32 => "uint32",
		TypeKind.Float32 => "float32",
		TypeKind.Float64 => "float64",
		TypeKind.Array => {
			return "Array(" + (t.typeReturn !== null ? typeKey(t.typeReturn) : "any") + ")";
		},
		TypeKind.Tuple => {
			let k = "tuple:";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) k = k + ",";
				k = k + typeKey(t.typeChildren[i]);
				i += 1;
			}
			return k;
		},
		_ => t.kind.toString(),
	};
}

// ===== Type Classification Helpers =====

export function isStructType(t: Type): boolean {
	if (t === null) return false;
	if (t.kind !== TypeKind.Struct) return false;
	return (t.typeFlags & TypeFlag.IsStruct) !== 0;
}

export function isMaybeType(t: Type): boolean {
	if (t === null) return false;
	return (t.typeFlags & TypeFlag.IsMaybe) !== 0;
}

export function unwrapMaybeType(t: Type): Type {
	return t.typeReturn;
}

// unwrapRef — unwrap Ref<T> or Ptr<T> to get inner type (reference: skip pointer types)
export function unwrapRef(t: Type): Type {
	if (t === null) return t;
	if (t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr) return t.typeReturn;
	return t;
}

// ===== Needs RC =====
// Types that need reference counting. Pure type query — no codegen dependency.

export function needsRC(t: Type): boolean {
	if (t === null) return false;
	return match (t.kind) {
		TypeKind.String => true,
		TypeKind.Array => true,
		TypeKind.SizedArray => needsRC(t.typeReturn),
		TypeKind.Span => false,
		TypeKind.Ref => true,
		TypeKind.Tuple => {
			let i = 0;
			while (i < t.typeChildren.length) {
				if (needsRC(t.typeChildren[i])) return true;
				i += 1;
			}
			return false;
		},
		_ => false,
	};
}

// ===== tfHasAsgn Flag — Reference parity: propagated lifecycle management flag =====
// Set on types that need lifecycle management (destroy/copy/sink).
// Propagated bottom-up from children to parents at type construction time.

export function hasAsgnFlag(t: Type): boolean {
	if (t === null) return false;
	return (t.typeFlags & TypeFlag.HasAsgn) !== 0;
}

export function propagateToOwner(parent: Type, child: Type): void {
	if (child !== null && (child.typeFlags & TypeFlag.HasAsgn) !== 0) {
		parent.typeFlags = parent.typeFlags | TypeFlag.HasAsgn;
	}
}

// ===== Ownership Modifiers (Reference parity: sink and lent modifiers) =====
// Sink/Lent wrap the inner param type. Standard reference: `proc foo(x: sink T)` → param type is a sink modifier wrapping T.
// skipModifier unwraps one level, following standard reference patterns.

export function wrapSink(inner: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Sink;
	t.typeReturn = inner;
	return t;
}

export function wrapLent(inner: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Lent;
	t.typeReturn = inner;
	return t;
}

export function isSinkType(t: Type): boolean {
	return t !== null && t.kind === TypeKind.Sink;
}

export function isLentType(t: Type): boolean {
	return t !== null && t.kind === TypeKind.Lent;
}

export function skipModifier(t: Type): Type {
	if (t === null) return t;
	if (t.kind === TypeKind.Sink || t.kind === TypeKind.Lent || t.kind === TypeKind.Var) return t.typeReturn;
	return t;
}

// ===== Type Size Estimation (Reference: reference codegen utils parity) =====
// Returns estimated C struct size in bytes for reference pointer introduction threshold.
// Reference: size threshold = 24 bytes on 64-bit. Objects/tuples larger than this → pass by pointer.
let _sizeDepth: number = 0;

export function getTypeSize(t: Type): number {
	if (t === null) return 0;
	// Guard against recursive types (e.g. Type has Type[] fields)
	if (_sizeDepth > 8) return 64; // assume large → pass by pointer
	_sizeDepth = _sizeDepth + 1;
	const result = getTypeSizeInner(t);
	_sizeDepth = _sizeDepth - 1;
	return result;
}

function getTypeSizeInner(t: Type): number {
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float32 | TypeKind.Float64 => 8,
		TypeKind.Int8 | TypeKind.Uint8 => 1,
		TypeKind.Int16 | TypeKind.Uint16 => 2,
		TypeKind.Int32 | TypeKind.Uint32 | TypeKind.Char => 4,
		TypeKind.Int64 | TypeKind.Uint64 => 8,
		TypeKind.Boolean => 1,
		TypeKind.String | TypeKind.StringLiteral => targetPtrSize + targetPtrSize, // msString: data ptr + length
		TypeKind.CString => targetPtrSize,
		TypeKind.Enum | TypeKind.EnumLiteral => 4, // C int
		TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow => targetPtrSize,
		TypeKind.Array => targetPtrSize + targetPtrSize, // msArray: data ptr + length
		TypeKind.Function => targetPtrSize + targetPtrSize, // msClosure: fn ptr + env ptr
		TypeKind.Struct => {
			// Sum of field sizes
			if (t.typeChildren === null) { return targetPtrSize; } else {
				let size = 0;
				for (const field of t.typeChildren) {
					size = size + getTypeSize(field);
				}
				return size;
			}
		},
		TypeKind.Tuple => {
			if (t.typeChildren === null) { return 0; } else {
				let size = 0;
				for (const elem of t.typeChildren) {
					size = size + getTypeSize(elem);
				}
				return size;
			}
		},
		TypeKind.Union => {
			// tag + max(member sizes)
			let maxSize = 0;
			if (t.typeChildren !== null) {
				for (const member of t.typeChildren) {
					const ms = getTypeSize(member);
					if (ms > maxSize) maxSize = ms;
				}
			}
			return 4 + maxSize;
		},
		TypeKind.Span => targetPtrSize + targetPtrSize, // ptr + length
		_ => targetPtrSize, // conservative fallback
	};
}

// ===== Generic Instantiation =====

// Substitute a generic parameter name with a concrete type throughout a type tree.
// Returns a new Type (does not mutate original).
function substituteStruct(t: Type, paramName: string, concrete: Type): Type {
	const newFieldTypes: Type[] = [];
	let changed = false;
	for (let ci = 0; ci < t.typeChildren.length; ci += 1) {
		const sub = substituteType(t.typeChildren[ci], paramName, concrete);
		newFieldTypes.push(sub);
		if (sub !== t.typeChildren[ci]) changed = true;
	}
	if (!changed) return t;
	const newNames: string[] = [];
	for (let ni = 0; ni < t.typeNames.length; ni += 1) {
		newNames.push(t.typeNames[ni]);
	}
	const result = createStruct(t.typeName, newNames, newFieldTypes, isStructType(t));
	result.typeReturn = t.typeReturn;
	result.typeExtra = t.typeExtra;
	return result;
}

// Reference parity (instCopyType → newSons + dest[i] = src[i]):
// Copy type with independent arrays. Children copied via push(null) + indexed
// assignment so DRC generates =copy (incref) in C. JS gets independence from push.
function copyTypeForSubst(t: Type): Type {
	const result = emptyType();
	result.kind = t.kind;
	result.typeName = t.typeName;
	result.typeReturn = t.typeReturn;
	result.typeExtra = t.typeExtra;
	result.typeFlags = t.typeFlags - TypeFlag.Substituting;
	result.callConv = t.callConv;
	for (let ci = 0; ci < t.typeChildren.length; ci += 1) {
		result.typeChildren.push(null as unknown as Type);
		result.typeChildren[ci] = t.typeChildren[ci];
	}
	for (let ni = 0; ni < t.typeNames.length; ni += 1) {
		result.typeNames.push("");
		result.typeNames[ni] = t.typeNames[ni];
	}
	for (let oi = 0; oi < t.attachedOps.length; oi += 1) {
		result.attachedOps.push("");
		result.attachedOps[oi] = t.attachedOps[oi];
	}
	return result;
}

// In-place substitute all children of a copied type.
function substituteChildrenInPlace(copy: Type, paramName: string, concrete: Type): void {
	for (let ci = 0; ci < copy.typeChildren.length; ci += 1) {
		copy.typeChildren[ci] = substituteType(copy.typeChildren[ci], paramName, concrete);
	}
}

// Cycle detection: flag on the Type itself.
// Reference parity: uses localCache (hash table). We use a flag bit — same principle
// (identity-based, no incref/decref on tracked types). O(1) check vs O(n) linear scan.
// Cannot use Type[] stack — DRC push/pop/decref frees rc=0 types (fatal in C binary).
function substituteIsSeen(t: Type): boolean {
	return (t.typeFlags & TypeFlag.Substituting) !== 0;
}

function substituteSetFlag(t: Type): void {
	t.typeFlags = t.typeFlags | TypeFlag.Substituting;
}

function substituteClearFlag(t: Type): void {
	if ((t.typeFlags & TypeFlag.Substituting) !== 0) {
		t.typeFlags = t.typeFlags - TypeFlag.Substituting;
	}
}

export function substituteType(t: Type, paramName: string, concrete: Type): Type {
	if (t === null) return t;
	if (t.kind === TypeKind.GenericParam && t.typeName === paramName) return concrete;
	if (substituteIsSeen(t)) return t;
	substituteSetFlag(t);
	const result = match (t.kind) {
			TypeKind.Number | TypeKind.String | TypeKind.Boolean |
			TypeKind.Void | TypeKind.Null | TypeKind.Unknown |
			TypeKind.Never | TypeKind.Error | TypeKind.GenericParam |
			TypeKind.CString => t,
			TypeKind.Array => createArray(substituteType(t.typeReturn, paramName, concrete)),
			TypeKind.SizedArray => createSizedArray(substituteType(t.typeReturn, paramName, concrete), t.typeFlags - TypeFlag.Substituting),
			TypeKind.Span => createSpan(substituteType(t.typeReturn, paramName, concrete)),
			TypeKind.Function => {
				const fn = copyTypeForSubst(t);
				substituteChildrenInPlace(fn, paramName, concrete);
				fn.typeReturn = substituteType(t.typeReturn, paramName, concrete);
				substituteClearFlag(t);
				return fn;
			},
			TypeKind.Union | TypeKind.Tuple => {
				const copy = copyTypeForSubst(t);
				substituteChildrenInPlace(copy, paramName, concrete);
				substituteClearFlag(t);
				return copy;
			},
			TypeKind.Ref => createRef(substituteType(t.typeReturn, paramName, concrete)),
			TypeKind.Ptr => createPtr(substituteType(t.typeReturn, paramName, concrete)),
			TypeKind.Borrow => createBorrow(substituteType(t.typeReturn, paramName, concrete)),
			TypeKind.Struct => substituteStruct(t, paramName, concrete),
			TypeKind.GenericInstance => {
				const gi = copyTypeForSubst(t);
				gi.typeReturn = null as unknown as Type;
				substituteChildrenInPlace(gi, paramName, concrete);
				substituteClearFlag(t);
				return gi;
			},
			TypeKind.Conditional => {
				// Substitute in all 4 children, then try to evaluate
				const cond = copyTypeForSubst(t);
				substituteChildrenInPlace(cond, paramName, concrete);
				substituteClearFlag(t);
				return evaluateConditionalType(cond);
			},
			_ => t,
		};
	substituteClearFlag(t);
	return result;
}

// Instantiate a generic type with concrete type arguments.
export function instantiateGeneric(t: Type, genericParamNames: string[], typeArgs: Type[]): Type {
	let result = t;
	const limit = genericParamNames.length < typeArgs.length ? genericParamNames.length : typeArgs.length;
	for (let i = 0; i < limit; i += 1) {
		result = substituteType(result, genericParamNames[i], typeArgs[i]);
	}
	return result;
}

// ===== Type Unification =====
// Recursively match formal (may contain GenericParam) against concrete (always resolved).
// Extracts bindings into UnifyBindings (parallel arrays: names + types).

export interface UnifyBindings {
	names: string[];
	types: Type[];
}

export function createUnifyBindings(): UnifyBindings {
	return { names: [], types: [] };
}

let unifyDepth = 0;

export function unifyType(formal: Type, concrete: Type, bindings: UnifyBindings): void {
	if (formal === null || concrete === null) return;
	// Identity check — break circular type references (e.g., Doc → DocData → Doc)
	if (formal === concrete) return;
	// Depth guard — prevent infinite recursion on recursive types (e.g., JsonValue contains JsonValue[])
	if (unifyDepth > 20) return;
	unifyDepth = unifyDepth + 1;
	unifyTypeInner(formal, concrete, bindings);
	unifyDepth = unifyDepth - 1;
}

function unifyTypeInner(formal: Type, concrete: Type, bindings: UnifyBindings): void {
	// Direct generic param match
	if (formal.kind === TypeKind.GenericParam) {
		bindings.names.push(formal.typeName);
		bindings.types.push(concrete);
		return;
	}
	// Array/Span/Ref/Ptr: unify element types
	if (formal.kind === concrete.kind
		&& (formal.kind === TypeKind.Array || formal.kind === TypeKind.SizedArray
			|| formal.kind === TypeKind.Span || formal.kind === TypeKind.Ref || formal.kind === TypeKind.Ptr)) {
		if (formal.typeReturn !== null && concrete.typeReturn !== null) {
			unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		}
		return;
	}
	// GenericInstance: structural unification of type arguments
	// HashMap<K,V> (formal, with GenericParam children) vs HashMap<string,string> (concrete)
	// Base type must match: HashMap<K,V> unifies with HashMap<string,string> but NOT HashSet<string>
	if (formal.kind === TypeKind.GenericInstance && concrete.kind === TypeKind.GenericInstance) {
		// Affine and plain Promises share typeName "Promise" — their distinction
		// is in flag bits, not in the name. Simple equality covers both.
		const namesMatch = formal.typeName === concrete.typeName;
		if (!namesMatch) return;
		const limit = formal.typeChildren.length < concrete.typeChildren.length ? formal.typeChildren.length : concrete.typeChildren.length;
		for (let gi = 0; gi < limit; gi += 1) {
			unifyType(formal.typeChildren[gi], concrete.typeChildren[gi], bindings);
		}
		return;
	}
	// GenericInstance vs Struct (either direction) — try base type matching
	if (formal.kind === TypeKind.GenericInstance && concrete.kind === TypeKind.Struct) {
		if (formal.typeExtra !== null) {
			unifyType(formal.typeExtra, concrete, bindings);
		}
		return;
	}
	if (formal.kind === TypeKind.Struct && concrete.kind === TypeKind.GenericInstance) {
		// Struct("Map") with generic params vs GenericInstance("Map", [string, string])
		// Unify by matching formal's fields against the instantiated body's fields
		if (formal.typeName === concrete.typeName && concrete.typeReturn !== null) {
			const body = unwrapRef(concrete.typeReturn);
			if (body.kind === TypeKind.Struct) {
				const limit = formal.typeChildren.length < body.typeChildren.length ? formal.typeChildren.length : body.typeChildren.length;
				for (let i = 0; i < limit; i += 1) {
					unifyType(formal.typeChildren[i], body.typeChildren[i], bindings);
				}
			}
		}
		return;
	}
	// Structural match — same kind, recurse into children
	if (formal.kind !== concrete.kind) return;
	if (formal.kind === TypeKind.Array || formal.kind === TypeKind.SizedArray || formal.kind === TypeKind.Span) {
		unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		return;
	}
	// Result and Promise are now GenericInstance — handled above
	if (formal.kind === TypeKind.Function) {
		const fnLimit = formal.typeChildren.length < concrete.typeChildren.length ? formal.typeChildren.length : concrete.typeChildren.length;
		for (let i = 0; i < fnLimit; i += 1) {
			unifyType(formal.typeChildren[i], concrete.typeChildren[i], bindings);
		}
		unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		return;
	}
	if (formal.kind === TypeKind.Ref || formal.kind === TypeKind.Ptr) {
		unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		return;
	}
	if (formal.kind === TypeKind.Union || formal.kind === TypeKind.Struct) {
		const uoLimit = formal.typeChildren.length < concrete.typeChildren.length ? formal.typeChildren.length : concrete.typeChildren.length;
		for (let i = 0; i < uoLimit; i += 1) {
			unifyType(formal.typeChildren[i], concrete.typeChildren[i], bindings);
		}
		return;
	}
}

// Cycle-safe: named Object/Union types don't contain GenericParams after resolution
let _hasGenericDepth = 0;
export function hasGenericParams(t: Type): boolean {
	if (t === null) return false;
	if (t.kind === TypeKind.GenericParam) return true;
	if (_hasGenericDepth > 20) return false;
	_hasGenericDepth = _hasGenericDepth + 1;
	const result = hasGenericParamsInner(t);
	_hasGenericDepth = _hasGenericDepth - 1;
	return result;
}

function hasGenericParamsInner(t: Type): boolean {
	// GenericInstance: check type args for GenericParam (e.g., HashMap<K,V> has GenericParam children)
	if (t.kind === TypeKind.GenericInstance) {
		for (let gi = 0; gi < t.typeChildren.length; gi += 1) {
			if (hasGenericParams(t.typeChildren[gi])) return true;
		}
		return false;
	}
	// Named types can't contain GenericParams (they're resolved) — skip to avoid cycles
	if ((t.kind === TypeKind.Struct || t.kind === TypeKind.Union) && t.typeName !== "") return false;
	if (t.typeReturn !== null && hasGenericParams(t.typeReturn)) return true;
	if (t.typeExtra !== null && hasGenericParams(t.typeExtra)) return true;
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		if (hasGenericParams(t.typeChildren[i])) return true;
	}
	return false;
}

// ===== Type Query Helpers =====

export function isNumeric(t: Type): boolean {
	return t.kind === TypeKind.Number || t.kind === TypeKind.Int8 ||
		t.kind === TypeKind.Int16 || t.kind === TypeKind.Int32 ||
		t.kind === TypeKind.Int64 || t.kind === TypeKind.Uint8 ||
		t.kind === TypeKind.Uint16 || t.kind === TypeKind.Uint32 ||
		t.kind === TypeKind.Uint64 || t.kind === TypeKind.Float32 ||
		t.kind === TypeKind.Float64 || t.kind === TypeKind.Char;
}

export function isIntegerType(t: Type): boolean {
	if (t === null) return false;
	return t.kind === TypeKind.Int8 || t.kind === TypeKind.Int16 ||
		t.kind === TypeKind.Int32 || t.kind === TypeKind.Int64 ||
		t.kind === TypeKind.Uint8 || t.kind === TypeKind.Uint16 ||
		t.kind === TypeKind.Uint32 || t.kind === TypeKind.Uint64;
}

// Integer rank for narrowing detection (higher = wider range)
// Parity: standard reference's ordinal range comparison patterns
export function integerRank(t: Type): number {
	return match (t.kind) {
		TypeKind.Int8    => 1,
		TypeKind.Uint8   => 2,
		TypeKind.Int16   => 3,
		TypeKind.Uint16  => 4,
		TypeKind.Int32   => 5,
		TypeKind.Uint32  => 6,
		TypeKind.Int64   => 7,
		TypeKind.Uint64  => 8,
		TypeKind.Float32 => 9,
		TypeKind.Number  => 10,
		TypeKind.Float64 => 10,
		_ => 0,
	};
}

// Returns true when source → target is a narrowing integer conversion
// Parity: standard reference integer conversion matching — narrowing needs HiddenStdConv + range check
export function isNarrowingIntConv(source: Type, target: Type): boolean {
	if (!isIntegerType(target)) return false;
	if (!isIntegerType(source) && source.kind !== TypeKind.Number && source.kind !== TypeKind.Float64) return false;
	return integerRank(source) > integerRank(target);
}


export function isBoolType(t: Type): boolean {
	return t.kind === TypeKind.Boolean;
}

export function isCallable(t: Type): boolean {
	return t.kind === TypeKind.Function;
}

export function getReturnType(t: Type): Type {
	if (t.kind === TypeKind.Function) return t.typeReturn;
	return unknownType();
}

export function getElementType(t: Type): Type {
	if (t.kind === TypeKind.Array || t.kind === TypeKind.SizedArray || t.kind === TypeKind.Span || t.kind === TypeKind.Ptr) return t.typeReturn;
	// @builtin("IndexableMap") subscript: `m[k]` returns V. Makes `{ [key: K]: V }`
	// work at runtime via .get() after the lowering in transform/native/nativeLower.ms.
	if (t.kind === TypeKind.GenericInstance && isIndexableMapType(t)
		&& t.typeChildren !== null && t.typeChildren.length === 2) {
		return t.typeChildren[1];
	}
	return unknownType();
}

// Collect unique GenericParam names from a type tree (used by getProperty for GenericInstance substitution)
let _collectGenericDepth = 0;
function collectGenericParamNames(t: Type, names: string[]): void {
	if (t === null) return;
	if (_collectGenericDepth > 20) return;
	if (t.kind === TypeKind.GenericParam) {
		let dup = false;
		let ni = 0;
		while (ni < names.length) { if (names[ni] === t.typeName) { dup = true; } ni = ni + 1; }
		if (!dup) names.push(t.typeName);
		return;
	}
	_collectGenericDepth = _collectGenericDepth + 1;
	if (t.typeReturn !== null) collectGenericParamNames(t.typeReturn, names);
	if (t.typeExtra !== null) collectGenericParamNames(t.typeExtra, names);
	let ci = 0;
	while (ci < t.typeChildren.length) {
		collectGenericParamNames(t.typeChildren[ci], names);
		ci = ci + 1;
	}
	_collectGenericDepth = _collectGenericDepth - 1;
}

export function getProperty(t: Type, name: string): Type {
	// Unwrap Ref/Ptr to access inner Object's properties (class types are Ref<Object>)
	if (t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr) {
		if (t.typeReturn !== null) return getProperty(t.typeReturn, name);
	}
	if (t.kind === TypeKind.Struct) {
		let i = 0;
		for (const propName of t.typeNames) {
			if (propName === name) {
				if (i < t.typeChildren.length) {
					const found = t.typeChildren[i];
						return found;
				}
				return unknownType();
			}
			i += 1;
		}
	}
	// GenericInstance: access instantiated body (skipTypes → concrete struct).
	// typeReturn holds the eagerly instantiated body with concrete field types.
	// No lazy substitution needed — field types are already concrete.
	if (t.kind === TypeKind.GenericInstance) {
		// Primary: eagerly instantiated body (typeReturn) — fully concrete
		if (t.typeReturn !== null) {
			return getProperty(t.typeReturn, name);
		}
		// Fallback: lazy substitution for GenericInstances without instantiated body
		if (t.typeExtra !== null) {
			let baseProp = getProperty(t.typeExtra, name);
			if (baseProp.kind === TypeKind.Unknown) return baseProp;
			if (hasGenericParams(baseProp) && t.typeChildren.length > 0) {
				const paramNames: string[] = [];
				collectGenericParamNames(t.typeExtra, paramNames);
				let gi = 0;
				while (gi < paramNames.length) {
					if (gi < t.typeChildren.length) {
						baseProp = substituteType(baseProp, paramNames[gi], t.typeChildren[gi]);
					}
					gi = gi + 1;
				}
			}
			return baseProp;
		}
	}
	// Union field access: search all variants for the field.
	// For discriminated unions, the discriminant field maps to _tag.
	if (t.kind === TypeKind.Union && t.typeChildren !== null) {
		// Check discriminant field first (e.g. "kind" on a discriminated union)
		if (t.typeExtra !== null && t.typeNames !== null && t.typeNames.length > 0) {
			if (t.typeNames[0] === name) {
				return t.typeExtra; // discriminant field returns the enum type
			}
		}
		// Search variants for the field — return type if unambiguous across variants
		let foundType: Type = null;
		let ambiguous = false;
		for (const variant of t.typeChildren) {
			const ft = findFieldInVariant(variant, name);
			if (ft !== null) {
				if (foundType === null) {
					foundType = ft;
				} else if (foundType.kind !== ft.kind) {
					ambiguous = true;
				}
			}
		}
		if (foundType !== null && !ambiguous) return foundType;
		// Ambiguous fields (same name, different types across variants) require `as` cast
		if (foundType !== null) return foundType; // return first match — runtime guard needed
	}
	// Enum member access: Color.Red → returns the Enum type
	if (t.kind === TypeKind.Enum) {
		for (const member of t.typeNames) {
			if (member === name) return t;
		}
	}
	return unknownType();
}

// isPrimitiveKind — used by destructorLifting, analyzer/classify, and other DRC code
export function isPrimitiveKind(kind: TypeKind): boolean {
	return kind === TypeKind.Number
		|| kind === TypeKind.Boolean
		|| kind === TypeKind.Void
		|| kind === TypeKind.Null
		|| kind === TypeKind.Int8
		|| kind === TypeKind.Int16
		|| kind === TypeKind.Int32
		|| kind === TypeKind.Int64
		|| kind === TypeKind.Uint8
		|| kind === TypeKind.Uint16
		|| kind === TypeKind.Uint32
		|| kind === TypeKind.Uint64
		|| kind === TypeKind.Float32
		|| kind === TypeKind.Float64
		|| kind === TypeKind.Enum
		|| kind === TypeKind.EnumLiteral
		|| kind === TypeKind.Never
		|| kind === TypeKind.Unknown
		|| kind === TypeKind.Char
		|| kind === TypeKind.CString
		|| kind === TypeKind.StringLiteral
		|| kind === TypeKind.Error;
}

// typeNameOf — maps Type to its canonical string name (used by checker + transforms)
export function typeNameOf(t: Type): string {
	// Reference parity: ownership modifiers are transparent — unwrap before naming
	if (t.kind === TypeKind.Sink || t.kind === TypeKind.Lent) {
		if (t.typeReturn !== null) return typeNameOf(t.typeReturn);
		return "";
	}
	if (t.kind === TypeKind.Var) {
		if (t.typeReturn !== null) return "out " + typeNameOf(t.typeReturn);
		return "out";
	}
	if (t.kind === TypeKind.Struct) return t.typeName;
	if (t.kind === TypeKind.GenericInstance) return t.typeName;  // "Map" for receiver matching
	if (t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr) {
		if (t.typeReturn !== null) return typeNameOf(t.typeReturn);
		return "";
	}
	return match (t.kind) {
		TypeKind.String => "string",
		TypeKind.Number => "number",
		TypeKind.Boolean => "boolean",
		TypeKind.Char => "char",
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
		TypeKind.Array => "Array",
		TypeKind.SizedArray => "Array", // Both map to "Array" for extension lookup (UFCS)
		TypeKind.Span => "Span",
		TypeKind.Borrow => "Borrow",
		TypeKind.Tuple => "Tuple",
		TypeKind.CString => "cstring",
		TypeKind.StringLiteral => "\"" + t.typeName + "\"",
		TypeKind.EnumLiteral => t.typeName + "." + (t.typeNames.length > 0 ? t.typeNames[0] : ""),
		// Result and Promise are now GenericInstance — handled above via t.typeName
		TypeKind.Enum => t.typeName,
		TypeKind.TypeReference => t.typeName,
		TypeKind.Distinct => t.typeName,
		TypeKind.Union => {
			// Display string literal unions as "north" | "south"
			if (t.typeChildren.length > 0) {
				let display = "";
				for (const child of t.typeChildren) {
					if (display !== "") display = display + " | ";
					display = display + typeNameOf(child);
				}
				return display;
			}
			return t.typeName;
		},
		_ => "",
	};
}

// getBuiltinKind — read the @builtin("...") tag from a type's underlying class Symbol.
// Returns "" if the type has no builtin annotation. Walks transparent wrappers
// (Sink/Lent/Var/Distinct/Ref/Ptr) and GenericInstance → base class, mirroring
// typeNameOf's unwrap policy so `sink m: Map<K,V>` still registers as IndexableMap.
export function getBuiltinKind(t: Type): string {
	if (t === null) return "";
	if (t.sym !== null && t.sym.builtinKind !== "") return t.sym.builtinKind;
	if (t.kind === TypeKind.GenericInstance && t.typeExtra !== null) {
		return getBuiltinKind(t.typeExtra);
	}
	// Transparent wrappers — unwrap to inner type before looking up the tag.
	if ((t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr
			|| t.kind === TypeKind.Sink || t.kind === TypeKind.Lent
			|| t.kind === TypeKind.Var || t.kind === TypeKind.Distinct)
			&& t.typeReturn !== null) {
		return getBuiltinKind(t.typeReturn);
	}
	return "";
}

// isIndexableMapType — true when t is a class tagged @builtin("IndexableMap").
// Used by subscript lowering (m[k] → m.get(k) / m.set(k, v)) and m[k] element typing.
// Both Map<K,V> and HashMap<K,V> in std/core/struct.ms carry this tag.
export function isIndexableMapType(t: Type): boolean {
	return getBuiltinKind(t) === "IndexableMap";
}

// alignTo — round up offset to alignment boundary
function alignTo(offset: number, align: number): number {
	if (align <= 1) return offset;
	const rem = offset % align;
	if (rem === 0) return offset;
	return offset + (align - rem);
}

// alignOfType — natural alignment for C ABI (target-aware)
export function alignOfType(t: Type): number {
	const ps = targetPtrSize;
	if (t.kind === TypeKind.Struct || t.kind === TypeKind.Tuple) {
		return alignOfStruct(t);
	}
	if (t.kind === TypeKind.Distinct && t.typeReturn !== null) {
		return alignOfType(t.typeReturn);
	}
	return match (t.kind) {
		TypeKind.Boolean | TypeKind.Char | TypeKind.Int8 | TypeKind.Uint8 => 1,
		TypeKind.Int16 | TypeKind.Uint16 => 2,
		TypeKind.Int32 | TypeKind.Uint32 | TypeKind.Float32 | TypeKind.Enum | TypeKind.EnumLiteral => 4,
		TypeKind.Number | TypeKind.Float64 => ps,
		TypeKind.Int64 | TypeKind.Uint64 => ps,
		TypeKind.CString | TypeKind.Ref | TypeKind.Ptr | TypeKind.Function => ps,
		TypeKind.String | TypeKind.Array | TypeKind.Span => ps,
		_ => 0,
	};
}

function alignOfStruct(t: Type): number {
	let maxAlign = 1;
	if (t.typeChildren !== null) {
		let i = 0;
		while (i < t.typeChildren.length) {
			const a = alignOfType(t.typeChildren[i]);
			if (a > maxAlign) maxAlign = a;
			i = i + 1;
		}
	}
	return maxAlign;
}

// sizeOfType — compile-time sizeof for primitive and compound types (target-aware C ABI)
// Mirrors standard reference implementation for size/alignment: fields are aligned, struct is padded to maxAlign.
export function sizeOfType(t: Type): number {
	const ps = targetPtrSize;
	if (t.kind === TypeKind.Struct || t.kind === TypeKind.Tuple) {
		return sizeOfStruct(t);
	}
	if (t.kind === TypeKind.Distinct && t.typeReturn !== null) {
		return sizeOfType(t.typeReturn);
	}
	return match (t.kind) {
		TypeKind.Boolean | TypeKind.Char | TypeKind.Int8 | TypeKind.Uint8 => 1,
		TypeKind.Int16 | TypeKind.Uint16 => 2,
		TypeKind.Int32 | TypeKind.Uint32 | TypeKind.Float32 | TypeKind.Enum | TypeKind.EnumLiteral => 4,
		TypeKind.Number | TypeKind.Int64 | TypeKind.Uint64 | TypeKind.Float64 => ps,
		TypeKind.String => ps * 2,
		TypeKind.CString | TypeKind.Ref | TypeKind.Ptr => ps,
		TypeKind.Function => ps * 2,
		TypeKind.Array | TypeKind.Span => ps * 2,
		_ => 0,
	};
}

function sizeOfStruct(t: Type): number {
	let offset = 0;
	let maxAlign = 1;
	if (t.typeChildren !== null) {
		let i = 0;
		while (i < t.typeChildren.length) {
			const fieldSize = sizeOfType(t.typeChildren[i]);
			const fieldAlign = alignOfType(t.typeChildren[i]);
			if (fieldAlign > maxAlign) maxAlign = fieldAlign;
			offset = alignTo(offset, fieldAlign);
			offset = offset + fieldSize;
			i = i + 1;
		}
	}
	if (offset === 0) return 0;
	return alignTo(offset, maxAlign);
}

// ===== Tests =====
test "primitive kinds" {
	assert numberType().kind === TypeKind.Number;
	assert stringType().kind === TypeKind.String;
	assert booleanType().kind === TypeKind.Boolean;
	assert voidType().kind === TypeKind.Void;
	assert nullType().kind === TypeKind.Null;
	assert unknownType().kind === TypeKind.Unknown;
	assert neverType().kind === TypeKind.Never;
	assert errorType().kind === TypeKind.Error;
}

test "createArray" {
	const arrType = createArray(numberType());
	assert arrType.kind === TypeKind.Array;
	assert arrType.typeReturn.kind === TypeKind.Number;
}

test "createSizedArray" {
	const arrType = createSizedArray(numberType(), 4);
	assert arrType.kind === TypeKind.SizedArray;
	assert arrType.typeReturn.kind === TypeKind.Number;
	assert arrType.typeFlags === 4;
}

test "createSpan" {
	const spanType = createSpan(numberType());
	assert spanType.kind === TypeKind.Span;
	assert spanType.typeReturn.kind === TypeKind.Number;
}

test "createFunction" {
	const fnType = createFunction([numberType(), stringType()], ["a", "b"], booleanType());
	assert fnType.kind === TypeKind.Function;
	assert fnType.typeChildren.length === 2;
	assert fnType.typeNames[0] === "a";
	assert fnType.typeReturn.kind === TypeKind.Boolean;
}

test "createStruct" {
	const obj = createStruct("Point", ["x"], [numberType()], false);
	assert obj.kind === TypeKind.Struct;
	assert obj.typeName === "Point";
	assert obj.typeNames.length === 1;
	assert obj.typeChildren.length === 1;
	assert obj.typeFlags === 0;
}

test "createEnum" {
	const e = createEnum("Color", ["Red", "Green", "Blue"], null as unknown as number[]);
	assert e.kind === TypeKind.Enum;
	assert e.typeName === "Color";
	assert e.typeNames.length === 3;
}

test "createResult" {
	const r = createResult(numberType(), stringType());
	assert isResult(r);
	assert getResultOkType(r).kind === TypeKind.Number;
	assert getResultErrType(r).kind === TypeKind.String;
}

test "createTypeRef" {
	const t = createTypeRef("MyType");
	assert t.kind === TypeKind.TypeReference;
	assert t.typeName === "MyType";
}

test "createRef and Ptr" {
	const r = createRef(numberType());
	assert r.kind === TypeKind.Ref;
	assert r.typeReturn.kind === TypeKind.Number;
	const p = createPtr(stringType());
	assert p.kind === TypeKind.Ptr;
	assert p.typeReturn.kind === TypeKind.String;
}

test "isNumeric" {
	assert isNumeric(numberType());
	assert isNumeric(createPrimitive(TypeKind.Int32));
	assert isNumeric(createPrimitive(TypeKind.Float64));
	assert !isNumeric(stringType());
	assert !isNumeric(booleanType());
}

test "isStringLike" {
	assert isStringLike(stringType());
	assert isStringLike(createStringLiteral("north"));
	assert !isStringLike(numberType());
}

test "isBoolType" {
	assert isBoolType(booleanType());
	assert !isBoolType(numberType());
}

test "isCallable" {
	const fn = createFunction([], [], voidType());
	assert isCallable(fn);
	assert !isCallable(numberType());
}

test "getReturnType" {
	const fn = createFunction([], [], booleanType());
	assert getReturnType(fn).kind === TypeKind.Boolean;
	assert getReturnType(numberType()).kind === TypeKind.Unknown;
}

test "getElementType" {
	const arr = createArray(stringType());
	assert getElementType(arr).kind === TypeKind.String;
	assert getElementType(numberType()).kind === TypeKind.Unknown;
}

test "getProperty" {
	const obj = createStruct("Point", ["x", "y"], [numberType(), stringType()], false);
	assert getProperty(obj, "x").kind === TypeKind.Number;
	assert getProperty(obj, "y").kind === TypeKind.String;
	assert getProperty(obj, "z").kind === TypeKind.Unknown;
	assert getProperty(numberType(), "x").kind === TypeKind.Unknown;
}

test "substitute generic param" {
	const gp = createGenericParam("T");
	const result = substituteType(gp, "T", numberType());
	assert result.kind === TypeKind.Number;
}

test "substitute non-matching" {
	const gp = createGenericParam("T");
	const result = substituteType(gp, "U", numberType());
	assert result.kind === TypeKind.GenericParam;
}

test "substitute in array" {
	const arr = createArray(createGenericParam("T"));
	const result = substituteType(arr, "T", stringType());
	assert result.kind === TypeKind.Array;
	assert result.typeReturn.kind === TypeKind.String;
}

test "substitute in function" {
	const fn = createFunction([createGenericParam("T")], ["a"], createGenericParam("T"));
	const result = substituteType(fn, "T", numberType());
	assert result.kind === TypeKind.Function;
	assert result.typeChildren[0].kind === TypeKind.Number;
	assert result.typeReturn.kind === TypeKind.Number;
}

test "substitute in Result" {
	const r = createResult(createGenericParam("T"), createGenericParam("E"));
	const step1 = substituteType(r, "T", numberType());
	const step2 = substituteType(step1, "E", stringType());
	assert isResult(step2);
	assert getResultOkType(step2).kind === TypeKind.Number;
	assert getResultErrType(step2).kind === TypeKind.String;
}

test "instantiateGeneric multi-param" {
	const r = createResult(createGenericParam("T"), createGenericParam("E"));
	const result = instantiateGeneric(r, ["T", "E"], [numberType(), stringType()]);
	assert isResult(result);
	assert getResultOkType(result).kind === TypeKind.Number;
	assert getResultErrType(result).kind === TypeKind.String;
}

test "primitive unchanged" {
	const result = substituteType(numberType(), "T", stringType());
	assert result.kind === TypeKind.Number;
}

test "unify direct generic param" {
	const b = createUnifyBindings();
	unifyType(createGenericParam("T"), numberType(), b);
	assert b.names.length === 1;
	assert b.names[0] === "T";
	assert b.types[0].kind === TypeKind.Number;
}

test "unify Array<T> vs Array<string>" {
	const b = createUnifyBindings();
	unifyType(createArray(createGenericParam("T")), createArray(stringType()), b);
	assert b.names.length === 1;
	assert b.names[0] === "T";
	assert b.types[0].kind === TypeKind.String;
}

test "unify Result<T, E> vs Result<number, string>" {
	const b = createUnifyBindings();
	const formal = createResult(createGenericParam("T"), createGenericParam("E"));
	const concrete = createResult(numberType(), stringType());
	unifyType(formal, concrete, b);
	assert b.names.length === 2;
	assert b.names[0] === "T";
	assert b.types[0].kind === TypeKind.Number;
	assert b.names[1] === "E";
	assert b.types[1].kind === TypeKind.String;
}

test "unify mismatched kinds" {
	const b = createUnifyBindings();
	unifyType(createArray(createGenericParam("T")), numberType(), b);
	assert b.names.length === 0;
}

test "unify concrete no bindings" {
	const b = createUnifyBindings();
	unifyType(numberType(), numberType(), b);
	assert b.names.length === 0;
}

test "hasGenericParams true" {
	assert hasGenericParams(createGenericParam("T"));
	assert hasGenericParams(createArray(createGenericParam("T")));
	assert hasGenericParams(createFunction([createGenericParam("T")], ["a"], numberType()));
}

test "hasGenericParams false" {
	assert !hasGenericParams(numberType());
	assert !hasGenericParams(createArray(stringType()));
	assert !hasGenericParams(createFunction([numberType()], ["a"], stringType()));
}

test "default returns param count" {
	const fn1 = createFunction([numberType(), stringType()], ["a", "b"], voidType());
	assert getMinArity(fn1) === 2;
}

test "setMinArity stores correctly" {
	const fn2 = createFunction([numberType(), stringType()], ["a", "b"], voidType());
	setMinArity(fn2, 1);
	assert getMinArity(fn2) === 1;
}

test "setMinArity zero" {
	const fn3 = createFunction([numberType()], ["a"], voidType());
	setMinArity(fn3, 0);
	assert getMinArity(fn3) === 0;
}

test "preserves low bits" {
	const fn4 = createFunction([numberType()], ["a"], voidType());
	fn4.typeFlags = TypeFlag.IsStruct as int32;
	setMinArity(fn4, 1);
	assert getMinArity(fn4) === 1;
	assert (fn4.typeFlags & TypeFlag.IsStruct) !== 0;
}

test "createTuple" {
	const tup = createTuple([numberType(), stringType()]);
	assert tup.kind === TypeKind.Tuple;
	assert tup.typeChildren.length === 2;
	assert tup.typeChildren[0].kind === TypeKind.Number;
	assert tup.typeChildren[1].kind === TypeKind.String;
}

test "typeNameOf Tuple" {
	const tup = createTuple([numberType()]);
	assert typeNameOf(tup) === "Tuple";
}

test "substituteType Tuple" {
	const tup = createTuple([createGenericParam("T"), numberType()]);
	const result = substituteType(tup, "T", stringType());
	assert result.kind === TypeKind.Tuple;
	assert result.typeChildren[0].kind === TypeKind.String;
	assert result.typeChildren[1].kind === TypeKind.Number;
}

test "sizeOfType primitives 64-bit" {
	setTargetSizes(8, 8);
	assert sizeOfType(createPrimitive(TypeKind.Boolean)) === 1;
	assert sizeOfType(createPrimitive(TypeKind.Char)) === 1;
	assert sizeOfType(createPrimitive(TypeKind.Int32)) === 4;
	assert sizeOfType(createPrimitive(TypeKind.Uint32)) === 4;
	assert sizeOfType(createPrimitive(TypeKind.Float32)) === 4;
	assert sizeOfType(numberType()) === 8;
	assert sizeOfType(createPrimitive(TypeKind.Int64)) === 8;
	assert sizeOfType(createPrimitive(TypeKind.Float64)) === 8;
	assert sizeOfType(stringType()) === 16;
	assert sizeOfType(createArray(numberType())) === 16;
	assert sizeOfType(createPrimitive(TypeKind.Enum)) === 4;
}

test "sizeOfType primitives 32-bit" {
	setTargetSizes(4, 4);
	assert sizeOfType(numberType()) === 4;
	assert sizeOfType(stringType()) === 8;
	assert sizeOfType(createArray(numberType())) === 8;
	assert sizeOfType(createFunction([], [], numberType())) === 8;
	assert sizeOfType(createPrimitive(TypeKind.Ref)) === 4;
	assert sizeOfType(createPrimitive(TypeKind.Int32)) === 4;
	assert sizeOfType(createPrimitive(TypeKind.Int64)) === 4;
	setTargetSizes(8, 8);
}

test "sizeOfType object no padding" {
	const obj = createStruct("Pair", ["x", "y"], [createPrimitive(TypeKind.Int32), createPrimitive(TypeKind.Int32)], true);
	assert sizeOfType(obj) === 8;
}

test "sizeOfType object with padding" {
	// { char (1 byte) + padding(3) + int32 (4 bytes) } = 8
	const obj = createStruct("Mixed", ["a", "b"], [createPrimitive(TypeKind.Char), createPrimitive(TypeKind.Int32)], true);
	assert sizeOfType(obj) === 8;
}

test "sizeOfType object tail padding" {
	// { int64 (8 bytes) + char (1 byte) + padding(7) } = 16 (aligned to maxAlign=8)
	const obj = createStruct("Tail", ["x", "y"], [createPrimitive(TypeKind.Int64), createPrimitive(TypeKind.Char)], true);
	assert sizeOfType(obj) === 16;
}

test "sizeOfType function closure" {
	assert sizeOfType(createFunction([], [], numberType())) === 16;
}

test "alignOfType" {
	assert alignOfType(createPrimitive(TypeKind.Char)) === 1;
	assert alignOfType(createPrimitive(TypeKind.Int32)) === 4;
	assert alignOfType(numberType()) === 8;
}

test "alignOfType 32-bit" {
	setTargetSizes(4, 4);
	assert alignOfType(numberType()) === 4;
	assert alignOfType(createPrimitive(TypeKind.Ref)) === 4;
	assert alignOfType(createPrimitive(TypeKind.Int32)) === 4;
	setTargetSizes(8, 8);
}

// ===== Maybe<T> + Nullable Pointer Tests =====

test "createMaybeType for interface creates wrapper" {
	const inner = createStruct("Token", ["kind"], [numberType()], true);
	const maybe = createMaybeType(inner);
	assert maybe.kind === TypeKind.Struct;
	assert maybe.typeName === "Maybe_Token";
	assert maybe.typeNames.length === 2;
	assert maybe.typeNames[0] === "value";
	assert maybe.typeNames[1] === "present";
	assert isMaybeType(maybe);
	assert unwrapMaybeType(maybe).typeName === "Token";
}

test "createMaybeType for Ref returns bare pointer" {
	const refType = createRef(createStruct("Foo", [], [], true));
	const result = createMaybeType(refType);
	// Should return the Ref type unchanged — no wrapper
	assert result.kind === TypeKind.Ref;
	assert result === refType;
	assert !isMaybeType(result);
}

test "createMaybeType for Ptr returns bare pointer" {
	const ptrType = createPtr(createStruct("Bar", [], [], true));
	const result = createMaybeType(ptrType);
	// Should return the Ptr type unchanged — no wrapper
	assert result.kind === TypeKind.Ptr;
	assert result === ptrType;
	assert !isMaybeType(result);
}

test "isMaybeType false for Ref" {
	assert !isMaybeType(createRef(numberType()));
}

test "isMaybeType false for Ptr" {
	assert !isMaybeType(createPtr(numberType()));
}

test "isMaybeType false for plain interface" {
	assert !isMaybeType(createStruct("Token", [], [], true));
}

test "createMaybeType caches by name" {
	const inner = createStruct("Cached", [], [], true);
	const m1 = createMaybeType(inner);
	const m2 = createMaybeType(inner);
	assert m1 === m2;
}
