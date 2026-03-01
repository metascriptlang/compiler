// C Codegen — Type Mapping
//
// Follows Nim's ccgtypes.nim: MetaScript Type → C type string.
// Two-tier cache (forwTypeCache for forward decls, typeCache for full defs).
// Topological emit with cycle detection via forward declarations.

import { Type, TypeKind } from "../../checker/types";
import { CGen, CSection, Builder, TypeCache, add, addLine, addNewline, extract, sec, createBuilder, typeCacheGet, typeCacheSet, typeCacheHas } from "./context";
import { mangle, mangleTypeName, mangleFieldName } from "./names";
import { test, check, testGroup } from "std/testing";

// ===== Type Signature Key =====
// Generates a unique string key for a Type (used for cache lookups).

export function typeKey(t: Type): string {
	if (t === null) return "null";
	return match (t.kind) {
		TypeKind.Number => "number",
		TypeKind.Float64 => "float64",
		TypeKind.Float32 => "float32",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint32 => "uint32",
		TypeKind.String => "string",
		TypeKind.Boolean => "boolean",
		TypeKind.Void => "void",
		TypeKind.Null => "null",
		TypeKind.Enum => { "enum:" + t.typeName; },
		TypeKind.Object => { "object:" + t.typeName; },
		TypeKind.Array => {
			const elemKey = typeKey(t.typeReturn);
			"array:" + elemKey;
		},
		TypeKind.Function => {
			let key = "func(";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) key = key + ",";
				key = key + typeKey(t.typeChildren[i]);
				i += 1;
			}
			key = key + "):" + typeKey(t.typeReturn);
			key;
		},
		TypeKind.Ref => { "ref:" + typeKey(t.typeReturn); },
		TypeKind.Ptr => { "ptr:" + typeKey(t.typeReturn); },
		TypeKind.Result => {
			"result:" + typeKey(t.typeReturn) + "," + typeKey(t.typeExtra);
		},
		TypeKind.TypeReference => { "typeref:" + t.typeName; },
		TypeKind.Distinct => { "distinct:" + t.typeName; },
		_ => "unknown",
	};
}

// ===== Primitive Type Mapping =====

export function getSimpleTypeDesc(t: Type): string {
	if (t === null) return "void";
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float64 => "double",
		TypeKind.Float32 => "float",
		TypeKind.Int32 => "int32_t",
		TypeKind.Int64 => "int64_t",
		TypeKind.Uint32 => "uint32_t",
		TypeKind.Boolean => "MS_BOOL",
		TypeKind.String => "msString",
		TypeKind.Void | TypeKind.Null => "void",
		_ => "",
	};
}

// ===== Is Pointer Type =====
// Types that are always represented as pointers in C.

export function isPointerType(t: Type): boolean {
	if (t === null) return false;
	return match (t.kind) {
		TypeKind.Object => {
			// Classes (typeFlags bit 1 not set = class) are pointers
			// Interfaces (typeFlags & 1 = interface) are value types
			const isInterface = (t.typeFlags & 1) !== 0;
			!isInterface;
		},
		TypeKind.Ref | TypeKind.Ptr => true,
		_ => false,
	};
}

// ===== Needs RC =====
// Types that need reference counting in C backend.

export function needsRC(t: Type): boolean {
	if (t === null) return false;
	return match (t.kind) {
		TypeKind.String => true,
		TypeKind.Array => true,
		TypeKind.Object => {
			// Classes are RC (heap allocated), interfaces are value types (stack)
			const isInterface = (t.typeFlags & 1) !== 0;
			!isInterface;
		},
		TypeKind.Ref => true,
		_ => false,
	};
}

// ===== Forward Declaration =====
// Emits "typedef struct X X;" to cfsForwardDecls if not already done.

export function ensureForwardDecl(g: CGen, typeName: string): void {
	const key = "fwd:" + typeName;
	if (typeCacheHas(g.forwTypeCache, key)) return;
	typeCacheSet(g.forwTypeCache, key, typeName);
	addLine(sec(g, CSection.ForwardDecls), "typedef struct " + typeName + " " + typeName + ";");
}

// ===== Full Type Description =====
// Main entry point: returns C type name string for a MetaScript Type.
// Emits type definitions to CGen sections as side effect.

export function getTypeDesc(g: CGen, t: Type): string {
	if (t === null) return "void";

	// Check simple types first (no caching needed)
	const simple = getSimpleTypeDesc(t);
	if (simple !== "") return simple;

	// Check full cache
	const key = typeKey(t);
	const cached = typeCacheGet(g.typeCache, key);
	if (cached !== "") return cached;

	// Generate based on kind
	const result = match (t.kind) {
		TypeKind.Enum => {
			genEnumType(g, t);
		},
		TypeKind.Object => {
			genObjectType(g, t);
		},
		TypeKind.Array => {
			genArrayType(g, t);
		},
		TypeKind.Function => {
			genFunctionType(g, t);
		},
		TypeKind.Ref | TypeKind.Ptr => {
			const inner = getTypeDesc(g, t.typeReturn);
			const ptrType = inner + "*";
			typeCacheSet(g.typeCache, key, ptrType);
			ptrType;
		},
		TypeKind.Result => {
			genResultType(g, t);
		},
		TypeKind.TypeReference => {
			// Unresolved type ref — use mangled name, assume forward declared
			const name = mangle(t.typeName);
			ensureForwardDecl(g, name);
			name;
		},
		_ => "void",
	};

	return result;
}

