// Type System - TypeKind, Type interface, constructors

// Design: Flat interface (no discriminated union) to avoid DRC codegen issues
// with self-referencing anonymous struct types (MsAnon collision).
// Function accessors instead of const singletons to avoid closure capture bugs.

import { bareAfterDelim } from "../utils/string";



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

// ===== TypeKind Enum =====

export enum TypeKind {
	// Primitives
	Number, String, Boolean, Void, Char, Null, Unknown, Never,
	// Sized integers/floats (C interop)
	Int8, Int16, Int32, Int64, Uint8, Uint16, Uint32, Uint64, Float32, Float64,
	// Compound
	Struct, Array, SizedArray, Span, Function, Tuple, Map, Set, CString,
	// Generics
	GenericParam, GenericInstance,
	// Memory
	Ref, Ptr, Borrow,
	// Ownership modifiers (standard reference parity — wrap inner type)
	Sink, Lent,
	// Special
	TypeReference, Union, Enum, Result,
	// Distinct
	Distinct,
	// Error sentinel
	Error,
}

// ===== Type Interface (Tagged Union — standard implementation parity) =====
// Flat interface with fields reused per TypeKind. Only read documented fields per kind.
// Under Bun: all fields allocated (JS objects). Under C backend: fixed struct layout.
//
// Field validity per TypeKind (the "tag contract"):
// ┌────────────────┬──────────┬───────────┬──────────────┬───────────┬──────────┬───────────┐
// │ TypeKind       │ typeName │ typeNames │ typeChildren │ typeReturn│ typeExtra│ typeFlags │
// ├────────────────┼──────────┼───────────┼──────────────┼───────────┼──────────┼───────────┤
// │ Primitives(13) │    —     │     —     │      —       │     —     │    —     │     —     │
// │ Object         │ name     │ propNames │ propTypes    │     —     │ baseClass│ isIface   │
// │ Function       │ rtHint   │ paramNames│ paramTypes   │ returnTy  │    —     │ minArity  │
// │ Array          │    —     │     —     │      —       │ elemType  │    —     │     —     │
// │ SizedArray     │    —     │     —     │      —       │ elemType  │    —     │ size      │
// │ Span           │    —     │     —     │      —       │ elemType  │    —     │     —     │
// │ Tuple          │    —     │     —     │ elemTypes    │     —     │    —     │     —     │
// │ Map            │    —     │     —     │      —       │ keyType   │ valType  │     —     │
// │ Set            │    —     │     —     │      —       │ elemType  │    —     │     —     │
// │ Enum           │ name     │ members   │      —       │     —     │    —     │     —     │
// │ Union          │ aliasNm  │ disc+keys│ variantTypes │     —     │ discEnum │     —     │
// │ Ref/Ptr        │    —     │     —     │      —       │ innerType │    —     │     —     │
// │ Sink/Lent      │    —     │     —     │      —       │ innerType │    —     │     —     │
// │ Distinct       │    —     │     —     │      —       │ innerType │    —     │     —     │
// │ Result         │    —     │     —     │      —       │ okType    │ errType  │     —     │
// │ GenericParam   │ paramName│     —     │      —       │     —     │ constraint│    —     │
// │ GenericInstance │    —     │     —     │ typeArgs     │     —     │ baseType │     —     │
// │ TypeReference  │ refName  │     —     │      —       │     —     │    —     │     —     │
// └────────────────┴──────────┴───────────┴──────────────┴───────────┴──────────┴───────────┘

// ===== Calling Convention (Standard reference parity) =====
export enum CallingConvention {
	CcDefault,       // normal function call
	CcClosure,       // closure call (fn + env pair)
	CcInline,        // inline hint
	CcNoInline,      // no-inline hint
}

// ===== Attached Lifecycle Ops (Standard reference parity) =====
// Index into Type.attachedOps[] — stores the symbol/name for each lifecycle hook.
export enum AttachedOp {
	AttachedWasMoved,    // =wasMoved
	AttachedDestructor,  // =destroy
	AttachedAsgn,        // =copy
	AttachedDup,         // =dup
	AttachedSink,        // =sink
	AttachedTrace,       // =trace (ORC)
}

export interface Type {
	kind: TypeKind;
	typeName: string;         // Object name, Enum name, TypeRef name, GenericParam name
	typeNames: string[];      // Function param names, Enum members, Object prop names
	typeChildren: Type[];     // Function params, Union types, Tuple elements, Object prop types
	typeReturn: Type;         // Function return, Array element, Ref/Ptr/Distinct inner, Result okType
	typeExtra: Type;          // Result errType, Map value, GenericInstance base
	typeFlags: int32;         // Bitfield: 1=isInterface, 2=optional, 4=readonly, 8=static; bits 8-15=minArity
	callConv: CallingConvention; // Function calling convention (Standard parity)
	attachedOps: string[];    // Lifecycle hook names indexed by AttachedOp (Standard parity)
}

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
		typeReturn: null as unknown as Type,
		typeExtra: null as unknown as Type,
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
	if (isInterface) { t.typeFlags = 1; }
	return t;
}

