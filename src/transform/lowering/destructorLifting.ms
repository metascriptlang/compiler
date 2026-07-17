// Destructor Lifting — generate per-type lifecycle hook function bodies
//
// Standard reference implementation for lifecycle hook generation
// Routing table: TypeKind → type family helper
//   fillStrOp()            — string lifecycle
//   fillSeqOp()            — sequence/array lifecycle
//   atomicRefOp()          — ref/ptr lifecycle
//   closureOp()            — closure lifecycle
//   fillBodyObjT()         — value-type object lifecycle
//   fillBodyTup()          — tuple field iteration
//   considerUserDefinedOp  — user hook dispatch (onDestroy/onCopy/etc.)
//   cyclicType()           — cycle detection for ORC
//   checkSelfAssignment()  — early return on dest === src
//
// Generates up to 6 hooks per type + TypeInfo:
//   =destroy   TypeName_destroy(self)            — cleanup RC fields
//   =copy      TypeName_copy(dest, src)          — deep copy (assign + incref)
//   =sink      TypeName_sink(dest, src)          — move (transfer ownership)
//   =wasMoved  TypeName_wasMoved(self)           — zero RC handles after move
//   =dup       TypeName_dup(src): TypeName       — clone (init + copy, return)
//   =trace     TypeName_trace(self, callback)    — ORC cycle tracing (cyclic types only)
//   TypeInfo   TypeName_typeInfo                  — msTypeInfo for ORC runtime

import { Node, NodeKind, DeclKind, ProgramData, FunctionDeclData, SourceLocation, makeLoc, InterfaceDeclData, ClassDeclData, ExportDeclData, VariableDeclData, TypeAliasDeclData, IdentifierData, MemberExprData, ArrayAccessData, HiddenDerefData, BlockStmtData, WhileStmtData, DoWhileStmtData, IfStmtData, ForStmtData, ForOfStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, Type, TypeKind, TypeFlag, AttachedOp, Symbol, SymbolKind } from "../../ast/node";
import { TransformContext, NameSet, nameSetContains, nameSetAdd, createNameSet, createTransformContextWithChecker } from "../context";
import { makeIdent, makeIdentResolved, makeBlock, makeExprStmt, makeCall, makeMember, makeAssign, makeFnDecl, makeVarDecl, makeReturn, makeIf, makeBinary, makeUnary, makeNull, makeString, makeBool, makeNumber, makeObjectLiteral, makeHiddenAddr, makeHiddenDeref, makeWhile, makeArrayAccess } from "../util";
import { isPrimitiveKind, isNumeric, isPrimitiveUnionMember, setAttachedOp, unwrapRef, unwrapRefNullUnion, createArray, createPtr, createVar, createPrimitive, createRef, stringType, isStringLike, createStruct, createUnion, isStructType, isAwaitable, isAtomicRef, instantiateGenericBody, peelToStruct, tupleTypeName } from "../../checker/types";
import { anonTypeName, isAnonTypeName, recordGenDestroyHook, resetGenDestroyHooks, arrayCTypeName } from "../../codegen/c/types";
import { getGenericDecl } from "../../parser/context";
import { mangleMonoName } from "../../monomorphize/registry";
import { walkNode } from "../walker";
import { lookupSymbol, makeSymbol, setFlag, SymbolFlag } from "../../checker/symbol";
import { CheckerContext } from "../../checker/context";
import { checkProgram } from "../../checker/checkPass";
import { parseInput } from "../testUtil";
import { lowerOperators } from "./operatorLower";

// ===== Global Hook Ownership Registry =====
// Reference parity: attachedOps[] is global — hooks generated once per canonical type.
// First module to need a type's hooks generates the bodies; other modules skip.
// Consuming modules get extern forward declarations via ensureDrcProto in codegen.
//
// TypeInfo ownership is tracked SEPARATELY from hook ownership because the
// emission triggers differ: hooks can be emitted by any module that references
// the type (DRC correctness only requires one definition); TypeInfo must be
// emitted by the DEFINING module to match codegen's cross-module extern
// conventions. Without this split, a consumer module that claims hooks first
// would also block the defining module from emitting the TypeInfo global
// (observed as `undefined symbol: _SymbolTypeInfo` link errors).
let _globalHookOwners: NameSet = createNameSet();
let _globalTypeInfoOwners: NameSet = createNameSet();

export function setGlobalHookOwners(owners: NameSet): void {
	_globalHookOwners = owners;
	_globalTypeInfoOwners = createNameSet();
	resetGenDestroyHooks();
}

function isGloballyOwned(typeName: string): boolean {
	return nameSetContains(_globalHookOwners, typeName);
}

function claimGlobal(typeName: string): void {
	nameSetAdd(_globalHookOwners, typeName);
}

function isTypeInfoGloballyOwned(typeName: string): boolean {
	return nameSetContains(_globalTypeInfoOwners, typeName);
}

function claimGlobalTypeInfo(typeName: string): void {
	nameSetAdd(_globalTypeInfoOwners, typeName);
}

// ===== Lift Context (reference TLiftCtx) =====

interface SeqElemEntry {
	name: string;
	elemType: Type;
}

class LiftCtx {
	checkerCtx: CheckerContext;  // borrowed — do NOT store full TransformContext (causes double-free)
	tempCounter: number;
	generated: NameSet;    // fully generated types (dedup)
	generating: NameSet;   // currently generating (cycle guard)
	collector: Node[];
	cyclicCache: NameSet;     // types confirmed cyclic
	nonCyclicCache: NameSet;  // types confirmed non-cyclic
	neededSeqHooks: NameSet;  // array hook families needed (e.g., "msStringArray", "msRefArray")
	seqElemTypes: SeqElemEntry[];  // per-type array elem types (for generating per-type hooks)
}

// NodeBuf: heap-allocated buffer for accumulating AST nodes.
// Node[] arrays are passed by value in C (msRefArray = 16-byte struct).
// When helper functions push to a `buf: Node[]` parameter, the push modifies
// a LOCAL COPY — callers never see the new items. NodeBuf is a class (pointer),
// so `nb.items.push(x)` modifies the heap object through the pointer.
class NodeBuf {
	items: Node[];
}

function newBuf(): NodeBuf {
	return { items: [] };
}

// Reference parity: only types that completed hook generation have hooks.
// Check both local (this module) and global (any module) registries.
// Struct/Union fields can't form direct cycles (infinite size), so cycles always go through
// Ref/Ptr which has its own handler in fillBody. Safe to check only `generated`.
function namedTypeHasHooks(typeName: string, lctx: LiftCtx): boolean {
	return nameSetContains(lctx.generated, typeName) || isGloballyOwned(typeName);
}

// Unwrap a GenericInstance to (mangledName, concreteStructBody) for hook generation.
// Returns empty mangledName when body not yet instantiated — callers fall through.
//
// Skip boundary: awaitable (Promise) has bespoke codegen — `msFuture_<T>` emitted
// by runtime msFuture ops, not `Promise__<args>`. Emitting mangleMonoName-based
// hooks would reference a struct type codegen never produces → compile error.
// Result was historically here too, but post-migration it flows through the
// standard Union path (boolean-discriminated tagged union).
// Iterator (`TypeKind.Struct`) is already filtered by the GenericInstance kind check.
function unwrapGenericInstance(gi: Type): { mangledName: string, body: Type } {
	if (gi === null || gi.kind !== TypeKind.GenericInstance) {
		return { mangledName: "", body: null as unknown as Type };
	}
	if (isAwaitable(gi)) {
		return { mangledName: "", body: null as unknown as Type };
	}
	// Lazy-instantiate body when encountering nested generics. Outer instantiation
	// (instantiateGenericBody at checker types.ms:787) substitutes K/V → concrete types
	// in the containing struct's fields, but doesn't recursively populate `typeReturn`
	// on inner GIs. Codegen does the same lazy pattern at types.ms:601 via getGenericDecl.
	if (gi.typeReturn === null) {
		const decl = getGenericDecl(gi.typeName);
		if (decl !== "") instantiateGenericBody(gi, decl);
	}
	if (gi.typeReturn === null) {
		return { mangledName: "", body: null as unknown as Type };
	}
	const mangledName = mangleMonoName(gi.typeName, gi.typeChildren);
	const src = gi.typeReturn;
	// Preserve src kind: Union bodies (match-type / TS-style DU) must NOT be
	// wrapped as Struct — `generateHook` dispatches on `objType.kind` to route
	// Unions through `generateUnionArms` (per-variant tag dispatch). Coercing
	// to Struct here makes the hook walk `typeNames` (discriminator metadata)
	// as if they were field names, emitting bogus `dest.ok = src.ok` accesses.
	let body: Type;
	if (src.kind === TypeKind.Union) {
		body = createUnion(src.typeChildren);
		body.typeName = mangledName;
		body.typeNames = src.typeNames;
		body.typeExtra = src.typeExtra;
		body.typeFlags = src.typeFlags;
	} else {
		body = createStruct(mangledName, src.typeNames, src.typeChildren, isStructType(src));
	}
	return { mangledName, body };
}

// ===== Cycle Detection (reference cyclicType) =====
// Determines if a type can form reference cycles (needed for =trace hook).

function isCyclicType(t: Type, lctx: LiftCtx, visited: NameSet): boolean {
	if (t === null) return false;
	if (isPrimitiveKind(t.kind) || t.kind === TypeKind.String) return false;

	match (t.kind) {
		TypeKind.Ref | TypeKind.Function => { return true; },
		TypeKind.Ptr => { return false; },
		TypeKind.Array | TypeKind.Distinct => {
			if (t.typeReturn === null) return false;
			return isCyclicType(t.typeReturn, lctx, visited);
		},
		TypeKind.Struct => {
			if (t.typeName !== "") {
				if (nameSetContains(lctx.cyclicCache, t.typeName)) return true;
				if (nameSetContains(lctx.nonCyclicCache, t.typeName)) return false;
				if (nameSetContains(visited, t.typeName)) return false;
				nameSetAdd(visited, t.typeName);
			}
			for (const child of t.typeChildren) {
				if (isCyclicType(child, lctx, visited)) {
					if (t.typeName !== "") nameSetAdd(lctx.cyclicCache, t.typeName);
					return true;
				}
			}
			if (t.typeName !== "") nameSetAdd(lctx.nonCyclicCache, t.typeName);
			return false;
		},
		TypeKind.Union => {
			if (t.typeName !== "") {
				if (nameSetContains(lctx.cyclicCache, t.typeName)) return true;
				if (nameSetContains(lctx.nonCyclicCache, t.typeName)) return false;
				if (nameSetContains(visited, t.typeName)) return false;
				nameSetAdd(visited, t.typeName);
			}
			for (const variant of t.typeChildren) {
				if (variant !== null && variant.typeChildren !== null) {
					for (const child of variant.typeChildren) {
						if (isCyclicType(child, lctx, visited)) {
							if (t.typeName !== "") nameSetAdd(lctx.cyclicCache, t.typeName);
							return true;
						}
					}
				}
			}
			if (t.typeName !== "") nameSetAdd(lctx.nonCyclicCache, t.typeName);
			return false;
		},
		TypeKind.Tuple => {
			for (const child of t.typeChildren) {
				if (isCyclicType(child, lctx, visited)) return true;
			}
			return false;
		},
		_ => { return false; },
	};
	return false;
}

// ===== Hook Suffix (shared by generateHook + base class dispatch) =====

function hookSuffix(hook: string): string {
	return match (hook) {
		"destroy" => "Destroy",
		"copy" => "Copy",
		"sink" => "Sink",
		"trace" => "Trace",
		_ => "WasMoved",
	};
}

// Reference parity (sfGeneratedOp): mark a generated function node so DRC skips injection.
// Reference sets sfGeneratedOp on the symbol in produceSym/symPrototype.
function markGeneratedOp(fnNode: Node, name: string): void {
	const sym = makeSymbol(name, SymbolKind.Function, fnNode.nodeType, false);
	setFlag(sym, SymbolFlag.GeneratedOp);
	fnNode.resolvedSym = sym;
}

// Set hook function param/return types to concrete Types.
// Reference parity: symPrototype sets dest.typ/src.typ directly, never string names.
// We set each param individually because makeFnDecl can't resolve named struct types.
function setHookParamType(fnNode: Node, index: number, t: Type): void {
	if (fnNode.nodeType !== null && fnNode.nodeType.typeChildren !== null
		&& index < fnNode.nodeType.typeChildren.length) {
		fnNode.nodeType.typeChildren[index] = t;
	}
}

function setHookReturnType(fnNode: Node, t: Type): void {
	if (fnNode.nodeType !== null) {
		fnNode.nodeType.typeReturn = t;
	}
}

// ===== Reference defaultOp =====
// Primitives: copy/sink => assign, destroy/wasMoved => no-op

function defaultOp(hook: string, x: Node, y: Node, buf: NodeBuf, loc: SourceLocation): void {
	if (hook === "copy" || hook === "sink") {
		buf.items.push(makeExprStmt(makeAssign(x, y, loc), loc));
	}
}

// ===== Node Path Cloning (reference parity: field access creates fresh trees) =====
// Deep-copies MemberExpr/Identifier chains so markPointerParams won't double-wrap shared refs.

function clonePath(node: Node, loc: SourceLocation): Node {
	if (node === null) return node;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		const r = makeIdent(d.name, loc);
		r.nodeType = node.nodeType;
		return r;
	}
	if (node.kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		const r = makeMember(clonePath(d.object, loc), d.property, loc);
		r.nodeType = node.nodeType;
		return r;
	}
	// reference parity: array access always creates fresh nodes
	if (node.kind === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		const r = makeArrayAccess(clonePath(d.array, loc), clonePath(d.index, loc), loc);
		r.nodeType = node.nodeType;
		return r;
	}
	if (node.kind === NodeKind.HiddenDeref) {
		const d = node.data as HiddenDerefData;
		const r = makeHiddenDeref(clonePath(d.expr, loc), loc);
		r.nodeType = node.nodeType;
		return r;
	}
	return node;
}

// ===== Emit helpers =====

// Emit runtime call — unary (destroy/wasMoved) or binary (copy/sink)
function genCall(name: string, hook: string, x: Node, y: Node, buf: NodeBuf, loc: SourceLocation): void {
	if (hook === "destroy" || hook === "wasMoved") {
		buf.items.push(makeExprStmt(makeCall(makeIdent(name, loc), [x], loc), loc));
	} else {
		buf.items.push(makeExprStmt(makeCall(makeIdent(name, loc), [x, y], loc), loc));
	}
}

