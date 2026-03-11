// C Codegen — Type Mapping
//
// Follows standard reference implementation patterns for type mapping.
// Two-tier cache (forwTypeCache for forward decls, typeCache for full defs).
// Topological emit with cycle detection via forward declarations.

import { Type, TypeKind, isInterfaceType, getTypeSize, skipModifier } from "../../checker/types";
import { Node, NodeKind, CallExprData } from "../../ast/node";
import { findChar, trimStr, splitTopLevel } from "../../utils/string";
import { CGen, CSection, Builder, TypeCache, add, addLine, addNewline, extract, sec, createBuilder, typeCacheGet, typeCacheSet, typeCacheHas, nameSetHas } from "./context";
import { lookupSymbol } from "../../checker/symbol";
import { mangle, mangleTypeName, mangleFieldName, safeName } from "./names";

// ===== Resolve TypeReference via Symbol Table =====
// The reference PType is always a pointer to full type info. Our TypeReference is name-only.
// Instead of a pre-built registry, resolve lazily via the checker's symbol table.
// After 3 checker passes, all types (local + imported) are in scope.

function resolveTypeName(g: CGen, name: string): Type {
	if (g.checkerCtx === null) return null;
	const sym = lookupSymbol(g.checkerCtx.table, name);
	if (sym !== null && sym.symbolType !== null) return sym.symbolType;
	return null;
}

// ===== Deferred Struct Body Emission (Union types only) =====
// When resolving a union type's field types, nested getTypeDesc calls may trigger
// struct body emissions (e.g., Doc contains DocData by value, DocData union variants
// reference Doc*). We defer struct body emission during union resolution so the
// union wrapper struct is emitted before types that embed it by value.
// NOTE: genObjectType does NOT defer struct bodies — Standard reference emits nested structs
// BEFORE the parent (natural recursion gives correct C ordering for value fields).

// ===== Cycle Detection (Standard implementation parity) =====
// Tracks type keys currently being defined. Used by genArrayType to detect
// self-referential arrays (e.g., Type[] inside struct Type) and emit
// Standard reference two-struct split pattern instead of MS_ARRAY macro.

let typesBeingDefined: string[] = [];

function isBeingDefined(key: string): boolean {
	for (const k of typesBeingDefined) {
		if (k === key) return true;
	}
	return false;
}

// ===== Deferred Array Content Structs =====
// For self-referential arrays (Standard reference two-struct split), the content struct
// (with flexible array member T data[]) must be emitted after T is complete.

let deferredArrayContentStructs: string[] = [];

// ===== Anonymous Type Naming =====
// Generates deterministic C struct names for anonymous interfaces (typeName === "").
// Uses a structural key (field names + types) hashed to a short hex-like string.