// ===== Enum Type Generation =====

function genEnumType(g: CGen, t: Type): string {
	const name = mangle(t.typeName);
	const key = typeKey(t);
	typeCacheSet(g.typeCache, key, name);

	// Emit: typedef int32_t EnumName;
	addLine(sec(g, CSection.Types), "typedef int32_t " + name + ";");

	// Emit enum constants
	for (let i = 0; i < t.typeNames.length; i += 1) {
		const memberName = name + "_" + mangle(t.typeNames[i]);
		addLine(sec(g, CSection.Types), "#define " + memberName + " " + i);
	}
	addNewline(sec(g, CSection.Types));

	return name;
}

// ===== Object Type Generation =====
// Handles both interfaces (value types) and classes (pointer types).

function genObjectType(g: CGen, t: Type): string {
	const name = mangle(t.typeName);
	const key = typeKey(t);
	const isInterface = (t.typeFlags & 1) !== 0;

	// For classes, the C type is a pointer to the struct
	const cTypeName = match (isInterface) {
		true => name,
		_ => name + "*",
	};
	typeCacheSet(g.typeCache, key, cTypeName);

	// Ensure forward declaration
	ensureForwardDecl(g, name);

	// Emit struct definition
	const b = sec(g, CSection.Types);
	addLine(b, "struct " + name + " {");
	b.indent += 1;

	// Classes: no refcount field — msRefHeader (16 bytes) is prepended by msAlloc

	// Emit fields
	for (let i = 0; i < t.typeNames.length; i += 1) {
		const fieldName = mangleFieldName(t.typeNames[i]);
		const fieldType = match (i < t.typeChildren.length) {
			true => getTypeDesc(g, t.typeChildren[i]),
			_ => "void",
		};
		addLine(b, fieldType + " " + fieldName + ";");
	}

	b.indent -= 1;
	addLine(b, "};");
	addNewline(b);

	return cTypeName;
}

// ===== Array Type Generation =====

function genArrayType(g: CGen, t: Type): string {
	const elemType = getTypeDesc(g, t.typeReturn);
	const key = typeKey(t);

	// Use specific array types for common element types
	const arrType = match (elemType) {
		"double" => "msNumberArray",
		"msString" => "msStringArray",
		_ => "msArray",
	};

	typeCacheSet(g.typeCache, key, arrType);
	return arrType;
}

// ===== Function Type Generation =====
// Closure: msClosure { .fn, .env }. Raw function pointer for non-capturing.

function genFunctionType(g: CGen, t: Type): string {
	const key = typeKey(t);
	// Default to closure type
	const cType = "msClosure";
	typeCacheSet(g.typeCache, key, cType);
	return cType;
}

// ===== Result Type Generation =====

function genResultType(g: CGen, t: Type): string {
	const okType = getTypeDesc(g, t.typeReturn);
	const errType = getTypeDesc(g, t.typeExtra);
	const key = typeKey(t);

	// Generate unique struct name
	const name = "msResult_" + mangle(okType) + "_" + mangle(errType);
	typeCacheSet(g.typeCache, key, name);

	// Emit struct
	ensureForwardDecl(g, name);
	const b = sec(g, CSection.Types);
	addLine(b, "struct " + name + " {");
	b.indent += 1;
	addLine(b, "MS_BOOL ok;");
	addLine(b, okType + " value;");
	addLine(b, errType + " error;");
	b.indent -= 1;
	addLine(b, "};");
	addNewline(b);

	return name;
}

// ===== Tests =====

import { createPrimitive, createObject, createArray, createFunction, createEnum, createResult, createTypeRef, createRef } from "../../checker/types";
import { createCGen } from "./context";
import { CheckerContext } from "../../checker/context";

testGroup("C Type Key", () => {
	test("primitive keys", () => {
		check(typeKey(createPrimitive(TypeKind.Number)) === "number");
		check(typeKey(createPrimitive(TypeKind.String)) === "string");
		check(typeKey(createPrimitive(TypeKind.Boolean)) === "boolean");
		check(typeKey(createPrimitive(TypeKind.Void)) === "void");
	});
	test("enum key", () => {
		check(typeKey(createEnum("Color", ["Red", "Green"])) === "enum:Color");
	});
	test("object key", () => {
		check(typeKey(createObject("Foo", [], [], true)) === "object:Foo");
	});
	test("null type", () => {
		check(typeKey(null as unknown as Type) === "null");
	});
});