export function createArray(element: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Array;
	t.typeReturn = element;
	return t;
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
	const t = emptyType();
	t.kind = TypeKind.Function;
	t.typeChildren = paramTypes;
	t.typeNames = paramNames;
	t.typeReturn = returnType;
	return t;
}

// Standard reference parity: procedure type literals default to closure calling convention.
// Named function declarations use createFunction which defaults to the default calling convention.
export function createClosureType(paramTypes: Type[], paramNames: string[], returnType: Type): Type {
	const t = createFunction(paramTypes, paramNames, returnType);
	t.callConv = CallingConvention.CcClosure;
	return t;
}

export function createEnum(name: string, members: string[]): Type {
	const t = emptyType();
	t.kind = TypeKind.Enum;
	t.typeName = name;
	t.typeNames = members;
	return t;
}

export function createResult(okType: Type, errType: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Result;
	t.typeReturn = okType;
	t.typeExtra = errType;
	return t;
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
	if (variant === null || variant.typeNames === null) return null as unknown as Type;
	let i = 0;
	while (i < variant.typeNames.length) {
		if (variant.typeNames[i] === fieldName && i < variant.typeChildren.length) {
			return variant.typeChildren[i];
		}
		i = i + 1;
	}
	return null as unknown as Type;
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
// Only for interfaces. Cached by inner type name to avoid duplicates.
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
	t.typeFlags = 17;       // isInterface (bit 0) + isMaybe (bit 4)
	t.typeReturn = inner;    // store inner type for unwrapping
	_maybeCache.push(t);
	_maybeCacheNames.push(name);
	return t;
}

export function createRef(inner: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Ref;
	t.typeReturn = inner;
	return t;
}

export function createPtr(inner: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Ptr;
	t.typeReturn = inner;
	return t;
}

export function createBorrow(inner: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Borrow;
	t.typeReturn = inner;
	return t;
}

export function createTuple(elementTypes: Type[]): Type {
	const t = emptyType();
	t.kind = TypeKind.Tuple;
	t.typeChildren = elementTypes;
	return t;
}

export function createSet(elemType: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Set;
	t.typeReturn = elemType;
	return t;
}

export function createDistinct(inner: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Distinct;
	t.typeReturn = inner;
	return t;
}

export function createGenericParam(name: string): Type {
	const t = emptyType();
	t.kind = TypeKind.GenericParam;
	t.typeName = name;
	return t;
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
	while (j < key.length) {
		hash = ((hash * 33) + (key.charCodeAt(j) as int32)) & 0x7FFFFFFF;
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
			"Array(" + (t.typeReturn !== null ? typeKey(t.typeReturn) : "any") + ")";
		},
		TypeKind.Tuple => {
			let k = "tuple:";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) k = k + ",";
				k = k + typeKey(t.typeChildren[i]);
				i += 1;
			}
			k;
		},
		_ => t.kind.toString(),
	};
}

// ===== Type Classification Helpers =====

export function isInterfaceType(t: Type): boolean {
	if (t === null) return false;
	if (t.kind !== TypeKind.Struct) return false;
	return (t.typeFlags & 1) !== 0;
}

export function isMaybeType(t: Type): boolean {
	if (t === null) return false;
	return (t.typeFlags & 16) !== 0;
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
	if (t.kind === TypeKind.Sink || t.kind === TypeKind.Lent) return t.typeReturn;
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
			if (t.typeChildren === null) { targetPtrSize; } else {
				let size = 0;
				for (const field of t.typeChildren) {
					size = size + getTypeSize(field);
				}
				size;
			}
		},
		TypeKind.Tuple => {
			if (t.typeChildren === null) { 0; } else {
				let size = 0;
				for (const elem of t.typeChildren) {
					size = size + getTypeSize(elem);
				}
				size;
			}
		},
		TypeKind.Result => {
			// ok bool + max(okType, errType)
			const okSize = getTypeSize(t.typeReturn);
			const errSize = getTypeSize(t.typeExtra);
			const payloadSize = okSize > errSize ? okSize : errSize;
			1 + payloadSize;
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
			4 + maxSize;
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
	const result = createStruct(t.typeName, newNames, newFieldTypes, t.typeFlags === 1);
	result.typeReturn = t.typeReturn;
	result.typeExtra = t.typeExtra;
	return result;
}