function anonFieldKey(t: Type): string {
	if (t === null) return "null";
	return match (t.kind) {
		TypeKind.Struct => {
			if (t.typeName.length === 0) return `anon(${anonStructuralKey(t)})`;
			return t.typeName;
		},
		TypeKind.Enum => "enum:" + t.typeName,
		TypeKind.Array => "arr:" + anonFieldKey(t.typeReturn),
		TypeKind.Function => "fn",
		TypeKind.Result => "result",
		TypeKind.Ref | TypeKind.Ptr => "ptr:" + anonFieldKey(t.typeReturn),
		TypeKind.TypeReference => "ref:" + t.typeName,
		_ => {
			const simple = getSimpleTypeDesc(t);
			if (simple !== "") return simple;
			return "unknown";
		},
	};
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
		h = (h * 33 + s.charCodeAt(i)) % 2147483647;
		i += 1;
	}
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
	const mapped = match (s) {
		"number" | "float64" => "double",
		"float32" => "float",
		"int8" => "int8_t",
		"int16" => "int16_t",
		"int32" => "int32_t",
		"int64" => "int64_t",
		"uint8" => "uint8_t",
		"uint16" => "uint16_t",
		"uint32" => "uint32_t",
		"uint64" => "uint64_t",
		"boolean" => "MS_BOOL",
		"string" => "msString",
		"cstring" => "const char*",
		"void" | "null" => "void*",
		_ => "",
	};
	if (mapped !== "") return mapped;
	// Array types: "T[]", "T []", "T [ ]" (checker may include spaces)
	if (s.endsWith("[]") || s.endsWith("[ ]")) {
		let elem = s;
		if (elem.endsWith("[ ]")) elem = elem.slice(0, elem.length - 3);
		else elem = elem.slice(0, elem.length - 2);
		elem = trimStr(elem);
		if (elem === "number") return "msNumberArray";
		if (elem === "string") return "msStringArray";
		if (elem === "uint8") return "msUint8Array";
		// Per-type array typedef (Standard reference pattern)
		return mangle(elem) + "Array";
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

	let def = `#ifndef ${structName}_DEFINED\n`;
	def = def + `#define ${structName}_DEFINED\n`;
	def = def + `typedef struct ${structName} ${structName};\n`;
	def = def + `struct ${structName} {\n`;

	for (const field of fields) {
		const colonPos = findChar(field, ":");
		if (colonPos < 0) continue;
		const fname = trimStr(field.slice(0, colonPos));
		const ftype = trimStr(field.slice(colonPos + 1, field.length));
		def = def + `  ${annotationToC(ftype)} ${safeName(fname)};\n`;
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
		TypeKind.Int8 => "int8",
		TypeKind.Int16 => "int16",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint8 => "uint8",
		TypeKind.Uint16 => "uint16",
		TypeKind.Uint32 => "uint32",
		TypeKind.Uint64 => "uint64",
		TypeKind.String => "string",
		TypeKind.Boolean => "boolean",
		TypeKind.Char => "char",
		TypeKind.CString => "cstring",
		TypeKind.Void => "void",
		TypeKind.Null => "null",
		TypeKind.Enum => { "enum:" + t.typeName; },
		TypeKind.Struct => {
			// Anonymous/structural types: use structural key to distinguish
			if (isAnonTypeName(t.typeName)) {
				`anon(${anonStructuralKey(t)})`;
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
			`sizedArray:${elemKey}[${intToString(t.typeFlags)}]`;
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
		TypeKind.Var => { "var:" + typeKey(t.typeReturn); },
		TypeKind.Borrow => { "borrow:" + typeKey(t.typeReturn); },
		TypeKind.Map => { `map:${typeKey(t.typeReturn)}:${typeKey(t.typeExtra)}`; },
		TypeKind.Set => { "set:" + typeKey(t.typeReturn); },
		TypeKind.Result => {
			`result:${typeKey(t.typeReturn)},${typeKey(t.typeExtra)}`;
		},
		TypeKind.TypeReference => { "typeref:" + t.typeName; },
		TypeKind.Distinct => { "distinct:" + t.typeName; },
		TypeKind.Union => {
			if (t.typeName.length > 0) {
				"union:" + t.typeName;
			} else {
				let key = "union(";
				let ui = 0;
				while (ui < t.typeChildren.length) {
					if (ui > 0) key = key + "|";
					key = key + typeKey(t.typeChildren[ui]);
					ui += 1;
				}
				key + ")";
			}
		},
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
		TypeKind.Int8 => "int8_t",
		TypeKind.Int16 => "int16_t",
		TypeKind.Int32 => "int32_t",
		TypeKind.Int64 => "int64_t",
		TypeKind.Uint8 => "uint8_t",
		TypeKind.Uint16 => "uint16_t",
		TypeKind.Uint32 => "uint32_t",
		TypeKind.Uint64 => "uint64_t",
		TypeKind.Boolean => "MS_BOOL",
		TypeKind.Char => "char",
		TypeKind.String => "msString",
		TypeKind.CString => "const char*",
		TypeKind.Void | TypeKind.Null => "void",
		_ => "",
	};
}

// ===== Is Pointer Type =====
// Types that are always represented as pointers in C.
// Reference parity: skipTypes(abstractPtrs) strips Sink/Lent before kind checks.

export function isPointerType(t: Type): boolean {
	if (t === null) return false;
	const inner = skipModifier(t);
	if (inner === null) return false;
	return match (inner.kind) {
		TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow => true,
		_ => false,
	};
}

// Reference parity: value types that can't be nil in C.
// Used by codegen to emit {0} instead of MS_NIL, and memset instead of NULL assignment.
export function isNilableValueType(t: Type): boolean {
	if (t === null) return false;
	const k = t.kind;
	return k === TypeKind.Struct || k === TypeKind.Array || k === TypeKind.Result
		|| k === TypeKind.Tuple || k === TypeKind.String || k === TypeKind.Function
		|| k === TypeKind.Map || k === TypeKind.Set || k === TypeKind.Union;
}

// ===== ccgIntroducedPtr (Reference: reference codegen utils parity) =====
// Determines if a param type should be passed by pointer in C.
// Reference: skipTypes(typedescInst) strips Sink/Lent before dispatch.
// Object types with size > 24 bytes, tuple same threshold,
// Result/Union/Span always by pointer.
const PTR_THRESHOLD: number = 24;

export function ccgIntroducedPtr(t: Type): boolean {
	if (t === null) return false;
	if (t.kind === TypeKind.Var) return true;  // out params always by pointer
	const inner = skipModifier(t);
	if (inner === null) return false;
	if (isInterfaceType(inner)) return getTypeSize(inner) > PTR_THRESHOLD;
	return match (inner.kind) {
		TypeKind.Tuple => getTypeSize(inner) > PTR_THRESHOLD,
		TypeKind.Result | TypeKind.Union | TypeKind.Span => true,
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
		TypeKind.Ref => true,
		TypeKind.Map | TypeKind.Set => true,
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

// ===== NRVO Detection (Type-based, Standard reference parity) =====
// Returns true for types that are C structs — these need out-param calling convention.

export function isNrvoReturnType(t: Type): boolean {
	if (t === null) return false;
	if (isInterfaceType(t)) return true;  // value-type structs → NRVO
	if (t.kind === TypeKind.Span) return true; // Span is { ptr, len } struct
	if (t.kind === TypeKind.Result) return true;
	if (t.kind === TypeKind.Tuple) return true;
	return false;
}

// ===== NRVO Call-Site Detection (Standard reference pattern) =====
// Centralized two-source callee type lookup. Reference implementation uses a single isInvalidReturnType()
// in reference types called from 10 locations across 4 files.

export function getCalleeReturnType(callNode: Node): Type {
	const cd = callNode.data as CallExprData;
	if (cd.callee !== null && cd.callee.nodeType !== null && cd.callee.nodeType.kind === TypeKind.Function) {
		return cd.callee.nodeType.typeReturn;
	}
	if (callNode.resolvedSym !== null && callNode.resolvedSym.symbolType !== null) {
		const st = callNode.resolvedSym.symbolType;
		if (st.kind === TypeKind.Function) return st.typeReturn;
	}
	return null;
}

// ===== Forward Declaration =====
// Emits "typedef struct X X;" to cfsForwardDecls if not already done.

// getTypeForward — Standard reference implementation parity: like getTypeDesc but only emits a forward
// declaration + returns the C type name. Used when only a pointer is needed
// (e.g., array element type during self-referential struct definition).
export function getTypeForward(g: CGen, t: Type): string {
	if (t === null) return "void*";
	const simple = getSimpleTypeDesc(t);
	if (simple !== "") return simple;
	// Check cache — if already fully resolved, just return
	const key = typeKey(t);
	const cached = typeCacheGet(g.typeCache, key);
	if (cached !== "") return cached;
	// For Object/Enum/TypeReference — forward-declare only
	if (t.kind === TypeKind.Struct || t.kind === TypeKind.Enum) {
		const name = isAnonTypeName(t.typeName) ? anonTypeName(t) : mangle(t.typeName);
		ensureForwardDecl(g, name);
		return name;
	}
	if (t.kind === TypeKind.TypeReference) {
		const name = mangle(t.typeName);
		ensureForwardDecl(g, name);
		return name;
	}
	// Other types — fall through to full resolution
	return getTypeDesc(g, t);
}

export function ensureForwardDecl(g: CGen, typeName: string): void {
	const key = "fwd:" + typeName;
	if (typeCacheHas(g.forwTypeCache, key)) return;
	typeCacheSet(g.forwTypeCache, key, typeName);
	// Skip runtime types already defined in system.h or runtime headers
	if (typeName === "msClosure") return;
	addLine(sec(g, CSection.ForwardDecls), `#ifndef ${typeName}_DEFINED\ntypedef struct ${typeName} ${typeName};\n#endif`);
}

// Ensure msTypeInfo extern declaration exists for cross-module new expressions.
// The owning module emits `msTypeInfo Foo_typeInfo;` via destructorLifting (non-static linkage).
// Consuming modules need `extern msTypeInfo Foo_typeInfo;` to reference it.
export function ensureTypeInfo(g: CGen, className: string): void {
	const key = "typeInfo:" + className;
	if (typeCacheHas(g.forwTypeCache, key)) return;
	typeCacheSet(g.forwTypeCache, key, className);
	addLine(sec(g, CSection.ForwardDecls), `extern msTypeInfo ${className}_typeInfo;`);
}

// ===== Full Type Description =====
// Main entry point: returns C type name string for a MetaScript Type.
// Emits type definitions to CGen sections as side effect.

export function getTypeDesc(g: CGen, t: Type): string {
	if (t === null) return "void*";
	// Standard reference parity: strip ownership modifiers at entry.
	// Ownership modifiers like sink and lent don't affect the C type descriptor.
	if (t.kind === TypeKind.Sink || t.kind === TypeKind.Lent) {
		return getTypeDesc(g, t.typeReturn);
	}
	const __k = t.kind;
	if (__k === null) return "void*";
	if (__k !== __k) return "void*";  // NaN check fallback

	// Check simple types first (no caching needed)
	const simple = getSimpleTypeDesc(t);
	if (simple !== "") {
		return simple;
	}

	// Check full cache
	const key = typeKey(t);
	const cached = typeCacheGet(g.typeCache, key);
	if (cached !== "") return cached;

	// Handle TypeReference before match — avoid match arm value propagation gotcha
	if (t.kind === TypeKind.TypeReference) {
		if (findChar(t.typeName, "=") >= 0 || (t.typeName.length > 0 && t.typeName.charAt(0) === "(")) {
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
		// Resolve via symbol table (reference PType parity: full type info via pointer)
		const resolved = resolveTypeName(g, t.typeName);
		if (resolved !== null) {
			return getTypeDesc(g, resolved);
		}
		// Fallback for C runtime types defined in headers (not in symbol table)
		const name = mangle(t.typeName);
		ensureForwardDecl(g, name);
		return name;
	}

	// Generate based on kind
	const result = match (t.kind) {
		TypeKind.Enum => {
			genEnumType(g, t);
		},
		TypeKind.Struct => {
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
			return ptrType;
		},
		TypeKind.Var => {
			// Var returns inner type desc — the * is added by ccgIntroducedPtr at declaration/call level
			const inner = getTypeDesc(g, t.typeReturn);
			typeCacheSet(g.typeCache, key, inner);
			return inner;
		},
		TypeKind.Borrow => {
			const inner = getTypeDesc(g, t.typeReturn);
			const ptrType = "const " + inner + "*";
			typeCacheSet(g.typeCache, key, ptrType);
			return ptrType;
		},
		TypeKind.Result => {
			return genResultType(g, t);
		},
		TypeKind.Map => {
			typeCacheSet(g.typeCache, key, "msMap");
			return "msMap";
		},
		TypeKind.Set => {
			typeCacheSet(g.typeCache, key, "msSet");
			return "msSet";
		},
		TypeKind.TypeReference => "void*", // handled above, shouldn't reach here
		TypeKind.Unknown => "void*",
		TypeKind.Any => "void*",
		TypeKind.Union => {
			return genUnionType(g, t);
		},
		TypeKind.Intersection => "void*",
		TypeKind.Tuple => {
			return genTupleType(g, t);
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
	addLine(sec(g, CSection.Types), `typedef int32_t ${name};`);

	// Emit enum constants (use explicit values from typeChildren if available)
	for (let i = 0; i < t.typeNames.length; i += 1) {
		const memberName = `${name}_${mangle(t.typeNames[i])}`;
		let val = i;
		if (t.typeChildren !== null && i < t.typeChildren.length && t.typeChildren[i] !== null) {
			val = t.typeChildren[i].typeFlags as number;
		}
		addLine(sec(g, CSection.Types), `#define ${memberName} (((${name})${val.toString()}))`);
	}
	addNewline(sec(g, CSection.Types));

	return name;
}

// ===== Object Type Generation =====
// Objects are always value-type structs. Pointer semantics come from Ref<T>/Ptr<T> wrapping.

function genObjectType(g: CGen, t: Type): string {
	// Anonymous/structural types get hash-based names; named types get mangled names
	const name = isAnonTypeName(t.typeName) ? anonTypeName(t) : mangle(t.typeName);
	const key = typeKey(t);

	// Always value type — Ref<Object> adds the * via TypeKind.Ref path
	const cTypeName = name;
	typeCacheSet(g.typeCache, key, cTypeName);

	// Ensure forward declaration
	ensureForwardDecl(g, name);

	// Cycle tracking (Standard implementation parity)
	// Track this type as "being defined" so genArrayType can detect self-referential
	// arrays (e.g., Type[] inside struct Type) and use the two-struct split.
	typesBeingDefined.push(key);

	// Pre-resolve field types BEFORE emitting struct body (Standard reference pattern).
	// Natural recursion ensures nested struct bodies are emitted BEFORE this struct.
	// This is correct for C: value-type fields need complete types.
	const fieldTypes: string[] = [];
	for (let i = 0; i < t.typeNames.length; i += 1) {
		let ft = (i < t.typeChildren.length) ? getTypeDesc(g, t.typeChildren[i]) : "void";
		// Self-referential fields: same type as containing struct → must be pointer
		// C cannot contain a struct by value inside itself (infinite size)
		if (ft === name) {
			ft = name + "*";
		}
		fieldTypes.push(ft);
	}

	// Build struct definition string
	let structDef = `#ifndef ${name}_DEFINED\n#define ${name}_DEFINED\nstruct ${name} {\n`;
	for (let i = 0; i < t.typeNames.length; i += 1) {
		structDef = structDef + `  ${fieldTypes[i]} ${mangleFieldName(t.typeNames[i])};\n`;
	}
	structDef = structDef + "};\n#endif\n";

	// Emit struct body directly (reference parity: natural recursion gives correct order)
	const b = sec(g, CSection.Types);
	add(b, structDef);
	addNewline(b);

	// Remove from cycle tracking
	typesBeingDefined.pop();

	// Flush deferred array content structs — this struct is now complete,
	// so any self-referential array content structs can be emitted
	if (deferredArrayContentStructs.length > 0 && typesBeingDefined.length === 0) {
		const b2 = sec(g, CSection.Types);
		for (const def of deferredArrayContentStructs) {
			addLine(b2, def);
		}
		deferredArrayContentStructs = [];
	}

	return cTypeName;
}

// ===== Union Type Generation =====
// Standard reference pattern: union variant structs + wrapper struct with anonymous union.
// Each variant Object type in typeChildren gets its own named struct.
// The `as` cast maps to .vN member access at the codegen level.

function genUnionType(g: CGen, t: Type): string {
	const name = (t.typeName.length > 0) ? mangle(t.typeName) : "msUnion_" + hashToBase36(typeKey(t));
	const key = typeKey(t);

	// Early return if already cached
	const cached = typeCacheGet(g.typeCache, key);
	if (cached !== "") return cached;

	typeCacheSet(g.typeCache, key, name);
	ensureForwardDecl(g, name);

	const b = sec(g, CSection.Types);

	// reference parity: no struct body deferral during union resolution.
	// Natural recursion ensures value-type field dependencies (e.g., Type in variant v29)
	// are emitted BEFORE the variant structs. The typeCache (set above) prevents re-entry.

	// Phase 1a: Cache all variant Object types AND pre-resolve ALL field types.
	// Track canonical names for structurally identical variants (e.g., { expr: Node }
	// appears as both ExprStmtData and HiddenDerefData — they share one C typedef).
	const allFieldTypes: string[][] = [];
	const canonicalNames: string[] = [];
	let vi = 0;
	while (vi < t.typeChildren.length) {
		const variant = t.typeChildren[vi];
		const varName = `${name}_v${intToString(vi)}`;

		// Cache variant Object type so getTypeDesc returns the variant struct name.
		// First variant with a given structural key wins — duplicates reuse it.
		let canonical = varName;
		if (variant !== null && variant.kind === TypeKind.Struct) {
			const varKey = typeKey(variant);
			const existing = typeCacheGet(g.typeCache, varKey);
			if (existing !== "") {
				canonical = existing;
			} else {
				typeCacheSet(g.typeCache, varKey, varName);
			}
		}
		canonicalNames.push(canonical);

		// Pre-resolve field types
		const fieldTypes: string[] = [];
		if (variant !== null && variant.typeNames !== null) {
			let fi = 0;
			while (fi < variant.typeNames.length) {
				let ft = (fi < variant.typeChildren.length && variant.typeChildren[fi] !== null)
					? getTypeDesc(g, variant.typeChildren[fi])
					: "void";
				fieldTypes.push(ft);
				fi += 1;
			}
		}
		allFieldTypes.push(fieldTypes);
		vi += 1;
	}

	// Phase 1b: Emit named variant structs (skip duplicates that reuse a canonical name)
	vi = 0;
	while (vi < t.typeChildren.length) {
		const variant = t.typeChildren[vi];
		const varName = `${name}_v${intToString(vi)}`;
		const fieldTypes = allFieldTypes[vi];

		// Skip duplicate: this variant reuses an earlier variant's typedef
		if (canonicalNames[vi] !== varName) {
			vi += 1;
			continue;
		}

		addLine(b, "typedef struct {");
		b.indent += 1;
		if (variant !== null && variant.typeNames !== null) {
			let fi = 0;
			while (fi < variant.typeNames.length) {
				addLine(b, `${fieldTypes[fi]} ${mangleFieldName(variant.typeNames[fi])};`);
				fi += 1;
			}
		}
		b.indent -= 1;
		addLine(b, "} " + varName + ";");

		vi += 1;
	}
	addNewline(b);

	// Phase 2: Emit wrapper struct with anonymous union
	addLine(b, `#ifndef ${name}_DEFINED`);
	addLine(b, `#define ${name}_DEFINED`);
	addLine(b, `struct ${name} {`);
	b.indent += 1;
	// Discriminated union: use enum type for _tag; undiscriminated: int32_t
	if (t.typeExtra !== null && t.typeExtra.kind === TypeKind.Enum && t.typeExtra.typeName !== "") {
		addLine(b, mangle(t.typeExtra.typeName) + " _tag;");
	} else {
		addLine(b, "int32_t _tag;");
	}
	addLine(b, "union {");
	b.indent += 1;
	vi = 0;
	while (vi < t.typeChildren.length) {
		// Use canonical name — duplicate variants share the same typedef
		const memberType = canonicalNames[vi];
		addLine(b, `${memberType} v${intToString(vi)};`);
		vi += 1;
	}
	b.indent -= 1;
	addLine(b, "};");
	b.indent -= 1;
	addLine(b, "};");
	addLine(b, "#endif");
	addNewline(b);

	return name;
}

// ===== Array Type Generation =====
// Standard reference pattern: each element type gets its own array typedef.
// Primitives use built-in types (msNumberArray, msStringArray).
// Struct/interface elements use per-type MS_ARRAY(T) typedefs.

function genArrayType(g: CGen, t: Type): string {
	const key = typeKey(t);

	// Check element type key for self-referentiality BEFORE resolving
	// (Standard implementation parity: cycle detection)
	const elemKey = (t.typeReturn !== null) ? typeKey(t.typeReturn) : "";
	const selfRef = elemKey !== "" && isBeingDefined(elemKey);

	const elemType = selfRef ? getTypeForward(g, t.typeReturn) : getTypeDesc(g, t.typeReturn);

	// Built-in array types for primitives
	if (elemType === "double") { typeCacheSet(g.typeCache, key, "msNumberArray"); return "msNumberArray"; }
	if (elemType === "msString") { typeCacheSet(g.typeCache, key, "msStringArray"); return "msStringArray"; }
	if (elemType === "MS_BOOL") { typeCacheSet(g.typeCache, key, "msNumberArray"); return "msNumberArray"; }
	if (elemType === "uint8_t") { typeCacheSet(g.typeCache, key, "msUint8Array"); return "msUint8Array"; }

	// Pointer element types (classes, refs, void*) → msRefArray (void* indirection is correct)
	// Resolve TypeReference via symbol table (reference PType parity)
	let resolvedElem = t.typeReturn;
	if (resolvedElem !== null && resolvedElem.kind === TypeKind.TypeReference && resolvedElem.typeName !== null) {
		const looked = resolveTypeName(g, resolvedElem.typeName);
		if (looked !== null) resolvedElem = looked;
	}
	// Class types: symbol table returns Ref<Struct>, resolvedElem.kind === Ref → isPointerType catches it.
	// Fallback for unresolved TypeReference: check knownClassNames.
	const elemIsClass = t.typeReturn !== null && t.typeReturn.kind === TypeKind.TypeReference &&
		t.typeReturn.typeName !== null && nameSetHas(g.knownClassNames, mangle(t.typeReturn.typeName));
	if (elemType === "void*" || elemIsClass || (resolvedElem !== null && isPointerType(resolvedElem))) {
		typeCacheSet(g.typeCache, key, "msRefArray");
		return "msRefArray";
	}

	// Value-type struct elements → per-type array typedef
	const arrTypeName = mangle(elemType) + "Array";
	typeCacheSet(g.typeCache, key, arrTypeName);

	// Emit typedef if not already done
	const fwdKey = "arrtd:" + arrTypeName;
	if (!typeCacheHas(g.forwTypeCache, fwdKey)) {
		typeCacheSet(g.forwTypeCache, fwdKey, arrTypeName);

		if (selfRef) {
			// Standard reference two-struct split: Array[T] = { len, p* } + Content = { cap, T data[] }
			// The slim struct has no dependency on T being complete (just a pointer).
			// The content struct needs T complete — deferred until parent struct is done.
			const contentName = arrTypeName + "__Content";
			const b = sec(g, CSection.Types);
			// Forward-declare both
			addLine(sec(g, CSection.ForwardDecls), `typedef struct ${arrTypeName} ${arrTypeName};`);
			addLine(sec(g, CSection.ForwardDecls), `typedef struct ${contentName} ${contentName};`);
			// Emit slim struct immediately (no dependency on element type)
			addLine(b, `struct ${arrTypeName} { int64_t len; ${contentName}* p; };`);
			// Defer content struct until element type is complete
			deferredArrayContentStructs.push(
				`struct ${contentName} { int64_t cap; ${mangle(elemType)} data[]; };`
			);
		} else {
			// Only use 'struct X' prefix for codegen-emitted structs.
			// Runtime typedefs (msRefArray etc.), pointers (void*), and primitives are bare names.
			const mangledElem = mangle(elemType);
			const needsStructPrefix = t.typeReturn !== null
				&& (t.typeReturn.kind === TypeKind.Struct || t.typeReturn.kind === TypeKind.Enum);
			const elemRef = needsStructPrefix ? ("struct " + mangledElem) : mangledElem;
			const line = `typedef MS_ARRAY(${elemRef}) ${arrTypeName};`;
			addLine(sec(g, CSection.Types), line);
		}
	}

	return arrTypeName;
}

// Returns the array type name for a given element type string (for use in expressions/statements).
export function getArrayTypeName(elemType: string): string {
	if (elemType === "double") return "msNumberArray";
	if (elemType === "msString") return "msStringArray";
	if (elemType === "uint8_t") return "msUint8Array";
	return mangle(elemType) + "Array";
}

// ===== Sized Array (Stack) =====

function genSizedArrayType(g: CGen, t: Type): string {
	const elemType = getTypeDesc(g, t.typeReturn);
	const size = t.typeFlags;
	const key = typeKey(t);
	const name = `msSizedArray_${mangle(elemType)}_${intToString(size)}`;

	if (typeCacheHas(g.typeCache, key)) return typeCacheGet(g.typeCache, key);
	typeCacheSet(g.typeCache, key, name);

	ensureForwardDecl(g, name);
	const b = sec(g, CSection.Types);
	addLine(b, `struct ${name} {`);
	addLine(b, `    ${elemType} data[${intToString(size)}];`);
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
	addLine(b, `struct ${name} {`);
	addLine(b, `    ${elemType}* data;`);
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

// ===== Closure Cast Helpers (Standard reference pattern) =====
// Shared helpers for genClHalfCast/genClFullCast — standard reference pattern
// with a declareEnvironment boolean. We extract the common param/return mapping.

function closureParamTypeToC(g: CGen, pt: Type): string {
	if (pt === null) return "void*";
	const simple = getSimpleTypeDesc(pt);
	if (simple !== "") return simple;
	const desc = getTypeDesc(g, pt);
	// Reference parity: ccgIntroducedPtr params are passed by pointer in C
	if (ccgIntroducedPtr(pt)) return desc + "*";
	return desc;
}

function closureRetTypeToC(g: CGen, t: Type): string {
	if (t !== null && t.kind === TypeKind.Function && t.typeReturn !== null) {
		return closureParamTypeToC(g, t.typeReturn);
	}
	if (t !== null && t.kind === TypeKind.TypeReference) return "void*";
	return "void";
}

// ===== Closure Half Type (standard reference implementation parity — direct fn pointer without env) =====
// Generates a C function pointer type string from a Function type:
//   (n: number) => boolean  →  "MS_BOOL(*)(double)"
// Reference implementation equivalent: get closure type cast string.

// Build closure function pointer cast: retType(*)(params...)
// withEnv=true appends void* for the env parameter (full closure call).
// Standard reference parity: environment is the LAST parameter in closure calls.
// ARM64 requires non-variadic casts — variadic calling convention differs.
// nrvoType: if non-empty, return type becomes void and nrvoType* is prepended as first param.
function genClosureCast(g: CGen, t: Type, withEnv: boolean, nrvoType: string): string {
	let retC = "";
	if (nrvoType !== "") {
		retC = "void";
	} else {
		retC = closureRetTypeToC(g, t);
	}
	let params = "";
	// NRVO: first param is the hidden result pointer
	if (nrvoType !== "") {
		params = nrvoType + "*";
	}
	if (t !== null && t.kind === TypeKind.Function && t.typeChildren.length > 0) {
		let i = 0;
		while (i < t.typeChildren.length) {
			if (params !== "") params = params + ", ";
			params = params + closureParamTypeToC(g, t.typeChildren[i]);
			i = i + 1;
		}
		if (withEnv) params = params + ", void*";
	} else if (withEnv) {
		if (params !== "") params = params + ", ";
		params = params + "void*";
	} else if (params === "") {
		params = "void";
	}
	return `${retC}(*)(${params})`;
}

// Reference parity: genProcParams adds Result* param for isInvalidReturnType.
// getClosureType calls genProcParams — so closure casts ALWAYS include NRVO when return type requires it.
// Auto-detect NRVO from the function type's return type, matching the shared genProcParams path.
function autoNrvoType(g: CGen, t: Type): string {
	if (t !== null && t.kind === TypeKind.Function && t.typeReturn !== null && isNrvoReturnType(t.typeReturn)) {
		return getTypeDesc(g, t.typeReturn);
	}
	return "";
}

export function genClHalfCast(g: CGen, t: Type): string { return genClosureCast(g, t, false, autoNrvoType(g, t)); }
export function genClFullCast(g: CGen, t: Type): string { return genClosureCast(g, t, true, autoNrvoType(g, t)); }
export function genClHalfCastNrvo(g: CGen, t: Type, nrvoType: string): string { return genClosureCast(g, t, false, nrvoType); }
export function genClFullCastNrvo(g: CGen, t: Type, nrvoType: string): string { return genClosureCast(g, t, true, nrvoType); }

// ===== Result Type Generation =====

export function genResultType(g: CGen, t: Type): string {
	const okType = getTypeDesc(g, t.typeReturn);
	const errType = getTypeDesc(g, t.typeExtra);
	const key = typeKey(t);

	// Generate unique struct name
	const name = `msResult_${mangle(okType)}_${mangle(errType)}`;
	typeCacheSet(g.typeCache, key, name);

	// Emit struct (guarded to avoid redefinition when cross-module protos exist)
	ensureForwardDecl(g, name);
	const b = sec(g, CSection.Types);
	addLine(b, `#ifndef ${name}_DEFINED`);
	addLine(b, `#define ${name}_DEFINED`);
	addLine(b, `struct ${name} {`);
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
	addLine(b, `#ifndef ${name}_DEFINED`);
	addLine(b, `#define ${name}_DEFINED`);
	addLine(b, `struct ${name} {`);
	b.indent += 1;
	let i = 0;
	while (i < t.typeChildren.length) {
		const ft = getTypeDesc(g, t.typeChildren[i]);
		addLine(b, `${ft} _${intToString(i)};`);
		i += 1;
	}
	b.indent -= 1;
	addLine(b, "};");
	addLine(b, "#endif");
	addNewline(b);

	return name;
}

// ===== Tests =====

import { createPrimitive, createStruct, createArray, createFunction, createEnum, createResult, createTypeRef, createRef, createTuple } from "../../checker/types";
import { createCGen } from "./context";
import { CheckerContext } from "../../checker/context";
test "primitive keys" {
	assert typeKey(createPrimitive(TypeKind.Number)) === "number";
	assert typeKey(createPrimitive(TypeKind.String)) === "string";
	assert typeKey(createPrimitive(TypeKind.Boolean)) === "boolean";
	assert typeKey(createPrimitive(TypeKind.Void)) === "void";
}

test "enum key" { assert typeKey(createEnum("Color", ["Red", "Green"], null as unknown as number[])) === "enum:Color"; }

test "object key" { assert typeKey(createStruct("Foo", [], [], true)) === "object:Foo"; }

test "null type" { assert typeKey(null) === "null"; }

test "primitives" {
	assert getSimpleTypeDesc(createPrimitive(TypeKind.Number)) === "double";
	assert getSimpleTypeDesc(createPrimitive(TypeKind.Int32)) === "int32_t";
	assert getSimpleTypeDesc(createPrimitive(TypeKind.Boolean)) === "MS_BOOL";
	assert getSimpleTypeDesc(createPrimitive(TypeKind.String)) === "msString";
	assert getSimpleTypeDesc(createPrimitive(TypeKind.Void)) === "void";
}

test "non-primitive returns empty" {
	assert getSimpleTypeDesc(createEnum("X", [], null as unknown as number[])) === "";
	assert getSimpleTypeDesc(createStruct("Y", [], [], true)) === "";
}

test "class (Ref<Object>) is pointer" { assert isPointerType(createRef(createStruct("Foo", [], [], true))); }

test "interface is not pointer" { assert !isPointerType(createStruct("Bar", [], [], true)); }

test "ref is pointer" { assert isPointerType(createRef(createPrimitive(TypeKind.Int32))); }

test "primitive is not pointer" { assert !isPointerType(createPrimitive(TypeKind.Number)); }

test "string needs RC" { assert needsRC(createPrimitive(TypeKind.String)); }

test "array needs RC" { assert needsRC(createArray(createPrimitive(TypeKind.Number))); }

test "class (Ref<Object>) needs RC" { assert needsRC(createRef(createStruct("Foo", [], [], true))); }

test "interface no RC" { assert !needsRC(createStruct("Bar", [], [], true)); }

test "number no RC" { assert !needsRC(createPrimitive(TypeKind.Number)); }

test "map needs RC" { assert needsRC(createPrimitive(TypeKind.Map)); }

test "map is not pointer" { assert !isPointerType(createPrimitive(TypeKind.Map)); }

test "map type key" {
	const t = createPrimitive(TypeKind.Map);
	t.typeReturn = createPrimitive(TypeKind.String);
	t.typeExtra = createPrimitive(TypeKind.Number);
	assert typeKey(t) === "map:string:number";
}

test "map type desc" {
	const g = createCGen(null as unknown as CheckerContext, "");
	const t = createPrimitive(TypeKind.Map);
	t.typeReturn = createPrimitive(TypeKind.String);
	t.typeExtra = createPrimitive(TypeKind.Number);
	assert getTypeDesc(g, t) === "msMap";
}

test "primitive type desc" {
	const g = createCGen(null as unknown as CheckerContext, "");
	assert getTypeDesc(g, createPrimitive(TypeKind.Number)) === "double";
	assert getTypeDesc(g, createPrimitive(TypeKind.Int32)) === "int32_t";
	assert getTypeDesc(g, createPrimitive(TypeKind.String)) === "msString";
}

test "enum emits typedef and defines" {
	const g = createCGen(null as unknown as CheckerContext, "");
	const result = getTypeDesc(g, createEnum("Color", ["Red", "Green", "Blue"], null as unknown as number[]));
	assert result === "Color";
	const types = extract(sec(g, CSection.Types));
	assert types.contains("typedef int32_t Color");
	assert types.contains("Color_Red");
	assert types.contains("Color_Green");
	assert types.contains("Color_Blue");
}

test "interface emits struct" {
	const propNames: string[] = [];
	propNames.push("x");
	propNames.push("y");
	const propTypes: Type[] = [];
	propTypes.push(createPrimitive(TypeKind.Int32));
	propTypes.push(createPrimitive(TypeKind.Int32));
	const g = createCGen(null as unknown as CheckerContext, "");
	const result = getTypeDesc(g, createStruct("Point", propNames, propTypes, true));
	assert result === "Point";
	const types = extract(sec(g, CSection.Types));
	assert types === "#ifndef Point_DEFINED\n#define Point_DEFINED\nstruct Point {\n  int32_t x;\n  int32_t y;\n};\n#endif\n\n";
}

test "class (Ref<Object>) emits struct with pointer" {
	const propNames: string[] = [];
	propNames.push("name");
	const propTypes: Type[] = [];
	propTypes.push(createPrimitive(TypeKind.String));
	const g = createCGen(null as unknown as CheckerContext, "");
	const result = getTypeDesc(g, createRef(createStruct("Person", propNames, propTypes, true)));
	assert result === "Person*";
	const types = extract(sec(g, CSection.Types));
	assert types === "#ifndef Person_DEFINED\n#define Person_DEFINED\nstruct Person {\n  msString name;\n};\n#endif\n\n";
}

test "array type" {
	const g = createCGen(null as unknown as CheckerContext, "");
	assert getTypeDesc(g, createArray(createPrimitive(TypeKind.Number))) === "msNumberArray";
	assert getTypeDesc(g, createArray(createPrimitive(TypeKind.String))) === "msStringArray";
}

test "forward decl emitted" {
	const g = createCGen(null as unknown as CheckerContext, "");
	getTypeDesc(g, createStruct("Widget", [], [], true));
	const fwd = extract(sec(g, CSection.ForwardDecls));
	assert fwd === "#ifndef Widget_DEFINED\ntypedef struct Widget Widget;\n#endif\n";
}

test "cached second call" {
	const g = createCGen(null as unknown as CheckerContext, "");
	const t = createEnum("Dir", ["Up", "Down"], null as unknown as number[]);
	const r1 = getTypeDesc(g, t);
	const r2 = getTypeDesc(g, t);
	assert r1 === r2;
	assert r1 === "Dir";
}

test "anonymous type gets unique name" {
	const names1: string[] = [];
	names1.push("x");
	names1.push("y");
	const types1: Type[] = [];
	types1.push(createPrimitive(TypeKind.Number));
	types1.push(createPrimitive(TypeKind.Number));
	const anon1 = createStruct("", names1, types1, true);
	const name1 = anonTypeName(anon1);
	assert name1 !== "empty_";
	assert name1.length > 7; // "msAnon_" + at least 1 char
}

test "different anonymous types get different names" {
	const names1: string[] = [];
	names1.push("x");
	names1.push("y");
	const types1: Type[] = [];
	types1.push(createPrimitive(TypeKind.Number));
	types1.push(createPrimitive(TypeKind.Number));
	const anon1 = createStruct("", names1, types1, true);

	const names2: string[] = [];
	names2.push("a");
	names2.push("b");
	const types2: Type[] = [];
	types2.push(createPrimitive(TypeKind.String));
	types2.push(createPrimitive(TypeKind.Boolean));
	const anon2 = createStruct("", names2, types2, true);

	assert anonTypeName(anon1) !== anonTypeName(anon2);
}

test "same anonymous type gets same name (deterministic)" {
	const names1: string[] = [];
	names1.push("x");
	const types1: Type[] = [];
	types1.push(createPrimitive(TypeKind.Int32));
	const anon1 = createStruct("", names1, types1, true);

	const names2: string[] = [];
	names2.push("x");
	const types2: Type[] = [];
	types2.push(createPrimitive(TypeKind.Int32));
	const anon2 = createStruct("", names2, types2, true);

	assert anonTypeName(anon1) === anonTypeName(anon2);
}

test "anonymous type cache key distinguishes" {
	const names1: string[] = [];
	names1.push("x");
	const types1: Type[] = [];
	types1.push(createPrimitive(TypeKind.Number));
	const anon1 = createStruct("", names1, types1, true);

	const names2: string[] = [];
	names2.push("y");
	const types2: Type[] = [];
	types2.push(createPrimitive(TypeKind.String));
	const anon2 = createStruct("", names2, types2, true);

	assert typeKey(anon1) !== typeKey(anon2);
}

test "tuple type key" {
	const t = createTuple([createPrimitive(TypeKind.Number), createPrimitive(TypeKind.String)]);
	assert typeKey(t) === "tuple:number,string";
}

test "tuple type desc emits struct" {
	const g = createCGen(null as unknown as CheckerContext, "");
	const t = createTuple([createPrimitive(TypeKind.Number), createPrimitive(TypeKind.String)]);
	const name = getTypeDesc(g, t);
	assert name !== "void*";
	assert name.length > 8; // "msTuple_" + hash
	const types = extract(sec(g, CSection.Types));
	assert types.length > 0;
}

test "tuple needsRC with string element" {
	const t = createTuple([createPrimitive(TypeKind.Number), createPrimitive(TypeKind.String)]);
	assert needsRC(t);
}

test "tuple needsRC without RC elements" {
	const t = createTuple([createPrimitive(TypeKind.Number), createPrimitive(TypeKind.Int32)]);
	assert !needsRC(t);
}

test "set needs RC" { assert needsRC(createPrimitive(TypeKind.Set)); }

test "anonymous type emits struct with hash name" {
	const names1: string[] = [];
	names1.push("x");
	names1.push("y");
	const types1: Type[] = [];
	types1.push(createPrimitive(TypeKind.Number));
	types1.push(createPrimitive(TypeKind.Number));
	const anon = createStruct("", names1, types1, true);
	const g = createCGen(null as unknown as CheckerContext, "");
	const result = getTypeDesc(g, anon);
	// Should NOT be "empty_"
	assert result !== "empty_";
	// Should start with msAnon_
	assert result.length > 7;
}