testGroup("C Simple Type", () => {
	test("primitives", () => {
		check(getSimpleTypeDesc(createPrimitive(TypeKind.Number)) === "double");
		check(getSimpleTypeDesc(createPrimitive(TypeKind.Int32)) === "int32_t");
		check(getSimpleTypeDesc(createPrimitive(TypeKind.Boolean)) === "MS_BOOL");
		check(getSimpleTypeDesc(createPrimitive(TypeKind.String)) === "msString");
		check(getSimpleTypeDesc(createPrimitive(TypeKind.Void)) === "void");
	});
	test("non-primitive returns empty", () => {
		check(getSimpleTypeDesc(createEnum("X", [])) === "");
		check(getSimpleTypeDesc(createObject("Y", [], [], true)) === "");
	});
});

testGroup("C Pointer Type", () => {
	test("class is pointer", () => {
		check(isPointerType(createObject("Foo", [], [], false)));
	});
	test("interface is not pointer", () => {
		check(!isPointerType(createObject("Bar", [], [], true)));
	});
	test("ref is pointer", () => {
		check(isPointerType(createRef(createPrimitive(TypeKind.Int32))));
	});
	test("primitive is not pointer", () => {
		check(!isPointerType(createPrimitive(TypeKind.Number)));
	});
});

testGroup("C Needs RC", () => {
	test("string needs RC", () => {
		check(needsRC(createPrimitive(TypeKind.String)));
	});
	test("array needs RC", () => {
		check(needsRC(createArray(createPrimitive(TypeKind.Number))));
	});
	test("class needs RC", () => {
		check(needsRC(createObject("Foo", [], [], false)));
	});
	test("interface no RC", () => {
		check(!needsRC(createObject("Bar", [], [], true)));
	});
	test("number no RC", () => {
		check(!needsRC(createPrimitive(TypeKind.Number)));
	});
});

testGroup("C Type Desc", () => {
	test("primitive type desc", () => {
		const g = createCGen(null as unknown as CheckerContext);
		check(getTypeDesc(g, createPrimitive(TypeKind.Number)) === "double");
		check(getTypeDesc(g, createPrimitive(TypeKind.Int32)) === "int32_t");
		check(getTypeDesc(g, createPrimitive(TypeKind.String)) === "msString");
	});
	test("enum emits typedef and defines", () => {
		const g = createCGen(null as unknown as CheckerContext);
		const result = getTypeDesc(g, createEnum("Color", ["Red", "Green", "Blue"]));
		check(result === "Color");
		const types = extract(sec(g, CSection.Types));
		check(types === "typedef int32_t Color;\n#define Color_Red 0\n#define Color_Green 1\n#define Color_Blue 2\n\n");
	});
	test("interface emits struct", () => {
		const propNames: string[] = [];
		propNames.push("x");
		propNames.push("y");
		const propTypes: Type[] = [];
		propTypes.push(createPrimitive(TypeKind.Int32));
		propTypes.push(createPrimitive(TypeKind.Int32));
		const g = createCGen(null as unknown as CheckerContext);
		const result = getTypeDesc(g, createObject("Point", propNames, propTypes, true));
		check(result === "Point");
		const types = extract(sec(g, CSection.Types));
		check(types === "struct Point {\n  int32_t x;\n  int32_t y;\n};\n\n");
	});
	test("class emits struct without refcount", () => {
		const propNames: string[] = [];
		propNames.push("name");
		const propTypes: Type[] = [];
		propTypes.push(createPrimitive(TypeKind.String));
		const g = createCGen(null as unknown as CheckerContext);
		const result = getTypeDesc(g, createObject("Person", propNames, propTypes, false));
		check(result === "Person*");
		const types = extract(sec(g, CSection.Types));
		check(types === "struct Person {\n  msString name;\n};\n\n");
	});
	test("array type", () => {
		const g = createCGen(null as unknown as CheckerContext);
		check(getTypeDesc(g, createArray(createPrimitive(TypeKind.Number))) === "msNumberArray");
		check(getTypeDesc(g, createArray(createPrimitive(TypeKind.String))) === "msStringArray");
	});
	test("forward decl emitted", () => {
		const g = createCGen(null as unknown as CheckerContext);
		getTypeDesc(g, createObject("Widget", [], [], true));
		const fwd = extract(sec(g, CSection.ForwardDecls));
		check(fwd === "typedef struct Widget Widget;\n");
	});
	test("cached second call", () => {
		const g = createCGen(null as unknown as CheckerContext);
		const t = createEnum("Dir", ["Up", "Down"]);
		const r1 = getTypeDesc(g, t);
		const r2 = getTypeDesc(g, t);
		check(r1 === r2);
		check(r1 === "Dir");
	});
});
