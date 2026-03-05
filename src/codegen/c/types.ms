// C Codegen — Type Mapping
//
// Follows Nim's ccgtypes.nim: MetaScript Type → C type string.
// Two-tier cache (forwTypeCache for forward decls, typeCache for full defs).
// Topological emit with cycle detection via forward declarations.

import { Type, TypeKind, isInterfaceType } from "../../checker/types";
import { findChar, trimStr, splitTopLevel, endsWith } from "../../utils/string";
import { CGen, CSection, Builder, TypeCache, add, addLine, addNewline, extract, sec, createBuilder, typeCacheGet, typeCacheSet, typeCacheHas, nameSetHas } from "./context";
import { mangle, mangleTypeName, mangleFieldName, safeName } from "./names";
import { check } from "std/testing";

// ===== Anonymous Type Naming =====
// Generates deterministic C struct names for anonymous interfaces (typeName === "").
// Uses a structural key (field names + types) hashed to a short hex-like string.

function anonFieldKey(t: Type): string {
	if (t === null) return "null";
	// For anonymous nested objects, recurse
	if (t.kind === TypeKind.Object && t.typeName.length === 0) {
		return "anon(" + anonStructuralKey(t) + ")";
	}
	// Named objects use their name
	if (t.kind === TypeKind.Object) return t.typeName;
	// Everything else uses the standard typeKey
	const simple = getSimpleTypeDesc(t);
	if (simple !== "") return simple;
	if (t.kind === TypeKind.Enum) return "enum:" + t.typeName;
	if (t.kind === TypeKind.Array) return "arr:" + anonFieldKey(t.typeReturn);
	if (t.kind === TypeKind.Function) return "fn";
	if (t.kind === TypeKind.Result) return "result";
	if (t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr) return "ptr:" + anonFieldKey(t.typeReturn);
	if (t.kind === TypeKind.TypeReference) return "ref:" + t.typeName;
	return "unknown";
}

function anonStructuralKey(t: Type): string {
	let key = "";
	let i = 0;
	while (i < t.typeNames.length) {
		if (i > 0) key = key + ",";
		key = key + t.typeNames[i] + ":";
		if (i < t.typeChildren.length && t.typeChildren[i] !== null) {
			key = key + anonFieldKey(t.typeChildren[i]);
		} else {
			key = key + "void";
		}
		i += 1;
	}
	return key;
}

// DJB2 hash → base-36 string for short C identifiers
export function hashToBase36(s: string): string {
	let h = 5381;
	let i = 0;
	while (i < s.length) {
		h = h * 33 + s.charCodeAt(i);
		i += 1;
	}
	// Keep positive (mask to 31 bits via modulo)
	if (h < 0) h = 0 - h;
	// Convert to base-36 alphanumeric string
	const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
	let result = "";
	if (h === 0) return "0";
	while (h > 0) {
		const rem = h % 36;
		result = digits.charAt(rem) + result;
		h = (h - rem) / 36;
	}
	return result;
}

// Detects if a typeName is "anonymous-like" — empty, or a raw structural signature
// like "{ programStmts : Node[] }" from discriminated union variants.
export function isAnonTypeName(name: string): boolean {
	if (name.length === 0) return true;
	const ch = name.charAt(0);
	// Raw discriminated union variants start with "{"
	// Raw function signatures start with "("
	// Raw union types start with "|"
	if (ch === "{" || ch === "(" || ch === "|") return true;
	return false;
}

export function anonTypeName(t: Type): string {
	if (t.typeNames.length === 0) return "msAnon_empty";
	const key = anonStructuralKey(t);
	return "msAnon_" + hashToBase36(key);
}

// ===== Annotation-to-C Mapping (Single Source of Truth) =====
// Maps a MetaScript type annotation string to its C type name.
// Used by both CGen-path and proto-path anonymous struct emission.
// Mirrors getSimpleTypeDesc but works from annotation strings (no Type object).