// Copy-ref pattern: for 2-arg copy functions (msStringCopy), emit =copy(&dest, src) directly.
// For unary incref (msIncref, msClosureCopy), emit decref-old + assign + incref-new.
function genCopyRef(increfFn: string, x: Node, y: Node, fieldName: string, buf: NodeBuf, loc: SourceLocation): void {
	// Reference parity: msStringCopy is 2-arg =copy(&dest, src) — handles destroy-old internally
	if (increfFn === "msStringCopy") {
		buf.items.push(makeExprStmt(makeCall(makeIdent("msStringCopy", loc),
			[makeHiddenAddr(clonePath(x, loc), loc), clonePath(y, loc)], loc), loc));
		return;
	}
	// Cyclic refs: Nim attachedAsgn isCyclic order (liftdestructors.nim:768-775) —
	// incref new, assign, decref old last, so a collect triggered by the old value's
	// destroy never traces a dest still pointing at the dying object.
	if (increfFn === "msIncrefCyclic") {
		genCall("msRefCopyCyclic", "copy", clonePath(x, loc), clonePath(y, loc), buf, loc);
		return;
	}
	// Unary incref types: decref old, assign, incref new
	const decrefFn = increfFn === "msIncref" ? "msDecref"
		: increfFn === "msAtomicIncref" ? "msAtomicDecref"
		: increfFn === "msClosureCopy" ? "msClosureDestroy"
		: increfFn === "msClosureIncref" ? "msClosureDecref"
		: increfFn === "msMapIncref" ? "msMapDecref"
		: "";
	if (decrefFn !== "") {
		buf.items.push(makeExprStmt(makeCall(makeIdent(decrefFn, loc), [clonePath(x, loc)], loc), loc));
	}
	buf.items.push(makeExprStmt(makeAssign(clonePath(x, loc), clonePath(y, loc), loc), loc));
	buf.items.push(makeExprStmt(makeCall(makeIdent(increfFn, loc), [clonePath(x, loc)], loc), loc));
}

// Inline sink: destroy old value + raw assign (eliminates per-field function call)
function genInlineSink(destroyFn: string, xf: Node, yf: Node, buf: NodeBuf, loc: SourceLocation): void {
	genCall(destroyFn, "destroy", xf, yf, buf, loc);
	// Clone xf for assign to avoid AST sharing (markPointerParams mutates in-place)
	buf.items.push(makeExprStmt(makeAssign(clonePath(xf, loc), yf, loc), loc));
}

// ===== Type Family Helpers (Modular pattern) =====
// Each helper owns all runtime names for its type family.

// --- Standard string hook generator ---
function stringOp(hook: string, xf: Node, yf: Node, fieldName: string, buf: NodeBuf, loc: SourceLocation): void {
	match (hook) {
		"destroy" => { genCall("msStringDecref", hook, xf, yf, buf, loc); },
		"copy" => { genCopyRef("msStringCopy", xf, yf, fieldName, buf, loc); },
		"sink" => { genInlineSink("msStringDecref", xf, yf, buf, loc); },
		"wasMoved" => { genCall("msStringWasMoved", hook, xf, yf, buf, loc); },
		_ => {},
	};
}

// --- Inline element loop (reference parity: unrolled loops for elements) ---
// Generates: var $i = 0; while ($i < arr.length) { fillBody(elem, arr[$i], ...); $i = $i + 1; }
function genArrayLoop(hook: string, elemType: Type, xf: Node, yf: Node, lctx: LiftCtx, buf: NodeBuf, loc: SourceLocation): void {
	const ctr = lctx.tempCounter;
	lctx.tempCounter = ctr + 1;
	const counterName = "$i_" + ctr.toString();
	buf.items.push(makeVarDecl(counterName, makeNumber(0, loc), DeclKind.Let, loc));

	// reference parity: set nodeType on result.
	// Set nodeType on cloned array expressions so nativeLower can rewrite arr[i] → msXxxArrayAccess(arr, i).
	const arrType = xf.nodeType;
	const xClone = clonePath(xf, loc);
	if (xClone.nodeType === null && arrType !== null) { xClone.nodeType = arrType; }
	const lenAccess = makeMember(clonePath(xf, loc), "length", loc);
	const cond = makeBinary(makeIdent(counterName, loc), "<", lenAccess, loc);

	const xi = makeArrayAccess(xClone, makeIdent(counterName, loc), loc);
	const bodyBuf = newBuf();
	const visited: NameSet = createNameSet();

	if (hook === "trace") {
		// Reference: trace passes raw callback (y), not y[i]
		fillBody(hook, xi, yf, "", elemType, lctx, bodyBuf, visited, loc);
	} else if (hook === "copy") {
		const yClone = clonePath(yf, loc);
		if (yClone.nodeType === null && yf.nodeType !== null) { yClone.nodeType = yf.nodeType; }
		const yi = makeArrayAccess(yClone, makeIdent(counterName, loc), loc);
		fillBody(hook, xi, yi, "", elemType, lctx, bodyBuf, visited, loc);
	} else if (hook === "destroy") {
		fillBody(hook, xi, xi, "", elemType, lctx, bodyBuf, visited, loc);
	}

	// $i = $i + 1
	bodyBuf.items.push(makeExprStmt(makeAssign(
		makeIdent(counterName, loc),
		makeBinary(makeIdent(counterName, loc), "+", makeNumber(1, loc), loc),
		loc
	), loc));

	buf.items.push(makeWhile(cond, makeBlock(bodyBuf.items, loc), loc));
}

// Register a sequence's element type for per-type walker generation. The walker name is the
// array's C type name from `arrayCTypeName` — the SAME single source codegen (genArrayType)
// uses — so the transform-generated walker and the codegen box-site reference can never
// drift, for every element kind (struct/tuple/enum/generic/nested/…). Built-in families
// (msStringArray/msRefArray/…) are runtime/fixed-block provided; only per-type names get a
// seqElemTypes entry. Shared by `arrayOp` (call-site element use) and `scanTypeForArrays`.
function registerSeqElement(elem: Type, lctx: LiftCtx): void {
	if (elem.kind === TypeKind.Distinct && elem.typeReturn !== null) {
		// distinct shares its base layout → reuse the base type's per-type walker
		registerSeqElement(elem.typeReturn, lctx);
		return;
	}
	const seqName = arrayCTypeName(createArray(elem));
	nameSetAdd(lctx.neededSeqHooks, seqName);
	if (seqName !== "msStringArray" && seqName !== "msRefArray" && seqName !== "msNumberArray"
		&& seqName !== "msUint8Array" && seqName !== "msClosureArray") {
		lctx.seqElemTypes.push({ name: seqName, elemType: elem });
	}
	// Nested array element may itself need a per-type inner hook (e.g. Vec<Cell>[] → CellArray).
	if (elem.kind === TypeKind.Array && elem.typeReturn !== null && !isPrimitiveKind(elem.typeReturn.kind)) {
		registerSeqElement(elem.typeReturn, lctx);
	}
}

// --- Standard sequence/array hook generator (reference parity: reference sequence op) ---
// Primitive elements: runtime macros (no per-element cleanup).
// Non-primitive elements: inline loops via genArrayLoop (reference loop pattern).
function arrayOp(hook: string, elem: Type, xf: Node, yf: Node, lctx: LiftCtx, buf: NodeBuf, loc: SourceLocation): void {
	// Actor-handle elements are DRC-exempt (classify.ms classifyArray) — free the array
	// storage but never per-element decref, else the shared actors double-free.
	const isActorElem = elem !== null && (elem.kind === TypeKind.Ref || elem.kind === TypeKind.Ptr)
		&& elem.sym !== null && elem.sym.symbolKind === SymbolKind.Actor;
	const needsElemLoop = elem !== null && !isPrimitiveKind(elem.kind) && !isActorElem;
	// Unwrap GenericInstance element so it enters the Struct branch below.
	// Mirrors codegen (types.ms:582-620): monomorphized struct is addressable by its
	// mangled typeName (e.g., `OrderedMapEntry__int32_ref_Symbol`).
	let elemResolved = elem;
	if (needsElemLoop && elem !== null && elem.kind === TypeKind.GenericInstance) {
		const unwrapped = unwrapGenericInstance(elem);
		if (unwrapped.mangledName !== "") elemResolved = unwrapped.body;
	}
	if (needsElemLoop && elemResolved !== null) {
		registerSeqElement(elemResolved, lctx);
	}
	match (hook) {
		"destroy" => {
			if (needsElemLoop) { genArrayLoop("destroy", elem, xf, yf, lctx, buf, loc); }
			genCall("msArrayDestroy", hook, xf, yf, buf, loc);
		},
		"copy" => {
			if (needsElemLoop && elem !== null && elem.kind === TypeKind.String) {
				// String arrays: use bulk msArrayStringCopy (allocates new payload, copies + increfs each element).
				// The per-element loop generates msStringCopy(&arr[i], src[i]) which writes to a
				// C temporary instead of the array slot (msArrayAccess returns by value).
				genCall("msArrayStringCopy", hook, xf, yf, buf, loc);
			} else if (needsElemLoop) {
				genCall("msArraySetLen", hook, xf, yf, buf, loc);
				genArrayLoop("copy", elem, xf, yf, lctx, buf, loc);
			} else {
				genCall("msArrayCopy", hook, xf, yf, buf, loc);
			}
		},
		"sink" => {
			// reference parity: if (dest.p != src.p) { destroy(dest) }; dest = src
			const guardCond = makeBinary(
				makeMember(clonePath(xf, loc), "p", loc),
				"!==",
				makeMember(clonePath(yf, loc), "p", loc),
				loc
			);
			const destroyBuf = newBuf();
			genCall("msArrayDestroy", "destroy", clonePath(xf, loc), yf, destroyBuf, loc);
			buf.items.push(makeIf(guardCond, makeBlock(destroyBuf.items, loc), null as unknown as Node, loc));
			buf.items.push(makeExprStmt(makeAssign(clonePath(xf, loc), clonePath(yf, loc), loc), loc));
		},
		"wasMoved" => { genCall("msArrayWasMoved", hook, xf, yf, buf, loc); },
		"trace" => {
			// Reference parity: only trace array elements if element type can form cycles
			if (needsElemLoop && elem !== null) {
				const av: NameSet = createNameSet();
				if (isCyclicType(elem, lctx, av)) {
					genArrayLoop("trace", elem, xf, yf, lctx, buf, loc);
				}
			}
		},
		_ => {},
	};
}

// --- Standard atomic reference hook generator ---
// isCyclic: true for types that can form reference cycles (reference parity: atomicRefOp)
// Cyclic types use msDecrefCyclic/msIncrefCyclic (ORC-aware when MSGC_ORC defined)
function refOp(hook: string, xf: Node, yf: Node, fieldName: string, isCyclic: boolean, atomic: boolean, buf: NodeBuf, loc: SourceLocation): void {
	const decrefFn = atomic ? "msAtomicDecref" : (isCyclic ? "msDecrefCyclic" : "msDecref");
	const increfFn = atomic ? "msAtomicIncref" : (isCyclic ? "msIncrefCyclic" : "msIncref");
	match (hook) {
		"destroy" => { genCall(decrefFn, hook, xf, yf, buf, loc); },
		"copy" => { genCopyRef(increfFn, xf, yf, fieldName, buf, loc); },
		"sink" => {
			// =sink owns the old value: decref dest before taking src (guard self-assign),
			// mirroring stringOp/arrayOp sinks. The prior raw assign leaked the old ref of
			// every value-type Ref field on each reassignment-sink. decref is null-safe.
			const guardCond = makeBinary(clonePath(xf, loc), "!==", clonePath(yf, loc), loc);
			const destroyBuf = newBuf();
			genCall(decrefFn, "destroy", clonePath(xf, loc), yf, destroyBuf, loc);
			buf.items.push(makeIf(guardCond, makeBlock(destroyBuf.items, loc), null as unknown as Node, loc));
			buf.items.push(makeExprStmt(makeAssign(clonePath(xf, loc), clonePath(yf, loc), loc), loc));
		},
		"wasMoved" => { genCall("msPtrWasMoved", hook, xf, yf, buf, loc); },
		"trace" => {
			// Arc<T> is acyclic by construction — its atomic rc is the sole owner accountant,
			// so it must never be traced into the cycle collector (a non-atomic flag mutation
			// there would race the atomic count). Pass &field for plain Refs only.
			if (!atomic) {
				buf.items.push(makeExprStmt(makeCall(makeIdent("msOrcTraceRef", loc), [makeHiddenAddr(xf, loc), yf], loc), loc));
			}
		},
		_ => {},
	};
}

// --- Standard value-type object hook generator ---
// Reference parity: Named-type hooks take pointer params (ccgIntroducedPtr).
// Wrap field accesses in HiddenAddr so codegen emits &(self.field).
function namedObjOp(hook: string, typeName: string, xf: Node, yf: Node, buf: NodeBuf, loc: SourceLocation): void {
	if (hook === "sink") {
		// Inline sink: destroy(&xf) + assign(xf = yf)
		buf.items.push(makeExprStmt(makeCall(makeIdent(typeName + "Destroy", loc), [makeHiddenAddr(xf, loc)], loc), loc));
		buf.items.push(makeExprStmt(makeAssign(xf, yf, loc), loc));
		return;
	}
	const name = typeName + hookSuffix(hook);
	// Named-type hooks expect pointers — wrap in HiddenAddr
	const ax = makeHiddenAddr(xf, loc);
	if (hook === "destroy" || hook === "wasMoved") {
		buf.items.push(makeExprStmt(makeCall(makeIdent(name, loc), [ax], loc), loc));
	} else if (hook === "trace") {
		buf.items.push(makeExprStmt(makeCall(makeIdent(name, loc), [ax, yf], loc), loc));
	} else {
		const ay = makeHiddenAddr(yf, loc);
		buf.items.push(makeExprStmt(makeCall(makeIdent(name, loc), [ax, ay], loc), loc));
	}
}

// --- Parameterized runtime op (shared by closure, map) ---
function runtimeOp(prefix: string, destroyName: string, copySuffix: string, wasMovedSuffix: string, traceSuffix: string, hasTrace: boolean, hook: string, xf: Node, yf: Node, buf: NodeBuf, loc: SourceLocation): void {
	match (hook) {
		"destroy" => { genCall(destroyName, hook, xf, yf, buf, loc); },
		"copy" => { genCall(prefix + copySuffix, hook, xf, yf, buf, loc); },
		"sink" => { genInlineSink(destroyName, xf, yf, buf, loc); },
		"wasMoved" => { genCall(prefix + wasMovedSuffix, hook, xf, yf, buf, loc); },
		"trace" => { if (hasTrace) genCall(prefix + traceSuffix, hook, xf, yf, buf, loc); },
		_ => {},
	};
}