// Visited set for cycle detection in self-referential types
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
	// Cycle detection for self-referential types (parity: semtypinst.nim recursionLimit)
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
			createFunction(newParams, t.typeNames, substituteType(t.typeReturn, paramName, concrete))
		},
		TypeKind.Result => createResult(substituteType(t.typeReturn, paramName, concrete), substituteType(t.typeExtra, paramName, concrete)),
		TypeKind.Union => {
			const newMembers: Type[] = [];
			for (const member of t.typeChildren) {
				newMembers.push(substituteType(member, paramName, concrete));
			}
			createUnion(newMembers)
		},
		TypeKind.Map => {
			const mt = createPrimitive(TypeKind.Map);
			mt.typeReturn = substituteType(t.typeReturn, paramName, concrete);
			mt.typeExtra = substituteType(t.typeExtra, paramName, concrete);
			mt
		},
		TypeKind.Ref => createRef(substituteType(t.typeReturn, paramName, concrete)),
		TypeKind.Ptr => createPtr(substituteType(t.typeReturn, paramName, concrete)),
		TypeKind.Borrow => createBorrow(substituteType(t.typeReturn, paramName, concrete)),
		TypeKind.Set => createSet(substituteType(t.typeReturn, paramName, concrete)),
		TypeKind.Tuple => {
			const newChildren: Type[] = [];
			for (const child of t.typeChildren) {
				newChildren.push(substituteType(child, paramName, concrete));
			}
			createTuple(newChildren)
		},
		TypeKind.Struct => substituteStruct(t, paramName, concrete),
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
	// Structural match — same kind, recurse into children
	if (formal.kind !== concrete.kind) return;
	if (formal.kind === TypeKind.Array || formal.kind === TypeKind.SizedArray || formal.kind === TypeKind.Span) {
		unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		return;
	}
	if (formal.kind === TypeKind.Result) {
		unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		unifyType(formal.typeExtra, concrete.typeExtra, bindings);
		return;
	}
	if (formal.kind === TypeKind.Function) {
		const fnLimit = formal.typeChildren.length < concrete.typeChildren.length ? formal.typeChildren.length : concrete.typeChildren.length;
		for (let i = 0; i < fnLimit; i += 1) {
			unifyType(formal.typeChildren[i], concrete.typeChildren[i], bindings);
		}
		unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		return;
	}
	if (formal.kind === TypeKind.Map) {
		unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		unifyType(formal.typeExtra, concrete.typeExtra, bindings);
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
export function hasGenericParams(t: Type): boolean {
	if (t === null) return false;
	if (t.kind === TypeKind.GenericParam) return true;
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
	if (!isIntegerType(source) && source.kind !== TypeKind.Number) return false;
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
		let foundType = null as unknown as Type;
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
	// Result fields: ok (boolean), value (T), error (E)
	if (t.kind === TypeKind.Result) {
		if (name === "ok") return booleanType();
		if (name === "value") return t.typeReturn !== null ? t.typeReturn : unknownType();
		if (name === "error") return t.typeExtra !== null ? t.typeExtra : unknownType();
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
	if (t.kind === TypeKind.Struct) return t.typeName;
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
		TypeKind.Map => "Map",
		TypeKind.Tuple => "Tuple",
		TypeKind.Set => "Set",
		TypeKind.CString => "cstring",
		TypeKind.Result => "Result",
		TypeKind.Enum => t.typeName,
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
	const e = createEnum("Color", ["Red", "Green", "Blue"]);
	assert e.kind === TypeKind.Enum;
	assert e.typeName === "Color";
	assert e.typeNames.length === 3;
}

test "createResult" {
	const r = createResult(numberType(), stringType());
	assert r.kind === TypeKind.Result;
	assert r.typeReturn.kind === TypeKind.Number;
	assert r.typeExtra.kind === TypeKind.String;
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
	assert step2.kind === TypeKind.Result;
	assert step2.typeReturn.kind === TypeKind.Number;
	assert step2.typeExtra.kind === TypeKind.String;
}

test "instantiateGeneric multi-param" {
	const r = createResult(createGenericParam("T"), createGenericParam("E"));
	const result = instantiateGeneric(r, ["T", "E"], [numberType(), stringType()]);
	assert result.kind === TypeKind.Result;
	assert result.typeReturn.kind === TypeKind.Number;
	assert result.typeExtra.kind === TypeKind.String;
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
	fn4.typeFlags = 1;
	setMinArity(fn4, 1);
	assert getMinArity(fn4) === 1;
	assert (fn4.typeFlags & 0xFF) === 1;
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

test "createSet" {
	const s = createSet(stringType());
	assert s.kind === TypeKind.Set;
	assert s.typeReturn.kind === TypeKind.String;
}

test "typeNameOf Set" {
	assert typeNameOf(createSet(stringType())) === "Set";
}

test "substituteType Set" {
	const s = createSet(createGenericParam("T"));
	const result = substituteType(s, "T", stringType());
	assert result.kind === TypeKind.Set;
	assert result.typeReturn.kind === TypeKind.String;
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