export function annotationToC(annotation: string): string {
	const s = trimStr(annotation);
	if (s === "number" || s === "float64") return "double";
	if (s === "float32") return "float";
	if (s === "int32") return "int32_t";
	if (s === "int64") return "int64_t";
	if (s === "uint8") return "uint8_t";
	if (s === "uint16") return "uint16_t";
	if (s === "uint32") return "uint32_t";
	if (s === "uint64") return "uint64_t";
	if (s === "boolean") return "MS_BOOL";
	if (s === "string") return "msString";
	if (s === "void" || s === "null") return "void*";
	// Array types: "T[]", "T []", "T [ ]" (checker may include spaces)
	if (endsWith(s, "[]") || endsWith(s, "[ ]")) {
		let elem = s;
		if (endsWith(elem, "[ ]")) elem = elem.slice(0, elem.length - 3);
		else elem = elem.slice(0, elem.length - 2);
		elem = trimStr(elem);
		if (elem === "number") return "msNumberArray";
		if (elem === "string") return "msStringArray";
		return "msRefArray";
	}
	// Named types — mangle (value-type struct by default)
	return mangle(s);
}

// ===== Anonymous Struct Definition Builder =====
// Parses "{ field : type , field2 : type2 }" into a guarded C struct definition string.
// Shared by CGen-path (emitAnonStructFromTypeName) and proto-path (index.ms).

export function buildAnonStructDef(structName: string, rawName: string): string {
	// Strip outer braces
	let body = trimStr(rawName);
	if (body.length > 0 && body.charAt(0) === "{") body = body.slice(1, body.length);
	if (body.length > 0 && body.charAt(body.length - 1) === "}") body = body.slice(0, body.length - 1);

	// splitTopLevel handles nested brackets/generics and auto-trims
	const fields = splitTopLevel(body, ",");

	let def = "#ifndef " + structName + "_DEFINED\n";
	def = def + "#define " + structName + "_DEFINED\n";
	def = def + "typedef struct " + structName + " " + structName + ";\n";
	def = def + "struct " + structName + " {\n";

	for (let fi = 0; fi < fields.length; fi += 1) {
		const colonPos = findChar(fields[fi], ":");
		if (colonPos < 0) continue;
		const fname = trimStr(fields[fi].slice(0, colonPos));
		const ftype = trimStr(fields[fi].slice(colonPos + 1, fields[fi].length));
		def = def + "  " + annotationToC(ftype) + " " + safeName(fname) + ";\n";
	}

	def = def + "};\n#endif\n";
	return def;
}

// CGen-path: emit anonymous struct body into CSection.Types
function emitAnonStructFromTypeName(g: CGen, structName: string, rawName: string): void {
	if (typeCacheHas(g.typeCache, "anonBody:" + structName)) return;
	typeCacheSet(g.typeCache, "anonBody:" + structName, structName);
	add(sec(g, CSection.Types), buildAnonStructDef(structName, rawName));
	addNewline(sec(g, CSection.Types));
}

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
		TypeKind.Char => "char",
		TypeKind.Void => "void",
		TypeKind.Null => "null",
		TypeKind.Enum => { "enum:" + t.typeName; },
		TypeKind.Object => {
			// Anonymous/structural types: use structural key to distinguish
			if (isAnonTypeName(t.typeName)) {
				"anon(" + anonStructuralKey(t) + ")";
			} else {
				"object:" + t.typeName;
			}
		},
		TypeKind.Array => {
			const elemKey = typeKey(t.typeReturn);
			"array:" + elemKey;
		},
		TypeKind.SizedArray => {
			const elemKey = typeKey(t.typeReturn);
			"sizedArray:" + elemKey + "[" + intToString(t.typeFlags) + "]";
		},
		TypeKind.Span => {
			const elemKey = typeKey(t.typeReturn);
			"span:" + elemKey;
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
		TypeKind.Borrow => { "borrow:" + typeKey(t.typeReturn); },
		TypeKind.Map => { "map:" + typeKey(t.typeReturn) + ":" + typeKey(t.typeExtra); },
		TypeKind.Set => { "set:" + typeKey(t.typeReturn); },
		TypeKind.Result => {
			"result:" + typeKey(t.typeReturn) + "," + typeKey(t.typeExtra);
		},
		TypeKind.TypeReference => { "typeref:" + t.typeName; },
		TypeKind.Distinct => { "distinct:" + t.typeName; },
		TypeKind.Tuple => {
			let key = "tuple:";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) key = key + ",";
				key = key + typeKey(t.typeChildren[i]);
				i += 1;
			}
			key;
		},
		_ => "unknown",
	};
}