// ===== fillBody — pure routing table (Standard pattern) =====
// Routes TypeKind to type family helper. No inline hook logic.

function fillBody(hook: string, x: Node, y: Node, fieldName: string, fieldType: Type, lctx: LiftCtx, buf: NodeBuf, visited: NameSet, loc: SourceLocation): void {
	if (fieldType === null) return;
	// Skip void-typed fields (e.g. `Result<void, E>` variant has `void value`)
	// — typedef emit drops them too, so generating copy/destroy for a missing
	// field would produce invalid C (`(*dest).v0.value` on a void slot).
	if (fieldType.kind === TypeKind.Void) return;
	let xf = fieldName !== ""
		? makeMember(x, fieldName, loc)
		: x;
	if (fieldName !== "") { xf.nodeType = fieldType; }
	// reference parity: trace keeps y as raw callback, not y.field
	let yf = (fieldName !== "" && hook !== "trace")
		? makeMember(y, fieldName, loc)
		: y;
	if (fieldName !== "" && hook !== "trace") { yf.nodeType = fieldType; }

	// Tuple case extracted from match (MetaScript match arm limitation with block-scoped vars)
	if (fieldType.kind === TypeKind.Tuple) {
		// Emit the named msTuple_<hash> hooks for moveOrCopy to reference at tuple
		// assignment sites (classify.ms); this container hook still walks elements inline.
		ensureTupleHooks(tupleTypeName(fieldType), fieldType, lctx, loc);
		for (let ti = 0; ti < fieldType.typeChildren.length; ti += 1) {
			const visited2: NameSet = createNameSet();
			fillBody(hook, xf, yf, "_" + ti.toString(), fieldType.typeChildren[ti], lctx, buf, visited2, loc);
		}
		return;
	}

	// Primitives fall through to _ => defaultOp (isPrimitiveKind is canonical list)
	match (fieldType.kind) {
		TypeKind.String | TypeKind.StringLiteral => { stringOp(hook, xf, yf, fieldName, buf, loc); },
		TypeKind.Array => {
			const elem = fieldType.typeReturn;
			if (elem !== null) arrayOp(hook, elem, xf, yf, lctx, buf, loc);
		},
		TypeKind.Struct => {
			// Anon structs from `{...}` type annotations have empty typeName (created
			// via createStruct("", ...) in resolvePass). Codegen emits them as
			// `msAnon_<hash>`; mirror that here so the hook name matches.
			const resolvedName = (fieldType.typeName !== "" && !isAnonTypeName(fieldType.typeName))
				? fieldType.typeName
				: (fieldType.typeNames.length > 0 ? anonTypeName(fieldType) : "");
			if (resolvedName !== "") {
				// Reference parity: trace only emits for cyclic field types (defaultOp is no-op for trace)
				if (hook !== "trace" || isCyclicType(fieldType, lctx, visited)) {
					// Field-recursion is a CONSUMER path — skip TypeInfo emission.
					ensureHooks(resolvedName, fieldType, null as unknown as Type, false, lctx, loc);
					if (namedTypeHasHooks(resolvedName, lctx)) {
						namedObjOp(hook, resolvedName, xf, yf, buf, loc);
					} else {
						defaultOp(hook, xf, yf, buf, loc);
					}
				}
			} else {
				defaultOp(hook, xf, yf, buf, loc);
			}
		},
		TypeKind.Ref => {
			// Actor handles are DRC-exempt (classify.ms: SymbolKind.Actor -> noRcInfo).
			// Emitting decref/incref on a sibling actor field underflows its rc (spawn
			// never increfs it) -> double-free of the shared actor's state.
			if (fieldType.sym !== null && fieldType.sym.symbolKind === SymbolKind.Actor) {
				defaultOp(hook, xf, yf, buf, loc);
			} else {
				const cyclic = isCyclicType(fieldType, lctx, visited);
				refOp(hook, xf, yf, fieldName, cyclic, isAtomicRef(fieldType), buf, loc);
			}
		},
		TypeKind.Ptr => {
			defaultOp(hook, xf, yf, buf, loc);
		},
		TypeKind.Function => {
			if (hook === "copy") {
				genCopyRef("msClosureCopy", xf, yf, fieldName, buf, loc);
			} else {
				runtimeOp("msClosure", "msClosureDestroy", "Copy", "WasMoved", "Trace", true, hook, xf, yf, buf, loc);
			}
		},
		TypeKind.GenericInstance => {
			// Promise<T> is exempt from generated Promise__T_destroy hooks (codegen
			// emits msFuture_<T> directly, not via per-type hook). But Promise FIELDS
			// inside other types (e.g. async fn envs $Env_X_shared with $retFut/$yf0)
			// MUST emit msFutureDrcDestroy at the container's destroy hook — otherwise
			// futures held by the env leak when the env's destroyFn runs. Combined
			// with the markReturnedVarsMoved MemberExpr fix and the msAsyncCb NULL
			// decref, this completes the async fn cleanup chain.
			if (isAwaitable(fieldType)) {
				match (hook) {
					"destroy" => { genCall("msFutureDrcDestroy", hook, xf, yf, buf, loc); },
					"copy" | "sink" => { defaultOp(hook, xf, yf, buf, loc); },
					_ => {},
				};
				return;
			}
			const unwrapped = unwrapGenericInstance(fieldType);
			if (unwrapped.mangledName !== "") {
				if (hook !== "trace" || isCyclicType(unwrapped.body, lctx, visited)) {
					ensureHooks(unwrapped.mangledName, unwrapped.body, null as unknown as Type, false, lctx, loc);
					if (namedTypeHasHooks(unwrapped.mangledName, lctx)) {
						namedObjOp(hook, unwrapped.mangledName, xf, yf, buf, loc);
					} else {
						defaultOp(hook, xf, yf, buf, loc);
					}
				}
			} else {
				defaultOp(hook, xf, yf, buf, loc);
			}
		},
		TypeKind.Union => {
			const refInner = unwrapRefNullUnion(fieldType);
			if (refInner !== null) {
				if (refInner.kind === TypeKind.Ptr || (refInner.sym !== null && refInner.sym.symbolKind === SymbolKind.Actor)) {
					defaultOp(hook, xf, yf, buf, loc);
				} else {
					const cyclic = isCyclicType(fieldType, lctx, visited);
					refOp(hook, xf, yf, fieldName, cyclic, isAtomicRef(fieldType), buf, loc);
				}
				return;
			}
			// Pure strlit union is msString-backed (see isTaggedUnion below) —
			// same ops as a String field, never named tagged-union hooks.
			if (isStringLike(fieldType)) {
				stringOp(hook, xf, yf, fieldName, buf, loc);
			} else if (fieldType.typeName !== "") {
				if (hook !== "trace" || isCyclicType(fieldType, lctx, visited)) {
					// Field-recursion is a CONSUMER path — skip TypeInfo emission.
					ensureHooks(fieldType.typeName, fieldType, null as unknown as Type, false, lctx, loc);
					if (namedTypeHasHooks(fieldType.typeName, lctx)) {
						namedObjOp(hook, fieldType.typeName, xf, yf, buf, loc);
					}
				}
			} else if (isPrimitiveOnlyUnion(fieldType)) {
				primitiveUnionOp(hook, fieldType, xf, yf, buf, loc);
			}
		},
		TypeKind.Distinct => {
			if (fieldType.typeReturn !== null) {
				fillBody(hook, x, y, fieldName, fieldType.typeReturn, lctx, buf, visited, loc);
			}
		},
		_ => { defaultOp(hook, xf, yf, buf, loc); },
	};
}

// --- Anonymous primitive-union hooks (float32 | string, tagged struct) ---
// Payload lives as raw C members in `union { float v0; msString v1; }` + `_tag`.
// POD members blit with the struct assign; the (single) msString member gets
// rc ops gated on `_tag`. Union slots hold GARBAGE bits for inactive members —
// every string op must be tag-guarded or it reads a float as a pointer.

function primitiveUnionStringIdx(t: Type): number {
	let i = 0;
	while (i < t.typeChildren.length) {
		const m = t.typeChildren[i];
		if (m !== null && (m.kind === TypeKind.String || m.kind === TypeKind.StringLiteral)) return i;
		i += 1;
	}
	return -1;
}

function isPrimitiveOnlyUnion(t: Type): boolean {
	if (t.typeChildren === null || t.typeChildren.length === 0) return false;
	let strs = 0;
	let i = 0;
	while (i < t.typeChildren.length) {
		const m = t.typeChildren[i];
		if (!isPrimitiveUnionMember(m)) return false;
		if (m !== null && (m.kind === TypeKind.String || m.kind === TypeKind.StringLiteral)) strs += 1;
		i += 1;
	}
	return strs <= 1;
}

function unionTagIs(n: Node, idx: number, loc: SourceLocation): Node {
	return makeBinary(makeMember(clonePath(n, loc), "_tag", loc), "===", makeNumber(idx, loc), loc);
}

function tagGuardedStringCall(fnName: string, xf: Node, px: Node, py: Node, sIdx: number, buf: NodeBuf, loc: SourceLocation): void {
	const b = newBuf();
	genCall(fnName, "destroy", px, py, b, loc);
	buf.items.push(makeIf(unionTagIs(xf, sIdx, loc), makeBlock(b.items, loc), makeNull(loc), loc));
}

function primitiveUnionOp(hook: string, u: Type, xf: Node, yf: Node, buf: NodeBuf, loc: SourceLocation): void {
	const sIdx = primitiveUnionStringIdx(u);
	if (sIdx < 0) {
		defaultOp(hook, xf, yf, buf, loc);
		return;
	}
	const vName = `v${sIdx}`;
	const px = makeMember(clonePath(xf, loc), vName, loc);
	const py = makeMember(clonePath(yf, loc), vName, loc);
	if (hook === "destroy") {
		tagGuardedStringCall("msStringDecref", xf, px, py, sIdx, buf, loc);
		return;
	}
	if (hook === "wasMoved") {
		tagGuardedStringCall("msStringWasMoved", xf, px, py, sIdx, buf, loc);
		return;
	}
	if (hook === "sink") {
		tagGuardedStringCall("msStringDecref", xf, px, py, sIdx, buf, loc);
		defaultOp(hook, clonePath(xf, loc), clonePath(yf, loc), buf, loc);
		return;
	}
	if (hook === "copy") {
		// dest string, src string  → msStringCopy (releases old, dups new)
		const ssBuf = newBuf();
		genCopyRef("msStringCopy", px, py, vName, ssBuf, loc);
		// dest string, src pod     → release old string, blit
		const spBuf = newBuf();
		genCall("msStringDecref", "destroy", clonePath(px, loc), py, spBuf, loc);
		defaultOp("copy", clonePath(xf, loc), clonePath(yf, loc), spBuf, loc);
		const xStr = makeIf(unionTagIs(yf, sIdx, loc), makeBlock(ssBuf.items, loc), makeBlock(spBuf.items, loc), loc);
		// dest pod → blit, then bump the shared string when src was active
		const incBuf = newBuf();
		genCall("msStringIncref", "destroy", clonePath(px, loc), py, incBuf, loc);
		const podBuf = newBuf();
		defaultOp("copy", clonePath(xf, loc), clonePath(yf, loc), podBuf, loc);
		podBuf.items.push(makeIf(unionTagIs(xf, sIdx, loc), makeBlock(incBuf.items, loc), makeNull(loc), loc));
		buf.items.push(makeIf(unionTagIs(xf, sIdx, loc), makeBlock([xStr], loc), makeBlock(podBuf.items, loc), loc));
		return;
	}
	// trace: primitive unions hold no traced refs.
}

// A tagged (match-type) DU emits `struct { _tag; union{...} }` — its variants peel to
// structs. A primitive/string union (`"a" | "b"`) has no struct variants and is backed by
// msString at runtime, so it must NOT get tagged-union hooks (they'd touch `_tag`).
function isTaggedUnion(t: Type): boolean {
	if (t.kind !== TypeKind.Union) return false;
	for (let vi = 0; vi < t.typeChildren.length; vi += 1) {
		const v = peelToStruct(t.typeChildren[vi]);
		if (v !== null && v.kind === TypeKind.Struct) return true;
	}
	return false;
}

// ===== Needs Hooks Check =====
// Probe: run fillBody("destroy") on throwaway buf. If it emits anything, type needs hooks.

function typeNeedsHooks(objType: Type, lctx: LiftCtx, loc: SourceLocation): boolean {
	if (objType.kind !== TypeKind.Struct && objType.kind !== TypeKind.Union) return false;
	const probe = newBuf();
	if (objType.kind === TypeKind.Union) {
		// Probe each variant's fields. Peel Ref/Ptr — interface variants are
		// Ref<Struct> in the C backend.
		for (let vi = 0; vi < objType.typeChildren.length; vi += 1) {
			const variant = peelToStruct(objType.typeChildren[vi]);
			if (variant !== null && variant.typeNames !== null) {
				for (let fi = 0; fi < variant.typeNames.length; fi += 1) {
					const visited: NameSet = createNameSet();
					fillBody("destroy", makeIdent("self", loc), makeIdent("self", loc), variant.typeNames[fi], variant.typeChildren[fi], lctx, probe, visited, loc);
					if (probe.items.length > 0) return true;
				}
			}
		}
		return false;
	}
	for (let i = 0; i < objType.typeNames.length; i += 1) {
		const visited: NameSet = createNameSet();
		fillBody("destroy", makeIdent("self", loc), makeIdent("self", loc), objType.typeNames[i], objType.typeChildren[i], lctx, probe, visited, loc);
		if (probe.items.length > 0) return true;
	}
	return false;
}

// ===== Inheritance Helper (Standard reference pattern) =====

function getBaseClass(typeName: string, lctx: LiftCtx): string {
	const sym = lookupSymbol(lctx.checkerCtx.table, typeName);
	if (sym === null) return "";
	if (sym.symbolKind !== SymbolKind.Class) return "";
	const inner = unwrapRef(sym.symbolType);
	if (inner.typeExtra === null) return "";
	// typeExtra is the resolved base class type (Struct or Ref<Struct>)
	const base = inner.typeExtra;
	if (base.kind === TypeKind.Struct && base.typeName !== "") return base.typeName;
	if (base.kind === TypeKind.Ref && base.typeReturn !== null && base.typeReturn.typeName !== "") return base.typeReturn.typeName;
	return "";
}

