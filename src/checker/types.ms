// Type System - TypeKind, Type interface, constructors

// Design: Flat interface (no discriminated union) to avoid DRC codegen issues
// with self-referencing anonymous struct types (MsAnon collision).
// Function accessors instead of const singletons to avoid closure capture bugs.



// ===== Target Configuration (Nim parity: ConfigRef.target) =====
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
	Int32, Int64, Uint32, Float32, Float64,
	// Compound
	Object, Array, SizedArray, Span, Function, Tuple, Map, Set, CString,
	// Generics
	GenericParam, GenericInstance,
	// Memory
	Ref, Ptr, Borrow,
	// Special
	TypeReference, Union, Enum, Result,
	// Distinct
	Distinct,
	// Error sentinel
	Error,
}

// ===== Type Interface (Tagged Union — Nim parity) =====
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
// │ Union          │    —     │     —     │ memberTypes  │     —     │    —     │     —     │
// │ Ref/Ptr        │    —     │     —     │      —       │ innerType │    —     │     —     │
// │ Distinct       │    —     │     —     │      —       │ innerType │    —     │     —     │
// │ Result         │    —     │     —     │      —       │ okType    │ errType  │     —     │
// │ GenericParam   │ paramName│     —     │      —       │     —     │ constraint│    —     │
// │ GenericInstance │    —     │     —     │ typeArgs     │     —     │ baseType │     —     │
// │ TypeReference  │ refName  │     —     │      —       │     —     │    —     │     —     │
// └────────────────┴──────────┴───────────┴──────────────┴───────────┴──────────┴───────────┘

// ===== Calling Convention (Nim parity: TCallingConvention) =====
export enum CallingConvention {
	CcDefault,       // normal function call
	CcClosure,       // closure call (fn + env pair)
	CcInline,        // inline hint
	CcNoInline,      // no-inline hint
}

// ===== Attached Lifecycle Ops (Nim parity: TTypeAttachedOp) =====
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
	typeFlags: number;        // Bitfield: 1=isInterface, 2=optional, 4=readonly, 8=static; bits 8-15=minArity
	callConv: CallingConvention; // Function calling convention (Nim parity: ccClosure vs ccDefault)
	attachedOps: string[];    // Lifecycle hook names indexed by AttachedOp (Nim parity: TTypeAttachedOp)
	typeChildrenFlags: number[]; // Parameter flags (SF_SINK / SF_LENT) for Function types
}

// ===== Constructors =====

function emptyType(): Type {
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
		typeChildrenFlags: [],
	};
}

export function createPrimitive(kind: TypeKind): Type {
	const t = emptyType();
	t.kind = kind;
	return t;
}

export function createObject(name: string, propNames: string[], propTypes: Type[], isInterface: boolean): Type {
	const t = emptyType();
	t.kind = TypeKind.Object;
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

// ===== System Types (Nim parity: ModuleGraph.sysTypes) =====
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
	t.typeFlags = (t.typeFlags & 0xFF) | ((minArity + 1) << 8);
}

export function getMinArity(t: Type): number {
	const encoded = (t.typeFlags >> 8) & 0xFF;
	if (encoded === 0) return t.typeChildren.length;
	return encoded - 1;
}

// ===== Attached Ops Helpers (Nim parity: getAttachedOp/setAttachedOp) =====

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

// ===== Type Classification Helpers =====

export function isInterfaceType(t: Type): boolean {
	if (t === null) return false;
	if (t.kind !== TypeKind.Object) return false;
	return (t.typeFlags & 1) !== 0;
}

export function isClassType(t: Type): boolean {
	if (t === null) return false;
	if (t.kind !== TypeKind.Object) return false;
	return (t.typeFlags & 1) === 0 && t.typeName !== "";
}

// ===== Generic Instantiation =====

