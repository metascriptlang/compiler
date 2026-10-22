// C Codegen — Type Mapping
//
// Follows standard reference implementation patterns for type mapping.
// Two-tier cache (forwTypeCache for forward decls, typeCache for full defs).
// Topological emit with cycle detection via forward declarations.

import { TargetInfo, unwrapVarargs, genericInstanceAbiRepr, isStructType, emptyType, assignType, sizeOfType, alignOfType, offsetOfField, skipModifier, isAwaitable, awaitedType, isResult, substituteInstanceArgs, createStruct, createArray, createRef, needsRC, hasAsgnFlag, isNumeric, isPrimitiveUnionMember, isStringLike, unwrapRefNullUnion, peelToStructOrUnion, peelTransparentInstance, distinctInstanceRepr, distinctBody, isAtomicRef, setRepr, arrayElementNeedsCleanup, tupleTypeName, inlineVariantStruct, spelled, genericParamsOf, nominalTypeKey, isNominalKind, enumStorageKind, peelToRepr, isValueStorage, classParentOf, runtimeClassSym, typeDisplayName, storesNothing, createPrimitive, createEnum, createTuple, createFunction, createDistinct, literalUnionBase, numberLiteralBase, createGenericInstance, isIntegerType, isUncountedElement } from "../../checker/types";
import { AttachedOp, Node, NodeKind, NodeFlag, CallExprData, ObjectLiteralData, Type, TypeKind, TypeFlag, SymbolKind, SymbolState, Symbol } from "../../ast/node";
import { monoInstanceName } from "../../monomorphize/registry";
import { splitTopLevel } from "../../utils/string";
import { hashToBase36 as _stdHashToBase36 } from "std/hash";
import { CGen, CSection, CTypeInfoDemand, TypeInfoKind, DeferredStructDef, add, addLine, addNewline, extract, sec, typeCacheGet, typeCacheSet, typeCacheHas, nameSetHas, nameSetAdd, addCGenError, NameSet, createNameSet, useHeader, createCGen } from "./context";
import { passedByValue } from "../../checker/varPartitions";
import { SymbolFlag, hasFlag, makeSymbol, setFlag, lookupSymbolReadonly } from "../../checker/symbol";
import { mangle, mangledTypeName, ownedGeneratedName, mangledFunctionName, mangleFieldName, safeName, resolveOverloadWinner, overloadAt, mangleQualified, mangleModuleName } from "./names";
import { CheckerContext, newSym, GcMode, addError, createContext } from "../../checker/context";
import { cStringLiteral, escapeCString } from "./literals";

function namingSym(t: Readonly<Type>): Readonly<Symbol | null> {
	if (t.sym != null && hasFlag(t.sym, SymbolFlag.Anon)) return t.sym;
	return t.typeFlags.has(TypeFlag.Spelled) ? null : t.sym;
}

export function resolvedTypeCName(t: Readonly<Type>, hasCheckerCtx: boolean): string {
	const owner = namingSym(t);
	if (owner != null && t.typeFlags.has(TypeFlag.DuVariant)) return mangledTypeName(owner, t.typeName) + "_" + hashToBase36(nominalTypeKey(t));
	if (owner != null) return mangledTypeName(owner, t.typeName);
	if (hasCheckerCtx && t.typeName != "" && isNominalKind(t.kind)) nominalTypeKey(t);
	return mangledTypeName(null, t.typeName);
}

function typeIdentityName(g: CGen, t: Readonly<Type>): string {
	return resolvedTypeCName(t, g.checkerCtx != null);
}

// The single oracle for a lifecycle hook's base name, shared by the lifter (hook
// definitions + ownership keys) and the analyzer (call sites). Both must spell a
// type the way codegen spells its struct, or one module's hooks answer for
// another module's same-named type.
export function hookBaseCName(typeName: string, t: Type | null, cc: Readonly<CheckerContext> | null): string {
	if (typeName == "") return "";
	if (typeName.slice(0, 1) == "$") return t != null && t.typeName == typeName && ownedGeneratedName(t.sym) ? mangledTypeName(t.sym, typeName) : typeName;
	const named = t != null && t.typeName == typeName;
	if (named && t.typeInst != null) return monoInstanceName(t.typeInst);
	if (named) return resolvedTypeCName(t, cc != null);
	return typeName;
}

function structIdentityName(g: CGen, t: Readonly<Type>): string {
	if (isAnonTypeName(t.typeName)) return anonTypeName(t);
	return typeIdentityName(g, t);
}

// ===== Generated lifecycle hook symbols (attachedOps analog) =====
// destructorLifting sets AttachedDestructor on a per-Type-object instance (a throwaway built by
// unwrapGenericInstance for mono types), so the op never reaches the canonical type codegen reads.
let _hookSymsSealed = false;

export interface KeyedOp {
	key: string;
	sym: Symbol;
	canon: boolean;
}

let _opSyms: HashMap<string, Symbol> = new HashMap<string, Symbol>();
let _opKeyOfSym: HashMap<Symbol, string> = new HashMap<Symbol, string>();
let _opOrder: KeyedOp[] = [];
let _canonOps: HashSet<Symbol> = new HashSet<Symbol>();

export function sealHookSyms(sealed: boolean): void {
	_hookSymsSealed = sealed;
}

export function resetHookSyms(): void {
	_opSyms = new HashMap<string, Symbol>();
	_opKeyOfSym = new HashMap<Symbol, string>();
	_opOrder = [];
	_canonOps = new HashSet<Symbol>();
}

function attachedOpName(op: AttachedOp): string {
	return match (op) {
		AttachedOp.AttachedWasMoved => "wasMoved",
		AttachedOp.AttachedDestructor => "destroy",
		AttachedOp.AttachedAsgn => "copy",
		AttachedOp.AttachedDup => "dup",
		AttachedOp.AttachedSink => "sink",
		AttachedOp.AttachedTrace => "trace",
		AttachedOp.AttachedEq => "eq",
		AttachedOp.AttachedLt => "lt",
		AttachedOp.AttachedLe => "le",
		AttachedOp.AttachedToString => "toString",
	};
}

export function arrayOpElement(elem: Type | null): Type | null;
export function arrayOpElement(elem: Readonly<Type | null>): Readonly<Type | null>;
export function arrayOpElement(elem: Readonly<Type | null>): Readonly<Type | null> {
	let e = elem;
	while (e != null) {
		const body = distinctBody(e);
		if (body != null) {
			e = body;
			continue;
		}
		const peeled = peelTransparentInstance(e);
		if (peeled != e) {
			e = peeled;
			continue;
		}
		if ((e.kind == TypeKind.Distinct || e.kind == TypeKind.Alias) && e.typeReturn != null) {
			e = e.typeReturn;
			continue;
		}
		return e;
	}
	return e;
}

export function opTypeKey(t: Readonly<Type | null>): string {
	if (t == null) return "null";
	if (t.kind == TypeKind.Alias && t.typeReturn != null) return opTypeKey(t.typeReturn);
	if (t.kind == TypeKind.Array) return "array:" + opTypeKey(arrayOpElement(t.typeReturn));
	if (t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr) {
		const counting = isAtomicRef(t) ? "atomic:" : "";
		return (t.kind == TypeKind.Ref ? "ref:" : "ptr:") + counting + opTypeKey(t.typeReturn);
	}
	if (t.kind == TypeKind.Cursor) return "cursor:" + opTypeKey(t.typeReturn);
	return typeKey(t);
}

export function opKey(t: Readonly<Type>, op: AttachedOp): string {
	return attachedOpName(op) + "|" + opTypeKey(t);
}

function recordOp(key: string, sym: Symbol, canon: boolean): void {
	const held = _opSyms.get(key);
	if (held != null && held != sym) {
		throw new Error(`internal: type-bound op ${key} is both '${held.name}' and '${sym.name}'`);
	}
	if (canon) {
		const heldKey = _opKeyOfSym.get(sym);
		if (heldKey != null && heldKey != key) {
			throw new Error(`internal: generated op '${sym.name}' serves two types: ${heldKey} and ${key}`);
		}
		if (heldKey == null) _opKeyOfSym.set(sym, key);
		_canonOps.add(sym);
	}
	if (held == sym) return;
	_opSyms.set(key, sym);
	_opOrder.push({ key, sym, canon });
}

export function setOpByKey(t: Type, op: AttachedOp, sym: Symbol): void {
	recordOp(opKey(t, op), sym, true);
}

export function bindOpByKey(t: Type, op: AttachedOp, sym: Symbol): void {
	recordOp(opKey(t, op), sym, false);
}

export function isTypeBoundOp(sym: Readonly<Symbol>): boolean {
	return _canonOps.has(sym);
}

export function hasLiftedOp(t: Type, op: AttachedOp): boolean {
	const sym = _opSyms.get(opKey(t, op));
	return sym != null && sym.state == SymbolState.Checked;
}

export function getOpByKey(t: Type, op: AttachedOp): Symbol | null;
export function getOpByKey(t: Readonly<Type>, op: AttachedOp): Readonly<Symbol | null>;
export function getOpByKey(t: Readonly<Type>, op: AttachedOp): Readonly<Symbol | null> {
	return _opSyms.get(opKey(t, op));
}

// The lifted-op table, handed to emission through its facts.
export function hookOps(): HashMap<string, Symbol> {
	return _opSyms;
}

export function getOpByKeyIn(ops: HashMap<string, Symbol>, t: Type, op: AttachedOp): Symbol | null;
export function getOpByKeyIn(ops: Readonly<HashMap<string, Symbol>>, t: Readonly<Type>, op: AttachedOp): Readonly<Symbol | null>;
export function getOpByKeyIn(ops: Readonly<HashMap<string, Symbol>>, t: Readonly<Type>, op: AttachedOp): Readonly<Symbol | null> {
	return ops.readonlyGet(opKey(t, op));
}

export function requireOpByKey(t: Type, op: AttachedOp): Symbol {
	const key = opKey(t, op);
	const sym = _opSyms.get(key);
	if (sym == null) throw new Error(`internal: type-bound op ${key} is used before it was lifted`);
	return sym;
}

export function opPrototype(t: Type, op: AttachedOp, name: string, ctx: CheckerContext): Symbol {
	const key = opKey(t, op);
	const existing = _opSyms.get(key);
	if (existing != null) return existing;
	if (_hookSymsSealed) throw new Error(`internal: type-bound op ${key} first requested while C modules are emitted in parallel`);
	const sym = newSym(ctx, SymbolKind.Function, name, null);
	setFlag(sym, SymbolFlag.GeneratedOp);
	if (op == AttachedOp.AttachedDestructor) setFlag(sym, SymbolFlag.DestroyOp);
	else if (op == AttachedOp.AttachedWasMoved) setFlag(sym, SymbolFlag.WasMovedOp);
	recordOp(key, sym, true);
	return sym;
}

export function aliasOpByKey(orig: Type, canon: Type, op: AttachedOp): void {
	const sym = _opSyms.get(opKey(canon, op));
	if (sym != null) recordOp(opKey(orig, op), sym, false);
}

export function opMark(): int32 {
	return _opOrder.length as int32;
}

export function opsFrom(mark: int32): KeyedOp[] {
	const taken: KeyedOp[] = [];
	for (let i = mark; i < _opOrder.length; i += 1) taken.push(_opOrder[i]);
	return taken;
}

export function replayOps(ops: KeyedOp[]): void {
	for (const op of ops) recordOp(op.key, op.sym, op.canon);
}

export function liftedOp(t: Type, op: AttachedOp, name: string, fnType: Type | null): Symbol {
	const key = opKey(t, op);
	const held = _opSyms.get(key);
	if (held != null) {
		if (held.name != name) throw new Error(`internal: type-bound op ${key} is '${held.name}', requested as '${name}'`);
		if (fnType != null) held.symbolType = fnType;
		return held;
	}
	if (_hookSymsSealed) throw new Error(`internal: type-bound op ${key} first requested while C modules are emitted in parallel`);
	const sym = makeSymbol(name, SymbolKind.Function, fnType, false);
	setFlag(sym, SymbolFlag.GeneratedOp);
	if (op == AttachedOp.AttachedDestructor) setFlag(sym, SymbolFlag.DestroyOp);
	else if (op == AttachedOp.AttachedWasMoved) setFlag(sym, SymbolFlag.WasMovedOp);
	recordOp(key, sym, true);
	return sym;
}

export function hasNoRuntimeRepr(t: Readonly<Type | null>): boolean {
	return t != null && t.kind == TypeKind.Void;
}

export function runtimeParamCount(t: Readonly<Type>): int32 {
	let n: int32 = 0;
	for (const param of t.typeChildren) {
		if (!hasNoRuntimeRepr(param)) n += 1;
	}
	return n;
}

