// Type System - TypeKind, Type interface, constructors

// Design: Flat interface (no discriminated union) to avoid DRC codegen issues
// with self-referencing anonymous struct types (MsAnon collision).
// Function accessors instead of const singletons to avoid closure capture bugs.

import { test, check, testGroup } from "std/testing";

// ===== TypeKind Enum =====

export enum TypeKind {
	// Primitives
	Number, String, Boolean, Void, Null, Unknown, Never,
	// Sized integers/floats (C interop)
	Int32, Int64, Uint32, Float32, Float64,
	// Compound
	Object, Array, Function, Tuple, Map, Set,
	// Generics
	GenericParam, GenericInstance,
	// Memory
	Ref, Ptr,
	// Special
	TypeReference, Union, Enum, Result,
	// Distinct
	Distinct,
	// Error sentinel
	Error,
}

// ===== Type Interface (Flat) =====
// All fields present; unused fields are empty/null.
// This avoids discriminated union codegen issues with self-referencing types.

export interface Type {
	kind: TypeKind;
	typeName: string;         // Object name, Enum name, TypeRef name, GenericParam name
	typeNames: string[];      // Function param names, Enum members, Object prop names
	typeChildren: Type[];     // Function params, Union types, Tuple elements, Object prop types
	typeReturn: Type;         // Function return, Array element, Ref/Ptr/Distinct inner, Result okType
	typeExtra: Type;          // Result errType, Map value, GenericInstance base
	typeFlags: number;        // Bitfield: 1=isInterface, 2=optional, 4=readonly, 8=static
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

// ===== Well-Known Types (function accessors to avoid closure capture DRC bugs) =====

export function numberType(): Type { return createPrimitive(TypeKind.Number); }
export function stringType(): Type { return createPrimitive(TypeKind.String); }
export function booleanType(): Type { return createPrimitive(TypeKind.Boolean); }
export function voidType(): Type { return createPrimitive(TypeKind.Void); }
export function nullType(): Type { return createPrimitive(TypeKind.Null); }
export function unknownType(): Type { return createPrimitive(TypeKind.Unknown); }
export function neverType(): Type { return createPrimitive(TypeKind.Never); }
export function errorType(): Type { return createPrimitive(TypeKind.Error); }

// ===== Type Query Helpers =====

export function isNumeric(t: Type): boolean {
	return t.kind === TypeKind.Number || t.kind === TypeKind.Int32 ||
		t.kind === TypeKind.Int64 || t.kind === TypeKind.Uint32 ||
		t.kind === TypeKind.Float32 || t.kind === TypeKind.Float64;
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
	if (t.kind === TypeKind.Array) return t.typeReturn;
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
	return unknownType();
}

// ===== Tests =====

testGroup("TypeKind", () => {
	test("primitive kinds", () => {
		check(numberType().kind === TypeKind.Number);
		check(stringType().kind === TypeKind.String);
		check(booleanType().kind === TypeKind.Boolean);
		check(voidType().kind === TypeKind.Void);
		check(nullType().kind === TypeKind.Null);
		check(unknownType().kind === TypeKind.Unknown);
		check(neverType().kind === TypeKind.Never);
		check(errorType().kind === TypeKind.Error);
	});
	test("createArray", () => {
		const arrType = createArray(numberType());
		check(arrType.kind === TypeKind.Array);
		check(arrType.typeReturn.kind === TypeKind.Number);
	});
	test("createFunction", () => {
		const fnType = createFunction([numberType(), stringType()], ["a", "b"], booleanType());
		check(fnType.kind === TypeKind.Function);
		check(fnType.typeChildren.length === 2);
		check(fnType.typeNames[0] === "a");
		check(fnType.typeReturn.kind === TypeKind.Boolean);
	});
	test("createObject", () => {
		const obj = createObject("Point", ["x"], [numberType()], false);
		check(obj.kind === TypeKind.Object);
		check(obj.typeName === "Point");
		check(obj.typeNames.length === 1);
		check(obj.typeChildren.length === 1);
		check(obj.typeFlags === 0);
	});
	test("createEnum", () => {
		const e = createEnum("Color", ["Red", "Green", "Blue"]);
		check(e.kind === TypeKind.Enum);
		check(e.typeName === "Color");
		check(e.typeNames.length === 3);
	});
	test("createResult", () => {
		const r = createResult(numberType(), stringType());
		check(r.kind === TypeKind.Result);
		check(r.typeReturn.kind === TypeKind.Number);
		check(r.typeExtra.kind === TypeKind.String);
	});
	test("createTypeRef", () => {
		const t = createTypeRef("MyType");
		check(t.kind === TypeKind.TypeReference);
		check(t.typeName === "MyType");
	});
	test("createRef and Ptr", () => {
		const r = createRef(numberType());
		check(r.kind === TypeKind.Ref);
		check(r.typeReturn.kind === TypeKind.Number);
		const p = createPtr(stringType());
		check(p.kind === TypeKind.Ptr);
		check(p.typeReturn.kind === TypeKind.String);
	});
});

testGroup("Type Helpers", () => {
	test("isNumeric", () => {
		check(isNumeric(numberType()));
		check(isNumeric(createPrimitive(TypeKind.Int32)));
		check(isNumeric(createPrimitive(TypeKind.Float64)));
		check(!isNumeric(stringType()));
		check(!isNumeric(booleanType()));
	});
	test("isStringType", () => {
		check(isStringType(stringType()));
		check(!isStringType(numberType()));
	});
	test("isBoolType", () => {
		check(isBoolType(booleanType()));
		check(!isBoolType(numberType()));
	});
	test("isCallable", () => {
		const fn = createFunction([], [], voidType());
		check(isCallable(fn));
		check(!isCallable(numberType()));
	});
	test("getReturnType", () => {
		const fn = createFunction([], [], booleanType());
		check(getReturnType(fn).kind === TypeKind.Boolean);
		check(getReturnType(numberType()).kind === TypeKind.Unknown);
	});
	test("getElementType", () => {
		const arr = createArray(stringType());
		check(getElementType(arr).kind === TypeKind.String);
		check(getElementType(numberType()).kind === TypeKind.Unknown);
	});
	test("getProperty", () => {
		const obj = createObject("Point", ["x", "y"], [numberType(), stringType()], false);
		check(getProperty(obj, "x").kind === TypeKind.Number);
		check(getProperty(obj, "y").kind === TypeKind.String);
		check(getProperty(obj, "z").kind === TypeKind.Unknown);
		check(getProperty(numberType(), "x").kind === TypeKind.Unknown);
	});
});