// Substitute a generic parameter name with a concrete type throughout a type tree.
// Returns a new Type (does not mutate original).
export function substituteType(t: Type, paramName: string, concrete: Type): Type {
	if (t === null) return t;
	// Guard before match: GenericParam with matching name
	if (t.kind === TypeKind.GenericParam && t.typeName === paramName) return concrete;
	return match (t.kind) {
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
		_ => t,
	};
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

export function unifyType(formal: Type, concrete: Type, bindings: UnifyBindings): void {
	if (formal === null || concrete === null) return;
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
	if (formal.kind === TypeKind.Union || formal.kind === TypeKind.Object) {
		const uoLimit = formal.typeChildren.length < concrete.typeChildren.length ? formal.typeChildren.length : concrete.typeChildren.length;
		for (let i = 0; i < uoLimit; i += 1) {
			unifyType(formal.typeChildren[i], concrete.typeChildren[i], bindings);
		}
		return;
	}
}

export function hasGenericParams(t: Type): boolean {
	if (t === null) return false;
	if (t.kind === TypeKind.GenericParam) return true;
	if (t.typeReturn !== null && hasGenericParams(t.typeReturn)) return true;
	if (t.typeExtra !== null && hasGenericParams(t.typeExtra)) return true;
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		if (hasGenericParams(t.typeChildren[i])) return true;
	}
	return false;
}

// ===== Type Query Helpers =====

export function isNumeric(t: Type): boolean {
	return t.kind === TypeKind.Number || t.kind === TypeKind.Int32 ||
		t.kind === TypeKind.Int64 || t.kind === TypeKind.Uint32 ||
		t.kind === TypeKind.Float32 || t.kind === TypeKind.Float64 ||
		t.kind === TypeKind.Char;
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
	if (t.kind === TypeKind.Array || t.kind === TypeKind.SizedArray || t.kind === TypeKind.Span) return t.typeReturn;
	return unknownType();
}