export function intToString(n: number): string {
	return "" + n;
}

// ===== Primitive Type Mapping =====

export function getSimpleTypeDesc(t: Type): string {
	if (!t) return "void";
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float64 => "double",
		TypeKind.Float32 => "float",
		TypeKind.Int32 => "int32_t",
		TypeKind.Int64 => "int64_t",
		TypeKind.Uint32 => "uint32_t",
		TypeKind.Boolean => "MS_BOOL",
		TypeKind.Char => "char",
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
		TypeKind.Object => { !isInterfaceType(t) },
		TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow => true,
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
		TypeKind.SizedArray => needsRC(t.typeReturn), // Recurse for nested RC
		TypeKind.Span => false, // Span is non-owning
		TypeKind.Object => { !isInterfaceType(t) },
		TypeKind.Ref => true,
		TypeKind.Map => true,
		TypeKind.Tuple => {
			let i = 0;
			while (i < t.typeChildren.length) {
				if (needsRC(t.typeChildren[i])) return true;
				i += 1;
			}
			false;
		},
		_ => false,
	};
}

// ===== NRVO Detection (Type-based, Nim parity) =====
// Returns true for types that are C structs — these need out-param calling convention.

export function isNrvoReturnType(t: Type): boolean {
	if (t === null) return false;
	if (isInterfaceType(t)) return true;  // value-type structs → NRVO
	if (t.kind === TypeKind.Span) return true; // Span is { ptr, len } struct
	if (t.kind === TypeKind.Result) return true;
	if (t.kind === TypeKind.Tuple) return true;
	return false;
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
	if (t === null) return "void*";
	const __k = t.kind;
	if (__k === null) return "void*";
	if (__k !== __k) return "void*";  // NaN check fallback

	// Check simple types first (no caching needed)
	const simple = getSimpleTypeDesc(t);
	if (simple !== "") return simple;

	// Check full cache
	const key = typeKey(t);
	const cached = typeCacheGet(g.typeCache, key);
	if (cached !== "") return cached;

	// Handle TypeReference before match — avoid match arm value propagation gotcha
	if (t.kind === TypeKind.TypeReference) {
		if (findChar(t.typeName, "=".code) >= 0 || (t.typeName.length > 0 && t.typeName.charAt(0) === "(")) {
			return "msClosure";
		}
		if (t.typeName === "unknown" || t.typeName === "undefined" || t.typeName === "any" || t.typeName === "never") {
			return "void*";
		}
		// Anonymous type aliases (discriminated union variants) — resolve structurally
		if (isAnonTypeName(t.typeName)) {
			// TypeReference with anonymous typeName has no typeChildren/typeNames.
			// Generate a stable hash-based name from the raw typeName string.
			const anonName = "msAnon_" + hashToBase36(t.typeName);
			ensureForwardDecl(g, anonName);
			// Emit struct body by parsing field info from typeName if available
			emitAnonStructFromTypeName(g, anonName, t.typeName);
			return anonName;
		}
		const name = mangle(t.typeName);
		ensureForwardDecl(g, name);
		// Class types need pointer semantics (Name* not Name)
		if (nameSetHas(g.knownClassNames, name)) {
			return name + "*";
		}
		return name;
	}

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
		TypeKind.SizedArray => {
			genSizedArrayType(g, t);
		},
		TypeKind.Span => {
			genSpanType(g, t);
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
		TypeKind.Borrow => {
			const inner = getTypeDesc(g, t.typeReturn);
			const ptrType = "const " + inner + "*";
			typeCacheSet(g.typeCache, key, ptrType);
			ptrType;
		},
		TypeKind.Result => {
			genResultType(g, t);
		},
		TypeKind.Map => {
			typeCacheSet(g.typeCache, key, "msMap");
			"msMap";
		},
		TypeKind.Set => {
			typeCacheSet(g.typeCache, key, "msSet");
			"msSet";
		},
		TypeKind.TypeReference => "void*", // handled above, shouldn't reach here
		TypeKind.Unknown => "void*",
		TypeKind.Any => "void*",
		TypeKind.Union => "void*",
		TypeKind.Intersection => "void*",
		TypeKind.Tuple => {
			genTupleType(g, t);
		},
		TypeKind.Generic | TypeKind.GenericParam => "void*",
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
	// Anonymous/structural types get hash-based names; named types get mangled names
	const name = isAnonTypeName(t.typeName) ? anonTypeName(t) : mangle(t.typeName);
	const key = typeKey(t);
	const iface = isInterfaceType(t);

	// For classes, the C type is a pointer to the struct
	const cTypeName = match (iface) {
		true => name,
		_ => name + "*",
	};
	typeCacheSet(g.typeCache, key, cTypeName);

	// Ensure forward declaration
	ensureForwardDecl(g, name);

	// Pre-resolve field types BEFORE emitting struct body.
	// This ensures nested type definitions (enums, other structs) are emitted
	// to CSection.Types before the struct body starts, avoiding inline typedefs.
	const fieldTypes: string[] = [];
	for (let i = 0; i < t.typeNames.length; i += 1) {
		let ft = (i < t.typeChildren.length) ? getTypeDesc(g, t.typeChildren[i]) : "void";
		// Self-referential fields: same interface type as containing struct → must be pointer
		// C cannot contain a struct by value inside itself (infinite size)
		if (iface && ft === name) {
			ft = name + "*";
		}
		fieldTypes.push(ft);
	}

	// Emit struct definition (guarded to avoid redefinition with cross-module protos)
	const b = sec(g, CSection.Types);
	addLine(b, "#ifndef " + name + "_DEFINED");
	addLine(b, "#define " + name + "_DEFINED");
	addLine(b, "struct " + name + " {");
	b.indent += 1;

	// Classes: no refcount field — msRefHeader (16 bytes) is prepended by msAlloc

	// Emit fields
	for (let i = 0; i < t.typeNames.length; i += 1) {
		addLine(b, fieldTypes[i] + " " + mangleFieldName(t.typeNames[i]) + ";");
	}

	b.indent -= 1;
	addLine(b, "};");
	addLine(b, "#endif");
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
		_ => "msRefArray",
	};

	typeCacheSet(g.typeCache, key, arrType);
	return arrType;
}

