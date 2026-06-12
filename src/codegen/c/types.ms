// C Codegen — Type Mapping
//
// Follows standard reference implementation patterns for type mapping.
// Two-tier cache (forwTypeCache for forward decls, typeCache for full defs).
// Topological emit with cycle detection via forward declarations.

import { isStructType, getTypeSize, skipModifier, isAwaitable, awaitedType, isResult, substituteType, createStruct, createArray, needsRC, hasAsgnFlag, unwrapRefNullUnion, peelToStructOrUnion, peelToStruct, hasDestructor, getAttachedOp } from "../../checker/types";
import { AttachedOp } from "../../ast/node";
import { getGenericDecl } from "../../parser/context";
import { monoTypeKey } from "../../monomorphize/registry";
import { Node, NodeKind, NodeFlag, CallExprData, ObjectLiteralData, Type, TypeKind, SymbolKind } from "../../ast/node";
import { findChar, splitTopLevel } from "../../utils/string";
import { hashToBase36 as _stdHashToBase36 } from "std/hash";
import { CGen, CSection, add, addLine, addNewline, extract, sec, typeCacheGet, typeCacheSet, typeCacheHas, NameSet, nameSetHas, nameSetAdd, createNameSet } from "./context";
import { SymbolFlag, hasFlag } from "../../checker/symbol";
import { mangle, mangleFieldName, safeName } from "./names";
import { useHeader } from "./context";

// ===== Generated destroy-hook registry (Nim graph.attachedOps[attachedDestructor] analog) =====
// destructorLifting sets AttachedDestructor on a per-Type-object instance (a throwaway built by
// unwrapGenericInstance for mono types), so the op never reaches the canonical type codegen reads.
// Nim instead keeps attached ops in a GLOBAL table keyed by type identity. Mirror that: record the
// mangled type name whenever a real destroy hook is generated, and let `ensureTypeInfoDef` consult
// it by name to wire `.destroyFn` for monomorphized instances (whose objType carries no op).
// Lives here (codegen) so destructorLifting — which already imports this module — can populate it
// without an import cycle. Reset per build via `setGlobalHookOwners` to avoid cross-test bleed.
let _genDestroyHooks: NameSet = createNameSet();
export function recordGenDestroyHook(typeName: string): void { nameSetAdd(_genDestroyHooks, typeName); }
export function genHasDestroyHook(typeName: string): boolean { return nameSetHas(_genDestroyHooks, typeName); }
export function resetGenDestroyHooks(): void { _genDestroyHooks = createNameSet(); }

// ===== Type Resolution =====
// All types are fully resolved PType objects by codegen time.
// No TypeReference ever reaches codegen — the checker resolves everything.


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

// ===== Anonymous Type Naming =====
// Generates deterministic C struct names for anonymous interfaces (typeName === "").
// Uses a structural key (field names + types) hashed to a short hex-like string.