// ===== User-Defined Hook Dispatch (Reference considerUserDefinedOp) =====
// Maps each lifecycle op to its user-facing method name. A user hook is any
// method/extension with that name on the receiver type — class methods and
// free-function extensions both land in the extension registry (collectPass),
// keyed by (receiverTypeName, methodName) with the real callable sym attached.
// Reference: Nim binds `=destroy`/`=copy`/… to the type and getAttachedOp
// retrieves by type — never by reconstructing a symbol name.

function userHookMethodName(hook: string): string {
	return match (hook) {
		"destroy" => "onDestroy",
		"copy" => "onCopy",
		"sink" => "onMove",
		"wasMoved" => "onMoved",
		"dup" => "onClone",
		"trace" => "onTrace",
		_ => "",
	};
}

function getUserDefinedHookSym(typeName: string, hook: string, lctx: LiftCtx): Symbol {
	const methodName = userHookMethodName(hook);
	if (methodName === "") return null as unknown as Symbol;
	if (lctx.checkerCtx === null || lctx.checkerCtx.extensionRegistry === null) return null as unknown as Symbol;
	// A type may carry duplicate registry entries reached through different import
	// paths — distinct Symbol instances whose modulePath differs only by spelling
	// (e.g. `crypto/index` vs `crypto/tls/../index`), each mangling to a different
	// C name. Reference rule: a type-bound op is defined in the type's own module.
	// Prefer the sym whose module matches the type's so the emitted call resolves
	// to the emitted definition (a stale-path sym links to an undefined symbol).
	let typeModulePath = "";
	const typeSym = lookupSymbol(lctx.checkerCtx.table, typeName);
	if (typeSym !== null) typeModulePath = typeSym.modulePath;
	let fallback: Symbol = null as unknown as Symbol;
	for (const m of lctx.checkerCtx.extensionRegistry.methods) {
		if (m.receiverTypeName !== typeName || m.methodName !== methodName || m.isStatic) continue;
		if (m.sym === null) continue;
		if (typeModulePath !== "" && m.sym.modulePath === typeModulePath) return m.sym;
		if (fallback === null) fallback = m.sym;
	}
	return fallback;
}

function hasUserDefinedHook(typeName: string, hook: string, lctx: LiftCtx): boolean {
	return getUserDefinedHookSym(typeName, hook, lctx) !== null;
}

// Reference parity: declaring any lifecycle hook makes the type need lifecycle
// management (Nim sets tfHasAsgn in bindTypeHook). A handle-only type (e.g. a
// uint32 GPU buffer) has no RC fields, so typeNeedsHooks alone would skip it —
// the user hook would then never be wired into <T>Destroy.
function hasAnyUserHook(typeName: string, lctx: LiftCtx): boolean {
	return hasUserDefinedHook(typeName, "destroy", lctx)
		|| hasUserDefinedHook(typeName, "copy", lctx)
		|| hasUserDefinedHook(typeName, "sink", lctx)
		|| hasUserDefinedHook(typeName, "wasMoved", lctx)
		|| hasUserDefinedHook(typeName, "trace", lctx);
}

// ===== Union variant arm generation (if/else chain on _tag) =====

// Emit `dest._tag = src._tag` (variant discriminator copy). Used by sink and
// every non-unary hook that needs to mirror the source's active-variant tag.
function emitTagCopy(buf: NodeBuf, dest: string, src: string, loc: SourceLocation): void {
	const lhs = makeMember(makeIdent(dest, loc), "_tag", loc);
	const rhs = makeMember(makeIdent(src, loc), "_tag", loc);
	buf.items.push(makeExprStmt(makeAssign(lhs, rhs, loc), loc));
}

function generateUnionArms(hook: string, typeName: string, objType: Type, p1: string, p2: string, lctx: LiftCtx, buf: NodeBuf, loc: SourceLocation): void {
	const isUnary = hook === "destroy" || hook === "wasMoved" || hook === "trace";

	// reference parity: sink must destroy old variant BEFORE reassigning _tag
	if (hook === "sink") {
		// 1. Destroy old fields (dispatch on dest._tag)
		const destroyChain = buildVariantDispatch("destroy", typeName, objType, p1, p1, true, lctx, loc);
		if (destroyChain !== null) buf.items.push(destroyChain);
		// 2. Assign _tag
		emitTagCopy(buf, p1, p2, loc);
		// 3. Assign new fields (dispatch on src._tag, simple assign only)
		const assignChain = buildVariantChain("sinkAssign", objType, p1, p2, false, lctx, loc);
		if (assignChain !== null) buf.items.push(assignChain);
		return;
	}

	// reference parity: =copy for case objects (liftdestructors.nim fillBodyObjT) —
	// blob = dest (snapshot old branch), wasMoved(dest) (whole-object zero: field copies
	// release old dest bits, which are foreign-variant garbage on unswitched memory),
	// copy tag + fields, destroy blob LAST (destroy-first frees src reachable through
	// dest's old branch).
	if (hook === "copy") {
		const ctr = lctx.tempCounter;
		lctx.tempCounter = ctr + 1;
		const blobName = "$blob_" + ctr.toString();
		const blobInit = makeIdent(p1, loc);
		blobInit.nodeType = objType;
		buf.items.push(makeVarDecl(blobName, blobInit, DeclKind.Let, loc));
		const zeroDest = makeIdent(p1, loc);
		zeroDest.nodeType = objType;
		buf.items.push(makeExprStmt(makeAssign(zeroDest, makeNull(loc), loc), loc));
		emitTagCopy(buf, p1, p2, loc);
		const copyChain = buildVariantDispatch("copy", typeName, objType, p1, p2, false, lctx, loc);
		if (copyChain !== null) buf.items.push(copyChain);
		buf.items.push(makeExprStmt(makeCall(makeIdent(typeName + "Destroy", loc),
			[makeHiddenAddr(makeIdent(blobName, loc), loc)], loc), loc));
		return;
	}

	// Build if/else chain dispatching on _tag via per-variant helpers
	const chain = buildVariantDispatch(hook, typeName, objType, p1, p2, isUnary, lctx, loc);
	if (chain !== null) buf.items.push(chain);

	// For wasMoved: set _tag = -1 after dispatch
	if (hook === "wasMoved") {
		buf.items.push(makeExprStmt(makeAssign(makeMember(makeIdent(p1, loc), "_tag", loc), makeNumber(-1, loc), loc), loc));
	}
}

// Build if/else chain that dispatches to per-variant helper functions.
// Each variant's arm logic is extracted into its own function to keep stack frames small.
// (Without this, the monolithic function hoists ALL variants' locals → stack overflow at -O0)
function buildVariantDispatch(hook: string, typeName: string, objType: Type, p1: string, p2: string, isUnary: boolean, lctx: LiftCtx, loc: SourceLocation): Node {
	let chain = null as unknown as Node;
	let vi = objType.typeChildren.length - 1;
	while (vi >= 0) {
		// Peel Ref/Ptr — interface variants are Ref<Struct> in the C backend.
		// Without peel, Phase 1a/1b skipped variant.typeNames (empty on Ref) and
		// no per-variant Destroy helpers were emitted, leaving the wrapper hook
		// (`<Union>Destroy`) calling undefined helpers at link time.
		const variant = peelToStruct(objType.typeChildren[vi]);
		if (variant !== null && variant.typeNames !== null) {
			// Generate per-variant arm body
			const armBuf = newBuf();
			const vName = "v" + vi.toString();
			buildVariantArmBody(hook, objType, p1, p2, vi, vName, variant, isUnary, lctx, armBuf, loc);

			if (armBuf.items.length > 0) {
				// Generate helper function: TypeName_vN_Suffix(self) or TypeName_vN_Suffix(dest, src)
				// Dedup: sink hook internally dispatches destroy — reuse already-generated destroy helpers
				const suffix = hookSuffix(hook);
				const helperName = `${typeName}_${vName}${suffix}`;
				if (!nameSetContains(lctx.generated, helperName)) {
					nameSetAdd(lctx.generated, helperName);
					const isTrace = hook === "trace";
					let helperFn: Node = null as unknown as Node;
					if (isTrace) {
						// Trace: (self, callback) — self is union type, callback is void*
						helperFn = makeFnDecl(helperName, [p1, p2], [typeName, "void*"], makeBlock(armBuf.items, loc), "", "void", loc);
					} else if (isUnary) {
						helperFn = makeFnDecl(helperName, [p1], [typeName], makeBlock(armBuf.items, loc), "", "void", loc);
					} else {
						helperFn = makeFnDecl(helperName, [p1, p2], [typeName, typeName], makeBlock(armBuf.items, loc), "", "void", loc);
					}
					const paramType = createVar(objType);
					setHookParamType(helperFn, 0, paramType);
					if (!isUnary) setHookParamType(helperFn, 1, paramType);
					// Trace param[1] stays void* (callback/env) — no type override
					markGeneratedOp(helperFn, helperName);
					lctx.collector.push(helperFn);
				}

				// Dispatch: call the helper from the main if/else chain
				const tagAccess = makeMember(makeIdent(p1, loc), "_tag", loc);
				const cond = makeBinary(tagAccess, "===", makeNumber(vi, loc), loc);
				const callArgs: Node[] = (isUnary && hook !== "trace")
					? [makeIdent(p1, loc)]
					: [makeIdent(p1, loc), makeIdent(p2, loc)];
				const callStmt = makeExprStmt(makeCall(makeIdent(helperName, loc), callArgs, loc), loc);
				chain = makeIf(cond, makeBlock([callStmt], loc), chain !== null ? chain : makeNull(loc), loc);
			}
		}
		vi -= 1;
	}
	return chain;
}

// Emit raw `dest.vN.field = src.vN.field` assignments for each variant field,
// skipping void-typed slots (e.g. `Result<void, E>` v0 has no `value`). Used
// for the `sinkAssign` hook by both inline and helper-extracted dispatch
// patterns.
function emitVariantSinkAssign(armBuf: NodeBuf, p1: string, p2: string, vName: string, variant: Type, loc: SourceLocation): void {
	let fi = 0;
	while (fi < variant.typeNames.length) {
		const ft = fi < variant.typeChildren.length ? variant.typeChildren[fi] : null;
		if (ft !== null && ft.kind === TypeKind.Void) { fi += 1; continue; }
		const xBase = makeMember(makeIdent(p1, loc), vName, loc);
		const yBase = makeMember(makeIdent(p2, loc), vName, loc);
		armBuf.items.push(makeExprStmt(makeAssign(
			makeMember(xBase, variant.typeNames[fi], loc),
			makeMember(yBase, variant.typeNames[fi], loc), loc), loc));
		fi += 1;
	}
}

// Generate the body of a single variant's arm (used by both inline and helper patterns)
function buildVariantArmBody(hook: string, objType: Type, p1: string, p2: string, vi: number, vName: string, variant: Type, isUnary: boolean, lctx: LiftCtx, armBuf: NodeBuf, loc: SourceLocation): void {
	if (hook === "destroy") {
		let fi = variant.typeNames.length - 1;
		while (fi >= 0) {
			const xBase = makeMember(makeIdent(p1, loc), vName, loc);
			const yBase = makeMember(makeIdent(p1, loc), vName, loc);
			const visited: NameSet = createNameSet();
			fillBody(hook, xBase, yBase, variant.typeNames[fi], variant.typeChildren[fi], lctx, armBuf, visited, loc);
			fi -= 1;
		}
	} else if (hook === "sinkAssign") {
		emitVariantSinkAssign(armBuf, p1, p2, vName, variant, loc);
	} else {
		let fi = 0;
		while (fi < variant.typeNames.length) {
			const xBase = makeMember(makeIdent(p1, loc), vName, loc);
			const yBase = (hook === "trace") ? makeIdent(p2, loc)
				: isUnary ? makeMember(makeIdent(p1, loc), vName, loc)
				: makeMember(makeIdent(p2, loc), vName, loc);
			const visited: NameSet = createNameSet();
			fillBody(hook, xBase, yBase, variant.typeNames[fi], variant.typeChildren[fi], lctx, armBuf, visited, loc);
			fi += 1;
		}
	}
}

// Build if/else chain over variant arms, dispatching on p1._tag
function buildVariantChain(hook: string, objType: Type, p1: string, p2: string, isUnary: boolean, lctx: LiftCtx, loc: SourceLocation): Node {
	let chain = null as unknown as Node;
	let vi = objType.typeChildren.length - 1;
	while (vi >= 0) {
		const variant = objType.typeChildren[vi];
		const armBuf = newBuf();
		if (variant !== null && variant.typeNames !== null) {
			const vName = "v" + vi.toString();
			buildVariantArmBody(hook, objType, p1, p2, vi, vName, variant, isUnary, lctx, armBuf, loc);
		}
		if (armBuf.items.length > 0) {
			const tagAccess = makeMember(makeIdent(p1, loc), "_tag", loc);
			const cond = makeBinary(tagAccess, "===", makeNumber(vi, loc), loc);
			chain = makeIf(cond, makeBlock(armBuf.items, loc), chain !== null ? chain : makeNull(loc), loc);
		}
		vi -= 1;
	}
	return chain;
}

// ===== Generate a single hook (Reference produceSym per op) =====