export function getProperty(t: Type, name: string): Type {
	if (t.kind === TypeKind.Object) {
		let i = 0;
		for (const propName of t.typeNames) {
			if (propName === name) {
				if (i < t.typeChildren.length) return t.typeChildren[i];
				return unknownType();
			}
			i += 1;
		}
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
		|| kind === TypeKind.Int32
		|| kind === TypeKind.Int64
		|| kind === TypeKind.Uint32
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
	if (t.kind === TypeKind.Object) return t.typeName;
	return match (t.kind) {
		TypeKind.String => "string",
		TypeKind.Number => "number",
		TypeKind.Boolean => "boolean",
		TypeKind.Char => "char",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint32 => "uint32",
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
	if (t.kind === TypeKind.Object || t.kind === TypeKind.Tuple) {
		return alignOfStruct(t);
	}
	if (t.kind === TypeKind.Distinct && t.typeReturn !== null) {
		return alignOfType(t.typeReturn);
	}
	return match (t.kind) {
		TypeKind.Boolean | TypeKind.Char => 1,
		TypeKind.Int32 | TypeKind.Uint32 | TypeKind.Float32 | TypeKind.Enum => 4,
		TypeKind.Number | TypeKind.Float64 => ps,
		TypeKind.Int64 => ps,
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
// Mirrors Nim's computeSizeAlign: fields are aligned, struct is padded to maxAlign.
export function sizeOfType(t: Type): number {
	const ps = targetPtrSize;
	if (t.kind === TypeKind.Object || t.kind === TypeKind.Tuple) {
		return sizeOfStruct(t);
	}
	if (t.kind === TypeKind.Distinct && t.typeReturn !== null) {
		return sizeOfType(t.typeReturn);
	}
	return match (t.kind) {
		TypeKind.Boolean | TypeKind.Char => 1,
		TypeKind.Int32 | TypeKind.Uint32 | TypeKind.Float32 | TypeKind.Enum => 4,
		TypeKind.Number | TypeKind.Int64 | TypeKind.Float64 => ps,
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
	expect(numberType().kind === TypeKind.Number);
	expect(stringType().kind === TypeKind.String);
	expect(booleanType().kind === TypeKind.Boolean);
	expect(voidType().kind === TypeKind.Void);
	expect(nullType().kind === TypeKind.Null);
	expect(unknownType().kind === TypeKind.Unknown);
	expect(neverType().kind === TypeKind.Never);
	expect(errorType().kind === TypeKind.Error);
}

test "createArray" {
	const arrType = createArray(numberType());
	expect(arrType.kind === TypeKind.Array);
	expect(arrType.typeReturn.kind === TypeKind.Number);
}

test "createSizedArray" {
	const arrType = createSizedArray(numberType(), 4);
	expect(arrType.kind === TypeKind.SizedArray);
	expect(arrType.typeReturn.kind === TypeKind.Number);
	expect(arrType.typeFlags === 4);
}

test "createSpan" {
	const spanType = createSpan(numberType());
	expect(spanType.kind === TypeKind.Span);
	expect(spanType.typeReturn.kind === TypeKind.Number);
}

test "createFunction" {
	const fnType = createFunction([numberType(), stringType()], ["a", "b"], booleanType());
	expect(fnType.kind === TypeKind.Function);
	expect(fnType.typeChildren.length === 2);
	expect(fnType.typeNames[0] === "a");
	expect(fnType.typeReturn.kind === TypeKind.Boolean);
}

test "createObject" {
	const obj = createObject("Point", ["x"], [numberType()], false);
	expect(obj.kind === TypeKind.Object);
	expect(obj.typeName === "Point");
	expect(obj.typeNames.length === 1);
	expect(obj.typeChildren.length === 1);
	expect(obj.typeFlags === 0);
}

test "createEnum" {
	const e = createEnum("Color", ["Red", "Green", "Blue"]);
	expect(e.kind === TypeKind.Enum);
	expect(e.typeName === "Color");
	expect(e.typeNames.length === 3);
}

test "createResult" {
	const r = createResult(numberType(), stringType());
	expect(r.kind === TypeKind.Result);
	expect(r.typeReturn.kind === TypeKind.Number);
	expect(r.typeExtra.kind === TypeKind.String);
}

test "createTypeRef" {
	const t = createTypeRef("MyType");
	expect(t.kind === TypeKind.TypeReference);
	expect(t.typeName === "MyType");
}

test "createRef and Ptr" {
	const r = createRef(numberType());
	expect(r.kind === TypeKind.Ref);
	expect(r.typeReturn.kind === TypeKind.Number);
	const p = createPtr(stringType());
	expect(p.kind === TypeKind.Ptr);
	expect(p.typeReturn.kind === TypeKind.String);
}

test "isNumeric" {
	expect(isNumeric(numberType()));
	expect(isNumeric(createPrimitive(TypeKind.Int32)));
	expect(isNumeric(createPrimitive(TypeKind.Float64)));
	expect(!isNumeric(stringType()));
	expect(!isNumeric(booleanType()));
}

test "isStringType" {
	expect(isStringType(stringType()));
	expect(!isStringType(numberType()));
}

test "isBoolType" {
	expect(isBoolType(booleanType()));
	expect(!isBoolType(numberType()));
}

test "isCallable" {
	const fn = createFunction([], [], voidType());
	expect(isCallable(fn));
	expect(!isCallable(numberType()));
}

test "getReturnType" {
	const fn = createFunction([], [], booleanType());
	expect(getReturnType(fn).kind === TypeKind.Boolean);
	expect(getReturnType(numberType()).kind === TypeKind.Unknown);
}

test "getElementType" {
	const arr = createArray(stringType());
	expect(getElementType(arr).kind === TypeKind.String);
	expect(getElementType(numberType()).kind === TypeKind.Unknown);
}

test "getProperty" {
	const obj = createObject("Point", ["x", "y"], [numberType(), stringType()], false);
	expect(getProperty(obj, "x").kind === TypeKind.Number);
	expect(getProperty(obj, "y").kind === TypeKind.String);
	expect(getProperty(obj, "z").kind === TypeKind.Unknown);
	expect(getProperty(numberType(), "x").kind === TypeKind.Unknown);
}

test "substitute generic param" {
	const gp = createGenericParam("T");
	const result = substituteType(gp, "T", numberType());
	expect(result.kind === TypeKind.Number);
}

test "substitute non-matching" {
	const gp = createGenericParam("T");
	const result = substituteType(gp, "U", numberType());
	expect(result.kind === TypeKind.GenericParam);
}

test "substitute in array" {
	const arr = createArray(createGenericParam("T"));
	const result = substituteType(arr, "T", stringType());
	expect(result.kind === TypeKind.Array);
	expect(result.typeReturn.kind === TypeKind.String);
}

test "substitute in function" {
	const fn = createFunction([createGenericParam("T")], ["a"], createGenericParam("T"));
	const result = substituteType(fn, "T", numberType());
	expect(result.kind === TypeKind.Function);
	expect(result.typeChildren[0].kind === TypeKind.Number);
	expect(result.typeReturn.kind === TypeKind.Number);
}

test "substitute in Result" {
	const r = createResult(createGenericParam("T"), createGenericParam("E"));
	const step1 = substituteType(r, "T", numberType());
	const step2 = substituteType(step1, "E", stringType());
	expect(step2.kind === TypeKind.Result);
	expect(step2.typeReturn.kind === TypeKind.Number);
	expect(step2.typeExtra.kind === TypeKind.String);
}

test "instantiateGeneric multi-param" {
	const r = createResult(createGenericParam("T"), createGenericParam("E"));
	const result = instantiateGeneric(r, ["T", "E"], [numberType(), stringType()]);
	expect(result.kind === TypeKind.Result);
	expect(result.typeReturn.kind === TypeKind.Number);
	expect(result.typeExtra.kind === TypeKind.String);
}

test "primitive unchanged" {
	const result = substituteType(numberType(), "T", stringType());
	expect(result.kind === TypeKind.Number);
}

test "unify direct generic param" {
	const b = createUnifyBindings();
	unifyType(createGenericParam("T"), numberType(), b);
	expect(b.names.length === 1);
	expect(b.names[0] === "T");
	expect(b.types[0].kind === TypeKind.Number);
}

test "unify Array<T> vs Array<string>" {
	const b = createUnifyBindings();
	unifyType(createArray(createGenericParam("T")), createArray(stringType()), b);
	expect(b.names.length === 1);
	expect(b.names[0] === "T");
	expect(b.types[0].kind === TypeKind.String);
}

test "unify Result<T, E> vs Result<number, string>" {
	const b = createUnifyBindings();
	const formal = createResult(createGenericParam("T"), createGenericParam("E"));
	const concrete = createResult(numberType(), stringType());
	unifyType(formal, concrete, b);
	expect(b.names.length === 2);
	expect(b.names[0] === "T");
	expect(b.types[0].kind === TypeKind.Number);
	expect(b.names[1] === "E");
	expect(b.types[1].kind === TypeKind.String);
}

test "unify mismatched kinds" {
	const b = createUnifyBindings();
	unifyType(createArray(createGenericParam("T")), numberType(), b);
	expect(b.names.length === 0);
}

test "unify concrete no bindings" {
	const b = createUnifyBindings();
	unifyType(numberType(), numberType(), b);
	expect(b.names.length === 0);
}

test "hasGenericParams true" {
	expect(hasGenericParams(createGenericParam("T")));
	expect(hasGenericParams(createArray(createGenericParam("T"))));
	expect(hasGenericParams(createFunction([createGenericParam("T")], ["a"], numberType())));
}

test "hasGenericParams false" {
	expect(!hasGenericParams(numberType()));
	expect(!hasGenericParams(createArray(stringType())));
	expect(!hasGenericParams(createFunction([numberType()], ["a"], stringType())));
}

test "default returns param count" {
	const fn1 = createFunction([numberType(), stringType()], ["a", "b"], voidType());
	expect(getMinArity(fn1) === 2);
}

test "setMinArity stores correctly" {
	const fn2 = createFunction([numberType(), stringType()], ["a", "b"], voidType());
	setMinArity(fn2, 1);
	expect(getMinArity(fn2) === 1);
}

test "setMinArity zero" {
	const fn3 = createFunction([numberType()], ["a"], voidType());
	setMinArity(fn3, 0);
	expect(getMinArity(fn3) === 0);
}

test "preserves low bits" {
	const fn4 = createFunction([numberType()], ["a"], voidType());
	fn4.typeFlags = 1;
	setMinArity(fn4, 1);
	expect(getMinArity(fn4) === 1);
	expect((fn4.typeFlags & 0xFF) === 1);
}

test "createTuple" {
	const tup = createTuple([numberType(), stringType()]);
	expect(tup.kind === TypeKind.Tuple);
	expect(tup.typeChildren.length === 2);
	expect(tup.typeChildren[0].kind === TypeKind.Number);
	expect(tup.typeChildren[1].kind === TypeKind.String);
}

test "typeNameOf Tuple" {
	const tup = createTuple([numberType()]);
	expect(typeNameOf(tup) === "Tuple");
}

test "substituteType Tuple" {
	const tup = createTuple([createGenericParam("T"), numberType()]);
	const result = substituteType(tup, "T", stringType());
	expect(result.kind === TypeKind.Tuple);
	expect(result.typeChildren[0].kind === TypeKind.String);
	expect(result.typeChildren[1].kind === TypeKind.Number);
}

test "createSet" {
	const s = createSet(stringType());
	expect(s.kind === TypeKind.Set);
	expect(s.typeReturn.kind === TypeKind.String);
}

test "typeNameOf Set" {
	expect(typeNameOf(createSet(stringType())) === "Set");
}

test "substituteType Set" {
	const s = createSet(createGenericParam("T"));
	const result = substituteType(s, "T", stringType());
	expect(result.kind === TypeKind.Set);
	expect(result.typeReturn.kind === TypeKind.String);
}

test "sizeOfType primitives 64-bit" {
	setTargetSizes(8, 8);
	expect(sizeOfType(createPrimitive(TypeKind.Boolean)) === 1);
	expect(sizeOfType(createPrimitive(TypeKind.Char)) === 1);
	expect(sizeOfType(createPrimitive(TypeKind.Int32)) === 4);
	expect(sizeOfType(createPrimitive(TypeKind.Uint32)) === 4);
	expect(sizeOfType(createPrimitive(TypeKind.Float32)) === 4);
	expect(sizeOfType(numberType()) === 8);
	expect(sizeOfType(createPrimitive(TypeKind.Int64)) === 8);
	expect(sizeOfType(createPrimitive(TypeKind.Float64)) === 8);
	expect(sizeOfType(stringType()) === 16);
	expect(sizeOfType(createArray(numberType())) === 16);
	expect(sizeOfType(createPrimitive(TypeKind.Enum)) === 4);
}

test "sizeOfType primitives 32-bit" {
	setTargetSizes(4, 4);
	expect(sizeOfType(numberType()) === 4);
	expect(sizeOfType(stringType()) === 8);
	expect(sizeOfType(createArray(numberType())) === 8);
	expect(sizeOfType(createFunction([], [], numberType())) === 8);
	expect(sizeOfType(createPrimitive(TypeKind.Ref)) === 4);
	expect(sizeOfType(createPrimitive(TypeKind.Int32)) === 4);
	expect(sizeOfType(createPrimitive(TypeKind.Int64)) === 4);
	setTargetSizes(8, 8);
}

test "sizeOfType object no padding" {
	const obj = createObject("Pair", ["x", "y"], [createPrimitive(TypeKind.Int32), createPrimitive(TypeKind.Int32)], true);
	expect(sizeOfType(obj) === 8);
}

test "sizeOfType object with padding" {
	// { char (1 byte) + padding(3) + int32 (4 bytes) } = 8
	const obj = createObject("Mixed", ["a", "b"], [createPrimitive(TypeKind.Char), createPrimitive(TypeKind.Int32)], true);
	expect(sizeOfType(obj) === 8);
}

test "sizeOfType object tail padding" {
	// { int64 (8 bytes) + char (1 byte) + padding(7) } = 16 (aligned to maxAlign=8)
	const obj = createObject("Tail", ["x", "y"], [createPrimitive(TypeKind.Int64), createPrimitive(TypeKind.Char)], true);
	expect(sizeOfType(obj) === 16);
}

test "sizeOfType function closure" {
	expect(sizeOfType(createFunction([], [], numberType())) === 16);
}

test "alignOfType" {
	expect(alignOfType(createPrimitive(TypeKind.Char)) === 1);
	expect(alignOfType(createPrimitive(TypeKind.Int32)) === 4);
	expect(alignOfType(numberType()) === 8);
}

test "alignOfType 32-bit" {
	setTargetSizes(4, 4);
	expect(alignOfType(numberType()) === 4);
	expect(alignOfType(createPrimitive(TypeKind.Ref)) === 4);
	expect(alignOfType(createPrimitive(TypeKind.Int32)) === 4);
	setTargetSizes(8, 8);
}