function anonFieldKey(t: Type | null): string {
	if (t === null) return "null";
	return match (t.kind) {
		TypeKind.Struct => {
			if (t.typeName.length === 0) return `anon(${anonStructuralKey(t)})`;
			return t.typeName;
		},
		TypeKind.Enum => "enum:" + t.typeName,
		TypeKind.Array => "arr:" + anonFieldKey(t.typeReturn),
		TypeKind.Function => "fn",
		TypeKind.Ref | TypeKind.Ptr => "ptr:" + anonFieldKey(t.typeReturn),
		TypeKind.Unknown => "unknown",
		TypeKind.Varargs => t.typeChildren.length > 0 ? anonFieldKey(t.typeChildren[0]) : "unknown",
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
export function hashToBase36(s: string): string { return _stdHashToBase36(s); }

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
	const s = annotation.trim();
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
		if (elem.endsWith("[ ]")) elem = elem.slice(0, elem.byteLength - 3);
		else elem = elem.slice(0, elem.byteLength - 2);
		elem = elem.trim();
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
// Used by proto-path (index.ms) for anonymous struct definitions.

export function buildAnonStructDef(structName: string, rawName: string): string {
	// Strip outer braces
	let body = rawName.trim();
	if (body.byteLength > 0 && body.charAt(0) === "{") body = body.slice(1, body.byteLength);
	if (body.byteLength > 0 && body.charAt(body.byteLength - 1) === "}") body = body.slice(0, body.byteLength - 1);

	// splitTopLevel handles nested brackets/generics and auto-trims
	const fields = splitTopLevel(body, ",");

	let def = `#ifndef ${structName}_DEFINED\n`;
	def = def + `#define ${structName}_DEFINED\n`;
	def = def + `typedef struct ${structName} ${structName};\n`;
	def = def + `struct ${structName} {\n`;

	for (const field of fields) {
		const colonPos = findChar(field, ":");
		if (colonPos < 0) continue;
		const fname = field.slice(0, colonPos).trim();
		const ftype = field.slice(colonPos + 1, field.length).trim();
		def = def + `  ${annotationToC(ftype)} ${safeName(fname)};\n`;
	}

	def = def + "};\n#endif\n";
	return def;
}

// ===== Type Signature Key =====
// Generates a unique string key for a Type (used for cache lookups).

export function typeKey(t: Type | null): string {
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
		TypeKind.StringLiteral => "strlit:" + t.typeName,
		TypeKind.BooleanLiteral => "boollit:" + t.typeName,
		TypeKind.Void => "void",
		TypeKind.Null => "null",
		TypeKind.Enum => { return "enum:" + t.typeName; },
		TypeKind.EnumLiteral => { return "enum:" + t.typeName; },
		TypeKind.Struct => {
			// Anonymous/structural types: use structural key to distinguish
			if (isAnonTypeName(t.typeName)) {
				return `anon(${anonStructuralKey(t)})`;
			} else {
				return "object:" + t.typeName;
			}
		},
		TypeKind.Array => {
			const elemKey = typeKey(t.typeReturn);
			return "array:" + elemKey;
		},
		TypeKind.SizedArray => {
			const elemKey = typeKey(t.typeReturn);
			return `sizedArray:${elemKey}[${t.typeFlags}]`;
		},
		TypeKind.Span => {
			const elemKey = typeKey(t.typeReturn);
			return "span:" + elemKey;
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
			return key;
		},
		TypeKind.Ref => { return "ref:" + typeKey(t.typeReturn); },
		TypeKind.Ptr => { return "ptr:" + typeKey(t.typeReturn); },
		TypeKind.Var => { return "var:" + typeKey(t.typeReturn); },
		TypeKind.Borrow => { return "borrow:" + typeKey(t.typeReturn); },
		TypeKind.GenericInstance => {
			let giKey = `ginst:${t.typeName}`;
			for (const arg of t.typeChildren) giKey = `${giKey}:${typeKey(arg)}`;
			return giKey;
		},
		TypeKind.TypeReference => { return "unknown"; },
		TypeKind.Distinct => { return "distinct:" + t.typeName; },
		TypeKind.Union => {
			if (t.typeName.length > 0) {
				return "union:" + t.typeName;
			} else {
				let key = "union(";
				let ui = 0;
				while (ui < t.typeChildren.length) {
					if (ui > 0) key = key + "|";
					key = key + typeKey(t.typeChildren[ui]);
					ui += 1;
				}
				return key + ")";
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
			return key;
		},
		TypeKind.Varargs => t.typeChildren.length > 0 ? typeKey(t.typeChildren[0]) : "unknown",
		_ => "unknown",
	};
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
		TypeKind.BooleanLiteral => "MS_BOOL",
		TypeKind.Char => "char",
		TypeKind.String | TypeKind.StringLiteral => "msString",
		TypeKind.CString => "const char*",
		TypeKind.Void => "void",
		// `Null` as a TYPE (not the literal value) appears when a generic param
		// monomorphizes to T=Null — e.g. `id(null)` without contextual type.
		// `void` is invalid for parameters and locals, so map to `void*` which
		// is exactly what MS_NIL/`((void*)0)` already is. Functions returning
		// or accepting `Null`-typed values then compile and link correctly.
		TypeKind.Null => "void*",
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
	// Union(Ref<T>, Null) collapses to T* in C — same C representation as Ref<T>.
	if (inner.kind === TypeKind.Union && unwrapRefNullUnion(inner) !== null) return true;
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
	return k === TypeKind.Struct || k === TypeKind.Array || k === TypeKind.GenericInstance
		|| k === TypeKind.Tuple || k === TypeKind.String || k === TypeKind.Function
		|| k === TypeKind.Union;
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
	if (isStructType(inner)) return getTypeSize(inner) > PTR_THRESHOLD;
	// Union(Ref<T>, Null) collapses to T* in C — the pointer IS the value, no struct-via-pointer.
	if (inner.kind === TypeKind.Union && unwrapRefNullUnion(inner) !== null) return false;
	return match (inner.kind) {
		TypeKind.Tuple => getTypeSize(inner) > PTR_THRESHOLD,
		TypeKind.Array => true,  // arrays always by pointer: mutable by default, realloc invalidates caller copy
		TypeKind.Union | TypeKind.Span => true,
		TypeKind.GenericInstance => !isAwaitable(inner),
		_ => false,
	};
}

// Mutation forces T* for Struct, Function (msClosure 16B), and small Tuple.
// Actor lowering sets mutation bits via markValueLayoutParamsAsMutated.
export function shouldIndirectParam(paramType: Type, isMutated: boolean): boolean {
	if (paramType === null) return false;
	const inner = skipModifier(paramType);
	if (inner !== null && isStructType(inner)) {
		if (isMutated) return true;
		return getTypeSize(inner) > PTR_THRESHOLD;
	}
	if (isMutated && inner !== null && (inner.kind === TypeKind.Function || inner.kind === TypeKind.Tuple)) return true;
	return ccgIntroducedPtr(paramType);
}

// Should this promoted param use const qualifier?
// Only unmutated struct params get const — all other promoted types use plain T*.
export function shouldConstParam(paramType: Type, isMutated: boolean): boolean {
	if (isMutated) return false;
	if (paramType === null) return false;
	const inner = skipModifier(paramType);
	return inner !== null && isStructType(inner);
}

// needsRC is now in checker/types.ms — imported above

// ===== NRVO Detection (Type-based, Standard reference parity) =====
// Returns true for types that are C structs — these need out-param calling convention.

// Reference parity: type defined in C header — skip codegen emission.
function isImportedType(t: Type): boolean {
	return t.sym !== null && hasFlag(t.sym, SymbolFlag.ImportC);
}

// Emit #include for imported type's header (reference parity: header pragma).
function useImportedTypeHeader(g: CGen, t: Type): void {
	if (t.sym !== null && t.sym.headerPath !== "") {
		useHeader(g, t.sym);
	}
}

// Reference parity (isInvalidReturnType): returns true when NRVO needed.
// Takes the return type AND optionally the function type (for cdecl/importc check).
export function isNrvoReturnType(retType: Type | null, funcType: Type | null): boolean {
	if (retType === null) return false;
	// importc return types → no NRVO (C struct returned by value)
	if (isImportedType(retType)) return false;
	// importc/cdecl functions → no NRVO (C ABI compatibility)
	if (funcType !== null && funcType.sym !== null && hasFlag(funcType.sym, SymbolFlag.ImportC)) return false;
	if (isStructType(retType)) return true;
	if (retType.kind === TypeKind.Span) return true;
	if (isResult(retType)) return true;
	if (retType.kind === TypeKind.Tuple) return true;
	return false;
}

// ===== NRVO Call-Site Detection (Standard reference pattern) =====
// Centralized two-source callee type lookup. Reference implementation uses a single isInvalidReturnType()
// in reference types called from 10 locations across 4 files.

// Peek inside an ObjectLiteral closure pair for the wrapped function's
// type info. lambdaLifting builds `{ fn: <typed-Identifier>, env: null }`
// where the Identifier's nodeType is the original arrow's Function type
// (set in liftNonCapturing). Without this peek, IIFE callees report null
// Function type and genClosureCall emits `void(*)(void)` casts.
function closurePairFuncType(callee: Node): Type | null {
	if (callee === null || callee.kind !== NodeKind.ObjectLiteral) return null;
	if ((callee.flags & NodeFlag.Closure) === 0) return null;
	const od = callee.data as ObjectLiteralData;
	if (od.properties.length === 0) return null;
	const fnProp = od.properties[0];
	if (fnProp.nodeType !== null && fnProp.nodeType.kind === TypeKind.Function) {
		return fnProp.nodeType;
	}
	if (fnProp.resolvedSym !== null && fnProp.resolvedSym.symbolType !== null
		&& fnProp.resolvedSym.symbolType.kind === TypeKind.Function) {
		return fnProp.resolvedSym.symbolType;
	}
	return null;
}

export function getCalleeReturnType(callNode: Node): Type | null {
	const cd = callNode.data as CallExprData;
	if (cd.callee !== null && cd.callee.nodeType !== null && cd.callee.nodeType.kind === TypeKind.Function) {
		return cd.callee.nodeType.typeReturn;
	}
	if (callNode.resolvedSym !== null && callNode.resolvedSym.symbolType !== null) {
		const st = callNode.resolvedSym.symbolType;
		if (st.kind === TypeKind.Function) return st.typeReturn;
	}
	const cpType = closurePairFuncType(cd.callee);
	if (cpType !== null) return cpType.typeReturn;
	return null;
}

export function getCalleeFuncType(callNode: Node): Type | null {
	const cd = callNode.data as CallExprData;
	if (cd.callee !== null && cd.callee.nodeType !== null && cd.callee.nodeType.kind === TypeKind.Function) {
		return cd.callee.nodeType;
	}
	if (callNode.resolvedSym !== null && callNode.resolvedSym.symbolType !== null) {
		const st = callNode.resolvedSym.symbolType;
		if (st.kind === TypeKind.Function) return st;
	}
	const cpType = closurePairFuncType(cd.callee);
	if (cpType !== null) return cpType;
	return null;
}

// ===== Forward Declaration =====
// Emits "typedef struct X X;" to cfsForwardDecls if not already done.

// getTypeForward — Standard reference implementation parity: like getTypeDesc but only emits a forward
// declaration + returns the C type name. Used when only a pointer is needed
// (e.g., array element type during self-referential struct definition).
export function getTypeForward(g: CGen, t: Type | null): string {
	if (t === null) return "void*";
	const simple = getSimpleTypeDesc(t);
	if (simple !== "") return simple;
	// Check cache — if already fully resolved, just return
	const key = typeKey(t);
	const cached = typeCacheGet(g.typeCache, key);
	if (cached !== "") return cached;
	// For Object/Enum — forward-declare only
	if (t.kind === TypeKind.Struct || t.kind === TypeKind.Enum) {
		const name = isAnonTypeName(t.typeName) ? anonTypeName(t) : mangle(t.typeName);
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
// The owning module emits `msTypeInfo FooTypeInfo;` via destructorLifting (non-static linkage).
// Consuming modules need `extern msTypeInfo FooTypeInfo;` to reference it.
export function ensureTypeInfo(g: CGen, className: string): void {
	// TypeInfo is DRC metadata — unused under --gc=manual (write-only in manual.h).
	if (g.checkerCtx !== null && g.checkerCtx.gcMode === GcMode.Manual) return;
	const key = "typeInfo:" + className;
	if (typeCacheHas(g.forwTypeCache, key)) return;
	typeCacheSet(g.forwTypeCache, key, className);
	addLine(sec(g, CSection.ForwardDecls), `extern msTypeInfo ${className}TypeInfo;`);
}

// Ensure msTypeInfo exists for object literal allocation (new Foo()).
// Reference parity (genTypeInfoV2): ownership-based deduplication.
// The owning module (has InterfaceDecl/ClassDecl → in declaredThings) emits the definition.
// Consuming modules emit extern. Compiler-generated types ($Env_*) are always local.
//
// Optional `objType` parameter wires the destroyFn field from the type's AttachedOps.
// destructorLifting calls setAttachedOp(type, AttachedDestructor, "<typeName>Destroy")
// when it generates the Destroy hook. When the caller has the Type available, pass
// it here so the TypeInfo gets `.destroyFn = (msDestroyProc)<mangled-destroy>;`. For
// types where destructorLifting ALSO emits a full TypeInfo (e.g. user-declared
// classes/interfaces with explicit InterfaceDecl), both paths assign the same value
// → harmless duplicate. For compiler-generated types ($Env_*) where destructorLifting
// only emits hooks (consumer path), this is the ONLY assignment, and missing it
// causes the env's Promise / Ref / managed fields to leak (async fn pattern).
export function ensureTypeInfoDef(g: CGen, className: string, objType: Type | null): void {
	// TypeInfo is DRC metadata — unused under --gc=manual (write-only in manual.h).
	if (g.checkerCtx !== null && g.checkerCtx.gcMode === GcMode.Manual) return;
	const defKey = "typeInfoDef:" + className;
	if (typeCacheHas(g.forwTypeCache, defKey)) return;
	typeCacheSet(g.forwTypeCache, defKey, className);
	// Check if destructorLifting already generated it (via genTypeInfoVar)
	const key = "typeInfo:" + className;
	if (typeCacheHas(g.typeCache, key)) return;
	// Ownership check (reference parity: genTypeInfoV2 routes to owning module).
	// declaredThings has the mangled name if this module processed InterfaceDecl/ClassDecl/EnumDecl.
	// Compiler-generated ($Env_*) and monomorphized generics (Map__K_V) are always local.
	const isCompilerGen = className.length > 0 && className.slice(0, 1) === "$";
	const isGeneric = className.indexOf("__", 0) >= 0;
	const isOwner = nameSetHas(g.declaredThings, className) || isCompilerGen || isGeneric;
	if (!isOwner) {
		ensureTypeInfo(g, className);
		return;
	}
	// Owning module: emit definition + DatInit assignment.
	// Generics use weak linkage — multiple modules may emit, linker deduplicates.
	if (isGeneric) {
		addLine(sec(g, CSection.GlobalVars), `__attribute__((weak)) msTypeInfo ${className}TypeInfo;`);
	} else {
		addLine(sec(g, CSection.GlobalVars), `msTypeInfo ${className}TypeInfo;`);
	}
	addLine(sec(g, CSection.DatInit), `  ${className}TypeInfo.name = "${className}";`);
	let destroyHook = "";
	if (objType !== null && hasDestructor(objType)) {
		destroyHook = mangle(getAttachedOp(objType, AttachedOp.AttachedDestructor));
	} else if (isGeneric && genHasDestroyHook(className)) {
		// Monomorphized generic: AttachedDestructor was set on a throwaway type instance in
		// destructorLifting (unwrapGenericInstance builds a fresh body), so it never reaches the
		// objType resolved here. Consult the global destroy-hook registry by mangled name — the MS
		// analog of Nim's identity-keyed graph.attachedOps[attachedDestructor] — and wire by
		// convention. This is an alloc site (msAllocTyped needs sizeof), so the struct is declared;
		// the typed proto matches the real hook signature (redundant-decl-safe) and resolves
		// cross-module to the owner module's global hook.
		destroyHook = mangle(className + "Destroy");
		ensureForwardDecl(g, className);
		addLine(sec(g, CSection.ForwardDecls), `void ${destroyHook}(${className}* self);`);
	}
	if (destroyHook.length > 0) {
		addLine(sec(g, CSection.DatInit), `  ${className}TypeInfo.destroyFn = (msDestroyProc)${destroyHook};`);
	}
}

// ===== Full Type Description =====
// Main entry point: returns C type name string for a MetaScript Type.
// Emits type definitions to CGen sections as side effect.

export function getTypeDesc(g: CGen, t: Type | null): string {
	if (t === null) return "void*";
	// Standard reference parity: strip ownership modifiers at entry.
	// Ownership modifiers like sink and lent don't affect the C type descriptor.
	if (t.kind === TypeKind.Sink || t.kind === TypeKind.Lent) {
		return getTypeDesc(g, t.typeReturn);
	}
	// Distinct types are nominal in the checker only — at the C ABI level they
	// share the underlying type's representation (e.g. `distinct type UserId =
	// number` compiles to `double`).
	if (t.kind === TypeKind.Distinct) {
		return getTypeDesc(g, t.typeReturn);
	}
	// Reference parity: tyVarargs is a transparent marker for rest params. The C
	// param descriptor is the wrapped array type — the marker carries no ABI.
	if (t.kind === TypeKind.Varargs && t.typeChildren.length > 0) {
		return getTypeDesc(g, t.typeChildren[0]);
	}
	// Check simple types first (no caching needed)
	const simple = getSimpleTypeDesc(t);
	if (simple !== "") {
		return simple;
	}

	// Check full cache
	const key = typeKey(t);
	const cached = typeCacheGet(g.typeCache, key);
	if (cached !== "") return cached;

	// Result is a boolean-discriminated match-type Union (createResult builds it).
	// Flow through the standard GenericInstance → Union path below; no bespoke
	// codegen needed.
	if (isAwaitable(t)) return genFutureType(g, t);

	return match (t.kind) {
		TypeKind.Enum => genEnumType(g, t),
		// EnumLiteral: treated as its underlying enum for C codegen (ints at runtime)
		TypeKind.EnumLiteral => {
			if (t.typeReturn !== null && t.typeReturn.kind === TypeKind.Enum) return genEnumType(g, t.typeReturn);
			return "int32_t";
		},
		TypeKind.Struct => genObjectType(g, t),
		TypeKind.Array => genArrayType(g, t),
		TypeKind.SizedArray => genSizedArrayType(g, t),
		TypeKind.Span => genSpanType(g, t),
		TypeKind.Function => genFunctionType(g, t),
		TypeKind.Ref => {
			const inner = getTypeDesc(g, t.typeReturn);
			const ptrType = inner + "*";
			typeCacheSet(g.typeCache, key, ptrType);
			return ptrType;
		},
		TypeKind.Ptr => {
			const innerType = t.typeReturn;
			if (innerType !== null && (innerType.kind === TypeKind.Ref || innerType.kind === TypeKind.Ptr)) {
				const ptrType = getTypeDesc(g, innerType);
				typeCacheSet(g.typeCache, key, ptrType);
				return ptrType;
			}
			const inner = getTypeDesc(g, innerType);
			const ptrType = inner + "*";
			typeCacheSet(g.typeCache, key, ptrType);
			return ptrType;
		},
		TypeKind.Var => {
			// Reference parity: tyVar → T* in C (pass by pointer).
			// liftdestructors uses Var<T> for lifecycle hook params (=destroy, =copy, =sink, =wasMoved).
			const inner = getTypeDesc(g, t.typeReturn);
			const varPtr = inner + "*";
			typeCacheSet(g.typeCache, key, varPtr);
			return varPtr;
		},
		TypeKind.Borrow => {
			const inner = getTypeDesc(g, t.typeReturn);
			const ptrType = "const " + inner + "*";
			typeCacheSet(g.typeCache, key, ptrType);
			return ptrType;
		},
		TypeKind.Union => {
			// Union(Ref<T>, Null) / Union(Ptr<T>, Null) → bare pointer.
			// The null pointer is the natural sentinel — no Maybe wrapper needed.
			const refMember = unwrapRefNullUnion(t);
			if (refMember !== null) return getTypeDesc(g, refMember);
			return genUnionType(g, t);
		},
		TypeKind.Tuple => genTupleType(g, t),
		TypeKind.Unknown => "void*",
		TypeKind.GenericParam => "void*",
		// GenericInstance: resolve to monomorphized C struct name
		TypeKind.GenericInstance => {
			// Build mangled name using monoTypeKey (single source of truth for C-safe type keys).
			// Must match the checker's naming in resolvePass.ms and checkExprPass.ms.
			let instName = t.typeName;
			for (let gi = 0; gi < t.typeChildren.length; gi += 1) {
				instName = `${instName}${gi === 0 ? "__" : "_"}${monoTypeKey(t.typeChildren[gi])}`;
			}
			const cacheKey = `object:${instName}`;
			const cached = typeCacheGet(g.typeCache, cacheKey);
			if (cached !== "") return cached;
			typeCacheSet(g.typeCache, cacheKey, instName);
			// Instantiate the base struct with concrete type args, then emit as a named struct.
			// Peel Ref/GenericInstance to reach the underlying Struct/Union body
			// (e.g. `Result<T, E> = Ref<ResultData<T, E>>` chains GI→Ref→GI→Union).
			const baseType: Type | null = peelToStructOrUnion(t.typeExtra);
			if (baseType !== null && baseType.kind === TypeKind.Struct) {
				// Substitute generic params in fields with concrete type args
				const genericDecl = getGenericDecl(t.typeName);
				if (genericDecl !== "") {
					const paramNames = splitTopLevel(genericDecl, ",");
					let concType: Type = baseType;
					for (let pi = 0; pi < paramNames.length; pi += 1) {
						if (pi < t.typeChildren.length) {
							concType = substituteType(concType, paramNames[pi].trim(), t.typeChildren[pi]);
						}
					}
					// If substituteType returned the same object, clone to avoid mutating the shared base
					if (concType === baseType) {
						const newChildren: Type[] = [];
						for (const c of concType.typeChildren) newChildren.push(c);
						const newNames: string[] = [];
						for (const n of concType.typeNames) newNames.push(n);
						concType = createStruct(instName, newNames, newChildren, isStructType(concType));
					} else {
						concType.typeName = instName;
					}
					return genObjectType(g, concType);
				}
			}
			// Generic match-type alias: baseType is Union with discriminant metadata.
			// Substitute generic params in variant struct fields, then emit as a named
			// tagged union. Required for `Result<T, E> = Ref<ResultData<T, E>>` style
			// types where ResultData is a generic match-type.
			if (baseType !== null && baseType.kind === TypeKind.Union) {
				const genericDecl = getGenericDecl(t.typeName);
				if (genericDecl !== "") {
					const paramNames = splitTopLevel(genericDecl, ",");
					let concType: Type = baseType;
					for (let pi = 0; pi < paramNames.length; pi += 1) {
						if (pi < t.typeChildren.length) {
							concType = substituteType(concType, paramNames[pi].trim(), t.typeChildren[pi]);
						}
					}
					// Stamp instance name so genUnionType caches under it (Phase 1b emits typedef)
					if (concType !== baseType) {
						concType.typeName = instName;
					}
					return genUnionType(g, concType);
				}
			}
			return instName;
		},
		_ => "void",
	};
}

// ===== Enum Type Generation =====

function genEnumType(g: CGen, t: Type): string {
	const name = mangle(t.typeName);
	const key = typeKey(t);
	typeCacheSet(g.typeCache, key, name);

	if (isImportedType(t)) { useImportedTypeHeader(g, t); return name; }

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

	if (isImportedType(t)) {
		useImportedTypeHeader(g, t);
		typeCacheSet(g.typeCache, key, t.typeName);
		return t.typeName;
	}

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

	return cTypeName;
}

// ===== Union Type Generation =====
// Standard reference pattern: union variant structs + wrapper struct with anonymous union.
// Each variant Object type in typeChildren gets its own named struct.
// The `as` cast maps to .vN member access at the codegen level.

function genUnionType(g: CGen, t: Type): string {
	const key = typeKey(t);

	// Pure string literal union → msString (TypeScript: string at runtime)
	let allStrLit = true;
	for (const child of t.typeChildren) {
		if (child === null || child.kind !== TypeKind.StringLiteral) allStrLit = false;
	}
	if (allStrLit && t.typeChildren.length > 0) {
		typeCacheSet(g.typeCache, typeKey(t), "msString");
		return "msString";
	}

	// Single cache lookup via typeKey. Naming is unique per type:
	//  - Named unions (incl. monomorphized generics): typeKey = "union:" + typeName.
	//    Different instances (e.g. `Result<int, string>` vs `Either<string, int>`)
	//    have distinct mangled typeNames even when structurally identical, so they
	//    correctly get separate C typedefs.
	//  - Anonymous unions (flow-narrowed shapes): typeKey = "union(<v0>|<v1>|...)"
	//    — pure structural form, so two occurrences of `A | B` collapse to one
	//    typedef.
	// Variant structs ARE shared structurally via the per-variant typeCache below
	// (Phase 1a) — that sharing is correct because variants are anonymous and
	// reusing them across outer unions saves typedefs.
	const cached = typeCacheGet(g.typeCache, key);
	if (cached !== "") return cached;

	const name = (t.typeName.length > 0) ? mangle(t.typeName) : "msUnion_" + hashToBase36(key);
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
		// Peel Ref/Ptr — interface variants are Ref<Struct> in the C backend.
		// Without peel, variant.typeNames is empty and the variant struct emits
		// no fields, breaking discriminated unions of named interfaces.
		const variant = peelToStruct(t.typeChildren[vi]);
		const varName = `${name}_v${vi}`;

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
		// Same Ref-peel as Phase 1a — interface variants are Ref<Struct>.
		const variant = peelToStruct(t.typeChildren[vi]);
		const varName = `${name}_v${vi}`;
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
				// Skip void-typed fields (e.g. `Result<void, E>` v0 has `void value`)
				// — emitting `void value;` is invalid C.
				if (fieldTypes[fi] !== "void") {
					addLine(b, `${fieldTypes[fi]} ${mangleFieldName(variant.typeNames[fi])};`);
				}
				fi += 1;
			}
		}
		b.indent -= 1;
		addLine(b, "} " + varName + ";");

		vi += 1;
	}
	addNewline(b);

	// Phase 2: Emit wrapper struct with anonymous union
	// Pre-resolve discriminant enum type BEFORE opening the struct (avoid nested typedef)
	let tagTypeName = "int32_t";
	if (t.typeExtra !== null && t.typeExtra.kind === TypeKind.Enum && t.typeExtra.typeName !== "") {
		tagTypeName = getTypeDesc(g, t.typeExtra);
	}
	addLine(b, `#ifndef ${name}_DEFINED`);
	addLine(b, `#define ${name}_DEFINED`);
	addLine(b, `struct ${name} {`);
	b.indent += 1;
	addLine(b, tagTypeName + " _tag;");
	addLine(b, "union {");
	b.indent += 1;
	vi = 0;
	while (vi < t.typeChildren.length) {
		// Use canonical name — duplicate variants share the same typedef
		const memberType = canonicalNames[vi];
		addLine(b, `${memberType} v${vi};`);
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

	// Resolve element key for cycle detection and pointer classification.
	const resolvedElem = t.typeReturn;
	const elemKey = (resolvedElem !== null) ? typeKey(resolvedElem) : "";
	const selfRef = elemKey !== "" && isBeingDefined(elemKey);

	const elemType = selfRef ? getTypeForward(g, t.typeReturn) : getTypeDesc(g, t.typeReturn);

	// Built-in array types for primitives
	if (elemType === "double") { typeCacheSet(g.typeCache, key, "msNumberArray"); return "msNumberArray"; }
	if (elemType === "msString") { typeCacheSet(g.typeCache, key, "msStringArray"); return "msStringArray"; }
	if (elemType === "MS_BOOL") { typeCacheSet(g.typeCache, key, "msNumberArray"); return "msNumberArray"; }
	if (elemType === "uint8_t") { typeCacheSet(g.typeCache, key, "msUint8Array"); return "msUint8Array"; }
	// Closure layout is uniform — single runtime msClosureArray works for all
	// closure types. Skip per-module typedef (would duplicate runtime decl).
	if (elemType === "msClosure") { typeCacheSet(g.typeCache, key, "msClosureArray"); return "msClosureArray"; }

	// Pointer element types (classes, refs, void*) → msRefArray (void* indirection is correct)
	// Class types: symbol table returns Ref<Struct>, resolvedElem.kind === Ref → isPointerType catches it.
	// Fallback: check type.sym for class kind (reference parity: t.sym.kind == skType).
	const elemIsClass = t.typeReturn !== null && t.typeReturn.sym !== null &&
		t.typeReturn.sym.symbolKind === SymbolKind.Class;
	if (elemType === "void*" || elemType.endsWith("*") || elemIsClass || (resolvedElem !== null && isPointerType(resolvedElem))) {
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

		// Reference parity: two-struct split { len, p* } + __Content { cap, T data[] }.
		// Forward decls in ForwardDecls, slim struct in Types, content in SeqTypes.
		// SeqTypes is emitted after Types — element type is always complete by then.
		const contentName = arrTypeName + "__Content";
		addLine(sec(g, CSection.ForwardDecls), `typedef struct ${arrTypeName} ${arrTypeName};`);
		addLine(sec(g, CSection.ForwardDecls), `typedef struct ${contentName} ${contentName};`);
		addLine(sec(g, CSection.Types), `struct ${arrTypeName} { int64_t len; ${contentName}* p; };`);
		addLine(sec(g, CSection.SeqTypes), `struct ${contentName} { int64_t cap; ${elemType} data[]; };`);
	}

	return arrTypeName;
}

// Returns the array type name for a given element type string (for use in expressions/statements).
export function getArrayTypeName(elemType: string): string {
	if (elemType === "double") return "msNumberArray";
	if (elemType === "msString") return "msStringArray";
	if (elemType === "uint8_t") return "msUint8Array";
	if (elemType === "msClosure") return "msClosureArray";
	return mangle(elemType) + "Array";
}

// Returns the array content/payload struct name for a given array type name.
// Built-in array types use runtime-defined payload structs; custom arrays use __Content suffix.
export function getArrayContentType(arrTypeName: string): string {
	if (arrTypeName === "msNumberArray") return "msNumberPayload";
	if (arrTypeName === "msStringArray") return "msStringPayload";
	if (arrTypeName === "msRefArray") return "msRefPayload";
	if (arrTypeName === "msUint8Array") return "msUint8Payload";
	if (arrTypeName === "msClosureArray") return "msClosurePayload";
	return arrTypeName + "__Content";
}

// ===== Sized Array (Stack) =====

function genSizedArrayType(g: CGen, t: Type): string {
	const elemType = getTypeDesc(g, t.typeReturn);
	const size = t.typeFlags;
	const key = typeKey(t);
	const name = `msSizedArray_${mangle(elemType)}_${size}`;

	if (typeCacheHas(g.typeCache, key)) return typeCacheGet(g.typeCache, key);
	typeCacheSet(g.typeCache, key, name);

	ensureForwardDecl(g, name);
	const b = sec(g, CSection.Types);
	addLine(b, `struct ${name} {`);
	addLine(b, `    ${elemType} data[${size}];`);
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

// Base type-to-C mapping for closure signatures (params and returns).
function closureBaseTypeToC(g: CGen, pt: Type): string {
	if (pt === null) return "void*";
	const simple = getSimpleTypeDesc(pt);
	if (simple !== "") return simple;
	return getTypeDesc(g, pt);
}

function closureParamTypeToC(g: CGen, pt: Type): string {
	const base = closureBaseTypeToC(g, pt);
	// Reference parity: ccgIntroducedPtr params are passed by pointer in C
	if (pt !== null && ccgIntroducedPtr(pt)) return base + "*";
	return base;
}

function closureRetTypeToC(g: CGen, t: Type): string {
	if (t !== null && t.kind === TypeKind.Function && t.typeReturn !== null) {
		// Return types are NOT promoted to pointers — only params are.
		return closureBaseTypeToC(g, t.typeReturn);
	}
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
	if (t !== null && t.kind === TypeKind.Function && t.typeReturn !== null && isNrvoReturnType(t.typeReturn, t)) {
		return getTypeDesc(g, t.typeReturn);
	}
	return "";
}

export function genClHalfCast(g: CGen, t: Type): string { return genClosureCast(g, t, false, autoNrvoType(g, t)); }
export function genClFullCast(g: CGen, t: Type): string { return genClosureCast(g, t, true, autoNrvoType(g, t)); }
export function genClHalfCastNrvo(g: CGen, t: Type, nrvoType: string): string { return genClosureCast(g, t, false, nrvoType); }
export function genClFullCastNrvo(g: CGen, t: Type, nrvoType: string): string { return genClosureCast(g, t, true, nrvoType); }

// `genResultType` (flat-struct codegen for `Result<T, E>`) was retired when
// Result migrated to a boolean-discriminated match-type Union. The standard
// `genUnionType` path in `getTypeDesc` now handles Result, with `void` payload
// fields filtered at typedef + hook walk to avoid `void value;` declarations.

// ===== Future Type Generation =====

// Lazy-emit entry: called from expressions.ms when it sees a call to
// msPromiseAllFor_msFuture_<T>. Resolves the element type T to its
// (SrcT, DstT, arrType, payloadType, copyStmt) tuple and ensures the
// instance is emitted once per module (via the #ifndef guard inside
// emitPromiseAllInstance). Pre-instantiated types (double / bool / ptr
// in combinator.h, msString in system.h) short-circuit — caller skips.
// Returns true if handled (either emitted now or pre-instantiated),
// false if innerType is an unsupported shape (void, nested array).
export function ensurePromiseAllInstance(g: CGen, innerType: Type): boolean {
	if (innerType === null || innerType.kind === TypeKind.Void) return false;
	const innerDesc = getTypeDesc(g, innerType);

	// Pre-instantiated in runtime (combinator.h / system.h) — no emission needed.
	if (innerDesc === "double" || innerDesc === "bool" || innerDesc === "MS_BOOL"
		|| innerDesc === "msString" || innerDesc.endsWith("*")) {
		return true;
	}

	// int32 / int64 — array types are custom (int32_tArray / int64_tArray). Force-emit
	// the array typedef so the payload struct is complete for sizeof() inside the macro.
	if (innerDesc === "int32_t") {
		genArrayType(g, createArray(innerType));
		emitPromiseAllInstance(g, "msFuture_int32", "int32_t", "int32_t", "int32_tArray", "int32_tArray__Content", "MS_COPY_SAME");
		return true;
	}
	if (innerDesc === "int64_t") {
		genArrayType(g, createArray(innerType));
		emitPromiseAllInstance(g, "msFuture_int64", "int64_t", "int64_t", "int64_tArray", "int64_tArray__Content", "MS_COPY_SAME");
		return true;
	}

	// Arrays-of-arrays: Promise<T[]>[] → Promise<T[][]> — not a common use case.
	// Caller falls back to generic msPromiseAll.
	if (innerDesc.endsWith("Array")) return false;

	// Structs and other named value types. When the struct has RC fields (signaled
	// by `hasAsgnFlag`), use its generated `<T>Copy` hook for a DRC-correct deep
	// copy — a shallow memcpy would silently duplicate RC pointers and cause leaks
	// or double-frees. `<T>Copy` is defined in CSection.Procs by destructorLifting;
	// emit a forward decl in ProcHeaders so the static-inline macro body (emitted
	// into GlobalVars, which renders before Procs) can reference it.
	genArrayType(g, createArray(innerType));
	const futName = "msFuture_" + mangle(innerDesc);
	const arrName = getArrayTypeName(innerDesc);
	const payloadName = getArrayContentType(arrName);
	let copyStmt = "MS_COPY_SAME";
	// destructorLifting generates `<typeName>Copy` only for named structs with
	// RC fields (`hasAsgnFlag`). Anonymous structs (typeName === "") are skipped
	// by destructorLifting at `lookupSymbol(...) === null`, so using the hook
	// there would produce an undefined reference at link. Match its filter.
	if (innerType.kind === TypeKind.Struct && innerType.typeName !== "" && hasAsgnFlag(innerType)) {
		const hookName = innerDesc + "Copy";
		// Dedup the forward decl across repeat calls for the same T — multiple
		// Promise.all sites in the same module otherwise emit N copies. Harmless
		// in C but noisy; cache via g.forwTypeCache.
		const fwdKey = "copyhookfwd:" + hookName;
		if (!typeCacheHas(g.forwTypeCache, fwdKey)) {
			typeCacheSet(g.forwTypeCache, fwdKey, hookName);
			addLine(sec(g, CSection.ProcHeaders), "void " + hookName + "(" + innerDesc + "* dest, " + innerDesc + "* src);");
		}
		copyStmt = hookName;
	}
	emitPromiseAllInstance(g, futName, innerDesc, innerDesc, arrName, payloadName, copyStmt);
	return true;
}

// Emit an MS_PROMISE_ALL_FOR instance for element-future-type `futName` whose
// MetaScript source type is T[] (array type `arrName`, payload `payloadName`,
// storage element `dstElem`). Guarded by #ifndef — idempotent across modules.
// Pre-instantiated types (msFuture_double / msFuture_bool / msFuture_ptr in
// combinator.h, msFuture_msString in system.h) are skipped at call sites.
function emitPromiseAllInstance(g: CGen, futName: string, srcT: string, dstElem: string, arrName: string, payloadName: string, copyStmt: string): void {
	const guard = "msPromiseAllFor_" + futName + "_DEFINED";
	// Emit into GlobalVars (runs after Types + SeqTypes) so the array payload's
	// full struct definition is visible to sizeof(payloadType) inside the macro
	// body — Types/SeqTypes ordering would otherwise produce incomplete-type errors.
	const b = sec(g, CSection.GlobalVars);
	addLine(b, "#ifndef " + guard);
	addLine(b, "#define " + guard);
	addLine(b, "MS_PROMISE_ALL_FOR(" + srcT + ", " + futName + ", " + dstElem + ", " + arrName + ", " + payloadName + ", " + copyStmt + ");");
	addLine(b, "#endif");
	addNewline(b);
}

export function genFutureType(g: CGen, t: Type): string {
	const innerType = awaitedType(t);
	const key = typeKey(t);

	// Promise<void> → msFuture_void* (typedef of msFutureBase, predefined in future.h)
	if (innerType === null || innerType.kind === TypeKind.Void) {
		typeCacheSet(g.typeCache, key, "msFuture_void*");
		return "msFuture_void*";
	}

	const innerDesc = getTypeDesc(g, innerType);

	// Map to predefined typed futures (avoid re-emitting structs already in future.h).
	if (innerDesc === "double") { typeCacheSet(g.typeCache, key, "msFuture_double*"); return "msFuture_double*"; }
	if (innerDesc === "int32_t") { typeCacheSet(g.typeCache, key, "msFuture_int32*"); return "msFuture_int32*"; }
	if (innerDesc === "int64_t") { typeCacheSet(g.typeCache, key, "msFuture_int64*"); return "msFuture_int64*"; }
	if (innerDesc === "bool" || innerDesc === "MS_BOOL") { typeCacheSet(g.typeCache, key, "msFuture_bool*"); return "msFuture_bool*"; }

	// Pointer/reference types → msFuture_ptr* (void* value, predefined)
	if (innerDesc.endsWith("*")) {
		typeCacheSet(g.typeCache, key, "msFuture_ptr*");
		return "msFuture_ptr*";
	}

	// String → emit custom struct (msString is a value type, not a pointer)
	// Other value types (structs, tuples) → emit custom struct
	const name = "msFuture_" + mangle(innerDesc);
	typeCacheSet(g.typeCache, key, name + "*");

	// Emit the future struct (guarded for cross-module safety, same `#ifndef
	// _DEFINED` pattern as `genUnionType`). The matching MS_PROMISE_ALL_FOR instance is NOT auto-emitted
	// here — it's emitted on-demand from expressions.ms when a Promise.all call
	// site references `msPromiseAllFor_msFuture_<T>`, avoiding dead inline code
	// for Promise<T> types that are never Promise.all'd.
	ensureForwardDecl(g, name);
	const b = sec(g, CSection.Types);
	addLine(b, "#ifndef " + name + "_DEFINED");
	addLine(b, "#define " + name + "_DEFINED");
	addLine(b, "MS_FUTURE_STRUCT(" + name + ", " + innerDesc + ");");
	addLine(b, "#endif");
	addNewline(b);

	return name + "*";
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
		addLine(b, `${ft} _${i};`);
		i += 1;
	}
	b.indent -= 1;
	addLine(b, "};");
	addLine(b, "#endif");
	addNewline(b);

	return name;
}

// ===== Tests =====

import { createPrimitive, createStruct, createArray, createEnum, createRef, createTuple } from "../../checker/types";
import { createCGen } from "./context";
import { CheckerContext, GcMode } from "../../checker/context";
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
	const types = extract(sec(g, CSection.Types));
	assert name !== "void*";
	assert name.length > 8; // "msTuple_" + hash
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