// Class types (Ref<Struct>) vs value types (Struct):
// ─────────────────────────────────────────────────────
// Hook bodies iterate the inner Struct fields (objType = unwrapRef(sym.symbolType)).
// But the PARAMETER TYPE differs:
//
//   Value types (interface/struct): param = Struct(Token)
//     → codegen uses ccgIntroducedPtr to decide pass-by-pointer based on size.
//     → callers wrap in HiddenAddr: Token_copy(&dest.field, &src.field)
//
//   Class types (ref object):       param = Ref<Struct(Doc)> = Doc*
//     → ALWAYS a pointer, regardless of struct size, because the struct lives
//       on the heap behind a Ref. The runtime calls hooks with void* pointers
//       (e.g. msDecref → type->destroyFn(ptr) when refcount hits zero).
//     → Same pattern as Maybe<Ref<T>> collapsing to bare Ref<T>: pointers are
//       natively indirect, no wrapper/threshold needed.
//
// classType is non-null for class types (= sym.symbolType = Ref<Struct>),
// null for value types. When non-null, param types use classType so codegen
// emits Doc* instead of Doc — matching the pointer the runtime passes.
function generateHook(hook: string, typeName: string, objType: Type, classType: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const buf = newBuf();
	const isTrace = hook === "trace";
	const isUnary = hook === "destroy" || hook === "wasMoved" || isTrace;
	const p1 = isUnary ? "self" : "dest";
	const p2 = match (hook) {
		"trace" => "callback",
		"destroy" | "wasMoved" => "self",
		_ => "src",
	};

	// Self-assignment guard for binary hooks (copy, sink).
	if (!isUnary && !isTrace) {
		buf.items.push(makeIf(
			makeBinary(makeHiddenAddr(makeIdent(p1, loc), loc), "===", makeHiddenAddr(makeIdent(p2, loc), loc), loc),
			makeBlock([makeReturn(null as unknown as Node, loc)], loc),
			null as unknown as Node,
			loc
		));
	}

	// User-defined hook dispatch (Reference considerUserDefinedOp).
	// A user hook fully OVERRIDES the compiler's field traversal (reference parity:
	// destructors.md "the compiler-generated hooks can be overridden ... to use an
	// alternative traversal ... or to avoid deep recursions"). This is load-bearing:
	// the default destroy recurses per field, so a deep/self-referential structure
	// overflows the stack (see resolvePass owning-self-referential-field warning) —
	// a user hook lets the author traverse iteratively instead. The author is
	// therefore responsible for ALL owned fields. Same for copy/sink/wasMoved/trace.
	const hookSym = getUserDefinedHookSym(typeName, hook, lctx);
	if (hookSym !== null) {
		const hookIdent = makeIdentResolved(hookSym, loc);
		if (isUnary) {
			buf.items.push(makeExprStmt(makeCall(hookIdent, [makeIdent(p1, loc)], loc), loc));
		} else {
			buf.items.push(makeExprStmt(makeCall(hookIdent, [makeIdent(p1, loc), makeIdent(p2, loc)], loc), loc));
		}
	} else {
		// Inheritance: ensure base class hooks exist (Implementation parity).
		// ensureHooksByName does sym lookup + dispatch to unified ensureHooks —
		// base classes are always declared so always reach ensureHooks.
		const baseTypeName = getBaseClass(typeName, lctx);
		if (baseTypeName !== "") {
			ensureHooksByName(baseTypeName, lctx, loc);
		}

		// Ref types: HiddenDeref unwraps Ref<Struct> → Struct for field access.
		// Value types (Var<T>): params are T* pointers — MemberExpr uses -> automatically
		// when it sees isPointerType on the identifier's symbolType.
		const isRef = classType !== null;
		const x1 = isRef ? makeHiddenDeref(makeIdent(p1, loc), loc) : makeIdent(p1, loc);
		const x2 = (isRef && !isTrace) ? makeHiddenDeref(makeIdent(p2, loc), loc) : makeIdent(p2, loc);

		// Phase 4: when child class has flattened parent fields (HasInheritedFields
		// flag set in resolveClass), suppress parent hook genCall — fields are
		// walked inline by the per-field loops below, so calling parent destroy
		// would double-free. ensureHooksByName above is preserved (parent type
		// still needs hooks emitted for cross-module references).
		const fieldsFlattened = (objType.typeFlags & TypeFlag.HasInheritedFields) !== 0;
		if (objType.kind === TypeKind.Union) {
			generateUnionArms(hook, typeName, objType, p1, p2, lctx, buf, loc);
		} else if (hook === "destroy") {
			// Destroy: fields first (reverse), then base class (LIFO — standard pattern)
			for (let i = objType.typeNames.length - 1; i >= 0; i -= 1) {
				const visited: NameSet = createNameSet();
				fillBody(hook, x1, x2, objType.typeNames[i], objType.typeChildren[i], lctx, buf, visited, loc);
			}
			if (!fieldsFlattened && baseTypeName !== "" && namedTypeHasHooks(baseTypeName, lctx)) {
				genCall(baseTypeName + "Destroy", hook, x1, x2, buf, loc);
			}
		} else {
			// Copy/sink/trace/wasMoved: base class first, then fields (standard pattern)
			if (!fieldsFlattened && baseTypeName !== "" && namedTypeHasHooks(baseTypeName, lctx)) {
				genCall(baseTypeName + hookSuffix(hook), hook, x1, x2, buf, loc);
			}
			for (let i = 0; i < objType.typeNames.length; i += 1) {
				const visited: NameSet = createNameSet();
				fillBody(hook, x1, x2, objType.typeNames[i], objType.typeChildren[i], lctx, buf, visited, loc);
			}
		}
	}

	// Wrap the destroy body in the ORC teardown critical section (msOrcBeginTeardown/EndTeardown):
	// a field decref here can register a cycle root and trigger a re-entrant collect that traces
	// this object's already-freed, not-yet-nulled slots (UAF). The guard defers collection until
	// the whole teardown unwinds. Destroy hooks are single-exit (no early return), so bracketing
	// the statement list is sufficient. No-op under --gc=drc.
	if (hook === "destroy") {
		const wrapped: Node[] = [makeExprStmt(makeCall(makeIdent("msOrcBeginTeardown", loc), [], loc), loc)];
		for (const it of buf.items) { wrapped.push(it); }
		wrapped.push(makeExprStmt(makeCall(makeIdent("msOrcEndTeardown", loc), [], loc), loc));
		buf.items = wrapped;
	}

	const suffix = hookSuffix(hook);

	let fnNode: Node = null as unknown as Node;
	if (isTrace) {
		fnNode = makeFnDecl(typeName + suffix, [p1, p2], [typeName, "void*"], makeBlock(buf.items, loc), "", "void", loc);
	} else if (isUnary) {
		fnNode = makeFnDecl(typeName + suffix, [p1], [typeName], makeBlock(buf.items, loc), "", "void", loc);
	} else {
		fnNode = makeFnDecl(typeName + suffix, [p1, p2], [typeName, typeName], makeBlock(buf.items, loc), "", "void", loc);
	}
	// Set hook param types explicitly (reference parity: symPrototype sets dest.typ/src.typ directly).
	// For class types, use classType (Ref<Struct>) — already a pointer.
	// For value types, wrap in Var (= pointer) — Standard reference parity: =destroy(x: var T).
	const paramType = classType !== null ? classType : createVar(objType);
	setHookParamType(fnNode, 0, paramType);
	if (!isUnary && !isTrace) {
		// copy/sink: both params are the struct type
		setHookParamType(fnNode, 1, paramType);
	}
	// trace: param[1] stays void* (callback/env) — reference: getSysType(pointer)
	markGeneratedOp(fnNode, typeName + suffix);
	lctx.collector.push(fnNode);
}

// ===== Ensure Type Hooks — unified entry (handles named class/interface,
// named struct, anonymous struct, generic instance, union) =====
//
// Single dispatch replaces the old `ensureTypeHooks(typeName)` /
// `ensureTypeHooksForType(objType, refType)` pair. Prior dual-path design had
// a DRY violation that caused a race: Path B (walker-driven) could claim
// global ownership for a named class (e.g. Symbol) before Path A
// (ClassDecl-driven) emitted the `<T>TypeInfo` global, leaving link errors on
// `msAllocTyped(sizeof(T), &TTypeInfo)` call sites. See
// `docs/KNOWN-ISSUES.md` / memory `project_actor_toplevel_bug.md` for context.
//
// Contract:
//   - `typeName` — required (anonymous types with typeName === "" can't name hooks; early return).
//   - `objType` — the struct/union type whose fields the hooks walk.
//   - `refType` — non-null iff caller already knows this is a Ref<Struct> (class/interface).
//     When null, the function looks up the symbol by name and infers class/interface status.
//   - Claims `lctx.generated` + `_globalHookOwners` atomically at the *end* of a
//     successful emission — never mid-flight, never before TypeInfo is emitted.

// Emit a minimal msTypeInfo for a class/interface with no RC fields. Needed so
// `msAllocTyped(sizeof(T), &TTypeInfo)` links; destroyFn / traceFn are null.
function emitMinimalTypeInfo(typeName: string, lctx: LiftCtx, loc: SourceLocation): void {
	const obj = makeObjectLiteral(
		["name", "isCyclic", "traceFn", "destroyFn"],
		[makeString(typeName, loc), makeBool(false, loc), makeNull(loc), makeNull(loc)],
		loc,
	);
	lctx.collector.push(makeVarDecl(typeName + "TypeInfo", obj, DeclKind.Const, loc));
}

// Emit the full msTypeInfo for a class/interface with RC fields. destroyFn
// points to the generated <T>Destroy; traceFn points to <T>Trace iff cyclic.
function emitFullTypeInfo(typeName: string, hasCycles: boolean, lctx: LiftCtx, loc: SourceLocation): void {
	const traceFn = hasCycles ? makeIdent(typeName + "Trace", loc) : makeNull(loc);
	const obj = makeObjectLiteral(
		["name", "isCyclic", "traceFn", "destroyFn"],
		[makeString(typeName, loc), makeBool(hasCycles, loc), traceFn, makeIdent(typeName + "Destroy", loc)],
		loc,
	);
	lctx.collector.push(makeVarDecl(typeName + "TypeInfo", obj, DeclKind.Const, loc));
}

// Emit the <T>Dup hook. Ref types (class/interface) get the incref shortcut;
// value types copy through <T>Copy. Signature identical to the paired Ref/val
// dup emission in the old Path A / Path B, just deduplicated.
function emitDup(typeName: string, objType: Type, classType: Type, isRef: boolean, lctx: LiftCtx, loc: SourceLocation): void {
	const dupStmts: Node[] = [];
	if (isRef) {
		// ref types: result = src; incref(result). No =copy call — just pointer copy + refcount.
		dupStmts.push(makeVarDecl("$result", makeIdent("src", loc), DeclKind.Let, loc));
		dupStmts.push(makeExprStmt(makeCall(makeIdent("msIncref", loc), [makeIdent("$result", loc)], loc), loc));
		dupStmts.push(makeReturn(makeIdent("$result", loc), loc));
	} else {
		// Value types: result = src; TypeName_copy(&result, &src); return result.
		dupStmts.push(makeVarDecl("$result", makeIdent("src", loc), DeclKind.Let, loc));
		dupStmts.push(makeExprStmt(makeCall(makeIdent(typeName + "Copy", loc), [makeHiddenAddr(makeIdent("$result", loc), loc), makeHiddenAddr(makeIdent("src", loc), loc)], loc), loc));
		dupStmts.push(makeReturn(makeIdent("$result", loc), loc));
	}
	const dupNode = makeFnDecl(typeName + "Dup", ["src"], [typeName], makeBlock(dupStmts, loc), "", typeName, loc);
	const dupType = classType !== null ? classType : objType;
	setHookParamType(dupNode, 0, dupType);
	setHookReturnType(dupNode, dupType);
	markGeneratedOp(dupNode, typeName + "Dup");
	lctx.collector.push(dupNode);
}

// `emitTypeInfo` gates whether this call should push the `<T>TypeInfo`
// global + init to the collector. Only the DEFINING module should emit —
// consumer modules (walker-driven) still emit hooks (in the first-claimer
// pattern) but skip TypeInfo to avoid duplicate-symbol link errors with
// codegen's `ensureTypeInfoDef` path. processDecl passes `true`;
// scanForAnonStructTypes / fillBody field-recursion pass `false`.
function ensureHooks(typeName: string, objType: Type, refType: Type, emitTypeInfo: boolean, lctx: LiftCtx, loc: SourceLocation): void {
	// ----- Guards (order matches old ensureTypeHooks for perf parity) -----
	if (typeName === "") return;
	if (nameSetContains(lctx.generated, typeName)) return;
	// Global dedup. Split: hooks-owned blocks hook emission, TypeInfo-owned
	// blocks TypeInfo emission. When defining module (emitTypeInfo=true) sees
	// hooks-owned but !typeInfo-owned, it still needs to enter and emit the
	// TypeInfo — that's the race the unified entry fixes. Otherwise skip.
	const hooksOwned = isGloballyOwned(typeName);
	if (hooksOwned && (!emitTypeInfo || isTypeInfoGloballyOwned(typeName))) return;
	if (nameSetContains(lctx.generating, typeName)) return;
	nameSetAdd(lctx.generating, typeName);

	// ----- Resolve category via symbol lookup (matches old ensureTypeHooks) -----
	let isClassOrInterface = refType !== null;
	let isCrossModuleClass = false;
	if (lctx.checkerCtx !== null) {
		const sym = lookupSymbol(lctx.checkerCtx.table, typeName);
		if (sym !== null) {
			if (sym.symbolKind === SymbolKind.TypeAlias
				&& sym.symbolType !== null
				&& sym.symbolType.kind === TypeKind.Ref) {
				nameSetAdd(lctx.generated, typeName);
				return;
			}
			if (sym.symbolKind === SymbolKind.Class
				|| sym.symbolKind === SymbolKind.Interface) {
				isClassOrInterface = true;
				if (refType === null) refType = sym.symbolType;
				isCrossModuleClass = sym.modulePath !== "" && sym.modulePath !== lctx.checkerCtx.modulePath;
			}
		}
	}

	// Lambda-lifted env InterfaceDecls (`$Env_*`) have no registered symbol.
	// They're heap-allocated ref types → must use HiddenDeref on `self` in hook
	// bodies. Synthesize a Ref wrapper so the classType path runs.
	if (typeName.length > 5 && typeName.startsWith("$Env_")) {
		isClassOrInterface = true;
		if (refType === null) refType = createRef(objType);
		isCrossModuleClass = false;
	}

	if (objType.kind !== TypeKind.Struct && objType.kind !== TypeKind.Union) return;

	// Cross-module class/interface: defer to defining module. Consumer-path
	// callers (emitTypeInfo=false) mark as seen locally and bail; the defining
	// module's processDecl (emitTypeInfo=true) emits both hooks and TypeInfo.
	if (isCrossModuleClass && !emitTypeInfo) {
		nameSetAdd(lctx.generated, typeName);
		return;
	}

	const shouldEmitHooks = !hooksOwned;
	// Union covers `Ref<Union>` wrapped via TypeAlias (e.g. JsonValue) — see fixedbugs/bug037.
	const isHeapAllocated = isClassOrInterface || objType.kind === TypeKind.Union;
	const shouldEmitTypeInfo = emitTypeInfo && isHeapAllocated && !isTypeInfoGloballyOwned(typeName);

	// No RC fields → minimal TypeInfo only (for class/interface) and skip hooks.
	// Exception (Nim parity, `produceSym` in liftdestructors.nim:1180): plain
	// value-type Struct still emits empty-body hooks so container iteration
	// (e.g. `HashSet__numberDestroy` calling `HashSetEntry__numberDestroy` per
	// element) links — macOS native `ld -dead_strip` hides the missing symbol
	// by discarding the unreachable caller on arm64, but `zig cc`'s cross-
	// compile lld checks undefined references before dead-stripping and fails.
	// `generateHook` + `fillBody` produce the empty body naturally when no
	// field needs work (loop over typeChildren adds nothing).
	//
	// Class/interface (Ref<Struct>) don't need this exception — msRefHeader
	// manages lifetime; no per-element loop references them. A value tagged (match-type)
	// DU is the same case as a value struct: a containing type destroys it by an
	// unconditionally-emitted per-field call, so the empty-body hook must exist to link.
	// Primitive/string unions (`type X = "a" | "b"` → msString) still skip — their hooks
	// would touch `_tag` on a non-tagged value.
	if (!typeNeedsHooks(objType, lctx, loc) && !hasAnyUserHook(typeName, lctx)) {
		const isPlainValueAggregate = !isClassOrInterface
			&& (objType.kind === TypeKind.Struct || isTaggedUnion(objType));
		if (!isPlainValueAggregate) {
			if (shouldEmitTypeInfo) {
				emitMinimalTypeInfo(typeName, lctx, loc);
				claimGlobalTypeInfo(typeName);
			}
			nameSetAdd(lctx.generated, typeName);
			if (shouldEmitHooks) claimGlobal(typeName);
			return;
		}
	}

	const classType = isClassOrInterface ? refType : null;
	let hasCycles = false;

	if (shouldEmitHooks) {
		generateHook("destroy",  typeName, objType, classType, lctx, loc);
		generateHook("copy",     typeName, objType, classType, lctx, loc);
		generateHook("sink",     typeName, objType, classType, lctx, loc);
		generateHook("wasMoved", typeName, objType, classType, lctx, loc);
		setAttachedOp(objType, AttachedOp.AttachedDestructor, typeName + "Destroy");
		// Record in the codegen global registry (Nim graph.attachedOps analog): for mono'd generic
		// instances, setAttachedOp lands on this throwaway objType and never reaches the type codegen
		// resolves, so codegen's ensureTypeInfoDef reads this by-name registry to wire .destroyFn.
		recordGenDestroyHook(typeName);
		setAttachedOp(objType, AttachedOp.AttachedAsgn,       typeName + "Copy");
		setAttachedOp(objType, AttachedOp.AttachedSink,       typeName + "Sink");
		setAttachedOp(objType, AttachedOp.AttachedWasMoved,   typeName + "WasMoved");

		const visited: NameSet = createNameSet();
		hasCycles = isCyclicType(objType, lctx, visited);
		if (hasCycles) {
			generateHook("trace", typeName, objType, classType, lctx, loc);
			setAttachedOp(objType, AttachedOp.AttachedTrace, typeName + "Trace");
		}

		emitDup(typeName, objType, classType, isClassOrInterface, lctx, loc);
		setAttachedOp(objType, AttachedOp.AttachedDup, typeName + "Dup");

		claimGlobal(typeName);
	} else if (shouldEmitTypeInfo) {
		// Hooks live elsewhere but we still need hasCycles to populate TypeInfo.
		const visited: NameSet = createNameSet();
		hasCycles = isCyclicType(objType, lctx, visited);
	}

	if (shouldEmitTypeInfo) {
		emitFullTypeInfo(typeName, hasCycles, lctx, loc);
		claimGlobalTypeInfo(typeName);
	}

	nameSetAdd(lctx.generated, typeName);
}