export function procHeader(g: CGen, name: string, fnType: Readonly<Type>, paramNames: Readonly<string[]> | null, mutBits: int32, hookAbi: boolean): string {
	let cRetType = getTypeDesc(g, fnType.typeReturn);
	if (fnType.typeReturn == null) cRetType = "void";
	const nrvo = isNrvoReturnType(fnType.typeReturn, fnType);
	const named = paramNames != null;
	const names = paramNames != null ? paramNames : [];
	const count = named ? names.length : fnType.typeChildren.length;
	const parts: string[] = [];
	if (nrvo) parts.push(cRetType + "* __result");
	for (let i = 0; i < count; i += 1) {
		const typed = i < fnType.typeChildren.length;
		if (typed && hasNoRuntimeRepr(fnType.typeChildren[i])) continue;
		if (typed && isOpenArrayParam(fnType.typeChildren[i])) {
			const elemPtr = getTypeDesc(g, skipModifier(fnType.typeChildren[i])!.typeReturn) + "*";
			parts.push(named ? `${elemPtr} ${openArrayDataName(safeName(names[i]))}` : elemPtr);
			parts.push(named ? `int64_t ${openArrayLenName(safeName(names[i]))}` : "int64_t");
			continue;
		}
		let pType = typed ? getTypeDesc(g, fnType.typeChildren[i]) : "void*";
		const mut = (mutBits & (1 << (i as int32))) != 0;
		const promote = typed && (hookAbi ? ccgIntroducedPtr(g.target, fnType.typeChildren[i]) : shouldIndirectParam(g.target, fnType.typeChildren[i], mut, i == 0 && returnsBorrow(fnType)));
		if (promote && pType.byteLength > 0 && pType.charAt(pType.byteLength - 1) != "*") {
			pType = (!hookAbi && shouldConstParam(fnType.typeChildren[i], mut)) ? "const " + pType + "*" : pType + "*";
		}
		parts.push(named ? `${pType} ${safeName(names[i])}` : pType);
	}
	const paramList = parts.length > 0 ? parts.join(", ") : "void";
	return `${nrvo ? "void" : cRetType} ${name}(${paramList})`;
}

export function ensureDrcProto(g: CGen, callee: string, sym: Readonly<Symbol | null>): void {
	const hook = sym;
	if (hook == null || !hasFlag(hook, SymbolFlag.GeneratedOp)) return;
	const fnType = hook.symbolType;
	if (fnType == null || fnType.kind != TypeKind.Function) return;
	const cName = hook.modulePath != "" ? mangledFunctionName(hook, hook.name, hook.overloadIdx) : callee;
	if (nameSetHas(g.declaredProcs, cName)) return;
	nameSetAdd(g.declaredProcs, cName);
	addLine(sec(g, CSection.ProcHeaders), procHeader(g, cName, fnType, null, 0, true) + ";");
}

export function opCName(op: Readonly<Symbol>): string {
	return mangledFunctionName(op, op.name, op.overloadIdx);
}


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

function isBeingDefined(g: CGen, key: string): boolean {
	for (const k of g.typesBeingDefined) {
		if (k == key) return true;
	}
	return false;
}

// ===== In-progress unions + deferred struct defs =====
// genUnionType caches the wrapper's C name BEFORE emitting its definition
// (re-entry guard). A struct generated while such a union is mid-flight can
// hold that union BY VALUE — emitting it inline would reference an incomplete
// type (clang "field has incomplete type"; hit by ast/fieldspec compiled as a
// dependency of test builds). Those structs defer here and flush once the
// blocking union's definition completes. Limitation: by-value deps BETWEEN
// two deferred structs are emitted FIFO — none exist today (deferral only
// ever waits on unions, whose by-value embedders are plain structs).

function unionInProgress(g: CGen, cname: string): boolean {
	for (const n of g.unionsInProgress) {
		if (n == cname) return true;
	}
	return false;
}

function flushDeferredStructs(g: CGen): void {
	let emitted = true;
	while (emitted) {
		emitted = false;
		const remaining: DeferredStructDef[] = [];
		for (const d of g.deferredStructs) {
			if (unionInProgress(g, d.blocker)) {
				remaining.push(d);
			} else {
				const b = sec(g, CSection.Types);
				add(b, d.def);
				addNewline(b);
				emitted = true;
			}
		}
		g.deferredStructs = remaining;
	}
}

// ===== Anonymous Type Naming =====
// Generates deterministic C struct names for anonymous interfaces (typeName === "").
// Uses a structural key (field names + types) hashed to a short hex-like string.

function anonFieldKey(t: Readonly<Type | null>, open: Cursor<Readonly<Type>>[]): string {
	if (t == null) return "null";
	return match (t.kind) {
		TypeKind.Struct => {
			if (t.typeName.length == 0) return anonStructKeyIn(t, open);
			return structKeyIdentity(t);
		},
		TypeKind.Enum => "enum:" + mangledTypeName(t.sym, t.typeName),
		TypeKind.GenericInstance => "ginst:" + monoInstanceName(t),
		TypeKind.Array => "arr:" + anonFieldKey(t.typeReturn, open),
		TypeKind.Function => {
			let k = "fn(";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) k = k + ",";
				k = k + anonFieldKey(t.typeChildren[i], open);
				i += 1;
			}
			return k + "):" + anonFieldKey(t.typeReturn, open);
		},
		TypeKind.Ref | TypeKind.Ptr => "ptr:" + anonFieldKey(t.typeReturn, open),
		TypeKind.Varargs => t.typeChildren.length > 0 ? anonFieldKey(t.typeChildren[0], open) : "varargs:empty",
		TypeKind.Union => {
			if (t.typeInst != null) return anonFieldKey(t.typeInst, open);
			if (t.typeName.length > 0) return "union:" + structKeyIdentity(t);
			let k = "union(";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) k = k + "|";
				k = k + anonFieldKey(t.typeChildren[i], open);
				i += 1;
			}
			return k + ")";
		},
		TypeKind.Tuple => {
			let k = "tuple(";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) k = k + ",";
				k = k + anonFieldKey(t.typeChildren[i], open);
				i += 1;
			}
			return k + ")";
		},
		// A key that collapses two distinct types onto one string makes the
		// variant-typedef dedup in genUnionType reuse the wrong struct, so an
		// unhandled kind must still key apart by ordinal and name.
		_ => {
			const simple = getSimpleTypeDesc(t);
			if (simple != "") return simple;
			let k = "k" + (t.kind as number).toString() + ":" + t.typeName;
			if (t.typeReturn != null) k = k + "<" + anonFieldKey(t.typeReturn, open) + ">";
			for (const child of t.typeChildren) k = k + "," + anonFieldKey(child, open);
			return k;
		},
	};
}

function anonStructKeyIn(t: Readonly<Type>, open: Cursor<Readonly<Type>>[]): string {
	let depth = open.length - 1;
	while (depth >= 0) {
		if (open[depth] == t) return `rec(${open.length - 1 - depth})`;
		depth -= 1;
	}
	open.push(t);
	const key = `anon(${anonFieldsKey(t, open)})`;
	open.pop();
	return key;
}

function anonFieldsKey(t: Readonly<Type>, open: Cursor<Readonly<Type>>[]): string {
	let key = "";
	let i = 0;
	while (i < t.typeNames.length) {
		if (i > 0) key = key + ",";
		key = key + t.typeNames[i] + ":";
		if (i < t.typeChildren.length && storesNothing(t, t.typeChildren[i])) {
			key = key + "none";
		} else if (i < t.typeChildren.length && t.typeChildren[i] != null) {
			key = key + anonFieldKey(t.typeChildren[i], open);
		} else {
			key = key + "void";
		}
		i += 1;
	}
	return key;
}

function anonStructuralKey(t: Readonly<Type>): string {
	return anonFieldsKey(t, [t]);
}

// DJB2 hash → base-36 string for short C identifiers
export function hashToBase36(s: string): string { return _stdHashToBase36(s); }

// Detects if a typeName is "anonymous-like" — empty, or a raw structural signature
// like "{ programStmts : Node[] }" from discriminated union variants.
export function isAnonTypeName(name: string): boolean {
	if (name.length == 0) return true;
	const ch = name.charAt(0);
	// Raw discriminated union variants start with "{"
	// Raw function signatures start with "("
	// Raw union types start with "|"
	if (ch == "{" || ch == "(" || ch == "|") return true;
	return false;
}

export function anonTypeName(t: Readonly<Type>): string {
	if (t.typeNames.length == 0) return "msAnon_empty";
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
	if (mapped != "") return mapped;
	// Array types: "T[]", "T []", "T [ ]" (checker may include spaces)
	if (s.endsWith("[]") || s.endsWith("[ ]")) {
		let elem = s;
		if (elem.endsWith("[ ]")) elem = elem.slice(0, elem.byteLength - 3);
		else elem = elem.slice(0, elem.byteLength - 2);
		elem = elem.trim();
		if (elem == "number") return "msNumberArray";
		if (elem == "string") return "msStringArray";
		if (elem == "uint8") return "msUint8Array";
		if (elem == "boolean") return "msUint8Array";
		// Per-type array typedef (Standard reference pattern)
		return mangle(elem) + "Array";
	}
	// Named types — mangle (value-type struct by default)
	return mangle(s);
}

// ===== Type Signature Key =====
// Generates a unique string key for a Type (used for cache lookups).

function structKeyIdentity(t: Readonly<Type>): string {
	const owner = namingSym(t);
	if (owner == null && t.typeFlags.has(TypeFlag.Spelled)) return mangledTypeName(null, t.typeName);
	if (owner != null && !t.typeFlags.has(TypeFlag.DuVariant)) return mangledTypeName(owner, t.typeName);
	return mangledTypeName(null, nominalTypeKey(t));
}

export function anonUnionCName(t: Readonly<Type>): string {
	return "msUnion_" + hashToBase36(typeKey(t));
}