// ===== Sized Array (Stack) =====

function genSizedArrayType(g: CGen, t: Type): string {
	const elemType = getTypeDesc(g, t.typeReturn);
	const size = t.typeFlags;
	const key = typeKey(t);
	const name = "msSizedArray_" + mangle(elemType) + "_" + intToString(size);

	if (typeCacheHas(g.typeCache, key)) return typeCacheGet(g.typeCache, key);
	typeCacheSet(g.typeCache, key, name);

	ensureForwardDecl(g, name);
	const b = sec(g, CSection.Types);
	addLine(b, "struct " + name + " {");
	addLine(b, "    " + elemType + " data[" + intToString(size) + "];");
	addLine(b, "};");
	addNewline(b);

	return name;
}

// ===== Span (View) =====

function genSpanType(g: CGen, t: Type): string {
	const elemType = getTypeDesc(g, t.typeReturn);
	const key = typeKey(t);
	const name = "msSpan_" + mangle(elemType);

	if (typeCacheHas(g.typeCache, key)) return typeCacheGet(g.typeCache, key);
	typeCacheSet(g.typeCache, key, name);

	ensureForwardDecl(g, name);
	const b = sec(g, CSection.Types);
	addLine(b, "struct " + name + " {");
	addLine(b, "    " + elemType + "* data;");
	addLine(b, "    int64_t len;");
	addLine(b, "};");
	addNewline(b);

	return name;
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

export function genResultType(g: CGen, t: Type): string {
	const okType = getTypeDesc(g, t.typeReturn);
	const errType = getTypeDesc(g, t.typeExtra);
	const key = typeKey(t);

	// Generate unique struct name
	const name = "msResult_" + mangle(okType) + "_" + mangle(errType);
	typeCacheSet(g.typeCache, key, name);

	// Emit struct (guarded to avoid redefinition when cross-module protos exist)
	ensureForwardDecl(g, name);
	const b = sec(g, CSection.Types);
	addLine(b, "#ifndef " + name + "_DEFINED");
	addLine(b, "#define " + name + "_DEFINED");
	addLine(b, "struct " + name + " {");
	b.indent += 1;
	addLine(b, "MS_BOOL ok;");
	if (okType !== "void") {
		addLine(b, okType + " value;");
	}
	if (errType !== "void") {
		addLine(b, errType + " error;");
	}
	b.indent -= 1;
	addLine(b, "};");
	addLine(b, "#endif");
	addNewline(b);

	return name;
}

// ===== Tuple Type Generation =====

function genTupleType(g: CGen, t: Type): string {
	const key = typeKey(t);
	if (typeCacheHas(g.typeCache, key)) return typeCacheGet(g.typeCache, key);

	// Hash-based name for uniqueness
	const name = "msTuple_" + hashToBase36(key);
	typeCacheSet(g.typeCache, key, name);
	ensureForwardDecl(g, name);

	// Emit struct: fields named _0, _1, ...
	const b = sec(g, CSection.Types);
	addLine(b, "#ifndef " + name + "_DEFINED");
	addLine(b, "#define " + name + "_DEFINED");
	addLine(b, "struct " + name + " {");
	b.indent += 1;
	let i = 0;
	while (i < t.typeChildren.length) {
		const ft = getTypeDesc(g, t.typeChildren[i]);
		addLine(b, ft + " _" + intToString(i) + ";");
		i += 1;
	}
	b.indent -= 1;
	addLine(b, "};");
	addLine(b, "#endif");
	addNewline(b);

	return name;
}

// ===== Tests =====

import { createPrimitive, createObject, createArray, createFunction, createEnum, createResult, createTypeRef, createRef, createTuple } from "../../checker/types";
import { createCGen } from "./context";
import { CheckerContext } from "../../checker/context";
test "primitive keys" {
	check(typeKey(createPrimitive(TypeKind.Number)) === "number");
	check(typeKey(createPrimitive(TypeKind.String)) === "string");
	check(typeKey(createPrimitive(TypeKind.Boolean)) === "boolean");
	check(typeKey(createPrimitive(TypeKind.Void)) === "void");
}

test "enum key" { check(typeKey(createEnum("Color", ["Red", "Green"])) === "enum:Color"); }

test "object key" { check(typeKey(createObject("Foo", [], [], true)) === "object:Foo"); }

test "null type" { check(typeKey(null as unknown as Type) === "null"); }

test "primitives" {
	check(getSimpleTypeDesc(createPrimitive(TypeKind.Number)) === "double");
	check(getSimpleTypeDesc(createPrimitive(TypeKind.Int32)) === "int32_t");
	check(getSimpleTypeDesc(createPrimitive(TypeKind.Boolean)) === "MS_BOOL");
	check(getSimpleTypeDesc(createPrimitive(TypeKind.String)) === "msString");
	check(getSimpleTypeDesc(createPrimitive(TypeKind.Void)) === "void");
}

test "non-primitive returns empty" {
	check(getSimpleTypeDesc(createEnum("X", [])) === "");
	check(getSimpleTypeDesc(createObject("Y", [], [], true)) === "");
}

test "class is pointer" { check(isPointerType(createObject("Foo", [], [], false))); }

test "interface is not pointer" { check(!isPointerType(createObject("Bar", [], [], true))); }

test "ref is pointer" { check(isPointerType(createRef(createPrimitive(TypeKind.Int32)))); }

test "primitive is not pointer" { check(!isPointerType(createPrimitive(TypeKind.Number))); }

test "string needs RC" { check(needsRC(createPrimitive(TypeKind.String))); }

test "array needs RC" { check(needsRC(createArray(createPrimitive(TypeKind.Number)))); }

test "class needs RC" { check(needsRC(createObject("Foo", [], [], false))); }

test "interface no RC" { check(!needsRC(createObject("Bar", [], [], true))); }

test "number no RC" { check(!needsRC(createPrimitive(TypeKind.Number))); }

test "map needs RC" { check(needsRC(createPrimitive(TypeKind.Map))); }

test "map is not pointer" { check(!isPointerType(createPrimitive(TypeKind.Map))); }

test "map type key" {
	const t = createPrimitive(TypeKind.Map);
	t.typeReturn = createPrimitive(TypeKind.String);
	t.typeExtra = createPrimitive(TypeKind.Number);
	check(typeKey(t) === "map:string:number");
}

test "map type desc" {
	const g = createCGen(null as unknown as CheckerContext, "");
	const t = createPrimitive(TypeKind.Map);
	t.typeReturn = createPrimitive(TypeKind.String);
	t.typeExtra = createPrimitive(TypeKind.Number);
	check(getTypeDesc(g, t) === "msMap");
}

test "primitive type desc" {
	const g = createCGen(null as unknown as CheckerContext, "");
	check(getTypeDesc(g, createPrimitive(TypeKind.Number)) === "double");
	check(getTypeDesc(g, createPrimitive(TypeKind.Int32)) === "int32_t");
	check(getTypeDesc(g, createPrimitive(TypeKind.String)) === "msString");
}

test "enum emits typedef and defines" {
	const g = createCGen(null as unknown as CheckerContext, "");
	const result = getTypeDesc(g, createEnum("Color", ["Red", "Green", "Blue"]));
	check(result === "Color");
	const types = extract(sec(g, CSection.Types));
	check(types === "typedef int32_t Color;\n#define Color_Red 0\n#define Color_Green 1\n#define Color_Blue 2\n\n");
}

test "interface emits struct" {
	const propNames: string[] = [];
	propNames.push("x");
	propNames.push("y");
	const propTypes: Type[] = [];
	propTypes.push(createPrimitive(TypeKind.Int32));
	propTypes.push(createPrimitive(TypeKind.Int32));
	const g = createCGen(null as unknown as CheckerContext, "");
	const result = getTypeDesc(g, createObject("Point", propNames, propTypes, true));
	check(result === "Point");
	const types = extract(sec(g, CSection.Types));
	check(types === "#ifndef Point_DEFINED\n#define Point_DEFINED\nstruct Point {\n  int32_t x;\n  int32_t y;\n};\n#endif\n\n");
}

test "class emits struct without refcount" {
	const propNames: string[] = [];
	propNames.push("name");
	const propTypes: Type[] = [];
	propTypes.push(createPrimitive(TypeKind.String));
	const g = createCGen(null as unknown as CheckerContext, "");
	const result = getTypeDesc(g, createObject("Person", propNames, propTypes, false));
	check(result === "Person*");
	const types = extract(sec(g, CSection.Types));
	check(types === "#ifndef Person_DEFINED\n#define Person_DEFINED\nstruct Person {\n  msString name;\n};\n#endif\n\n");
}

test "array type" {
	const g = createCGen(null as unknown as CheckerContext, "");
	check(getTypeDesc(g, createArray(createPrimitive(TypeKind.Number))) === "msNumberArray");
	check(getTypeDesc(g, createArray(createPrimitive(TypeKind.String))) === "msStringArray");
}

test "forward decl emitted" {
	const g = createCGen(null as unknown as CheckerContext, "");
	getTypeDesc(g, createObject("Widget", [], [], true));
	const fwd = extract(sec(g, CSection.ForwardDecls));
	check(fwd === "typedef struct Widget Widget;\n");
}

test "cached second call" {
	const g = createCGen(null as unknown as CheckerContext, "");
	const t = createEnum("Dir", ["Up", "Down"]);
	const r1 = getTypeDesc(g, t);
	const r2 = getTypeDesc(g, t);
	check(r1 === r2);
	check(r1 === "Dir");
}

test "anonymous type gets unique name" {
	const names1: string[] = [];
	names1.push("x");
	names1.push("y");
	const types1: Type[] = [];
	types1.push(createPrimitive(TypeKind.Number));
	types1.push(createPrimitive(TypeKind.Number));
	const anon1 = createObject("", names1, types1, true);
	const name1 = anonTypeName(anon1);
	check(name1 !== "empty_");
	check(name1.length > 7); // "msAnon_" + at least 1 char
}

test "different anonymous types get different names" {
	const names1: string[] = [];
	names1.push("x");
	names1.push("y");
	const types1: Type[] = [];
	types1.push(createPrimitive(TypeKind.Number));
	types1.push(createPrimitive(TypeKind.Number));
	const anon1 = createObject("", names1, types1, true);

	const names2: string[] = [];
	names2.push("a");
	names2.push("b");
	const types2: Type[] = [];
	types2.push(createPrimitive(TypeKind.String));
	types2.push(createPrimitive(TypeKind.Boolean));
	const anon2 = createObject("", names2, types2, true);

	check(anonTypeName(anon1) !== anonTypeName(anon2));
}

test "same anonymous type gets same name (deterministic)" {
	const names1: string[] = [];
	names1.push("x");
	const types1: Type[] = [];
	types1.push(createPrimitive(TypeKind.Int32));
	const anon1 = createObject("", names1, types1, true);

	const names2: string[] = [];
	names2.push("x");
	const types2: Type[] = [];
	types2.push(createPrimitive(TypeKind.Int32));
	const anon2 = createObject("", names2, types2, true);

	check(anonTypeName(anon1) === anonTypeName(anon2));
}

test "anonymous type cache key distinguishes" {
	const names1: string[] = [];
	names1.push("x");
	const types1: Type[] = [];
	types1.push(createPrimitive(TypeKind.Number));
	const anon1 = createObject("", names1, types1, true);

	const names2: string[] = [];
	names2.push("y");
	const types2: Type[] = [];
	types2.push(createPrimitive(TypeKind.String));
	const anon2 = createObject("", names2, types2, true);

	check(typeKey(anon1) !== typeKey(anon2));
}

test "tuple type key" {
	const t = createTuple([createPrimitive(TypeKind.Number), createPrimitive(TypeKind.String)]);
	check(typeKey(t) === "tuple:number,string");
}

test "tuple type desc emits struct" {
	const g = createCGen(null as unknown as CheckerContext, "");
	const t = createTuple([createPrimitive(TypeKind.Number), createPrimitive(TypeKind.String)]);
	const name = getTypeDesc(g, t);
	check(name !== "void*");
	check(name.length > 8); // "msTuple_" + hash
	const types = extract(sec(g, CSection.Types));
	check(types.length > 0);
}

test "tuple needsRC with string element" {
	const t = createTuple([createPrimitive(TypeKind.Number), createPrimitive(TypeKind.String)]);
	check(needsRC(t));
}

test "tuple needsRC without RC elements" {
	const t = createTuple([createPrimitive(TypeKind.Number), createPrimitive(TypeKind.Int32)]);
	check(!needsRC(t));
}

test "anonymous type emits struct with hash name" {
	const names1: string[] = [];
	names1.push("x");
	names1.push("y");
	const types1: Type[] = [];
	types1.push(createPrimitive(TypeKind.Number));
	types1.push(createPrimitive(TypeKind.Number));
	const anon = createObject("", names1, types1, true);
	const g = createCGen(null as unknown as CheckerContext, "");
	const result = getTypeDesc(g, anon);
	// Should NOT be "empty_"
	check(result !== "empty_");
	// Should start with msAnon_
	check(result.length > 7);
}