// ===== (Removed: `ensureTypeHooks` and `ensureTypeHooksForType`.)
//
// Both old entry points replaced by the unified `ensureHooks(typeName, objType,
// refType, emitTypeInfo, lctx, loc)` above. The old names lived here
// historically but diverged — one emitted TypeInfo, the other didn't, and
// the guard registry could race between them. See the block comment on
// `ensureHooks` for the semantics.

// ===== Auto-Generated == (reference parity: generic proc `==`*[T: tuple|object]) =====
// Generates TypeName_eq(a, b): boolean with field-by-field comparison.
// Reference implementation uses compile-time `fields()` magic iterator unrolling; we do the same here
// by iterating typeNames/typeChildren at transform time.

function fieldEqExpr(aField: Node, bField: Node, fieldType: Type, lctx: LiftCtx, loc: SourceLocation): Node {
	// For nested value-type objects, call their _eq function — ensure it exists (on-demand, like tuples below)
	if (fieldType.kind === TypeKind.Struct && fieldType.typeName !== "") {
		ensureEq(fieldType.typeName, lctx, loc);
		return makeCall(makeIdent(fieldType.typeName + "Eq", loc), [aField, bField], loc);
	}
	// Tuple fields are C structs — `===` would emit an invalid struct comparison.
	// Route to the generated msTuple_<hash>Eq (field-by-field), ensuring it exists.
	if (fieldType.kind === TypeKind.Tuple) {
		const tn = tupleTypeName(fieldType);
		ensureTupleEq(tn, fieldType, lctx, loc);
		return makeCall(makeIdent(tn + "Eq", loc), [aField, bField], loc);
	}
	// String fields — reference parity: genStrEquals → eqStrings().
	// msString is a C struct, so === doesn't work. Call msStringEquals(a, b).
	if (isStringLike(fieldType)) {
		return makeCall(makeIdent("msStringEquals", loc), [aField, bField], loc);
	}
	// Array fields — arrays are C structs, can't use ==.
	// JavaScript semantics: === is reference equality (same object).
	// Compare data pointers — same backing store = same array.
	// Deep comparison belongs in stdlib (e.g. deepEqual).
	if (fieldType.kind === TypeKind.Array) {
		const pA = makeMember(aField, "p", loc);
		const pB = makeMember(bField, "p", loc);
		return makeBinary(pA, "===", pB, loc);
	}
	// Closure fields — compare function pointer and environment separately (reference parity)
	if (fieldType.kind === TypeKind.Function) {
		const fnA = makeMember(aField, "fn", loc);
		const fnB = makeMember(bField, "fn", loc);
		const envA = makeMember(aField, "env", loc);
		const envB = makeMember(bField, "env", loc);
		return makeBinary(makeBinary(fnA, "===", fnB, loc), "&&", makeBinary(envA, "===", envB, loc), loc);
	}
	// For all other types (primitives, enums, etc): use === directly
	return makeBinary(aField, "===", bField, loc);
}

function generateEq(typeName: string, objType: Type, lctx: LiftCtx, loc: SourceLocation): void {
	// Build: function TypeName_eq(a: TypeName, b: TypeName): boolean {
	//   if (a.field1 !== b.field1) return false;
	//   if (a.field2 !== b.field2) return false;
	//   ...
	//   return true;
	// }
	const buf: Node[] = [];
	for (let i = 0; i < objType.typeNames.length; i += 1) {
		const fieldName = objType.typeNames[i];
		const fieldType = objType.typeChildren[i];
		const aField = makeMember(makeIdent("a", loc), fieldName, loc);
		const bField = makeMember(makeIdent("b", loc), fieldName, loc);

		// Generate: if (!fieldEq) return false;
		const eqExpr = fieldEqExpr(aField, bField, fieldType, lctx, loc);
		const notEq = makeUnary("!", eqExpr, loc);
		buf.push(makeIf(notEq, makeBlock([makeReturn(makeBool(false, loc), loc)], loc), makeNull(loc), loc));
	}
	buf.push(makeReturn(makeBool(true, loc), loc));
	const eqFn = makeFnDecl(typeName + "Eq", ["a", "b"], [typeName, typeName], makeBlock(buf, loc), "", "boolean", loc);
	setHookParamType(eqFn, 0, objType);
	setHookParamType(eqFn, 1, objType);
	markGeneratedOp(eqFn, typeName + "Eq");
	lctx.collector.push(eqFn);
}

// ===== Ensure Eq (on-demand: only for struct/interface types actually compared) =====

function ensureEq(typeName: string, lctx: LiftCtx, loc: SourceLocation): void {
	if (nameSetContains(lctx.generated, typeName + "Eq")) return;
	if (isGloballyOwned(typeName + "Eq")) return;
	nameSetAdd(lctx.generated, typeName + "Eq");
	claimGlobal(typeName + "Eq");

	const sym = lookupSymbol(lctx.checkerCtx.table, typeName);
	if (sym === null) return;
	// For value-type structs and interfaces (not classes — classes use reference equality)
	if (sym.symbolKind === SymbolKind.Class) return;
	const eqType = unwrapRef(sym.symbolType);
	if (eqType.kind !== TypeKind.Struct) return;

	generateEq(typeName, eqType, lctx, loc);
}

// ===== Tuple Lifecycle Hooks (first-class value type) =====
// A tuple is a structural value type — codegen emits `struct msTuple_<hash> { T _0; U _1; }`
// — so its DRC hooks mirror a value-struct's: destroy/copy/sink/wasMoved over positional
// fields _0, _1, ... The name is tupleTypeName (the single source codegen + classify.ms also
// use, so they never drift). Without these the analyzer emits MS_NIL at tuple assignment
// sites and the overwritten tuple's heap payload leaks.

function generateTupleHook(hook: string, tupleName: string, t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const buf = newBuf();
	const isUnary = hook === "destroy" || hook === "wasMoved";
	const p1 = isUnary ? "self" : "dest";
	const p2 = isUnary ? "self" : "src";

	if (!isUnary) {
		buf.items.push(makeIf(
			makeBinary(makeHiddenAddr(makeIdent(p1, loc), loc), "===", makeHiddenAddr(makeIdent(p2, loc), loc), loc),
			makeBlock([makeReturn(null as unknown as Node, loc)], loc), null as unknown as Node, loc));
	}

	const x1 = makeIdent(p1, loc);
	const x2 = makeIdent(p2, loc);
	if (hook === "destroy") {
		for (let i = t.typeChildren.length - 1; i >= 0; i -= 1) {
			const visited: NameSet = createNameSet();
			fillBody(hook, x1, x2, "_" + i.toString(), t.typeChildren[i], lctx, buf, visited, loc);
		}
	} else {
		for (let i = 0; i < t.typeChildren.length; i += 1) {
			const visited: NameSet = createNameSet();
			fillBody(hook, x1, x2, "_" + i.toString(), t.typeChildren[i], lctx, buf, visited, loc);
		}
	}

	const suffix = hookSuffix(hook);
	const fnNode = isUnary
		? makeFnDecl(tupleName + suffix, [p1], [tupleName], makeBlock(buf.items, loc), "", "void", loc)
		: makeFnDecl(tupleName + suffix, [p1, p2], [tupleName, tupleName], makeBlock(buf.items, loc), "", "void", loc);
	const paramType = createVar(t);
	setHookParamType(fnNode, 0, paramType);
	if (!isUnary) setHookParamType(fnNode, 1, paramType);
	markGeneratedOp(fnNode, tupleName + suffix);
	lctx.collector.push(fnNode);
}

// Probe whether any tuple element emits cleanup (mirror typeNeedsHooks for structs).
function tupleNeedsHooks(t: Type, lctx: LiftCtx, loc: SourceLocation): boolean {
	const probe = newBuf();
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		const visited: NameSet = createNameSet();
		fillBody("destroy", makeIdent("self", loc), makeIdent("self", loc), "_" + i.toString(), t.typeChildren[i], lctx, probe, visited, loc);
		if (probe.items.length > 0) return true;
	}
	return false;
}

// The four value-type hooks for a tuple, once per module + once globally (claimGlobal).
// No-RC tuples generate nothing — classify.ms returns noRcInfo, so no hook is referenced.
function ensureTupleHooks(tupleName: string, t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	if (tupleName === "" || t === null || t.kind !== TypeKind.Tuple) return;
	if (nameSetContains(lctx.generated, tupleName)) return;
	if (isGloballyOwned(tupleName)) { nameSetAdd(lctx.generated, tupleName); return; }
	if (nameSetContains(lctx.generating, tupleName)) return;
	if (!tupleNeedsHooks(t, lctx, loc)) return;
	nameSetAdd(lctx.generating, tupleName);
	nameSetAdd(lctx.generated, tupleName);
	claimGlobal(tupleName);
	generateTupleHook("destroy",  tupleName, t, lctx, loc);
	generateTupleHook("copy",     tupleName, t, lctx, loc);
	generateTupleHook("sink",     tupleName, t, lctx, loc);
	generateTupleHook("wasMoved", tupleName, t, lctx, loc);
}

// On-demand msTuple_<hash>Eq for a tuple compared as a struct/tuple field (fieldEqExpr).
// Shares the `tupleName + "Eq"` dedup key with operatorLower's pending-ops, so one body.
function ensureTupleEq(tupleName: string, t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	if (tupleName === "" || t === null || t.kind !== TypeKind.Tuple) return;
	const key = tupleName + "Eq";
	if (nameSetContains(lctx.generated, key)) return;
	if (isGloballyOwned(key)) { nameSetAdd(lctx.generated, key); return; }
	nameSetAdd(lctx.generated, key);
	claimGlobal(key);
	generateTupleEq(tupleName, t, lctx, loc);
}

// ===== Tuple Comparison Operators (reference parity: reference core lines 1973-1996) =====
// Auto-generate ==, <, <= for tuples using positional field names (_0, _1, ...).
// Reference implementation uses `fields()` magic iterator; we unroll at transform time.

// Tuple field access helper: a._0, a._1, etc.
function tupleField(obj: Node, idx: number, loc: SourceLocation): Node {
	return makeMember(obj, "_" + idx.toString(), loc);
}

// Generate element-by-element equality for tuples.
// Reference: proc `==`*[T: tuple|object](x, y: T): bool =
//        for a, b in fields(x, y): if a != b: return false
//        return true
function generateTupleEq(tupleName: string, t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const buf: Node[] = [];
	let i = 0;
	while (i < t.typeChildren.length) {
		const aField = tupleField(makeIdent("a", loc), i, loc);
		const bField = tupleField(makeIdent("b", loc), i, loc);
		const eqExpr = fieldEqExpr(aField, bField, t.typeChildren[i], lctx, loc);
		buf.push(makeIf(makeUnary("!", eqExpr, loc), makeBlock([makeReturn(makeBool(false, loc), loc)], loc), makeNull(loc), loc));
		i += 1;
	}
	buf.push(makeReturn(makeBool(true, loc), loc));
	const teqFn = makeFnDecl(tupleName + "Eq", ["a", "b"], [tupleName, tupleName], makeBlock(buf, loc), "", "boolean", loc);
	setHookParamType(teqFn, 0, t);
	setHookParamType(teqFn, 1, t);
	markGeneratedOp(teqFn, tupleName + "Eq");
	lctx.collector.push(teqFn);
}