export function typeKey(t: Readonly<Type | null>): string {
	if (t == null) return "null";
	return match (t.kind) {
		TypeKind.Alias => typeKey(t.typeReturn),
		TypeKind.Number | TypeKind.Float64 => "float64",
		TypeKind.Float32 => "float32",
		TypeKind.Int8 => "int8",
		TypeKind.Int16 => "int16",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint8 => "uint8",
		TypeKind.Uint16 => "uint16",
		TypeKind.Uint32 => "uint32",
		TypeKind.Uint64 => "uint64",
		TypeKind.BigInt => "bigint",
		TypeKind.String => "string",
		TypeKind.Boolean => "boolean",
		TypeKind.Char => "char",
		TypeKind.CString => "cstring",
		TypeKind.StringLiteral => "strlit:" + t.typeName,
		TypeKind.BooleanLiteral => "boollit:" + t.typeName,
		TypeKind.NumberLiteral => "numlit:" + t.typeName,
		TypeKind.Void => "void",
		TypeKind.Null => "null",
		TypeKind.Enum => { return "enum:" + mangledTypeName(t.sym, t.typeName); },
		TypeKind.EnumLiteral => {
			const e = t.typeReturn != null && t.typeReturn.kind == TypeKind.Enum ? t.typeReturn : t;
			return "enum:" + mangledTypeName(e.sym, e.typeName);
		},
		TypeKind.Struct => {
			// Anonymous/structural types: use structural key to distinguish
			if (isAnonTypeName(t.typeName)) {
				return `anon(${anonStructuralKey(t)})`;
			}
			return "object:" + structKeyIdentity(t);
		},
		TypeKind.Array => {
			const elemKey = typeKey(t.typeReturn);
			return "array:" + elemKey;
		},
		TypeKind.SizedArray => {
			const elemKey = typeKey(t.typeReturn);
			return `sizedArray:${elemKey}[${t.typeValue}]`;
		},
		TypeKind.Span => {
			const elemKey = typeKey(t.typeReturn);
			return "span:" + elemKey;
		},
		TypeKind.Set => {
			const elemKey = typeKey(t.typeReturn);
			return "set:" + elemKey;
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
		TypeKind.Cursor => { return typeKey(t.typeReturn); },
		TypeKind.Var => { return "var:" + typeKey(t.typeReturn); },
		TypeKind.Borrow => { return "borrow:" + typeKey(t.typeReturn); },
		TypeKind.GenericInstance => {
			const seen = peelTransparentInstance(t);
			if (seen != t && seen.kind == TypeKind.Union && seen.typeInst == null) return typeKey(seen);
			let giKey = `ginst:${monoInstanceName(t)}`;
			for (const arg of t.typeChildren) giKey = `${giKey}:${typeKey(arg)}`;
			return giKey;
		},
		TypeKind.TypeReference => { return "typeref:" + nominalTypeKey(t); },
		TypeKind.Distinct => { return "distinct:" + nominalTypeKey(t); },
		TypeKind.Union => {
			if (t.typeInst != null) return typeKey(t.typeInst);
			if (t.typeName.length > 0) {
				return "union:" + structKeyIdentity(t);
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
		TypeKind.Varargs => t.typeChildren.length > 0 ? typeKey(t.typeChildren[0]) : "varargs:empty",
		// Total catch-all: the key feeds typeCache, so collapsing two types onto one
		// string hands out a typedef built for the other one. Named types key by name
		// (recursing there would not terminate on `type Rec = { next: Rec | null }`).
		_ => {
			let key = "k" + (t.kind as number).toString() + ":" + t.typeName;
			if (t.typeReturn != null) key = key + "<" + typeKey(t.typeReturn) + ">";
			for (const child of t.typeChildren) key = key + "," + typeKey(child);
			return key;
		},
	};
}


// ===== Primitive Type Mapping =====

export function getSimpleTypeDesc(t: Readonly<Type>): string {
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
		TypeKind.Char | TypeKind.Module => "uint8_t",
		TypeKind.String | TypeKind.StringLiteral => "msString",
		TypeKind.BigInt => "msBigInt*",
		TypeKind.CString => "const char*",
		TypeKind.Alias => t.typeReturn == null ? "void" : getSimpleTypeDesc(t.typeReturn),
		TypeKind.NumberLiteral => getSimpleTypeDesc(numberLiteralBase(t)),
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

export function isPointerType(t: Readonly<Type>): boolean {
	if (t == null) return false;
	let inner = skipModifier(t);
	if (inner != null) inner = skipModifier(peelTransparentInstance(inner));
	while (inner != null && distinctBody(inner) != null) inner = skipModifier(peelTransparentInstance(distinctBody(inner)!));
	if (inner == null) return false;
	// Union(Ref<T>, Null) collapses to T* in C — same C representation as Ref<T>.
	if (inner.kind == TypeKind.Union) {
		const held = unwrapRefNullUnion(inner);
		return held != null && isPointerType(held);
	}
	return match (inner.kind) {
		TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow => true,
		// user `unknown` is void*; a Pending type must stay non-pointer
		// or arg shims deref/addr pending-typed scalar exprs (types.ms:1805 trap)
		TypeKind.Unknown => true,
		_ => false,
	};
}

// Reference parity: value types that can't be nil in C.
// Used by codegen to emit {0} instead of MS_NIL, and memset instead of NULL assignment.
export function isNilableValueType(t: Readonly<Type>): boolean {
	if (isValueStorage(t)) return true;
	if (t == null) return false;
	if ((t.kind == TypeKind.Distinct || t.kind == TypeKind.Alias) && t.typeReturn != null) return isNilableValueType(t.typeReturn);
	if (t.kind == TypeKind.Set) {
		const repr = setRepr(t);
		return repr != null && isNilableValueType(repr);
	}
	return t.kind == TypeKind.SizedArray;
}

// ===== ccgIntroducedPtr (Reference: reference codegen utils parity) =====
// Determines if a param type should be passed by pointer in C.
// Reference: skipTypes(typedescInst) strips Sink/Lent before dispatch.
// Object types over the threshold, tuple same threshold, Result and Union always.
function ptrThreshold(tg: TargetInfo): int32 { return tg.floatSize * 3; }

export function ccgIntroducedPtr(tg: TargetInfo, t: Readonly<Type>): boolean {
	if (t == null) return false;
	// Reference parity: tyVar is not tyObject/tyTuple — `else: result = false`.
	// A var param's `*` comes from mapType/getTypeDesc, never from lfIndirect.
	// Early exit BEFORE skipModifier: struct-size dispatch must not see through Var.
	if (t.kind == TypeKind.Var) return false;
	const inner = skipModifier(t);
	if (inner == null) return false;
	if (isStructType(inner)) return sizeOfType(tg, inner) > ptrThreshold(tg);
	// Union(Ref<T>, Null) collapses to T* in C — the pointer IS the value, no struct-via-pointer.
	if (inner.kind == TypeKind.Union && unwrapRefNullUnion(inner) != null) return false;
	const carried = literalUnionBase(inner);
	if (carried != null) return ccgIntroducedPtr(tg, carried);
	return match (inner.kind) {
		TypeKind.Tuple => sizeOfType(tg, inner) > ptrThreshold(tg),
		TypeKind.Array => true,  // arrays always by pointer: mutable by default, realloc invalidates caller copy
		TypeKind.Union => true,
		TypeKind.GenericInstance => {
			const repr = genericInstanceAbiRepr(inner);
			return repr == inner ? !isAwaitable(inner) : ccgIntroducedPtr(tg, repr);
		},
		_ => false,
	};
}

export function isOpenArrayParam(t: Readonly<Type | null>): boolean {
	if (t == null || t.kind == TypeKind.Var) return false;
	const inner = skipModifier(t);
	return inner != null && inner.kind == TypeKind.Span;
}

export function openArrayDataName(param: string): string { return param + "Data_0"; }
export function openArrayLenName(param: string): string { return param + "Len_0"; }

// Mutation forces T* for Struct, Function (msClosure 16B), and small Tuple.
// Actor lowering sets mutation bits via markValueLayoutParamsAsMutated.
export function returnsBorrow(fnType: Readonly<Type | null>): boolean {
	return fnType != null && fnType.kind == TypeKind.Function && fnType.typeReturn != null && fnType.typeReturn.kind == TypeKind.Borrow;
}

export function shouldIndirectParam(tg: TargetInfo, declared: Readonly<Type>, isMutated: boolean, lentFirst: boolean = false): boolean {
	if (declared == null) return false;
	const paramType = unwrapVarargs(declared);
	// Var params: the `*` is in the type (getTypeDesc); body derefs come from
	// HiddenDeref nodes. Never indirect — not even when mutated (an out param
	// is mutated by definition; the struct-mutation branch must not see
	// through Var via skipModifier).
	if (paramType.kind == TypeKind.Var) return false;
	const inner = paramAbiType(paramType);
	if (lentFirst && passedByValue(inner)) return true;
	if (inner != null && isStructType(inner)) {
		if (isMutated) return true;
		return sizeOfType(tg, inner) > ptrThreshold(tg);
	}
	if (isMutated && inner != null && (inner.kind == TypeKind.Function || inner.kind == TypeKind.Tuple)) return true;
	return ccgIntroducedPtr(tg, paramType);
}

function paramAbiType(paramType: Type): Type | null;
function paramAbiType(paramType: Readonly<Type>): Readonly<Type | null>;
function paramAbiType(paramType: Readonly<Type>): Readonly<Type | null> {
	const inner = skipModifier(paramType);
	if (inner == null) return null;
	if (inner.kind == TypeKind.GenericInstance) return genericInstanceAbiRepr(inner);
	if (inner.kind == TypeKind.Distinct && inner.typeReturn != null) return inner.typeReturn;
	return inner;
}

// Should this promoted param use const qualifier?
// Only unmutated struct params get const — all other promoted types use plain T*.
export function shouldConstParam(paramType: Readonly<Type>, isMutated: boolean): boolean {
	if (isMutated) return false;
	if (paramType == null) return false;
	const inner = paramAbiType(paramType);
	return inner != null && isStructType(inner);
}

// needsRC is now in checker/types.ms — imported above

// ===== NRVO Detection (Type-based, Standard reference parity) =====
// Returns true for types that are C structs — these need out-param calling convention.

// Reference parity: type defined in C header — skip codegen emission.
function isImportedType(t: Readonly<Type>): boolean {
	return t.sym != null && hasFlag(t.sym, SymbolFlag.ImportC);
}

// Emit #include for imported type's header (reference parity: header pragma).
function useImportedTypeHeader(g: CGen, t: Readonly<Type>): void {
	if (t.sym != null && t.sym.headerPath != "") {
		useHeader(g, t.sym);
	}
}

// Reference parity (isInvalidReturnType): returns true when NRVO needed.
// Takes the return type AND optionally the function type (for cdecl/importc check).
export function isNrvoReturnType(retType: Readonly<Type | null>, funcType: Readonly<Type | null>): boolean {
	if (retType == null) return false;
	// importc return types → no NRVO (C struct returned by value)
	if (isImportedType(retType)) return false;
	// importc/cdecl functions → no NRVO (C ABI compatibility)
	if (funcType != null && funcType.sym != null && hasFlag(funcType.sym, SymbolFlag.ImportC)) return false;
	if (isStructType(retType)) return true;
	if (retType.kind == TypeKind.Span) return true;
	if (isResult(retType)) return true;
	if (retType.kind == TypeKind.Tuple) return true;
	return hasArrayRepr(retType);
}

function hasArrayRepr(t: Readonly<Type | null>): boolean {
	if (t != null && t.kind == TypeKind.Alias) return hasArrayRepr(t.typeReturn);
	const repr = peelToRepr(t);
	return repr != null && repr.kind == TypeKind.SizedArray;
}

// ===== NRVO Call-Site Detection (Standard reference pattern) =====
// Centralized two-source callee type lookup. Reference implementation uses a single isInvalidReturnType()
// in reference types called from 10 locations across 4 files.

// Peek inside an ObjectLiteral closure pair for the wrapped function's
// type info. lambdaLifting builds `{ fn: <typed-Identifier>, env: null }`
// where the Identifier's nodeType is the original arrow's Function type
// (set in liftNonCapturing). Without this peek, IIFE callees report null
// Function type and genClosureCall emits `void(*)(void)` casts.
function closurePairFuncType(callee: Readonly<Node>): Readonly<Type | null> {
	if (callee == null || callee.kind != NodeKind.ObjectLiteral) return null;
	if (!callee.flags.has(NodeFlag.Closure)) return null;
	const od = callee.data as ObjectLiteralData;
	if (od.properties.length == 0) return null;
	const fnProp = od.properties[0];
	if (fnProp.nodeType != null && fnProp.nodeType.kind == TypeKind.Function) {
		return fnProp.nodeType;
	}
	if (fnProp.resolvedSym != null && fnProp.resolvedSym.symbolType != null
		&& fnProp.resolvedSym.symbolType.kind == TypeKind.Function) {
		return fnProp.resolvedSym.symbolType;
	}
	return null;
}

export function callOverloadWinner(callNode: Readonly<Node>): number {
	const sym = callNode.resolvedSym;
	if (sym == null || sym.overloads == null || sym.overloads.length == 0) return -1;
	const cd = callNode.data as CallExprData;
	return resolveOverloadWinner(sym, cd.resolvedOverloadIdx);
}

function overloadWinnerFuncType(callNode: Readonly<Node>): Readonly<Type | null> {
	const w = callOverloadWinner(callNode);
	if (w < 0 || callNode.resolvedSym == null) return null;
	const winner = overloadAt(callNode.resolvedSym, w);
	if (winner.symbolType == null || winner.symbolType.kind != TypeKind.Function) return null;
	return winner.symbolType;
}

export function getCalleeReturnType(callNode: Readonly<Node>): Readonly<Type | null> {
	const winnerType = overloadWinnerFuncType(callNode);
	if (winnerType != null) return winnerType.typeReturn;
	const cd = callNode.data as CallExprData;
	if (cd.callee != null && cd.callee.nodeType != null && cd.callee.nodeType.kind == TypeKind.Function) {
		return cd.callee.nodeType.typeReturn;
	}
	if (callNode.resolvedSym != null && callNode.resolvedSym.symbolType != null) {
		const st = callNode.resolvedSym.symbolType;
		if (st.kind == TypeKind.Function) return st.typeReturn;
	}
	const cpType = closurePairFuncType(cd.callee);
	if (cpType != null) return cpType.typeReturn;
	return null;
}

export function getCalleeFuncType(callNode: Readonly<Node>): Readonly<Type | null> {
	const winnerType = overloadWinnerFuncType(callNode);
	if (winnerType != null) return winnerType;
	const cd = callNode.data as CallExprData;
	if (cd.callee != null && cd.callee.nodeType != null) {
		const calleeType = peelTransparentInstance(cd.callee.nodeType);
		if (calleeType.kind == TypeKind.Function) return calleeType;
	}
	if (callNode.resolvedSym != null && callNode.resolvedSym.symbolType != null) {
		const st = callNode.resolvedSym.symbolType;
		if (st.kind == TypeKind.Function) return st;
	}
	const cpType = closurePairFuncType(cd.callee);
	if (cpType != null) return cpType;
	return null;
}

// ===== Forward Declaration =====
// Emits "typedef struct X X;" to cfsForwardDecls if not already done.

// getTypeForward — Standard reference implementation parity: like getTypeDesc but only emits a forward
// declaration + returns the C type name. Used when only a pointer is needed
// (e.g., array element type during self-referential struct definition).
export function getTypeForward(g: CGen, t: Readonly<Type | null>): string {
	if (t == null) return "void*";
	const simple = getSimpleTypeDesc(t);
	if (simple != "") return simple;
	// Check cache — if already fully resolved, just return
	const key = typeKey(t);
	const cached = typeCacheGet(g.typeCache, key);
	if (cached != "") return cached;
	if (t.kind == TypeKind.Struct && isImportedType(t)) return genObjectType(g, t);
	// For Object/Enum — forward-declare only
	if (t.kind == TypeKind.Struct || t.kind == TypeKind.Enum) {
		const name = (t.kind == TypeKind.Struct)
			? structIdentityName(g, t)
			: typeIdentityName(g, t);
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
	if (typeName == "msClosure") return;
	addLine(sec(g, CSection.ForwardDecls), `#ifndef ${typeName}_DEFINED\ntypedef struct ${typeName} ${typeName};\n#endif`);
}

export function typeInfoSubject(type: Type | null): Type | null;
export function typeInfoSubject(type: Readonly<Type | null>): Readonly<Type | null>;
export function typeInfoSubject(type: Readonly<Type | null>): Readonly<Type | null> {
	if (type == null) return null;
	let t = peelTransparentInstance(type);
	const nullableRef = unwrapRefNullUnion(t);
	if (nullableRef != null) t = nullableRef;
	if (t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr) {
		if (t.typeReturn != null) t = t.typeReturn;
		else if (t.typeChildren.length > 0 && t.typeChildren[0] != null) t = t.typeChildren[0];
		else return null;
	}
	if (t.kind == TypeKind.Alias && t.typeReturn != null) return typeInfoSubject(t.typeReturn);
	if (t.kind == TypeKind.GenericInstance) return t.typeName != "" ? t : null;
	if (t.kind != TypeKind.Struct && t.kind != TypeKind.Union) return null;
	return t;
}

export function typeInfoCName(subject: Readonly<Type>): string {
	if (subject.kind == TypeKind.GenericInstance) return mangle(monoInstanceName(subject));
	if (subject.kind == TypeKind.Union && subject.typeName == "") return anonUnionCName(subject);
	if (isAnonTypeName(subject.typeName)) return anonTypeName(subject);
	return resolvedTypeCName(subject, true);
}

export function objectTypeInfoKey(subject: Readonly<Type>): string {
	return `obj|${typeInfoCName(subject)}`;
}

export function arcCellKey(pointee: Readonly<Type>): string {
	return "arc|" + opTypeKey(pointee);
}

export function arcCellName(pointee: Type): string {
	return "msArcCell_" + hashToBase36(opTypeKey(pointee));
}

export enum PromiseAllShape {
	None,
	Int32,
	Int64,
	Integer,
	Boxed,
}

export function promiseAllShape(inner: Readonly<Type | null>): PromiseAllShape {
	if (inner == null || inner.kind == TypeKind.Void) return PromiseAllShape.None;
	if (inner.kind == TypeKind.Sink || inner.kind == TypeKind.Lent || inner.kind == TypeKind.Distinct) return promiseAllShape(inner.typeReturn);
	const simple = getSimpleTypeDesc(inner);
	if (simple != "") {
		if (simple == "double" || simple == "bool" || simple == "MS_BOOL" || simple == "msString" || simple.endsWith("*")) return PromiseAllShape.None;
		if (simple == "int32_t") return PromiseAllShape.Int32;
		if (simple == "int64_t") return PromiseAllShape.Int64;
		if (isIntegerType(inner)) return PromiseAllShape.Integer;
		return PromiseAllShape.Boxed;
	}
	if (isAwaitable(inner)) return PromiseAllShape.None;
	return match (inner.kind) {
		TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow | TypeKind.Cursor | TypeKind.Var
			| TypeKind.Array | TypeKind.SizedArray | TypeKind.Span => PromiseAllShape.None,
		TypeKind.Union => unwrapRefNullUnion(inner) != null ? PromiseAllShape.None : PromiseAllShape.Boxed,
		_ => PromiseAllShape.Boxed,
	};
}

export function hasUnionEq(t: Type): boolean {
	if (t.kind != TypeKind.Union || t.typeExtra != null || isStringLike(t)) return false;
	if (unwrapRefNullUnion(t) != null) return false;
	for (const m of t.typeChildren) {
		if (m == null) return false;
		if (isPrimitiveUnionMember(m) || m.kind == TypeKind.Ref || m.kind == TypeKind.Ptr) continue;
		return false;
	}
	return true;
}

function typeInfoPointer(g: CGen, info: Readonly<CTypeInfoDemand>): string {
	if (hcrTypeInfoRef(g, info.cName)) return `&${info.cName}TypeInfo`;
	const forwKey = "typeInfo:" + info.cName;
	if (!typeCacheHas(g.forwTypeCache, forwKey)) {
		typeCacheSet(g.forwTypeCache, forwKey, info.cName);
		addLine(sec(g, CSection.ForwardDecls), `extern msTypeInfo ${info.cName}TypeInfo;`);
	}
	return `&${info.cName}TypeInfo`;
}

function demandedTypeInfo(g: CGen, key: string, what: string): Readonly<CTypeInfoDemand> | null {
	const info = g.emissionFacts.typeInfos.readonlyGet(key);
	if (info == null) {
		addCGenError(g, `internal: ${what} TypeInfo ${key} demanded in ${g.modulePath} without a reachability edge`, 0, 0);
		return null;
	}
	return info;
}

export function typeInfoRef(g: CGen, type: Readonly<Type | null>): string {
	if (g.checkerCtx != null && g.checkerCtx.gcMode == GcMode.Manual) return "NULL";
	const subject = typeInfoSubject(type);
	if (subject == null) {
		addCGenError(g, `internal: a TypeInfo was requested in ${g.modulePath} for a type that has none`, 0, 0);
		return "NULL";
	}
	const info = demandedTypeInfo(g, objectTypeInfoKey(subject), "object");
	return info == null ? "NULL" : typeInfoPointer(g, info);
}

export function ensureArcCellTypeInfo(g: CGen, pointeeType: Readonly<Type>): string {
	if (g.checkerCtx != null && g.checkerCtx.gcMode == GcMode.Manual) return "NULL";
	const info = demandedTypeInfo(g, arcCellKey(pointeeType), "Arc cell");
	return info == null ? "NULL" : typeInfoPointer(g, info);
}

export function refArrayCellKey(arrT: Readonly<Type>): string {
	return "ref:" + opTypeKey(arrT);
}

export function refArrayCellOp(arrT: Type, op: AttachedOp): Symbol | null;
export function refArrayCellOp(arrT: Readonly<Type>, op: AttachedOp): Readonly<Symbol | null>;
export function refArrayCellOp(arrT: Readonly<Type>, op: AttachedOp): Readonly<Symbol | null> {
	return _opSyms.get(attachedOpName(op) + "|" + refArrayCellKey(arrT));
}

export function refArrayCellOpIn(ops: HashMap<string, Symbol>, arrT: Type, op: AttachedOp): Symbol | null;
export function refArrayCellOpIn(ops: Readonly<HashMap<string, Symbol>>, arrT: Readonly<Type>, op: AttachedOp): Readonly<Symbol | null>;
export function refArrayCellOpIn(ops: Readonly<HashMap<string, Symbol>>, arrT: Readonly<Type>, op: AttachedOp): Readonly<Symbol | null> {
	return ops.readonlyGet(attachedOpName(op) + "|" + refArrayCellKey(arrT));
}

export function isHcrImageModule(g: CGen, modulePath: string): boolean {
	return g.emissionFacts.hcrModules.has(modulePath);
}

export function hcrTypeInfoRef(g: CGen, cName: string): boolean {
	if (!isHcrImageModule(g, g.modulePath)) return false;
	const owner = g.emissionFacts.hcrTypeInfoOwners.readonlyGet(cName);
	if (owner == null) return false;
	const key = "hcrTypeInfo:" + cName;
	if (typeCacheHas(g.forwTypeCache, key)) return true;
	const pointer = `_ms_hcr_ti_${cName}`;
	typeCacheSet(g.forwTypeCache, key, pointer);
	addLine(sec(g, CSection.ForwardDecls), `static msTypeInfo* ${pointer};`);
	addLine(sec(g, CSection.ForwardDecls), `#define ${cName}TypeInfo (*${pointer})`);
	addLine(sec(g, CSection.DatInit), `  ${pointer} = (msTypeInfo*)msHcrTypeInfo(${cStringLiteral(owner)}, ${cStringLiteral(cName)});`);
	return true;
}

export function ensureRefArrayCellTypeInfo(g: CGen, arrT: Readonly<Type>): string {
	if (g.checkerCtx != null && g.checkerCtx.gcMode == GcMode.Manual) return "NULL";
	const key = refArrayCellKey(arrT);
	const info = demandedTypeInfo(g, key, "ref-array cell");
	return info == null ? "NULL" : typeInfoPointer(g, info);
}

function refArrayCellLabel(g: CGen, info: Readonly<CTypeInfoDemand>): string {
	const arrT = info.subject.typeReturn!;
	const arrCType = getTypeDesc(g, arrT);
	const elem = arrayOpElement(arrT.typeReturn);
	if (arrCType == "msRefArray" && isUncountedElement(elem)) return "msPtrArrayRefCell";
	if (arrCType == "msRefArray" && elem != null && (elem.kind == TypeKind.Ref || elem.kind == TypeKind.Ptr)) {
		if (elem.sym != null && elem.sym.symbolKind == SymbolKind.Actor) return "msPtrArrayRefCell";
		if (isAtomicRef(elem)) return "msAtomicArrayRefCell";
	}
	if (!arrCType.endsWith("Array")) return arrCType + "RefCell";
	const elemCName = arrCType.slice(0, arrCType.length - 5);
	const bare = typeCacheGet(g.typeCache, "bare:" + elemCName);
	return (bare != "" ? getArrayTypeName(bare) : arrCType) + "RefCell";
}

function objectTypeInfoLabel(info: Readonly<CTypeInfoDemand>): string {
	const t = info.subject;
	if (t.kind == TypeKind.GenericInstance || t.sym == null || t.sym.instantiatedFrom != null || isAnonTypeName(t.typeName)) return info.cName;
	return mangle(t.typeName);
}

function typeInfoLabel(g: CGen, info: Readonly<CTypeInfoDemand>): string {
	return match (info.kind) {
		TypeInfoKind.RefArrayCell => refArrayCellLabel(g, info),
		TypeInfoKind.Object => objectTypeInfoLabel(info),
		TypeInfoKind.ArcCell => mangle(getTypeDesc(g, info.subject)) + "Arc",
	};
}

function emitRttiHook(g: CGen, name: string, hook: Readonly<Symbol>, trace: boolean): string {
	const hookName = opCName(hook);
	ensureDrcProto(g, hookName, hook);
	const params = trace ? "void* dest, void* env" : "void* dest";
	addLine(sec(g, CSection.ProcHeaders), `static void ${name}(${params});`);
	addLine(sec(g, CSection.Procs), `static void ${name}(${params}) { ${hookName}(dest${trace ? ", env" : ""}); }`);
	return name;
}

export function emitOwnedTypeInfos(g: CGen): void {
	if (g.checkerCtx != null && g.checkerCtx.gcMode == GcMode.Manual) return;
	const viaRegistry = isHcrImageModule(g, g.modulePath);
	for (const info of g.emissionFacts.typeInfoOrder) {
		if (info.owner != g.modulePath) continue;
		let destroyName = "NULL";
		if (info.destroy != null) destroyName = emitRttiHook(g, info.cName + "RttiDestroy", info.destroy, false);
		let traceName = "NULL";
		if (info.trace != null) traceName = emitRttiHook(g, info.cName + "RttiTrace", info.trace, true);
		let baseRef = "NULL";
		if (info.baseKey != "") {
			const base = demandedTypeInfo(g, info.baseKey, "base class");
			if (base != null) baseRef = typeInfoPointer(g, base);
		}
		const label = typeInfoLabel(g, info);
		const shown = info.kind != TypeInfoKind.Object ? "" : runtimeClassSym(info.subject) != null ? typeDisplayName(info.subject) : "Object";
		const fields = `.name = "${label}", .isCyclic = ${info.trace != null ? "MS_TRUE" : "MS_FALSE"}, `
			+ `.traceFn = ${traceName}, .destroyFn = ${destroyName}, .flags = ${typeInfoFlags(info.subject)}${viaRegistry && info.kind == TypeInfoKind.Object ? " | MS_TYPE_FLAG_HCR" : ""}, .base = ${baseRef}`
			+ (shown != "" && shown != label ? `, .displayName = "${escapeCString(shown)}"` : "");
		if (viaRegistry && !hcrTypeInfoRef(g, info.cName)) {
			addCGenError(g, `internal: HCR image ${g.modulePath} owns TypeInfo ${info.cName} but no image module registers it`, 0, 0);
			continue;
		}
		if (viaRegistry) addLine(sec(g, CSection.DatInit), `  ${info.cName}TypeInfo = (msTypeInfo){ ${fields} };`);
		else addLine(sec(g, CSection.GlobalVars), `msTypeInfo ${info.cName}TypeInfo = { ${fields} };`);
		if (info.kind == TypeInfoKind.Object) emitTypeInfoDisplay(g, info);
	}
}

function emitTypeInfoDisplay(g: CGen, info: Readonly<CTypeInfoDemand>): void {
	const chain: string[] = [`&${info.cName}TypeInfo`];
	let key = info.baseKey;
	while (key != "") {
		const base = demandedTypeInfo(g, key, "base class");
		if (base == null) return;
		chain.push(typeInfoPointer(g, base));
		key = base.baseKey;
	}
	const displayName = info.cName + "TypeInfoDisplay";
	addLine(sec(g, CSection.GlobalVars), `static const msTypeInfo* ${displayName}[${chain.length}];`);
	const datInit = sec(g, CSection.DatInit);
	for (let slot = 0; slot < chain.length; slot += 1) {
		addLine(datInit, `  ${displayName}[${slot}] = ${chain[chain.length - 1 - slot]};`);
	}
	addLine(datInit, `  ${info.cName}TypeInfo.depth = ${chain.length - 1};`);
	addLine(datInit, `  ${info.cName}TypeInfo.display = ${displayName};`);
}

// ===== Full Type Description =====
// Main entry point: returns C type name string for a MetaScript Type.
// Emits type definitions to CGen sections as side effect.

// Nim getTypeDescAux else-branch (ccgtypes.nim internalError): a sentinel kind
// reaching codegen is a checker bug, never codegen leniency — see the
// sentinel-kind map at unknownType (checker/types.ms). Population measured
// empty 2026-08-06 (battery + Neon sweep + self-build) before this was armed.
function gateFlaglessUnknown(g: CGen, t: Readonly<Type>): void {
	const pn = g.currentProc != null ? g.currentProc.name : "<toplevel>";
	addCGenError(g, "internal: unresolved type (kind=" + (t.kind as number).toString() + ") reached codegen in " + g.modulePath + " proc " + pn, 0, 0);
}

function typeInfoFlags(subject: Readonly<Type | null>): string {
	return subject != null && subject.typeFlags.has(TypeFlag.ArityAdapter) ? "MS_TYPE_FLAG_ARITY_ADAPTER" : "0";
}

export function getTypeDesc(g: CGen, t: Readonly<Type | null>): string {
	if (t == null) return "void*";
	// Standard reference parity: strip ownership modifiers at entry.
	// Ownership modifiers like sink and lent don't affect the C type descriptor.
	if (t.kind == TypeKind.Sink || t.kind == TypeKind.Lent) {
		return getTypeDesc(g, t.typeReturn);
	}
	// Distinct types are nominal in the checker only — at the C ABI level they
	// share the underlying type's representation (e.g. `type UserId = distinct
	// number` compiles to `double`).
	if (t.kind == TypeKind.Distinct) {
		return getTypeDesc(g, t.typeReturn);
	}
	if (t.kind == TypeKind.Alias) {
		return getTypeDesc(g, t.typeReturn);
	}
	if (t.kind == TypeKind.Set) {
		const sr = setRepr(t);
		if (sr != null) return getTypeDesc(g, sr);
	}
	// Reference parity: tyVarargs is a transparent marker for rest params. The C
	// param descriptor is the wrapped array type — the marker carries no ABI.
	if (t.kind == TypeKind.Varargs && t.typeChildren.length > 0) {
		return getTypeDesc(g, t.typeChildren[0]);
	}
	// Check simple types first (no caching needed)
	const simple = getSimpleTypeDesc(t);
	if (simple != "") {
		return simple;
	}

	// Check full cache
	const key = typeKey(t);
	const cached = typeCacheGet(g.typeCache, key);
	if (cached != "") return cached;

	// Result is a boolean-discriminated match-type Union (createResult builds it).
	// Flow through the standard GenericInstance → Union path below; no bespoke
	// codegen needed.
	if (isAwaitable(t)) return genFutureType(g, t);

	return match (t.kind) {
		TypeKind.Enum => genEnumType(g, t),
		// EnumLiteral: treated as its underlying enum for C codegen (ints at runtime)
		TypeKind.EnumLiteral => {
			if (t.typeReturn != null && t.typeReturn.kind == TypeKind.Enum) return genEnumType(g, t.typeReturn);
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
		TypeKind.Cursor => {
			const cursorType = getTypeDesc(g, t.typeReturn);
			typeCacheSet(g.typeCache, key, cursorType);
			return cursorType;
		},
		TypeKind.Ptr => {
			const innerType = t.typeReturn;
			if (innerType != null && innerType.kind == TypeKind.Ref) {
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
			if (refMember != null) return getTypeDesc(g, refMember);
			if (t.typeInst != null) return genInstanceUnion(g, t.typeInst, t);
			return genUnionType(g, t);
		},
		TypeKind.Tuple => genTupleType(g, t),
		TypeKind.Unknown => "void*",
		// Sentinel kinds must never reach emission (Nim getTypeDescAux else-branch);
		// Pending is unconstructible, Inferred must resolve or error in sem.
		TypeKind.Pending => {
			gateFlaglessUnknown(g, t);
			return "void*";
		},
		TypeKind.None => {
			gateFlaglessUnknown(g, t);
			return "void*";
		},
		TypeKind.Inferred => {
			gateFlaglessUnknown(g, t);
			return "void*";
		},
		TypeKind.GenericParam => "void*",
		// GenericInstance: resolve to monomorphized C struct name
		TypeKind.GenericInstance => {
			const transparent = peelTransparentInstance(t);
			if (transparent != t) return getTypeDesc(g, transparent);
			// A generic distinct/alias instance is nominal to the checker only —
			// at the C ABI it is the underlying type, exactly like the non-generic
			// `type UserId = distinct number` case handled above.
			const instRepr = distinctInstanceRepr(t);
			if (instRepr != null) return getTypeDesc(g, instRepr);
			const declBody: Readonly<Type | null> = peelToStructOrUnion(t.typeExtra);
			const sharedBody = t.typeReturn != null ? peelToStructOrUnion(t.typeReturn) : null;
			if (sharedBody != null && sharedBody.kind == TypeKind.Union && sharedBody == declBody) return getTypeDesc(g, sharedBody);
			const instName = monoInstanceName(t);
			const cacheKey = `object:${instName}`;
			const cached = typeCacheGet(g.typeCache, cacheKey);
			if (cached != "") return cached;
			typeCacheSet(g.typeCache, cacheKey, instName);
			// `Result<T, E> = Ref<ResultData<T, E>>` chains GI→Ref→GI→Union before the body.
			const body: Readonly<Type | null> = t.typeReturn != null ? peelToStructOrUnion(t.typeReturn) : declBody;
			if (body == null || (genericParamsOf(t) == "" && t.typeReturn == null)) return instName;
			const instCName = mangledTypeName(null, instName);
			if (body.kind == TypeKind.Struct) return genObjectTypeAs(g, body, instCName, "object:" + instCName, instName);
			if (body.kind != TypeKind.Union) return instName;
			if (body == declBody) return genUnionType(g, body);
			return genUnionTypeAs(g, body, "union:" + instCName, instCName, instName);
		},
		_ => "void",
	};
}

// ===== Enum Type Generation =====

export function enumCTypeName(t: Readonly<Type | null>): string {
	if (t == null || t.kind != TypeKind.Enum) return "int32_t";
	return match (enumStorageKind(t)) {
		TypeKind.Uint8 => "uint8_t",
		TypeKind.Uint16 => "uint16_t",
		_ => "int32_t",
	};
}

function genEnumType(g: CGen, t: Readonly<Type>): string {
	const name = typeIdentityName(g, t);
	const key = typeKey(t);
	typeCacheSet(g.typeCache, key, name);
	if (t.typeName != "") {
		typeCacheSet(g.typeCache, "decl:" + name, name);
		typeCacheSet(g.typeCache, "bare:" + name, t.typeName);
	}

	if (isImportedType(t)) { useImportedTypeHeader(g, t); return name; }

	addLine(sec(g, CSection.Types), `typedef ${enumCTypeName(t)} ${name};`);

	// Emit enum constants (use explicit values from typeChildren if available)
	for (let i = 0; i < t.typeNames.length; i += 1) {
		const memberName = `${name}_${mangle(t.typeNames[i])}`;
		let val = i;
		if (t.typeChildren != null && i < t.typeChildren.length && t.typeChildren[i] != null) {
			val = t.typeChildren[i].typeValue;
		}
		addLine(sec(g, CSection.Types), `#define ${memberName} (((${name})${val.toString()}))`);
	}
	addNewline(sec(g, CSection.Types));

	return name;
}

// ===== Object Type Generation =====
// Objects are always value-type structs. Pointer semantics come from Ref<T>/Ptr<T> wrapping.

function genObjectType(g: CGen, t: Readonly<Type>): string {
	// Anonymous/structural types get hash-based names; named types get mangled names
	const name = structIdentityName(g, t);
	const key = typeKey(t);

	if (isImportedType(t)) {
		useImportedTypeHeader(g, t);
		typeCacheSet(g.typeCache, key, name);
		return name;
	}
	return genObjectTypeAs(g, t, name, key, t.typeName);
}

// `t` gives the fields and layout; name, key and bare name give the identity, which for a generic
// instance is the instance's rather than its body's.
function genObjectTypeAs(g: CGen, t: Readonly<Type>, name: string, key: string, bareName: string): string {
	// Always value type — Ref<Object> adds the * via TypeKind.Ref path
	const cTypeName = name;
	typeCacheSet(g.typeCache, key, cTypeName);
	if (!isAnonTypeName(bareName) && bareName != "") {
		typeCacheSet(g.typeCache, "decl:" + cTypeName, cTypeName);
		typeCacheSet(g.typeCache, "bare:" + cTypeName, bareName);
	}

	// Ensure forward declaration
	ensureForwardDecl(g, name);

	// Cycle tracking (Standard implementation parity)
	// Track this type as "being defined" so genArrayType can detect self-referential
	// arrays (e.g., Type[] inside struct Type) and use the two-struct split.
	g.typesBeingDefined.push(key);

	// Pre-resolve field types BEFORE emitting struct body (Standard reference pattern).
	// Natural recursion ensures nested struct bodies are emitted BEFORE this struct.
	// This is correct for C: value-type fields need complete types.
	const fieldTypes: string[] = [];
	for (let i = 0; i < t.typeNames.length; i += 1) {
		let ft = (i < t.typeChildren.length) ? getTypeDesc(g, t.typeChildren[i]) : "void";
		// Self-referential fields: same type as containing struct → must be pointer
		// C cannot contain a struct by value inside itself (infinite size)
		if (ft == name) {
			ft = name + "*";
		}
		fieldTypes.push(ft);
	}

	let structDef = `#ifndef ${name}_DEFINED\n#define ${name}_DEFINED\nstruct ${name} {\n`;
	for (let i = 0; i < t.typeNames.length; i += 1) {
		if (i < t.typeChildren.length && storesNothing(t, t.typeChildren[i])) continue;
		structDef = structDef + `  ${fieldTypes[i]} ${mangleFieldName(t.typeNames[i])};\n`;
	}
	structDef = structDef + "};\n" + layoutAssert(g, t, `struct ${name}`) + "#endif\n";

	// Emit struct body directly (reference parity: natural recursion gives correct order).
	// By-value dependency on a union still mid-generation defers to the queue
	// (see flushDeferredStructs) — emitting now would reference an incomplete type.
	let blocker = "";
	for (const ft of fieldTypes) {
		if (unionInProgress(g, ft)) { blocker = ft; break; }
	}
	if (blocker != "") {
		g.deferredStructs.push({ blocker: blocker, def: structDef });
	} else {
		const b = sec(g, CSection.Types);
		add(b, structDef);
		addNewline(b);
	}

	// Remove from cycle tracking
	g.typesBeingDefined.pop();

	return cTypeName;
}

function layoutAssert(g: CGen, t: Readonly<Type>, cType: string): string {
	const size = sizeOfType(g.target, t);
	return size < 0 ? "" : `_Static_assert(sizeof(${cType}) == ${size}, "${cType} layout");\n`;
}

export function assertExternLayout(g: CGen, t: Readonly<Type>): void {
	if (t.sym == null || !t.typeFlags.has(TypeFlag.CompleteStruct)) return;
	const cType = t.sym.nativeName;
	const size = sizeOfType(g.target, t);
	if (size < 0 || nameSetHas(g.declaredThings, "layout:" + cType)) return;
	nameSetAdd(g.declaredThings, "layout:" + cType);
	useImportedTypeHeader(g, t);
	let asserts = layoutAssert(g, t, cType)
		+ `_Static_assert(_Alignof(${cType}) == ${alignOfType(g.target, t)}, "${cType} alignment");\n`;
	for (const field of t.typeNames) {
		asserts = asserts + `_Static_assert(offsetof(${cType}, ${field}) == ${offsetOfField(g.target, t, field)}, "${cType}.${field} offset");\n`;
	}
	add(sec(g, CSection.Types), asserts);
}

// ===== Union Type Generation =====
// Standard reference pattern: union variant structs + wrapper struct with anonymous union.
// Each variant Object type in typeChildren gets its own named struct.
// The `as` cast maps to .vN member access at the codegen level.

function genInstanceUnion(g: CGen, gi: Readonly<Type>, body: Readonly<Type>): string {
	const instName = monoInstanceName(gi);
	const cacheKey = `object:${instName}`;
	const cached = typeCacheGet(g.typeCache, cacheKey);
	if (cached != "") return cached;
	typeCacheSet(g.typeCache, cacheKey, instName);
	return genUnionTypeAs(g, body, typeKey(body), mangledTypeName(body.sym, instName), instName);
}

function genUnionType(g: CGen, t: Readonly<Type>): string {
	const named = t.typeName.length > 0;
	return genUnionTypeAs(g, t, typeKey(t), named ? typeIdentityName(g, t) : "", named ? t.typeName : "");
}

// Identity as in genObjectTypeAs; an empty name means a structural union named by its shape.
function genUnionTypeAs(g: CGen, t: Readonly<Type>, key: string, identity: string, bareName: string): string {
	const carried = literalUnionBase(t);
	if (carried != null) {
		const carriedDesc = getTypeDesc(g, carried);
		typeCacheSet(g.typeCache, key, carriedDesc);
		return carriedDesc;
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
	if (cached != "") return cached;

	const name = identity != "" ? identity : anonUnionCName(t);
	typeCacheSet(g.typeCache, key, name);
	if (bareName != "") {
		typeCacheSet(g.typeCache, "decl:" + name, name);
		typeCacheSet(g.typeCache, "bare:" + name, bareName);
	}
	ensureForwardDecl(g, name);
	g.unionsInProgress.push(name);

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
		// Primitive/string variants (float32 | string) carry the raw C type as
		// payload — no per-variant struct typedef. Null is tag-only ("").
		const rawVariant = t.typeChildren[vi];
		const structVariant = inlineVariantStruct(rawVariant);
		if (isPrimitiveUnionMember(rawVariant) || structVariant == null || structVariant.kind != TypeKind.Struct) {
			canonicalNames.push(rawVariant.kind == TypeKind.Null ? "" : getTypeDesc(g, rawVariant));
			allFieldTypes.push([]);
			vi += 1;
			continue;
		}
		const variant = structVariant;
		const varName = `${name}_v${vi}`;

		// Cache variant Object type so getTypeDesc returns the variant struct name.
		// First variant with a given structural key wins — duplicates reuse it.
		// A variant DECLARED in this module (cname: registered by the pass-1
		// decl-name walk) resolves through its own declared typedef instead:
		// caching the slot name under the struct's typeKey ("object:<id>") made
		// genInterfaceDecl's idempotency gate think the body was already
		// emitted, silently dropping it — and DRC hook definitions then took
		// their parameter from that hijacked slot name while the hook
		// prototypes derive from the hook NAME (clang: conflicting types).
		// That happened whenever a function forced the union BEFORE the
		// interface decl was processed — exactly what lambda lifting's
		// prepend of lifted functions produces. Resolving the declared name
		// here emits the body and keeps hooks, prototypes and the later
		// InterfaceDecl in agreement regardless of statement order; anonymous
		// variants keep the structural sharing this cache was designed for.
		let canonical = varName;
		if (variant != null && variant.kind == TypeKind.Struct) {
			const varKey = typeKey(variant);
			const existing = typeCacheGet(g.typeCache, varKey);
			if (existing != "") {
				canonical = existing;
			} else if (variant.typeName != "" && !isAnonTypeName(variant.typeName)
					&& typeCacheHas(g.typeCache, "decl:" + structIdentityName(g, variant))) {
				canonical = getTypeDesc(g, variant);
			} else {
				typeCacheSet(g.typeCache, varKey, varName);
			}
		}
		canonicalNames.push(canonical);

		// Pre-resolve field types
		const fieldTypes: string[] = [];
		if (variant != null && variant.typeNames != null) {
			let fi = 0;
			while (fi < variant.typeNames.length) {
				let ft = (fi < variant.typeChildren.length && variant.typeChildren[fi] != null)
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
		const variant = inlineVariantStruct(t.typeChildren[vi]);
		const varName = `${name}_v${vi}`;
		const fieldTypes = allFieldTypes[vi];

		// Skip duplicate: this variant reuses an earlier variant's typedef
		if (canonicalNames[vi] != varName) {
			vi += 1;
			continue;
		}

		addLine(b, "typedef struct {");
		b.indent += 1;
		if (variant != null && variant.typeNames != null) {
			let fi = 0;
			while (fi < variant.typeNames.length) {
				const stored = fi >= variant.typeChildren.length || !storesNothing(variant, variant.typeChildren[fi]);
				if (stored && fieldTypes[fi] != "void") {
					addLine(b, `${fieldTypes[fi]} ${mangleFieldName(variant.typeNames[fi])};`);
				}
				fi += 1;
			}
		}
		b.indent -= 1;
		addLine(b, "} " + varName + ";");
		if (variant != null) add(b, layoutAssert(g, variant, varName));

		vi += 1;
	}
	addNewline(b);

	// Phase 2: Emit wrapper struct with anonymous union
	// Pre-resolve discriminant enum type BEFORE opening the struct (avoid nested typedef)
	let tagTypeName = "int32_t";
	if (t.typeExtra != null && t.typeExtra.kind == TypeKind.Enum && t.typeExtra.typeName != "") {
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
		// Use canonical name — duplicate variants share the same typedef.
		// "" = tag-only variant (Null): no payload member.
		const memberType = canonicalNames[vi];
		if (memberType != "") addLine(b, `${memberType} v${vi};`);
		vi += 1;
	}
	b.indent -= 1;
	addLine(b, "};");
	b.indent -= 1;
	addLine(b, "};");
	add(b, layoutAssert(g, t, `struct ${name}`));
	addLine(b, "#endif");
	addNewline(b);

	// Union definition is complete: structs deferred on it can now emit.
	g.unionsInProgress.pop();
	flushDeferredStructs(g);

	return name;
}

// ===== Array Type Generation =====
// Standard reference pattern: each element type gets its own array typedef.
// Primitives use built-in types (msNumberArray, msStringArray).
// Struct/interface elements use per-type MS_ARRAY(T) typedefs.

function genArrayType(g: CGen, t: Readonly<Type>): string {
	const key = typeKey(t);

	// Resolve element key for cycle detection and pointer classification.
	const resolvedElem = t.typeReturn;
	const elemKey = (resolvedElem != null) ? typeKey(resolvedElem) : "";
	const selfRef = elemKey != "" && isBeingDefined(g, elemKey);

	const byValue = !selfRef && resolvedElem != null && holdsStructByValue(resolvedElem);
	const elemType = selfRef ? getTypeForward(g, t.typeReturn) : (byValue ? "" : getTypeDesc(g, t.typeReturn));

	const arrTypeName = arrayCTypeName(t);
	typeCacheSet(g.typeCache, key, arrTypeName);

	// Built-in array families are runtime-provided — no per-type typedef.
	if (isRuntimeArrayFamily(t)) return arrTypeName;

	// Emit typedef if not already done
	const fwdKey = "arrtd:" + arrTypeName;
	if (!typeCacheHas(g.forwTypeCache, fwdKey)) {
		typeCacheSet(g.forwTypeCache, fwdKey, arrTypeName);

		// Reference parity: two-struct split { len, p* } + __Content { cap, T data[] }.
		// Forward decls in ForwardDecls, slim struct in Types, content in SeqTypes.
		// SeqTypes is emitted after Types — element type is always complete by then.
		// A by-value element is spelled by the name getTypeDesc gives it once defined
		// (defineDeferredElements), never by a name derived beside it.
		const contentName = arrTypeName + "__Content";
		addLine(sec(g, CSection.ForwardDecls), `typedef struct ${arrTypeName} ${arrTypeName};`);
		addLine(sec(g, CSection.ForwardDecls), `typedef struct ${contentName} ${contentName};`);
		addLine(sec(g, CSection.Types), `struct ${arrTypeName} { int64_t len; ${contentName}* p; };`);
		if (byValue && resolvedElem != null) {
			g.deferredElements.push({ elem: resolvedElem, contentName: contentName });
		} else {
			addLine(sec(g, CSection.SeqTypes), `struct ${contentName} { int64_t cap; ${elemType} data[]; };`);
		}
	}

	return arrTypeName;
}

function holdsStructByValue(t: Readonly<Type>): boolean {
	if (isImportedType(t)) return false;
	const peeled = peelTransparentInstance(t);
	if (peeled != t) return holdsStructByValue(peeled);
	if ((t.kind == TypeKind.Distinct || t.kind == TypeKind.Alias) && t.typeReturn != null) return holdsStructByValue(t.typeReturn);
	if (t.kind == TypeKind.GenericInstance) return distinctInstanceRepr(t) == null && isStructType(peelToStructOrUnion(t.typeExtra));
	return isStructType(t) || t.kind == TypeKind.Tuple;
}

export function defineDeferredElements(g: CGen): void {
	while (g.deferredElements.length > 0) {
		const pending = g.deferredElements;
		g.deferredElements = [];
		for (const d of pending) {
			const elemType = getTypeDesc(g, d.elem);
			addLine(sec(g, CSection.SeqTypes), `struct ${d.contentName} { int64_t cap; ${elemType} data[]; };`);
		}
	}
}

// Returns the array type name for a given element type string (for use in expressions/statements).
// Element-C-name → array-type-name rule. Used by destructorLifting (seqHookName) to name
// per-type array walkers; mirrors the inline rule in genArrayType.
export function getArrayTypeName(elemType: string): string {
	if (elemType == "double") return "msNumberArray";
	if (elemType == "msString") return "msStringArray";
	if (elemType == "MS_BOOL") return "msUint8Array";
	if (elemType == "uint8_t") return "msUint8Array";
	if (elemType == "msClosure") return "msClosureArray";
	return mangle(elemType) + "Array";
}

// Element's C type NAME (no emission) — mirrors EVERY name-producing branch of getTypeDesc
// using the SAME building blocks (getSimpleTypeDesc / mangle / monoTypeKey / tupleTypeName),
// so arrayCTypeName agrees with getTypeDesc for any element that appears in a value array.
function elemArrayCName(elem: Readonly<Type>): string {
	const simple = getSimpleTypeDesc(elem);
	if (simple != "") return simple;
	const transparent = peelTransparentInstance(elem);
	if (transparent != elem) return elemArrayCName(transparent);
	if ((elem.kind == TypeKind.Distinct || elem.kind == TypeKind.Alias) && elem.typeReturn != null) return elemArrayCName(elem.typeReturn);
	if (elem.kind == TypeKind.Set) {
		const sr = setRepr(elem);
		if (sr != null) return elemArrayCName(sr);
	}
	if (elem.kind == TypeKind.Enum) return resolvedTypeCName(elem, true);
	if (elem.kind == TypeKind.EnumLiteral) return (elem.typeReturn != null && elem.typeReturn.kind == TypeKind.Enum) ? resolvedTypeCName(elem.typeReturn, true) : "int32_t";
	if (elem.kind == TypeKind.Tuple) return tupleTypeName(elem);
	if (elem.kind == TypeKind.SizedArray) return sizedArrayCTypeName(elem);
	if (elem.kind == TypeKind.Array) return arrayCTypeName(elem);
	if ((elem.kind == TypeKind.Ref || elem.kind == TypeKind.Ptr || elem.kind == TypeKind.Var) && elem.typeReturn != null) return elemArrayCName(elem.typeReturn) + "*";
	if (elem.kind == TypeKind.Function) return "msClosure";
	if (elem.kind == TypeKind.Union) {
		const rm = unwrapRefNullUnion(elem);
		if (rm != null) return elemArrayCName(rm);
		return isAnonTypeName(elem.typeName) ? anonUnionCName(elem) : resolvedTypeCName(elem, true);
	}
	if (elem.kind == TypeKind.GenericInstance) return monoInstanceName(elem);
	if (elem.kind == TypeKind.Struct) {
		return isAnonTypeName(elem.typeName) ? anonTypeName(elem) : resolvedTypeCName(elem, true);
	}
	return "void*";
}

// Single source for an array's C type name (structural arrays/tuples carry no
// stored identity, so this is the one place the name is derived). genArrayType (codegen)
// and destructorLifting (transform) both route through here — no parallel naming.
export function arrayCTypeName(t: Readonly<Type>): string {
	const elem = t.typeReturn;
	if (elem == null) return "msRefArray";
	// Awaitable element → getTypeDesc emits msFuture_X* (pointer) → msRefArray.
	if (isAwaitable(elem)) return "msRefArray";
	const ecn = elemArrayCName(elem);
	const elemIsRefArray = elem.kind == TypeKind.Ref && elem.typeReturn != null && elem.typeReturn.kind == TypeKind.Array;
	const elemIsClass = elem.sym != null && elem.sym.symbolKind == SymbolKind.Class;
	if (!elemIsRefArray && (ecn == "void*" || ecn.endsWith("*") || elemIsClass || isPointerType(elem))) return "msRefArray";
	return getArrayTypeName(ecn);
}

export function isRuntimeArrayFamily(t: Readonly<Type>): boolean {
	const name = arrayCTypeName(t);
	return name == "msNumberArray" || name == "msStringArray" || name == "msUint8Array"
		|| name == "msClosureArray" || name == "msRefArray";
}

export function refArrayCellName(t: Type): string {
	return arrayCTypeName(t) + "_" + hashToBase36(opTypeKey(t)) + "RefCell";
}

// Returns the array content/payload struct name for a given array type name.
// Built-in array types use runtime-defined payload structs; custom arrays use __Content suffix.
export function getArrayContentType(arrTypeName: string): string {
	if (arrTypeName == "msNumberArray") return "msNumberPayload";
	if (arrTypeName == "msStringArray") return "msStringPayload";
	if (arrTypeName == "msRefArray") return "msRefPayload";
	if (arrTypeName == "msUint8Array") return "msUint8Payload";
	if (arrTypeName == "msClosureArray") return "msClosurePayload";
	return arrTypeName + "__Content";
}

// ===== Sized Array (Stack) =====

export function zeroInit(t: Readonly<Type | null>): string {
	return leadsWithEmptyAggregate(t, 0) ? "{}" : "{0}";
}

function leadsWithEmptyAggregate(t: Readonly<Type | null>, depth: int32): boolean {
	if (t == null || depth > 16) return false;
	if (t.kind == TypeKind.SizedArray) return t.typeValue == 0 || leadsWithEmptyAggregate(t.typeReturn, depth + 1);
	if (t.kind == TypeKind.Struct || t.kind == TypeKind.Tuple) {
		for (const field of t.typeChildren) {
			if (field != null && field.kind != TypeKind.Void) return leadsWithEmptyAggregate(field, depth + 1);
		}
		return false;
	}
	if (t.kind == TypeKind.Distinct || t.kind == TypeKind.Alias || t.kind == TypeKind.GenericInstance) {
		return leadsWithEmptyAggregate(t.typeReturn, depth + 1);
	}
	return false;
}

function sizedArrayCTypeName(t: Readonly<Type>): string {
	const elemType = t.typeReturn != null ? elemArrayCName(t.typeReturn) : "void*";
	return `msSizedArray_${mangle(elemType)}_${t.typeValue}`;
}

function genSizedArrayType(g: CGen, t: Readonly<Type>): string {
	const elemType = getTypeDesc(g, t.typeReturn);
	const size = t.typeValue;
	const key = typeKey(t);
	const name = sizedArrayCTypeName(t);

	if (typeCacheHas(g.typeCache, key)) return typeCacheGet(g.typeCache, key);
	typeCacheSet(g.typeCache, key, name);

	ensureForwardDecl(g, name);
	const b = sec(g, CSection.Types);
	addLine(b, `struct ${name} {`);
	addLine(b, `    ${elemType} data[${size == 0 ? 1 : size}];`);
	addLine(b, "};");
	addNewline(b);

	return name;
}

// ===== Span (View) =====

function genSpanType(g: CGen, t: Readonly<Type>): string {
	const elemType = getTypeDesc(g, t.typeReturn);
	const key = typeKey(t);
	const name = "msSpan_" + mangle(elemType);

	if (typeCacheHas(g.typeCache, key)) return typeCacheGet(g.typeCache, key);
	typeCacheSet(g.typeCache, key, name);
	const structKey = "span:" + name;
	if (typeCacheHas(g.typeCache, structKey)) return name;
	typeCacheSet(g.typeCache, structKey, name);

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

function genFunctionType(g: CGen, t: Readonly<Type>): string {
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
function closureBaseTypeToC(g: CGen, pt: Readonly<Type>): string {
	if (pt == null) return "void*";
	const simple = getSimpleTypeDesc(pt);
	if (simple != "") return simple;
	return getTypeDesc(g, pt);
}

function closureParamTypeToC(g: CGen, pt: Readonly<Type>): string {
	if (isOpenArrayParam(pt)) return getTypeDesc(g, skipModifier(pt)!.typeReturn) + "*, int64_t";
	const base = closureBaseTypeToC(g, pt);
	// Reference parity: ccgIntroducedPtr params are passed by pointer in C
	if (pt != null && ccgIntroducedPtr(g.target, pt)) return base + "*";
	return base;
}

function closureRetTypeToC(g: CGen, t: Readonly<Type>): string {
	if (t != null && t.kind == TypeKind.Function && t.typeReturn != null) {
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
function genClosureCast(g: CGen, t: Readonly<Type>, withEnv: boolean, nrvoType: string): string {
	let retC = "";
	if (nrvoType != "") {
		retC = "void";
	} else {
		retC = closureRetTypeToC(g, t);
	}
	let params = "";
	// NRVO: first param is the hidden result pointer
	if (nrvoType != "") {
		params = nrvoType + "*";
	}
	if (t != null && t.kind == TypeKind.Function && runtimeParamCount(t) > 0) {
		let i = 0;
		while (i < t.typeChildren.length) {
			if (!hasNoRuntimeRepr(t.typeChildren[i])) {
				if (params != "") params = params + ", ";
				params = params + closureParamTypeToC(g, t.typeChildren[i]);
			}
			i = i + 1;
		}
		if (withEnv) params = params + ", void*";
	} else if (withEnv) {
		if (params != "") params = params + ", ";
		params = params + "void*";
	} else if (params == "") {
		params = "void";
	}
	return `${retC}(*)(${params})`;
}

// Reference parity: genProcParams adds Result* param for isInvalidReturnType.
// getClosureType calls genProcParams — so closure casts ALWAYS include NRVO when return type requires it.
// Auto-detect NRVO from the function type's return type, matching the shared genProcParams path.
function autoNrvoType(g: CGen, t: Readonly<Type>): string {
	if (t != null && t.kind == TypeKind.Function && t.typeReturn != null && isNrvoReturnType(t.typeReturn, t)) {
		return getTypeDesc(g, t.typeReturn);
	}
	return "";
}

export function genClHalfCast(g: CGen, t: Readonly<Type>): string { return genClosureCast(g, t, false, autoNrvoType(g, t)); }
export function genClFullCast(g: CGen, t: Readonly<Type>): string { return genClosureCast(g, t, true, autoNrvoType(g, t)); }
export function genClHalfCastNrvo(g: CGen, t: Readonly<Type>, nrvoType: string): string { return genClosureCast(g, t, false, nrvoType); }
export function genClFullCastNrvo(g: CGen, t: Readonly<Type>, nrvoType: string): string { return genClosureCast(g, t, true, nrvoType); }

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
export function ensurePromiseAllInstance(g: CGen, arrT: Readonly<Type>): string {
	const innerType = arrT.typeReturn;
	if (innerType == null || innerType.kind == TypeKind.Void) return "";
	const innerDesc = getTypeDesc(g, innerType);
	const shape = promiseAllShape(innerType);
	if (shape == PromiseAllShape.None) return "";
	genArrayType(g, arrT);
	const arrTypeInfo = ensureRefArrayCellTypeInfo(g, arrT);
	if (shape == PromiseAllShape.Int32) {
		emitPromiseAllInstance(g, "msFuture_int32", "int32_t", "int32_t", "int32_tArray", "int32_tArray__Content", "MS_COPY_SAME", arrTypeInfo);
		return "msPromiseAllFor_msFuture_int32";
	}
	if (shape == PromiseAllShape.Int64) {
		emitPromiseAllInstance(g, "msFuture_int64", "int64_t", "int64_t", "int64_tArray", "int64_tArray__Content", "MS_COPY_SAME", arrTypeInfo);
		return "msPromiseAllFor_msFuture_int64";
	}
	const futName = "msFuture_" + mangle(innerDesc);
	const arrName = arrayCTypeName(arrT);
	const payloadName = getArrayContentType(arrName);
	const copyStmt = shape == PromiseAllShape.Integer ? "MS_COPY_SAME" : "MS_COPY_BOXED_MOVE";
	emitPromiseAllInstance(g, futName, innerDesc, innerDesc, arrName, payloadName, copyStmt, arrTypeInfo);
	return "msPromiseAllFor_" + futName;
}

// Emit an MS_PROMISE_ALL_FOR instance for element-future-type `futName` whose
// MetaScript source type is T[] (array type `arrName`, payload `payloadName`,
// storage element `dstElem`). Guarded by #ifndef — idempotent across modules.
// Pre-instantiated types (msFuture_double / msFuture_bool / msFuture_ptr in
// combinator.h, msFuture_msString in system.h) are skipped at call sites.
function emitPromiseAllInstance(g: CGen, futName: string, srcT: string, dstElem: string, arrName: string, payloadName: string, copyStmt: string, arrTypeInfo: string): void {
	const guard = "msPromiseAllFor_" + futName + "_DEFINED";
	// Emit into GlobalVars (runs after Types + SeqTypes) so the array payload's
	// full struct definition is visible to sizeof(payloadType) inside the macro
	// body — Types/SeqTypes ordering would otherwise produce incomplete-type errors.
	const b = sec(g, CSection.GlobalVars);
	addLine(b, "#ifndef " + guard);
	addLine(b, "#define " + guard);
	addLine(b, "MS_PROMISE_ALL_FOR_TI(" + srcT + ", " + futName + ", " + dstElem + ", " + arrName + ", " + payloadName + ", " + copyStmt + ", " + arrTypeInfo + ");");
	addLine(b, "#endif");
	addNewline(b);
}

// Emit the MS_DEFINE_FUTURE_THEN_BOXED instance for a boxed value type and return its
// name. The drop is the type's destructor hook.
export function ensureFutureThenBoxedInstance(g: CGen, innerType: Readonly<Type>, byRef: boolean): string {
	const innerDesc = getTypeDesc(g, innerType);
	const name = (byRef ? "msFutureThenBoxedRef_" : "msFutureThenBoxed_") + mangle(innerDesc);
	let drop = "MS_NO_DROP";
	if (hasAsgnFlag(innerType)) {
		const hook = getOpByKeyIn(g.emissionFacts.hookOps!, innerType, AttachedOp.AttachedDestructor);
		if (hook != null) {
			drop = opCName(hook);
			ensureDrcProto(g, drop, hook);
		}
	}
	const b = sec(g, CSection.GlobalVars);
	addLine(b, "#ifndef " + name + "_DEFINED");
	addLine(b, "#define " + name + "_DEFINED");
	const argType = byRef ? innerDesc + "*" : innerDesc;
	const pass = byRef ? "MS_PASS_REF" : "MS_PASS_VALUE";
	addLine(b, "MS_DEFINE_FUTURE_THEN_BOXED(" + name + ", " + innerDesc + ", " + argType + ", " + pass + ", " + drop + ")");
	addLine(b, "#endif");
	addNewline(b);
	return name;
}

export function genFutureType(g: CGen, t: Readonly<Type>): string {
	const innerType = awaitedType(t);
	const key = typeKey(t);

	// Promise<void> and Promise<never> → msFuture_void* (typedef of msFutureBase, predefined in future.h)
	if (innerType == null || innerType.kind == TypeKind.Void || innerType.kind == TypeKind.Never) {
		typeCacheSet(g.typeCache, key, "msFuture_void*");
		return "msFuture_void*";
	}

	const innerDesc = getTypeDesc(g, innerType);

	// Map to predefined typed futures (avoid re-emitting structs already in future.h).
	if (innerDesc == "double") { typeCacheSet(g.typeCache, key, "msFuture_double*"); return "msFuture_double*"; }
	if (innerDesc == "int32_t") { typeCacheSet(g.typeCache, key, "msFuture_int32*"); return "msFuture_int32*"; }
	if (innerDesc == "int64_t") { typeCacheSet(g.typeCache, key, "msFuture_int64*"); return "msFuture_int64*"; }
	if (innerDesc == "bool" || innerDesc == "MS_BOOL") { typeCacheSet(g.typeCache, key, "msFuture_bool*"); return "msFuture_bool*"; }

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

function genTupleType(g: CGen, t: Readonly<Type>): string {
	const key = typeKey(t);
	if (typeCacheHas(g.typeCache, key)) return typeCacheGet(g.typeCache, key);

	// tupleTypeName is the single source of the msTuple_<hash> name (analyzer, lifted
	// hooks and array-element refs all derive from it). A second name computed here from
	// codegen's own typeKey drifted for non-primitive elements → "unknown type name" at link.
	const name = tupleTypeName(t);
	typeCacheSet(g.typeCache, key, name);
	ensureForwardDecl(g, name);

	const fieldDescs: string[] = [];
	for (const child of t.typeChildren) fieldDescs.push(getTypeDesc(g, child));

	const b = sec(g, CSection.Types);
	addLine(b, `#ifndef ${name}_DEFINED`);
	addLine(b, `#define ${name}_DEFINED`);
	addLine(b, `struct ${name} {`);
	b.indent += 1;
	let i = 0;
	while (i < fieldDescs.length) {
		addLine(b, `${fieldDescs[i]} _${i};`);
		i += 1;
	}
	b.indent -= 1;
	addLine(b, "};");
	addLine(b, "#endif");
	addNewline(b);

	return name;
}

// ===== Tests =====

test "the pointer threshold follows the target float width" {
	const pair = createStruct("Pair", ["a", "b"], [createPrimitive(TypeKind.Float64), createPrimitive(TypeKind.Float64)], true);
	const wide: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const narrow: TargetInfo = { ptrSize: 4, floatSize: 4 };
	assert sizeOfType(wide, pair) == 16;
	assert !ccgIntroducedPtr(wide, pair);
	assert ccgIntroducedPtr(narrow, pair);
}

test "primitive keys" {
	assert typeKey(createPrimitive(TypeKind.Number)) == "float64";
	assert typeKey(createPrimitive(TypeKind.String)) == "string";
	assert typeKey(createPrimitive(TypeKind.Boolean)) == "boolean";
	assert typeKey(createPrimitive(TypeKind.Void)) == "void";
}

test "enum key" { assert typeKey(createEnum("Color", ["Red", "Green"])) == "enum:Color"; }

function declaredHere(t: Type): Type {
	t.sym = makeSymbol(t.typeName, SymbolKind.Struct, t, false);
	return t;
}

test "object key" { assert typeKey(declaredHere(createStruct("Foo", [], [], true))) == "object:Foo"; }

test "an object key refuses a declared-looking name that has no symbol" {
	let refused = "";
	try {
		typeKey(createStruct("Foo", [], [], true));
	} catch (e) {
		refused = e.message;
	}
	assert refused.contains("Foo");
}

test "two symbols of one name cannot hold one op key" {
	const t = createEnum("OpIdentityProbe", ["A"]);
	const a = makeSymbol("OpIdentityProbe_toString", SymbolKind.Function, t, false);
	const b = makeSymbol("OpIdentityProbe_toString", SymbolKind.Function, t, false);
	setOpByKey(t, AttachedOp.AttachedToString, a);
	setOpByKey(t, AttachedOp.AttachedToString, a);
	let refused = "";
	try {
		setOpByKey(t, AttachedOp.AttachedToString, b);
	} catch (e) {
		refused = e.message;
	}
	assert refused.contains("OpIdentityProbe_toString");
}

test "distinct types of one name keyed by their declaring module stay apart" {
	const a = createDistinct(createPrimitive(TypeKind.Int32));
	a.typeName = "Id";
	a.sym = makeSymbol("Id", SymbolKind.TypeAlias, a, false);
	a.sym.modulePath = "/m/a.ms";
	const b = createDistinct(createPrimitive(TypeKind.Float64));
	b.typeName = "Id";
	b.sym = makeSymbol("Id", SymbolKind.TypeAlias, b, false);
	b.sym.modulePath = "/m/b.ms";
	assert typeKey(a) != typeKey(b);
	assert typeKey(createArray(a)) != typeKey(createArray(b));
}

test "null type" { assert typeKey(null) == "null"; }

test "anonymous structs with different fields key apart" {
	const a = createStruct("", ["name"], [createPrimitive(TypeKind.String)], true);
	const b = createStruct("", ["tag"], [createPrimitive(TypeKind.String)], true);
	assert typeKey(a) != typeKey(b);
}

test "unhandled kinds key apart instead of sharing one string" {
	const a = createPrimitive(TypeKind.Never);
	const b = createPrimitive(TypeKind.Unknown);
	assert typeKey(a) != typeKey(b);
	assert typeKey(a) != "unknown";
}

test "primitives" {
	assert getSimpleTypeDesc(createPrimitive(TypeKind.Number)) == "double";
	assert getSimpleTypeDesc(createPrimitive(TypeKind.Int32)) == "int32_t";
	assert getSimpleTypeDesc(createPrimitive(TypeKind.Boolean)) == "MS_BOOL";
	assert getSimpleTypeDesc(createPrimitive(TypeKind.String)) == "msString";
	assert getSimpleTypeDesc(createPrimitive(TypeKind.Void)) == "void";
}

test "non-primitive returns empty" {
	assert getSimpleTypeDesc(createEnum("X", [])) == "";
	assert getSimpleTypeDesc(createStruct("Y", [], [], true)) == "";
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
	assert getTypeDesc(g, createPrimitive(TypeKind.Number)) == "double";
	assert getTypeDesc(g, createPrimitive(TypeKind.Int32)) == "int32_t";
	assert getTypeDesc(g, createPrimitive(TypeKind.String)) == "msString";
}

test "enum emits typedef and defines" {
	const g = createCGen(null as unknown as CheckerContext, "");
	const result = getTypeDesc(g, createEnum("Color", ["Red", "Green", "Blue"]));
	assert result == "Color";
	const types = extract(sec(g, CSection.Types));
	assert types.contains("typedef uint8_t Color");
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
	const result = getTypeDesc(g, declaredHere(createStruct("Point", propNames, propTypes, true)));
	assert result == "Point";
	const types = extract(sec(g, CSection.Types));
	assert types == "#ifndef Point_DEFINED\n#define Point_DEFINED\nstruct Point {\n  int32_t x;\n  int32_t y;\n};\n_Static_assert(sizeof(struct Point) == 8, \"struct Point layout\");\n#endif\n\n";
}

test "class (Ref<Object>) emits struct with pointer" {
	const propNames: string[] = [];
	propNames.push("name");
	const propTypes: Type[] = [];
	propTypes.push(createPrimitive(TypeKind.String));
	const g = createCGen(null as unknown as CheckerContext, "");
	const result = getTypeDesc(g, createRef(declaredHere(createStruct("Person", propNames, propTypes, true))));
	assert result == "Person*";
	const types = extract(sec(g, CSection.Types));
	assert types == "#ifndef Person_DEFINED\n#define Person_DEFINED\nstruct Person {\n  msString name;\n};\n_Static_assert(sizeof(struct Person) == 16, \"struct Person layout\");\n#endif\n\n";
}

test "array type" {
	const g = createCGen(null as unknown as CheckerContext, "");
	assert getTypeDesc(g, createArray(createPrimitive(TypeKind.Number))) == "msNumberArray";
	assert getTypeDesc(g, createArray(createPrimitive(TypeKind.String))) == "msStringArray";
}

test "forward decl emitted" {
	const g = createCGen(null as unknown as CheckerContext, "");
	getTypeDesc(g, declaredHere(createStruct("Widget", [], [], true)));
	const fwd = extract(sec(g, CSection.ForwardDecls));
	assert fwd == "#ifndef Widget_DEFINED\ntypedef struct Widget Widget;\n#endif\n";
}

test "cached second call" {
	const g = createCGen(null as unknown as CheckerContext, "");
	const t = createEnum("Dir", ["Up", "Down"]);
	const r1 = getTypeDesc(g, t);
	const r2 = getTypeDesc(g, t);
	assert r1 == r2;
	assert r1 == "Dir";
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
	assert name1 != "empty_";
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

	assert anonTypeName(anon1) != anonTypeName(anon2);
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

	assert anonTypeName(anon1) == anonTypeName(anon2);
}

test "anonymous type name ignores a generic field's lazily instantiated body" {
	const gi = createGenericInstance(createStruct("Box", ["item"], [createPrimitive(TypeKind.Int32)], true), [createPrimitive(TypeKind.Int32)]);
	const anon = createStruct("", ["v", "t"], [gi, createPrimitive(TypeKind.Uint8)], true);
	const before = anonTypeName(anon);
	gi.typeReturn = createStruct("Box", ["item"], [createPrimitive(TypeKind.Int32)], true);
	assert anonTypeName(anon) == before;
}

test "anonymous type name tells generic arguments apart" {
	const base = createStruct("Box", ["item"], [createPrimitive(TypeKind.Int32)], true);
	const ofInt = createStruct("", ["v"], [createGenericInstance(base, [createPrimitive(TypeKind.Int32)])], true);
	const ofString = createStruct("", ["v"], [createGenericInstance(base, [createPrimitive(TypeKind.String)])], true);
	assert anonTypeName(ofInt) != anonTypeName(ofString);
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

	assert typeKey(anon1) != typeKey(anon2);
}

test "tuple type key" {
	const t = createTuple([createPrimitive(TypeKind.Number), createPrimitive(TypeKind.String)]);
	assert typeKey(t) == "tuple:float64,string";
}

test "tuple type desc emits struct" {
	const g = createCGen(null as unknown as CheckerContext, "");
	const t = createTuple([createPrimitive(TypeKind.Number), createPrimitive(TypeKind.String)]);
	const name = getTypeDesc(g, t);
	const types = extract(sec(g, CSection.Types));
	assert name != "void*";
	assert name.length > 8; // "msTuple_" + hash
	assert types.length > 0;
}

test "a tuple's element types are defined before the tuple struct opens" {
	const g = createCGen(null as unknown as CheckerContext, "");
	const face = createEnum("Face", ["None", "Back"]);
	face.sym = makeSymbol("Face", SymbolKind.Enum, face, false);
	const t = createTuple([createTuple([face, createPrimitive(TypeKind.Int32)]), createPrimitive(TypeKind.Int32)]);
	const outer = getTypeDesc(g, t);
	const inner = getTypeDesc(g, t.typeChildren[0]);
	const types = extract(sec(g, CSection.Types));
	const enumAt = types.indexOf("typedef uint8_t Face");
	const innerAt = types.indexOf(`struct ${inner} {`);
	const outerAt = types.indexOf(`struct ${outer} {`);
	assert enumAt >= 0 && enumAt < innerAt;
	assert types.indexOf("};", innerAt) < outerAt;
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
	assert result != "empty_";
	// Should start with msAnon_
	assert result.length > 7;
}

test "a lifted op is one symbol per op and canonical type, whichever spelling asks" {
	resetHookSyms();
	const body = declaredHere(createStruct("OneKeyed", ["v"], [createPrimitive(TypeKind.String)], false));
	const proto = liftedOp(body, AttachedOp.AttachedEq, "OneKeyedEq", null);
	const again = liftedOp(declaredHere(createStruct("OneKeyed", ["v"], [createPrimitive(TypeKind.String)], false)), AttachedOp.AttachedEq, "OneKeyedEq", createFunction([body, body], ["x", "y"], createPrimitive(TypeKind.Boolean)));
	assert again == proto;
	assert proto.symbolType != null;
	assert getOpByKey(body, AttachedOp.AttachedDestructor) == null;
	assert isTypeBoundOp(proto);
}

test "a lifted op asked under another name for the same type is refused" {
	resetHookSyms();
	const t = declaredHere(createStruct("NamedOnce", ["v"], [createPrimitive(TypeKind.String)], false));
	liftedOp(t, AttachedOp.AttachedDestructor, "NamedOnceDestroy", null);
	let refused = "";
	try {
		liftedOp(t, AttachedOp.AttachedDestructor, "OtherDestroy", null);
	} catch (e) {
		refused = e.message;
	}
	assert refused.contains("NamedOnceDestroy");
}

test "a sealed op table serves known ops and refuses a new one" {
	resetHookSyms();
	const known = liftedOp(declaredHere(createStruct("SealKnown", [], [], false)), AttachedOp.AttachedDestructor, "SealKnownDestroy", null);
	sealHookSyms(true);
	const again = liftedOp(declaredHere(createStruct("SealKnown", [], [], false)), AttachedOp.AttachedDestructor, "SealKnownDestroy", null);
	let refused = "";
	try {
		liftedOp(declaredHere(createStruct("SealNew", [], [], false)), AttachedOp.AttachedDestructor, "SealNewDestroy", null);
	} catch (e) {
		refused = e.message;
	}
	sealHookSyms(false);
	assert again == known;
	assert refused.contains("SealNew");
}

test "a TypeInfo demanded without a reachability edge is an error naming the type" {
	const g = createCGen(null as unknown as CheckerContext, "consumer.ms");
	const t = declaredHere(createStruct("Undemanded", ["v"], [createPrimitive(TypeKind.String)], true));
	typeInfoRef(g, createRef(t));
	assert g.errors.length == 1;
	assert g.errors[0].message.contains("without a reachability edge");
}

test "a TypeInfo requested for a type that has none is an error" {
	const g = createCGen(null as unknown as CheckerContext, "consumer.ms");
	typeInfoRef(g, createPrimitive(TypeKind.String));
	assert g.errors.length == 1;
}

test "a generated $ type is spelled by its module-owned symbol in its hook base name" {
	const owned = declaredHere(createStruct("$Env_probe_1", ["v"], [createPrimitive(TypeKind.String)], false));
	owned.sym.modulePath = "/m/owner.ms";
	const want = mangledTypeName(owned.sym, "$Env_probe_1");
	assert hookBaseCName("$Env_probe_1", owned, null) == want;
	const ownerless = declaredHere(createStruct("$Env_probe_2", ["v"], [createPrimitive(TypeKind.String)], false));
	assert hookBaseCName("$Env_probe_2", ownerless, null) == "$Env_probe_2";
}

test "a hook base name comes from the type's own symbol, not from a table lookup by name" {
	const cc = createContext();
	const declared = declaredHere(createStruct("HookOwner", ["v"], [createPrimitive(TypeKind.String)], false));
	declared.sym.modulePath = "/m/owner.ms";
	assert hookBaseCName("HookOwner", declared, cc) == mangledTypeName(declared.sym, "HookOwner");
	let refused = "";
	try {
		hookBaseCName("Stray", createStruct("Stray", ["v"], [createPrimitive(TypeKind.String)], false), cc);
	} catch (e) {
		refused = e.message;
	}
	assert refused.contains("Stray");
}

test "enum typedef follows the largest ordinal and a negative member" {
	const g = createCGen(null as unknown as CheckerContext, "");
	getTypeDesc(g, createEnum("Wide", ["Low", "High"], [0, 300]));
	getTypeDesc(g, createEnum("Signed", ["Below", "Zero"], [-1, 0]));
	const types = extract(sec(g, CSection.Types));
	assert types.contains("typedef uint16_t Wide");
	assert types.contains("typedef int32_t Signed");
}
