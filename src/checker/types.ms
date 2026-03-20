// Type System — utility functions for Type manipulation
// Type class + enums are defined in ast/node.ms (reference parity: single-file AST).

import { bareAfterDelim, splitTopLevel } from "../utils/string";
import {
	Type, TypeKind, TypeFlag, CallingConvention, AttachedOp,
	Symbol,
} from "../ast/node";

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
	for (const pt of propTypes) { propagateHasAsgn(t, pt); }
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

export function isPromise(t: Type): boolean {
	if (t === null) return false;
	if (t.kind === TypeKind.Promise) return true;
	return t.kind === TypeKind.GenericInstance && t.typeName === "Promise";
}

export function getPromiseInner(t: Type): Type {
	if (t === null) return null;
	if (t.kind === TypeKind.GenericInstance && t.typeChildren.length > 0) return t.typeChildren[0];
	return t.typeReturn;
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

export function isPromiseResult(t: Type): boolean {
	if (!isPromise(t)) return false;
	const inner = getPromiseInner(t);
	return inner !== null && isResult(inner);
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
	for (const ut of types) { propagateHasAsgn(t, ut); }
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
						// When fieldTypes provided, also match by type kind to disambiguate
						// variants with same field names but different types
						if (fieldTypes.length > ti && fi < variant.typeChildren.length) {
							if (variant.typeChildren[fi].kind === fieldTypes[ti].kind) {
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
	let i = 1;
	while (i < unionType.typeNames.length) {
		const stored = unionType.typeNames[i];
		if (stored === enumValue) return i - 1;
		if (bareAfterDelim(stored, ".") === queryBare) return i - 1;
		i = i + 1;
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
	propagateHasAsgn(t, inner);
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
	for (const et of elementTypes) { propagateHasAsgn(t, et); }
	return t;
}



export function createDistinct(inner: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Distinct;
	t.typeReturn = inner;
	propagateHasAsgn(t, inner);
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
// Enables structural unification: Map<K,V> vs Map<string,string> → K=string, V=string.
export function createGenericInstance(baseType: Type, typeArgs: Type[]): Type {
	// For Ref<Struct> (interface types), use inner struct's name and flags
	const innerBase = (baseType !== null && baseType.kind === TypeKind.Ref && baseType.typeReturn !== null) ? baseType.typeReturn : baseType;
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
	// DJB2 hash → base36 (matches hashToBase36 in codegen)
	let hash: int32 = 5381;
	let j = 0;
	while (j < key.byteLength) {
		hash = ((hash * 33) + (key.byteAt(j) as int32)) & 0x7FFFFFFF;
		j += 1;
	}
	return "msTuple_" + (hash as number).toString(36);
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

export function propagateHasAsgn(parent: Type, child: Type): void {
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
		TypeKind.String => targetPtrSize + targetPtrSize, // msString: data ptr + length
		TypeKind.CString => targetPtrSize,
		TypeKind.Enum => 4, // C int
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

// Identity-based cycle detection for self-referential types (Reference parity: recursion limit and identity check)
// Type has typeReturn/typeExtra/typeChildren that can reference back to itself.
// Depth limit alone causes exponential branching; identity check prevents revisiting.
let substituteVisited: Type[] = [];

function substituteIsSeen(t: Type): boolean {
	for (let i = 0; i < substituteVisited.length; i += 1) {
		if (substituteVisited[i] === t) return true;
	}
	return false;
}

export function substituteType(t: Type, paramName: string, concrete: Type): Type {
	if (t === null) return t;
	// Guard before match: GenericParam with matching name
	if (t.kind === TypeKind.GenericParam && t.typeName === paramName) return concrete;
	// Cycle detection: identity-based visited set
	if (substituteIsSeen(t)) return t;
	substituteVisited.push(t);
	const result = match (t.kind) {
		TypeKind.Number | TypeKind.String | TypeKind.Boolean |
		TypeKind.Void | TypeKind.Null | TypeKind.Unknown |
		TypeKind.Never | TypeKind.Error | TypeKind.GenericParam |
		TypeKind.CString => t,
		TypeKind.Array => createArray(substituteType(t.typeReturn, paramName, concrete)),
		TypeKind.SizedArray => createSizedArray(substituteType(t.typeReturn, paramName, concrete), t.typeFlags),
		TypeKind.Span => createSpan(substituteType(t.typeReturn, paramName, concrete)),
		TypeKind.Function => {
			const newParams: Type[] = [];
			for (const param of t.typeChildren) {
				newParams.push(substituteType(param, paramName, concrete));
			}
			return createFunction(newParams, t.typeNames, substituteType(t.typeReturn, paramName, concrete));
		},
		// Result and Promise are now GenericInstance — handled by the GenericInstance arm
		TypeKind.Union => {
			const newMembers: Type[] = [];
			for (const member of t.typeChildren) {
				newMembers.push(substituteType(member, paramName, concrete));
			}
			return createUnion(newMembers);
		},
		TypeKind.Ref => createRef(substituteType(t.typeReturn, paramName, concrete)),
		TypeKind.Ptr => createPtr(substituteType(t.typeReturn, paramName, concrete)),
		TypeKind.Borrow => createBorrow(substituteType(t.typeReturn, paramName, concrete)),
		TypeKind.Tuple => {
			const newChildren: Type[] = [];
			for (const child of t.typeChildren) {
				newChildren.push(substituteType(child, paramName, concrete));
			}
			return createTuple(newChildren);
		},
		TypeKind.Struct => substituteStruct(t, paramName, concrete),
		TypeKind.GenericInstance => {
			const newArgs: Type[] = [];
			for (const arg of t.typeChildren) {
				newArgs.push(substituteType(arg, paramName, concrete));
			}
			return createGenericInstance(t.typeExtra, newArgs);
		},
		_ => t,
	};
	substituteVisited.pop();
	return result;
}

// Instantiate a generic type with concrete type arguments.
// genericParamNames: ["T", "E"], typeArgs: [numberType(), stringType()]
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
	// GenericInstance: structural unification of type arguments
	// Map<K,V> (formal, with GenericParam children) vs Map<string,string> (concrete)
	// Base type must match: Map<K,V> unifies with Map<string,string> but NOT Set<string>
	if (formal.kind === TypeKind.GenericInstance && concrete.kind === TypeKind.GenericInstance) {
		if (formal.typeName !== concrete.typeName) return;
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
	// GenericInstance: check type args for GenericParam (e.g., Map<K,V> has GenericParam children)
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
		TypeKind.Int8   => 1,
		TypeKind.Uint8  => 2,
		TypeKind.Int16  => 3,
		TypeKind.Uint16 => 4,
		TypeKind.Int32  => 5,
		TypeKind.Uint32 => 6,
		TypeKind.Int64  => 7,
		TypeKind.Uint64 => 8,
		TypeKind.Number => 9,
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

export function isStringType(t: Type): boolean {
	return t.kind === TypeKind.String;
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
				if (i < t.typeChildren.length) return t.typeChildren[i];
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
		|| kind === TypeKind.Never
		|| kind === TypeKind.Unknown
		|| kind === TypeKind.Char
		|| kind === TypeKind.CString
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
		// Result and Promise are now GenericInstance — handled above via t.typeName
		TypeKind.Enum => t.typeName,
		TypeKind.TypeReference => t.typeName,
		TypeKind.Distinct => t.typeName,
		_ => "",
	};
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
		TypeKind.Int32 | TypeKind.Uint32 | TypeKind.Float32 | TypeKind.Enum => 4,
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
		TypeKind.Int32 | TypeKind.Uint32 | TypeKind.Float32 | TypeKind.Enum => 4,
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

test "isStringType" {
	assert isStringType(stringType());
	assert !isStringType(numberType());
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