// Generate lexicographic < for tuples.
// Reference: proc `<`*[T: tuple](x, y: T): bool =
//        for a, b in fields(x, y):
//          var c = cmp(a, b)
//          if c < 0: return true
//          if c > 0: return false
//        return false
//
// We inline the cmp pattern: if (a < b) return true; if (a > b) return false;
function generateTupleLt(tupleName: string, t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const buf: Node[] = [];
	let i = 0;
	while (i < t.typeChildren.length) {
		const aField = tupleField(makeIdent("a", loc), i, loc);
		const bField = tupleField(makeIdent("b", loc), i, loc);
		// if (a._i < b._i) return true;
		buf.push(makeIf(makeBinary(aField, "<", bField, loc), makeBlock([makeReturn(makeBool(true, loc), loc)], loc), makeNull(loc), loc));
		// if (a._i > b._i) return false;
		const aField2 = tupleField(makeIdent("a", loc), i, loc);
		const bField2 = tupleField(makeIdent("b", loc), i, loc);
		buf.push(makeIf(makeBinary(aField2, ">", bField2, loc), makeBlock([makeReturn(makeBool(false, loc), loc)], loc), makeNull(loc), loc));
		i += 1;
	}
	buf.push(makeReturn(makeBool(false, loc), loc));
	const tltFn = makeFnDecl(tupleName + "Lt", ["a", "b"], [tupleName, tupleName], makeBlock(buf, loc), "", "boolean", loc);
	setHookParamType(tltFn, 0, t);
	setHookParamType(tltFn, 1, t);
	markGeneratedOp(tltFn, tupleName + "Lt");
	lctx.collector.push(tltFn);
}

// Generate lexicographic <= for tuples.
// Reference: proc `<=`*[T: tuple](x, y: T): bool =
//        for a, b in fields(x, y):
//          var c = cmp(a, b)
//          if c < 0: return true
//          if c > 0: return false
//        return true    <-- only difference from <
function generateTupleLe(tupleName: string, t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const buf: Node[] = [];
	let i = 0;
	while (i < t.typeChildren.length) {
		const aField = tupleField(makeIdent("a", loc), i, loc);
		const bField = tupleField(makeIdent("b", loc), i, loc);
		buf.push(makeIf(makeBinary(aField, "<", bField, loc), makeBlock([makeReturn(makeBool(true, loc), loc)], loc), makeNull(loc), loc));
		const aField2 = tupleField(makeIdent("a", loc), i, loc);
		const bField2 = tupleField(makeIdent("b", loc), i, loc);
		buf.push(makeIf(makeBinary(aField2, ">", bField2, loc), makeBlock([makeReturn(makeBool(false, loc), loc)], loc), makeNull(loc), loc));
		i += 1;
	}
	buf.push(makeReturn(makeBool(true, loc), loc));  // <= returns true when equal
	const tleFn = makeFnDecl(tupleName + "Le", ["a", "b"], [tupleName, tupleName], makeBlock(buf, loc), "", "boolean", loc);
	setHookParamType(tleFn, 0, t);
	setHookParamType(tleFn, 1, t);
	markGeneratedOp(tleFn, tupleName + "Le");
	lctx.collector.push(tleFn);
}

// ===== Standalone Array Lifecycle Hooks (reference parity: reference sequence op) =====

function generateArrayHook(hook: string, seqName: string, elemType: Type, arrayType: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const buf = newBuf();
	const isUnary = hook === "destroy" || hook === "wasMoved";
	const p1 = isUnary ? "self" : "dest";
	const p2 = isUnary ? "self" : "src";

	if (hook === "destroy") {
		const selfNode = makeIdent(p1, loc);
		selfNode.nodeType = arrayType;
		arrayOp(hook, elemType, selfNode, selfNode, lctx, buf, loc);
	} else if (hook === "wasMoved") {
		const d1 = makeHiddenDeref(makeIdent(p1, loc), loc);
		d1.nodeType = arrayType;
		arrayOp(hook, elemType, d1, d1, lctx, buf, loc);
	} else if (hook === "copy") {
		const destNode = makeHiddenDeref(makeIdent(p1, loc), loc);
		destNode.nodeType = arrayType;
		const srcNode = makeIdent(p2, loc);
		srcNode.nodeType = arrayType;
		const selfCheck = makeIf(
			makeBinary(
				makeMember(clonePath(destNode, loc), "p", loc),
				"===",
				makeMember(clonePath(srcNode, loc), "p", loc),
				loc
			),
			makeBlock([makeReturn(null as unknown as Node, loc)], loc),
			null as unknown as Node,
			loc
		);
		buf.items.push(selfCheck);
		arrayOp(hook, elemType, destNode, srcNode, lctx, buf, loc);
	} else {
		const destNode = makeHiddenDeref(makeIdent(p1, loc), loc);
		destNode.nodeType = arrayType;
		const srcNode = makeIdent(p2, loc);
		srcNode.nodeType = arrayType;
		arrayOp(hook, elemType, destNode, srcNode, lctx, buf, loc);
	}

	const suffix = hookSuffix(hook);

	let fnNode: Node = null as unknown as Node;
	if (isUnary) {
		fnNode = makeFnDecl(seqName + suffix, [p1], [seqName], makeBlock(buf.items, loc), "", "void", loc);
	} else {
		fnNode = makeFnDecl(seqName + suffix, [p1, p2], [seqName, seqName], makeBlock(buf.items, loc), "", "void", loc);
	}

	// Set param types based on hook kind.
	// Arrays are 16 bytes < pointer introduction threshold, so markPointerParams won't handle them.
	// destroy: by-value (no Ptr wrap)
	// wasMoved: by-pointer (Ptr wrap)
	// copy/sink: dest by-pointer, src by-value
	if (fnNode.nodeType !== null && fnNode.nodeType.typeChildren !== null) {
		if (hook === "destroy") {
			let pi = 0;
			while (pi < fnNode.nodeType.typeChildren.length) {
				fnNode.nodeType.typeChildren[pi] = arrayType;
				pi += 1;
			}
		} else if (hook === "wasMoved") {
			fnNode.nodeType.typeChildren[0] = createPtr(arrayType);
		} else {
			// copy/sink: dest → Ptr<Array>, src stays arrayType
			fnNode.nodeType.typeChildren[0] = createPtr(arrayType);
			if (fnNode.nodeType.typeChildren.length > 1) {
				fnNode.nodeType.typeChildren[1] = arrayType;
			}
		}
	}
	markGeneratedOp(fnNode, seqName + suffix);
	if (fnNode.resolvedSym !== null && fnNode.resolvedSym.symbolType !== null) {
		const symType = fnNode.resolvedSym.symbolType;
		if (symType.typeChildren !== null) {
			if (hook === "destroy") {
				let pi = 0;
				while (pi < symType.typeChildren.length) {
					symType.typeChildren[pi] = arrayType;
					pi += 1;
				}
			} else if (hook === "wasMoved") {
				symType.typeChildren[0] = createPtr(arrayType);
			} else {
				symType.typeChildren[0] = createPtr(arrayType);
				if (symType.typeChildren.length > 1) {
					symType.typeChildren[1] = arrayType;
				}
			}
		}
	}

	lctx.collector.push(fnNode);
}

function generateArrayHooks(lctx: LiftCtx, loc: SourceLocation): void {
	if (nameSetContains(lctx.neededSeqHooks, "msStringArray") && !nameSetContains(lctx.generated, "msStringArray") && !isGloballyOwned("msStringArray")) {
		nameSetAdd(lctx.generated, "msStringArray");
		claimGlobal("msStringArray");
		const strElemType = stringType();
		const strArrayType = createArray(strElemType);
		generateArrayHook("destroy", "msStringArray", strElemType, strArrayType, lctx, loc);
		generateArrayHook("copy", "msStringArray", strElemType, strArrayType, lctx, loc);
		generateArrayHook("sink", "msStringArray", strElemType, strArrayType, lctx, loc);
		generateArrayHook("wasMoved", "msStringArray", strElemType, strArrayType, lctx, loc);
	}

	if (nameSetContains(lctx.neededSeqHooks, "msRefArray") && !nameSetContains(lctx.generated, "msRefArray") && !isGloballyOwned("msRefArray")) {
		nameSetAdd(lctx.generated, "msRefArray");
		claimGlobal("msRefArray");
		const refElemType = createPrimitive(TypeKind.Ref);
		const refArrayType = createArray(refElemType);
		generateArrayHook("destroy", "msRefArray", refElemType, refArrayType, lctx, loc);
		generateArrayHook("copy", "msRefArray", refElemType, refArrayType, lctx, loc);
		generateArrayHook("sink", "msRefArray", refElemType, refArrayType, lctx, loc);
		generateArrayHook("wasMoved", "msRefArray", refElemType, refArrayType, lctx, loc);
	}

	// Per-type value struct element arrays (reference parity: each sequence gets its own hooks)
	for (const entry of lctx.seqElemTypes) {
		if (!nameSetContains(lctx.generated, entry.name) && !isGloballyOwned(entry.name)) {
			nameSetAdd(lctx.generated, entry.name);
			claimGlobal(entry.name);
			const arrType = createArray(entry.elemType);
			generateArrayHook("destroy", entry.name, entry.elemType, arrType, lctx, loc);
			generateArrayHook("copy", entry.name, entry.elemType, arrType, lctx, loc);
			generateArrayHook("sink", entry.name, entry.elemType, arrType, lctx, loc);
			generateArrayHook("wasMoved", entry.name, entry.elemType, arrType, lctx, loc);
		}
	}
}

// ===== Scan for Array Types =====

function scanTypeForArrays(t: Type, lctx: LiftCtx, visited: NameSet): void {
	if (t === null) return;
	if (t.typeName !== "" && nameSetContains(visited, t.typeName)) return;
	if (t.typeName !== "") nameSetAdd(visited, t.typeName);
	if (t.kind === TypeKind.Array) {
		const elem = t.typeReturn;
		if (elem !== null && !isPrimitiveKind(elem.kind)) {
			// Unwrap GenericInstance to its mangled struct body so the per-type
			// <Name>ArrayDestroy walker name matches arrayOp + codegen (else a generic
			// struct element array misregisters as msRefArray → undeclared walker).
			let elemResolved = elem;
			if (elem.kind === TypeKind.GenericInstance) {
				const unwrapped = unwrapGenericInstance(elem);
				if (unwrapped.mangledName !== "") elemResolved = unwrapped.body;
			}
			registerSeqElement(elemResolved, lctx);
		}
		return;
	}
	if (t.typeChildren !== null) {
		for (const child of t.typeChildren) {
			scanTypeForArrays(child, lctx, visited);
		}
	}
	if (t.typeReturn !== null) {
		scanTypeForArrays(t.typeReturn, lctx, visited);
	}
}

function scanStmtForArrayTypes(stmt: Node, lctx: LiftCtx): void {
	if (stmt === null) return;
	const visited: NameSet = createNameSet();
	match (stmt.kind) {
		NodeKind.VariableDecl => {
			if (stmt.nodeType !== null) scanTypeForArrays(stmt.nodeType, lctx, visited);
		},
		NodeKind.FunctionDecl => {
			if (stmt.nodeType !== null) scanTypeForArrays(stmt.nodeType, lctx, visited);
			// Recurse into function body to find local array types
			const fd = stmt.data as FunctionDeclData;
			if (fd.fnBody !== null) scanBlockForArrayTypes(fd.fnBody, lctx);
		},
		NodeKind.ExportDecl => {
			const ed = stmt.data as ExportDeclData;
			scanStmtForArrayTypes(ed.exportedDecl, lctx);
		},
		_ => {},
	};
}

// Recurse into blocks to find local variable declarations with array types.
// Intentional divergence from reference (which is demand-driven). Our
// architecture requires pre-registration of array hooks before codegen.
//
// Walks into control-flow constructs (while/if/for/try) — their bodies are
// BlockStmt but the OUTER statement isn't, so a flat BlockStmt-only check
// misses them. A loop-local `const xs: Foo[] = []` would otherwise skip
// hook registration → undefined ArrayDestroy at link.
function scanBlockForArrayTypes(block: Node, lctx: LiftCtx): void {
	if (block === null || block.kind !== NodeKind.BlockStmt) return;
	const bd = block.data as BlockStmtData;
	for (const s of bd.statements) {
		scanCtrlFlowForArrayTypes(s, lctx);
	}
}

function scanCtrlFlowForArrayTypes(s: Node, lctx: LiftCtx): void {
	if (s === null) return;
	const visited: NameSet = createNameSet();
	match (s.kind) {
		NodeKind.VariableDecl => {
			if (s.nodeType !== null) scanTypeForArrays(s.nodeType, lctx, visited);
		},
		NodeKind.FunctionDecl => { scanStmtForArrayTypes(s, lctx); },
		NodeKind.BlockStmt => { scanBlockForArrayTypes(s, lctx); },
		NodeKind.WhileStmt => {
			const wd = s.data as WhileStmtData;
			scanBlockForArrayTypes(wd.whileBody, lctx);
		},
		NodeKind.DoWhileStmt => {
			const dd = s.data as DoWhileStmtData;
			scanBlockForArrayTypes(dd.doBody, lctx);
		},
		NodeKind.IfStmt => {
			const id = s.data as IfStmtData;
			scanBlockForArrayTypes(id.consequent, lctx);
			if (id.alternate !== null) scanCtrlFlowForArrayTypes(id.alternate, lctx);
		},
		NodeKind.ForStmt => {
			const fd = s.data as ForStmtData;
			scanBlockForArrayTypes(fd.forBody, lctx);
		},
		NodeKind.ForOfStmt => {
			const fo = s.data as ForOfStmtData;
			scanBlockForArrayTypes(fo.forOfBody, lctx);
		},
		NodeKind.TryCatchStmt => {
			const td = s.data as TryCatchStmtData;
			scanBlockForArrayTypes(td.tryBody, lctx);
			if (td.catchBody !== null) scanBlockForArrayTypes(td.catchBody, lctx);
			if (td.finallyBody !== null) scanBlockForArrayTypes(td.finallyBody, lctx);
		},
		NodeKind.SwitchStmt => {
			const sd = s.data as SwitchStmtData;
			for (const c of sd.switchCases) {
				const cd = c.data as SwitchCaseData;
				for (const cs of cd.caseStmts) scanCtrlFlowForArrayTypes(cs, lctx);
			}
		},
		_ => {},
	};
}

// ===== Anonymous Struct Type Scanning =====

// Walk the AST to find anonymous struct types (typeName starts with "__anon").
// These have no InterfaceDecl so processDecl doesn't see them.
// Ensures lifecycle hooks are generated so DRC destroy calls link correctly.
function scanForAnonStructTypes(program: Node, lctx: LiftCtx, loc: SourceLocation): void {
	// Walk entire AST; ensure lifecycle hooks for ANY named struct that needs them.
	// Covers anonymous structs (__anon*), programmatically-created structs
	// (e.g. IteratorResult from createIterator), monomorphized class types
	// (HashMap<K,V>, HashSet<K>), and any other type without a declared AST node.
	walkNode(program, (node: Node): Node => {
		if (node.nodeType !== null) {
			// Consumer path — emitTypeInfo=false so we don't duplicate TypeInfo
			// with the defining module's emission or codegen's ensureTypeInfoDef.
			//
			// Skip match-type variant structs (typeName like "Alias.Key") — their
			// hooks are emitted via the parent Union's `<Union>_v<N>` helper
			// dispatch, not as standalone `<Alias.Key>Copy` (which would be an
			// invalid C identifier anyway).
			if (node.nodeType.kind === TypeKind.Struct && node.nodeType.typeName !== ""
				&& node.nodeType.typeName.indexOf(".") < 0) {
				ensureHooks(node.nodeType.typeName, node.nodeType, null as unknown as Type, false, lctx, node.location);
			} else if (node.nodeType.kind === TypeKind.Ref && node.nodeType.typeReturn !== null
				&& node.nodeType.typeReturn.kind === TypeKind.Struct && node.nodeType.typeReturn.typeName !== "") {
				// Monomorphized class/interface: unwrap Ref, pass Ref as refType for HiddenDeref.
				ensureHooks(node.nodeType.typeReturn.typeName, node.nodeType.typeReturn, node.nodeType, false, lctx, node.location);
			} else if (node.nodeType.kind === TypeKind.GenericInstance) {
				// Generic struct/class instance — unwrap to concrete Struct body with mangled
				// typeName so hook signatures match codegen's struct emission (types.ms:582-620).
				const unwrapped = unwrapGenericInstance(node.nodeType);
				if (unwrapped.mangledName !== "") {
					ensureHooks(unwrapped.mangledName, unwrapped.body, null as unknown as Type, false, lctx, node.location);
				}
			} else if (node.nodeType.kind === TypeKind.Ref && node.nodeType.typeReturn !== null
				&& node.nodeType.typeReturn.kind === TypeKind.GenericInstance) {
				// Ref<GenericInstance> — class/interface of generic (e.g. Ref<Map<K,V>>).
				const unwrapped = unwrapGenericInstance(node.nodeType.typeReturn);
				if (unwrapped.mangledName !== "") {
					ensureHooks(unwrapped.mangledName, unwrapped.body, node.nodeType, false, lctx, node.location);
				}
			}
			// Array element hooks for any array used anywhere, including expression
			// position (literals, call args, returns). The decl-only scanStmtForArrayTypes
			// misses those, leaving a boxed T[]'s per-type <Name>ArrayDestroy walker
			// unemitted → undefined symbol once codegen references it.
			if (node.nodeType.kind === TypeKind.Array
				|| (node.nodeType.kind === TypeKind.Ref && node.nodeType.typeReturn !== null
					&& node.nodeType.typeReturn.kind === TypeKind.Array)) {
				const arrVisited: NameSet = createNameSet();
				scanTypeForArrays(node.nodeType, lctx, arrVisited);
			}
			// A bare tuple local (reassigned or dropped) needs the same named hooks, but
			// fillBody only emits them for tuples that appear as a struct field — pre-register
			// here so classify.ms's msTuple_<hash>{Destroy,Sink} reference isn't undefined.
			if (node.nodeType.kind === TypeKind.Tuple) {
				ensureTupleHooks(tupleTypeName(node.nodeType), node.nodeType, lctx, node.location);
			}
		}
		return node;
	});
}

// ===== Process Declarations =====

// Look up the declared type's sym and dispatch to `ensureHooks`. Pulled out of
// processDecl's match arms so all three decl kinds share one resolve+dispatch.
// processDecl is the DEFINING-module path — passes emitTypeInfo=true.
function ensureHooksByName(typeName: string, lctx: LiftCtx, loc: SourceLocation): void {
	if (typeName === "") return;
	if (lctx.checkerCtx === null) return;
	const sym = lookupSymbol(lctx.checkerCtx.table, typeName);
	if (sym !== null && sym.symbolType !== null) {
		// TypeAlias-to-Ref: ensureHooks' category resolver handles it (same skip path).
		const objType = unwrapRef(sym.symbolType);
		if (objType === null) return;
		const refType = (sym.symbolKind === SymbolKind.Class || sym.symbolKind === SymbolKind.Interface)
			? sym.symbolType
			: null as unknown as Type;
		ensureHooks(typeName, objType, refType, true, lctx, loc);
		return;
	}
	// Sym not in checker table. This happens for lambda-lifting synthesized
	// InterfaceDecls (env structs, typeName starts with "dollarEnv_") —
	// transform pass synthesizes the decl AST node but doesn't register the
	// symbol. Dispatch to ensureHooks' naming-convention fallback. Need objType
	// from the InterfaceDecl's nodeType — caller is processDecl which already
	// has the node, but we don't get it here. Use ensureHooks with a minimal
	// placeholder — the naming-convention branch inside `ensureHooks` will
	// short-circuit if it can't infer the type.
	//
	// Rather than plumb node through, fall through: scanForAnonStructTypes
	// will visit references to this env type anyway (via Ref<Env> nodeType)
	// and emit correctly via its Ref branch.
}

function processDecl(stmt: Node, lctx: LiftCtx): void {
	match (stmt.kind) {
		NodeKind.InterfaceDecl | NodeKind.StructDecl => {
			const d = stmt.data as InterfaceDeclData;
			ensureHooksByName(d.interfaceName, lctx, stmt.location);
		},
		NodeKind.ClassDecl => {
			const d = stmt.data as ClassDeclData;
			ensureHooksByName(d.className, lctx, stmt.location);
		},
		NodeKind.TypeAliasDecl => {
			const d = stmt.data as TypeAliasDeclData;
			ensureHooksByName(d.aliasName, lctx, stmt.location);
		},
		NodeKind.ExportDecl => {
			const ed = stmt.data as ExportDeclData;
			processDecl(ed.exportedDecl, lctx);
		},
		_ => {},
	};
}

// ===== Main Entry Point =====

export function liftDestructors(program: Node, ctx: TransformContext): Node {
	if (ctx.checkerCtx === null) return program;

	const pd = program.data as ProgramData;
	const lctx: LiftCtx = {
		checkerCtx: ctx.checkerCtx,
		tempCounter: ctx.tempCounter,
		generated: createNameSet(),
		generating: createNameSet(),
		collector: [],
		cyclicCache: createNameSet(),
		nonCyclicCache: createNameSet(),
		neededSeqHooks: createNameSet(),
		seqElemTypes: [],
	};

	for (const stmt of pd.programStmts) {
		processDecl(stmt, lctx);
	}

	// Scan for anonymous struct types (from ObjectLiterals with no declaration).
	// These have typeName like "__anon..." set by the checker but no InterfaceDecl.
	const defaultLoc2 = makeLoc(0, 0);
	scanForAnonStructTypes(program, lctx, defaultLoc2);

	// Scan for standalone array type usage
	for (const stmt of pd.programStmts) {
		scanStmtForArrayTypes(stmt, lctx);
	}

	const defaultLoc = makeLoc(0, 0);
	generateArrayHooks(lctx, defaultLoc);

	// Process pending tuple comparison ops (collected by operatorLower).
	// reference parity: reference core:1973 (==), :1980 (<=), :1989 (<) for tuples.
	for (const pending of ctx.pendingTupleOps) {
		for (const op of pending.ops) {
			const key = pending.tupleName + op;
			if (nameSetContains(lctx.generated, key)) continue;
			if (isGloballyOwned(key)) continue;
			nameSetAdd(lctx.generated, key);
			claimGlobal(key);
			match (op) {
				"Eq" => { generateTupleEq(pending.tupleName, pending.tupleType, lctx, defaultLoc); },
				"Lt" => { generateTupleLt(pending.tupleName, pending.tupleType, lctx, defaultLoc); },
				"Le" => { generateTupleLe(pending.tupleName, pending.tupleType, lctx, defaultLoc); },
				_ => {},
			};
		}
	}

	// Lift Eq only for structs actually compared (collected by operatorLower); ensureEq is
	// idempotent and recurses into nested struct fields via fieldEqExpr.
	for (const structName of ctx.pendingStructEqs) {
		ensureEq(structName, lctx, defaultLoc);
	}

	for (const decl of lctx.collector) {
		pd.programStmts.push(decl);
	}

	return program;
}

// ===== Tests =====

function liftWithChecker(input: string): Node {
	// Reset global registries for isolated test runs (both hooks + TypeInfo,
	// matching setGlobalHookOwners so cross-test state doesn't leak).
	_globalHookOwners = createNameSet();
	_globalTypeInfoOwners = createNameSet();
	const pr = parseInput(input);
	if (!pr.ok) return pr.value;
	const checkerCtx = checkProgram(pr.value);
	const ctx = createTransformContextWithChecker(checkerCtx);
	return liftDestructors(pr.value, ctx);
}


// Count generated lifecycle hook functions (5 base + optional trace)
function generatedFnCount(input: string): number {
	const prog = liftWithChecker(input);
	const pd = prog.data as ProgramData;
	let count = 0;
	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.FunctionDecl) {
			const d = stmt.data as FunctionDeclData;
			if (d.fnName.endsWith("Destroy")
				|| d.fnName.endsWith("Copy")
				|| d.fnName.endsWith("Sink")
				|| d.fnName.endsWith("WasMoved")
				|| d.fnName.endsWith("Dup")
				|| d.fnName.endsWith("Trace")) {
				count += 1;
			}
		}
	}
	return count;
}

// Run the full lower→lift pipeline so `===` in the source drives on-demand Eq generation.
function liftWithCompare(input: string): Node {
	_globalHookOwners = createNameSet();
	_globalTypeInfoOwners = createNameSet();
	const pr = parseInput(input);
	if (!pr.ok) return pr.value;
	const checkerCtx = checkProgram(pr.value);
	const ctx = createTransformContextWithChecker(checkerCtx);
	const lowered = lowerOperators(pr.value, ctx);
	return liftDestructors(lowered, ctx);
}

function hasGeneratedFnIn(prog: Node, fnSuffix: string): boolean {
	const pd = prog.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.FunctionDecl) {
			const d = stmt.data as FunctionDeclData;
			if (d.fnName.endsWith(fnSuffix)) return true;
		}
	}
	return false;
}

// Check if a specific named function was generated
function hasGeneratedFn(input: string, fnSuffix: string): boolean {
	return hasGeneratedFnIn(liftWithChecker(input), fnSuffix);
}

// Check if a TypeInfo variable was generated
function hasTypeInfo(input: string, typeName: string): boolean {
	const prog = liftWithChecker(input);
	const pd = prog.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.VariableDecl) {
			const d = stmt.data as VariableDeclData;
			if (d.declName === typeName + "TypeInfo") return true;
		}
	}
	return false;
}

test "primitive-only no hooks" { assert generatedFnCount("interface Point { x: number; y: number; }") === 0; }

test "string field generates 5 hooks" { assert generatedFnCount("interface Token { value: string; }") === 5; }

// items is now Ref<Array> — cyclic-capable → Data gets _trace (6 hooks instead of 5)
test "array field generates 6 hooks" { assert generatedFnCount("interface Data { items: number[]; }") === 6; }

// Interface is now Ref type — B.a is Ref<A>, which is cyclic-capable → B gets _trace (6 hooks instead of 5)
test "nested interface generates 11 hooks" { assert generatedFnCount("interface A { name: string; } interface B { a: A; }") === 11; }

// B has Ref<A> fields → cyclic-capable → gets _trace (11 = 5 for A + 6 for B)
test "no duplicates" { assert generatedFnCount("interface A { name: string; } interface B { a1: A; a2: A; }") === 11; }

test "exported interface" { assert generatedFnCount("export interface Token { value: string; }") === 5; }

test "no interfaces passthrough" { assert generatedFnCount("const x = 1;") === 0; }
// =trace: Function fields are cyclic (closures capture refs)
test "trace NOT generated for flat string" { assert !hasGeneratedFn("interface Token { value: string; }", "TokenTrace"); }
// TypeInfo generated alongside hooks
test "typeInfo generated" { assert hasTypeInfo("interface Token { value: string; }", "Token"); }

// Interface is now Ref type — always needs typeInfo for msAllocTyped (even primitive-only)
test "typeInfo generated for primitive-only interface" { assert hasTypeInfo("interface Point { x: number; y: number; }", "Point"); }
// Struct (value type) with only primitives does NOT need typeInfo
test "typeInfo NOT generated for primitive-only struct" { assert !hasTypeInfo("struct Point { x: number; y: number; }", "Point"); }
// Inheritance: child with own hookable field + base both generate hooks
test "inheritance generates parent hooks" {
	const src = "interface Base { name: string; } class Child extends Base { extra: string; }";
	assert hasGeneratedFn(src, "BaseDestroy");
}
// All 5 core hooks present for a hookable type
test "all core hooks generated" {
	const src = "interface Wrap { data: string; }";
	assert hasGeneratedFn(src, "Destroy");
	assert hasGeneratedFn(src, "Copy");
	assert hasGeneratedFn(src, "Sink");
	assert hasGeneratedFn(src, "WasMoved");
	assert hasGeneratedFn(src, "Dup");
}

// Auto-generated == is lifted on-demand — only for value structs actually compared.
test "eq NOT generated for uncompared struct" {
	assert !hasGeneratedFn("struct Point { x: number; y: number; }", "PointEq");
}

test "eq generated on-demand for compared struct" {
	const src = "struct Point { x: number; y: number; } function f(a: Point, b: Point): boolean { return a === b; }";
	assert hasGeneratedFnIn(liftWithCompare(src), "PointEq");
}

test "eq transitive to nested struct field when outer compared" {
	const src = "struct Inner { a: number; } struct Outer { i: Inner; } function f(a: Outer, b: Outer): boolean { return a === b; }";
	assert hasGeneratedFnIn(liftWithCompare(src), "OuterEq");
	assert hasGeneratedFnIn(liftWithCompare(src), "InnerEq");
}

// Interfaces are reference types — `===` is pointer equality, no structural Eq is lifted.
test "eq NOT generated for interface" {
	assert !hasGeneratedFn("interface Token { value: string; }", "TokenEq");
}

test "eq NOT generated for class" {
	assert !hasGeneratedFn("class Obj { x: number; }", "ObjEq");
}
