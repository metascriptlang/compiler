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
// Generates up to 6 hooks per type:
//   =destroy   TypeName_destroy(self)            — cleanup RC fields
//   =copy      TypeName_copy(dest, src)          — deep copy (assign + incref)
//   =sink      TypeName_sink(dest, src)          — move (transfer ownership)
//   =wasMoved  TypeName_wasMoved(self)           — zero RC handles after move
//   =dup       TypeName_dup(src): TypeName       — clone (init + copy, return)
//   =trace     TypeName_trace(self, callback)    — ORC cycle tracing (cyclic types only)

import { Node, NodeKind, DeclKind, ProgramData, FunctionDeclData, SourceLocation, makeLoc, InterfaceDeclData, ClassDeclData, ExportDeclData, VariableDeclData, TypeAliasDeclData, IdentifierData, MemberExprData, ArrayAccessData, HiddenDerefData, BlockStmtData, WhileStmtData, DoWhileStmtData, IfStmtData, BinaryExprData, ForStmtData, ForOfStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, Type, TypeKind, TypeFlag, AttachedOp, Symbol, SymbolKind, SymbolState } from "../../ast/node";
import { TransformContext, NameSet, nameSetContains, nameSetAdd, createNameSet, createTransformContext } from "../context";
import { attachedOpSym, isRuntimeProcSym, makeIdent, makeIdentResolved, makeTypedIdentResolved, makeTypedIdent, makeBlock, makeExprStmt, makeCall, makeMember, makeAssign, makeFnDecl, makeVarDecl, makeReturn, makeIf, makeBinary, makeUnary, makeNull, makeString, makeBool, makeNumber, makeObjectLiteral, makeHiddenAddr, makeHiddenDeref, makeHiddenSubConv, makeWhile, makeArrayAccess, runtimeRef } from "../util";
import { peelTransparentInstance, distinctBody, isPrimitiveKind, isNumeric, isPrimitiveUnionMember, setAttachedOp, unwrapRef, unwrapRefNullUnion, hasAsgnFlag, isAllStringLiteralUnion, createArray, createPtr, createVar, createPrimitive, createRef, stringType, isStringLike, createStruct, createUnion, isStructType, isAwaitable, isAtomicRef, instantiateGenericBody, instantiatedBodyCount, inlineVariantStruct, tupleTypeName, typeNameOf, voidType, hasGenericParams, isTagCarriedUnion, isMaybeType, unwrapMaybeType, numberType, arrayElementNeedsCleanup, isUncountedPtrElement, setRepr } from "../../checker/types";
import { hasTypeIdentity } from "../../checker/types";
import { spelled } from "../../checker/types";
import { anonTypeName, isAnonTypeName, arrayCTypeName, refArrayCellName, hookBaseCName, resetHookSyms, anonUnionCName, setOpByKey, aliasOpByKey, requireOpByKey, getOpByKey, opPrototype, bindOpByKey, arrayOpElement, isRuntimeArrayFamily } from "../../codegen/c/types";
import { liftedOp } from "../../codegen/c/types";
import { opKey, opTypeKey, hasLiftedOp } from "../../codegen/c/types";
import { genericParamsOf } from "../../checker/types";
import { monoInstanceName } from "../../monomorphize/registry";
import { lookupInstanceHook, pickBodyCtx } from "../../checker/instantiate";
import { walkNode } from "../walker";
import { canFormAcycle } from "../cycles";
import { lookupSymbol, makeSymbol, setFlag, SymbolFlag } from "../../checker/symbol";
import { CheckerContext, newSym, extReceiverSym, findAllExtensionsByName, hasExtensionByName, getExtFnType, addError } from "../../checker/context";
import { checkProgram } from "../../checker/checkPass";
import { parseInput, checkedCtx } from "../testUtil";
import { lowerOperators } from "./operatorLower";
import { sizedArrayHookName } from "../../analyzer/classify";

export function resetLiftedOps(): void {
	resetHookSyms();
}

// ===== Lift Context (reference TLiftCtx) =====

class LiftCtx {
	checkerCtx: CheckerContext;  // borrowed — do NOT store full TransformContext (causes double-free)
	tempCounter: number;
	generated: NameSet;    // fully generated types (dedup)
	trivial: NameSet;
	generating: NameSet;   // currently generating (cycle guard)
	helperOps: HashMap<string, Symbol>;
	collector: Node[];
	cyclicCache: NameSet;     // types confirmed cyclic
	nonCyclicCache: NameSet;  // types confirmed non-cyclic
	seqTypes: Type[];
	refCellTraces: Type[];
	scannedTypes: HashSet<Type>;
	arrayRootEpochs: HashMap<Type, int32>;
	refusedArrayElems: HashSet<Type>;
	jsBackend: boolean;
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

// A hook's base name is the C type name codegen emits for the same type. The
// ownership registries dedup on that base, so a base less specific than the
// emitted symbol makes the second declaring module skip hooks it still needs.
function hookCName(typeName: string, t: Type | null, lctx: LiftCtx): string {
	return hookBaseCName(typeName, t, lctx.checkerCtx);
}

// Reference parity: only types that completed hook generation have hooks.
// Check both local (this module) and global (any module) registries.
// Struct/Union fields can't form direct cycles (infinite size), so cycles always go through
// Ref/Ptr which has its own handler in fillBody. Safe to check only `generated`.
function namedTypeHasHooks(t: Type, lctx: LiftCtx): boolean {
	return nameSetContains(lctx.generated, opTypeKey(t)) || hasLiftedOp(t, AttachedOp.AttachedDestructor);
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
	if (gi == null || gi.kind != TypeKind.GenericInstance) {
		return { mangledName: "", body: null as unknown as Type };
	}
	if (isAwaitable(gi) || peelTransparentInstance(gi) != gi) {
		return { mangledName: "", body: null as unknown as Type };
	}
	// Lazy-instantiate body when encountering nested generics. Outer instantiation
	// (instantiateGenericBody at checker types.ms:787) substitutes K/V → concrete types
	// in the containing struct's fields, but doesn't recursively populate `typeReturn`
	// on inner GIs. Codegen does the same lazy pattern at types.ms:601 via genericParamsOf.
	if (gi.typeReturn == null) {
		const decl = genericParamsOf(gi);
		if (decl != "") instantiateGenericBody(gi, decl);
	}
	if (gi.typeReturn == null) {
		return { mangledName: "", body: null as unknown as Type };
	}
	const mangledName = monoInstanceName(gi);
	const src = gi.typeReturn;
	// Preserve src kind: Union bodies (match-type / TS-style DU) must NOT be
	// wrapped as Struct — `generateHook` dispatches on `objType.kind` to route
	// Unions through `generateUnionArms` (per-variant tag dispatch). Coercing
	// to Struct here makes the hook walk `typeNames` (discriminator metadata)
	// as if they were field names, emitting bogus `dest.ok = src.ok` accesses.
	let body: Type;
	if (src.kind == TypeKind.Union) {
		body = createUnion(src.typeChildren);
		body.typeName = mangledName;
		body.typeNames = src.typeNames;
		body.typeExtra = src.typeExtra;
		body.typeFlags = src.typeFlags;
		spelled(body);
	} else {
		body = spelled(createStruct(mangledName, src.typeNames, src.typeChildren, isStructType(src)));
	}
	return { mangledName, body };
}

// ===== Cycle Detection (reference cyclicType) =====
// Determines if a type can form reference cycles (needed for =trace hook).

function isCyclicType(t: Type, lctx: LiftCtx, visited: NameSet): boolean {
	return canFormAcycle(t, lctx.cyclicCache, lctx.nonCyclicCache);
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
function liftOp(fnNode: Node, t: Type, orig: Type, op: AttachedOp, name: string): Symbol {
	if (orig != t && getOpByKey(t, op) == null) {
		const proto = getOpByKey(orig, op);
		if (proto != null) bindOpByKey(t, op, proto);
	}
	const sym = liftedOp(t, op, name, fnNode.nodeType);
	sym.state = SymbolState.Checked;
	fnNode.resolvedSym = sym;
	return sym;
}

function liftHelperOp(fnNode: Node, name: string, hook: string, lctx: LiftCtx): Symbol {
	const sym = makeSymbol(name, SymbolKind.Function, fnNode.nodeType, false);
	setFlag(sym, SymbolFlag.GeneratedOp);
	if (hook == "destroy") setFlag(sym, SymbolFlag.DestroyOp);
	else if (hook == "wasMoved") setFlag(sym, SymbolFlag.WasMovedOp);
	fnNode.resolvedSym = sym;
	lctx.helperOps.set(name, sym);
	return sym;
}

function aliasLiftedOps(orig: Type, canon: Type): void {
	if (orig == canon) return;
	aliasOpByKey(orig, canon, AttachedOp.AttachedDestructor);
	aliasOpByKey(orig, canon, AttachedOp.AttachedAsgn);
	aliasOpByKey(orig, canon, AttachedOp.AttachedSink);
	aliasOpByKey(orig, canon, AttachedOp.AttachedWasMoved);
	aliasOpByKey(orig, canon, AttachedOp.AttachedTrace);
	aliasOpByKey(orig, canon, AttachedOp.AttachedDup);
}


// Set hook function param/return types to concrete Types.
// Reference parity: symPrototype sets dest.typ/src.typ directly, never string names.
// We set each param individually because makeFnDecl can't resolve named struct types.
function setHookParamType(fnNode: Node, index: number, t: Type): void {
	if (fnNode.nodeType != null && fnNode.nodeType.typeChildren != null
		&& index < fnNode.nodeType.typeChildren.length) {
		fnNode.nodeType.typeChildren[index] = t;
	}
}

function setHookReturnType(fnNode: Node, t: Type): void {
	if (fnNode.nodeType != null) {
		fnNode.nodeType.typeReturn = t;
	}
}

// ===== Reference defaultOp =====
// Primitives: copy/sink => assign, destroy => no-op, wasMoved => zero the field

function defaultOp(hook: string, x: Node, y: Node, buf: NodeBuf, loc: SourceLocation): void {
	if (hook == "copy" || hook == "sink") {
		buf.items.push(makeExprStmt(makeAssign(x, y, loc), loc));
	} else if (hook == "wasMoved") {
		genCall("msPlainWasMoved", hook, x, y, buf, loc);
	}
}

// ===== Node Path Cloning (reference parity: field access creates fresh trees) =====
// Deep-copies MemberExpr/Identifier chains so markPointerParams won't double-wrap shared refs.

function clonePath(node: Node, loc: SourceLocation): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		if (node.resolvedSym == null) {
			throw new Error(`internal: hook body generation reached identifier '${d.name}' without its symbol`);
		}
		return makeTypedIdentResolved(node.resolvedSym, node.nodeType, loc);
	}
	if (node.kind == NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		const r = makeMember(clonePath(d.object, loc), d.property, loc);
		r.nodeType = node.nodeType;
		return r;
	}
	// reference parity: array access always creates fresh nodes
	if (node.kind == NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		const r = makeArrayAccess(clonePath(d.array, loc), clonePath(d.index, loc), loc);
		r.nodeType = node.nodeType;
		return r;
	}
	if (node.kind == NodeKind.HiddenDeref) {
		const d = node.data as HiddenDerefData;
		const r = makeHiddenDeref(clonePath(d.expr, loc), loc);
		r.nodeType = node.nodeType;
		return r;
	}
	return node;
}

// ===== Emit helpers =====

function attachedOpOf(hook: string): AttachedOp {
	return match (hook) {
		"destroy" => AttachedOp.AttachedDestructor,
		"copy" => AttachedOp.AttachedAsgn,
		"sink" => AttachedOp.AttachedSink,
		"wasMoved" => AttachedOp.AttachedWasMoved,
		_ => AttachedOp.AttachedTrace,
	};
}

// Emit runtime call — unary (destroy/wasMoved) or binary (copy/sink)
function genCall(name: string, hook: string, x: Node, y: Node, buf: NodeBuf, loc: SourceLocation): void {
	genOpCall(attachedOpSym(name, attachedOpOf(hook)), hook, x, y, buf, loc);
}

function genOpCall(sym: Symbol, hook: string, x: Node, y: Node, buf: NodeBuf, loc: SourceLocation): void {
	const callee = makeTypedIdentResolved(sym, null, loc);
	if (hook == "destroy" || hook == "wasMoved") {
		buf.items.push(makeExprStmt(makeCall(callee, [x], loc), loc));
	} else {
		buf.items.push(makeExprStmt(makeCall(callee, [x, y], loc), loc));
	}
}

// Copy-ref pattern: for 2-arg copy functions (msStringCopy), emit =copy(&dest, src) directly.
// For unary incref (msIncref, msClosureCopy), emit incref-new + decref-old + assign.
function genCopyRef(increfFn: string, x: Node, y: Node, fieldName: string, buf: NodeBuf, loc: SourceLocation): void {
	const increfSym = attachedOpSym(increfFn, AttachedOp.AttachedAsgn);
	// Reference parity: msStringCopy is 2-arg =copy(&dest, src) — handles destroy-old internally
	if (isRuntimeProcSym(increfSym, "msStringCopy")) {
		buf.items.push(makeExprStmt(makeCall(runtimeRef("msStringCopy", loc),
			[makeHiddenAddr(clonePath(x, loc), loc), clonePath(y, loc)], loc), loc));
		return;
	}
	// Cyclic refs: Nim attachedAsgn isCyclic order (liftdestructors.nim:768-775) —
	// incref new, assign, decref old last, so a collect triggered by the old value's
	// destroy never traces a dest still pointing at the dying object.
	if (isRuntimeProcSym(increfSym, "msIncrefCyclic")) {
		genCall("msRefCopyCyclic", "copy", clonePath(x, loc), clonePath(y, loc), buf, loc);
		return;
	}
	// Unary incref types: Nim attachedAsgn non-cyclic order (liftdestructors.nim:776-779,
	// bug #15753) — incref new FIRST so an rc==1 alias of dest's old value survives
	// the decref; then decref old, then assign.
	const decrefFn = isRuntimeProcSym(increfSym, "msIncref") ? "msDecref"
		: isRuntimeProcSym(increfSym, "msAtomicIncref") ? "msAtomicDecref"
		: isRuntimeProcSym(increfSym, "msClosureCopy") ? "msClosureDestroy"
		: isRuntimeProcSym(increfSym, "msClosureIncref") ? "msClosureDecref"
		: isRuntimeProcSym(increfSym, "msMapIncref") ? "msMapDecref"
		: "";
	buf.items.push(makeExprStmt(makeCall(makeTypedIdentResolved(increfSym, null, loc), [clonePath(y, loc)], loc), loc));
	if (decrefFn != "") {
		buf.items.push(makeExprStmt(makeCall(runtimeRef(decrefFn, loc), [clonePath(x, loc)], loc), loc));
	}
	buf.items.push(makeExprStmt(makeAssign(clonePath(x, loc), clonePath(y, loc), loc), loc));
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

function liftSym(lctx: LiftCtx, kind: SymbolKind, name: string, t: Type | null, mutable: boolean = false): Symbol {
	if (lctx.checkerCtx == null) throw new Error(`internal: lifted symbol '${name}' has no checker context to mint it from`);
	const sym = newSym(lctx.checkerCtx, kind, name, t);
	if (mutable) setFlag(sym, SymbolFlag.Mutable);
	return sym;
}

function liftTempSym(lctx: LiftCtx, name: string, t: Type | null): Symbol {
	const sym = liftSym(lctx, SymbolKind.Temp, name, t);
	sym.state = SymbolState.Checked;
	return sym;
}

// --- Inline element loop (reference parity: unrolled loops for elements) ---
// Generates: var $i = 0; while ($i < arr.length) { fillBody(elem, arr[$i], ...); $i = $i + 1; }
function genArrayLoop(hook: string, elemType: Type, xf: Node, yf: Node, lctx: LiftCtx, buf: NodeBuf, loc: SourceLocation): void {
	genElementLoop(hook, elemType, null, xf, yf, lctx, buf, loc);
}

function genElementLoop(hook: string, elemType: Type, bound: Node | null, xf: Node, yf: Node, lctx: LiftCtx, buf: NodeBuf, loc: SourceLocation): void {
	const ctr = lctx.tempCounter;
	lctx.tempCounter = ctr + 1;
	const counterName = "$i_" + ctr.toString();
	const counterSym = liftTempSym(lctx, counterName, numberType());
	const counterDecl = makeVarDecl(counterName, makeNumber(0, loc), DeclKind.Let, loc);
	counterDecl.resolvedSym = counterSym;

	// reference parity: set nodeType on result.
	// Set nodeType on cloned array expressions so nativeLower can rewrite arr[i] → msXxxArrayAccess(arr, i).
	const arrType = xf.nodeType;
	const xClone = clonePath(xf, loc);
	if (xClone.nodeType == null && arrType != null) { xClone.nodeType = arrType; }
	const lenAccess = bound != null ? bound : makeMember(clonePath(xf, loc), "length", loc);
	const cond = makeBinary(makeTypedIdentResolved(counterSym, null, loc), "<", lenAccess, loc);

	const xi = makeArrayAccess(xClone, makeTypedIdentResolved(counterSym, null, loc), loc);
	const bodyBuf = newBuf();
	const visited: NameSet = createNameSet();

	if (hook == "trace") {
		// Reference: trace passes raw callback (y), not y[i]
		fillBody(hook, xi, yf, "", elemType, lctx, bodyBuf, visited, loc);
	} else if (hook == "copy" || hook == "sink") {
		const yClone = clonePath(yf, loc);
		if (yClone.nodeType == null && yf.nodeType != null) { yClone.nodeType = yf.nodeType; }
		const yi = makeArrayAccess(yClone, makeTypedIdentResolved(counterSym, null, loc), loc);
		fillBody(hook, xi, yi, "", elemType, lctx, bodyBuf, visited, loc);
	} else {
		fillBody(hook, xi, xi, "", elemType, lctx, bodyBuf, visited, loc);
	}
	if (bodyBuf.items.length == 0) return;
	buf.items.push(counterDecl);

	// $i = $i + 1
	bodyBuf.items.push(makeExprStmt(makeAssign(
		makeTypedIdentResolved(counterSym, null, loc),
		makeBinary(makeTypedIdentResolved(counterSym, null, loc), "+", makeNumber(1, loc), loc),
		loc
	), loc));

	buf.items.push(makeWhile(cond, makeBlock(bodyBuf.items, loc), loc));
}

function runtimeCellDestroy(elem: Type | null, canon: Type): string {
	if (elem == null || isUncountedPtrElement(elem)) return "msNumberArrayDestroy";
	if (elem.kind == TypeKind.String) return "msStringArrayDestroy";
	if (elem.kind == TypeKind.Function) return "msClosureArrayDestroy";
	if (elem.kind == TypeKind.Ref || elem.kind == TypeKind.Ptr) {
		if (elem.sym != null && elem.sym.symbolKind == SymbolKind.Actor) return "msNumberArrayDestroy";
		return isAtomicRef(elem) ? "msAtomicRefArrayDestroy" : "msRefArrayDestroy";
	}
	const family = arrayCTypeName(canon);
	if (family == "msRefArray") return "msRefArrayDestroy";
	if (family == "msStringArray" && arrayElementNeedsCleanup(elem)) return "msStringArrayDestroy";
	if (family == "msClosureArray" && arrayElementNeedsCleanup(elem)) return "msClosureArrayDestroy";
	return "msNumberArrayDestroy";
}

function registerArrayOps(arrT: Type, lctx: LiftCtx): void {
	if (hasGenericParams(arrT)) return;
	const elem = arrayOpElement(arrT.typeReturn);
	const cell = createRef(arrT);
	if (getOpByKey(cell, AttachedOp.AttachedDestructor) != null) return;
	const canon = elem == arrT.typeReturn ? arrT : createArray(elem);
	let cellDestroy: Symbol = attachedOpSym(runtimeCellDestroy(elem, canon), AttachedOp.AttachedDestructor);
	if (!isRuntimeArrayFamily(canon)) {
		const seqName = arrayCTypeName(canon);
		for (const hook of ["destroy", "copy", "sink", "wasMoved"]) {
			opPrototype(canon, attachedOpOf(hook), seqName + hookSuffix(hook), lctx.checkerCtx);
		}
		lctx.seqTypes.push(canon);
		const pointerElem = elem != null && (elem.kind == TypeKind.Ref || elem.kind == TypeKind.Ptr || elem.kind == TypeKind.String || elem.kind == TypeKind.Function);
		if (!pointerElem && elem != null && arrayElementNeedsCleanup(elem)) cellDestroy = requireOpByKey(canon, AttachedOp.AttachedDestructor);
	}
	bindOpByKey(cell, AttachedOp.AttachedDestructor, cellDestroy);
	if (elem != null && elem.kind == TypeKind.Array) registerArrayOps(elem, lctx);
}

function elemNeedsLoop(elem: Type | null): boolean {
	if (elem == null || isPrimitiveKind(elem.kind)) return false;
	// Actor-handle elements are DRC-exempt (classify.ms classifyArray) — free the array
	// storage but never per-element decref, else the shared actors double-free.
	return !((elem.kind == TypeKind.Ref || elem.kind == TypeKind.Ptr)
		&& elem.sym != null && elem.sym.symbolKind == SymbolKind.Actor);
}

// --- Standard sequence/array hook generator (reference parity: reference sequence op) ---
// Primitive elements: runtime macros (no per-element cleanup).
// Non-primitive elements: inline loops via genArrayLoop (reference loop pattern).
function arrayOp(hook: string, elem: Type, xf: Node, yf: Node, lctx: LiftCtx, buf: NodeBuf, loc: SourceLocation): void {
	const needsElemLoop = elemNeedsLoop(elem);
	const isU8Elem = elem != null && elem.kind == TypeKind.Uint8;
	if (needsElemLoop && elem != null) registerArrayOps(createArray(elem), lctx);
	match (hook) {
		"destroy" => {
			if (needsElemLoop) { genArrayLoop("destroy", elem, xf, yf, lctx, buf, loc); }
			genCall(isU8Elem ? "msArrayUint8Destroy" : "msArrayDestroy", hook, xf, yf, buf, loc);
		},
		"copy" => {
			if (needsElemLoop && elem != null && elem.kind == TypeKind.String) {
				// String arrays: use bulk msArrayStringCopy (allocates new payload, copies + increfs each element).
				// The per-element loop generates msStringCopy(&arr[i], src[i]) which writes to a
				// C temporary instead of the array slot (msArrayAccess returns by value).
				genCall("msArrayStringCopy", hook, xf, yf, buf, loc);
			} else if (needsElemLoop) {
				genCall("msArraySetLen", hook, xf, yf, buf, loc);
				genArrayLoop("copy", elem, xf, yf, lctx, buf, loc);
			} else {
				genCall(isU8Elem ? "msArrayUint8Copy" : "msArrayCopy", hook, xf, yf, buf, loc);
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
			arrayOp("destroy", elem, clonePath(xf, loc), clonePath(xf, loc), lctx, destroyBuf, loc);
			buf.items.push(makeIf(guardCond, makeBlock(destroyBuf.items, loc), null as unknown as Node, loc));
			buf.items.push(makeExprStmt(makeAssign(clonePath(xf, loc), clonePath(yf, loc), loc), loc));
		},
		"wasMoved" => { genCall("msArrayWasMoved", hook, xf, yf, buf, loc); },
		"trace" => {
			// Reference parity: only trace array elements if element type can form cycles
			if (needsElemLoop && elem != null) {
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
function refOp(hook: string, xf: Node, yf: Node, fieldName: string, isCyclic: boolean, atomic: boolean, lctx: LiftCtx, buf: NodeBuf, loc: SourceLocation): void {
	const decrefFn = atomic ? "msAtomicDecref" : (isCyclic ? "msDecrefCyclic" : "msDecref");
	const increfFn = atomic ? "msAtomicIncref" : (isCyclic ? "msIncrefCyclic" : "msIncref");
	match (hook) {
		"destroy" => { genCall(decrefFn, hook, xf, yf, buf, loc); },
		"copy" => { genCopyRef(increfFn, xf, yf, fieldName, buf, loc); },
		"sink" => {
			if (isCyclic && !atomic) {
				const ctr = lctx.tempCounter;
				lctx.tempCounter = ctr + 1;
				const oldName = "$old_" + ctr.toString();
				const oldInit = clonePath(xf, loc);
				if (oldInit.nodeType == null) oldInit.nodeType = xf.nodeType;
				const oldSym = liftTempSym(lctx, oldName, oldInit.nodeType);
				const oldDecl = makeVarDecl(oldName, oldInit, DeclKind.Let, loc);
				oldDecl.resolvedSym = oldSym;
				buf.items.push(oldDecl);
				buf.items.push(makeExprStmt(makeAssign(clonePath(xf, loc), clonePath(yf, loc), loc), loc));
				const oldRef = makeTypedIdentResolved(oldSym, oldInit.nodeType, loc);
				genCall(decrefFn, "destroy", oldRef, oldRef, buf, loc);
			} else {
				genCall(decrefFn, "destroy", clonePath(xf, loc), yf, buf, loc);
				buf.items.push(makeExprStmt(makeAssign(clonePath(xf, loc), clonePath(yf, loc), loc), loc));
			}
		},
		"wasMoved" => { genCall("msPtrWasMoved", hook, xf, yf, buf, loc); },
		"trace" => {
			// Arc<T> is acyclic by construction — its atomic rc is the sole owner accountant,
			// so it must never be traced into the cycle collector (a non-atomic flag mutation
			// there would race the atomic count). Acyclic pointees are skipped per the
			// reference attachedTrace gate (liftdestructors.nim:782-791).
			if (!atomic && isCyclic) {
				buf.items.push(makeExprStmt(makeCall(runtimeRef("msOrcTraceRef", loc), [makeHiddenAddr(xf, loc), yf], loc), loc));
			}
		},
		_ => {},
	};
}

// --- Standard value-type object hook generator ---
// Reference parity: Named-type hooks take pointer params (ccgIntroducedPtr).
// Wrap field accesses in HiddenAddr so codegen emits &(self.field).
function namedObjOp(hook: string, t: Type, xf: Node, yf: Node, buf: NodeBuf, loc: SourceLocation): void {
	if (hook == "sink") {
		// Inline sink: destroy(&xf) + assign(xf = yf)
		buf.items.push(makeExprStmt(makeCall(makeTypedIdentResolved(requireOpByKey(t, AttachedOp.AttachedDestructor), null, loc), [makeHiddenAddr(xf, loc)], loc), loc));
		buf.items.push(makeExprStmt(makeAssign(xf, yf, loc), loc));
		return;
	}
	const op = requireOpByKey(t, attachedOpOf(hook));
	// Named-type hooks expect pointers — wrap in HiddenAddr
	const ax = makeHiddenAddr(xf, loc);
	if (hook == "destroy" || hook == "wasMoved") {
		buf.items.push(makeExprStmt(makeCall(makeTypedIdentResolved(op, null, loc), [ax], loc), loc));
	} else if (hook == "trace") {
		buf.items.push(makeExprStmt(makeCall(makeTypedIdentResolved(op, null, loc), [ax, yf], loc), loc));
	} else {
		const ay = makeHiddenAddr(yf, loc);
		buf.items.push(makeExprStmt(makeCall(makeTypedIdentResolved(op, null, loc), [ax, ay], loc), loc));
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
	if (fieldType == null) return;
	// Skip void-typed fields (e.g. `Result<void, E>` variant has `void value`)
	// — typedef emit drops them too, so generating copy/destroy for a missing
	// field would produce invalid C (`(*dest).v0.value` on a void slot).
	if (fieldType.kind == TypeKind.Void) return;
	let xf = fieldName != ""
		? makeMember(x, fieldName, loc)
		: x;
	if (fieldName != "") { xf.nodeType = fieldType; }
	// reference parity: trace keeps y as raw callback, not y.field
	let yf = (fieldName != "" && hook != "trace")
		? makeMember(y, fieldName, loc)
		: y;
	if (fieldName != "" && hook != "trace") { yf.nodeType = fieldType; }

	// Tuple case extracted from match (MetaScript match arm limitation with block-scoped vars)
	if (fieldType.kind == TypeKind.Tuple) {
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
			if (elem != null) arrayOp(hook, elem, xf, yf, lctx, buf, loc);
		},
		TypeKind.SizedArray => {
			const elem = fieldType.typeReturn;
			if (elem != null && sizedArrayNeedsHooks(fieldType, lctx, loc)) {
				ensureSizedArrayHooks(fieldType, lctx, loc);
				if (hook != "trace" || isCyclicType(elem, lctx, visited)) {
					genElementLoop(hook, elem, makeNumber(fieldType.typeValue as number, loc), xf, yf, lctx, buf, loc);
				}
			} else {
				defaultOp(hook, xf, yf, buf, loc);
			}
		},
		TypeKind.Struct => {
			// Anon structs from `{...}` type annotations have empty typeName (created
			// via createStruct("", ...) in resolvePass). Codegen emits them as
			// `msAnon_<hash>`; mirror that here so the hook name matches.
			const resolvedName = (fieldType.typeName != "" && !isAnonTypeName(fieldType.typeName))
				? fieldType.typeName
				: (fieldType.typeNames.length > 0 ? anonTypeName(fieldType) : "");
			if (resolvedName != "") {
				// Reference parity: trace only emits for cyclic field types (defaultOp is no-op for trace)
				if (hook != "trace" || isCyclicType(fieldType, lctx, visited)) {
					ensureHooks(resolvedName, fieldType, null as unknown as Type, fieldType, false, lctx, loc);
					if (namedTypeHasHooks(fieldType, lctx)) {
						namedObjOp(hook, fieldType, xf, yf, buf, loc);
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
			if (fieldType.sym != null && fieldType.sym.symbolKind == SymbolKind.Actor) {
				defaultOp(hook, xf, yf, buf, loc);
			} else {
				const cyclic = isCyclicType(fieldType, lctx, visited);
				refOp(hook, xf, yf, fieldName, cyclic, isAtomicRef(fieldType), lctx, buf, loc);
			}
		},
		TypeKind.BigInt => {
			// msBigInt is a refcounted heap value that can never form a cycle and
			// carries no atomic count — the plain non-cyclic ref ops, matching the
			// RcInfo classify.ms hands the analyzer for the same type.
			refOp(hook, xf, yf, fieldName, false, false, lctx, buf, loc);
		},
		TypeKind.Ptr => {
			defaultOp(hook, xf, yf, buf, loc);
		},
		TypeKind.Unknown => {
			refOp(hook, xf, yf, fieldName, true, false, lctx, buf, loc);
		},
		TypeKind.Function => {
			if (hook == "copy") {
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
			const distinctInner = distinctBody(fieldType);
			if (distinctInner != null) {
				fillBody(hook, x, y, fieldName, distinctInner, lctx, buf, visited, loc);
				return;
			}
			const transparentInner = peelTransparentInstance(fieldType);
			if (transparentInner != fieldType) {
				fillBody(hook, x, y, fieldName, transparentInner, lctx, buf, visited, loc);
				return;
			}
			const unwrapped = unwrapGenericInstance(fieldType);
			if (unwrapped.mangledName != "") {
				if (hook != "trace" || isCyclicType(unwrapped.body, lctx, visited)) {
					ensureHooks(unwrapped.mangledName, unwrapped.body, null as unknown as Type, fieldType, false, lctx, loc);
					if (namedTypeHasHooks(unwrapped.body, lctx)) {
						namedObjOp(hook, fieldType, xf, yf, buf, loc);
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
			if (refInner != null) {
				if (refInner.kind == TypeKind.Ptr
					|| (refInner.sym != null && refInner.sym.symbolKind == SymbolKind.Actor)) {
					defaultOp(hook, xf, yf, buf, loc);
				} else {
					const cyclic = isCyclicType(fieldType, lctx, visited);
					refOp(hook, xf, yf, fieldName, cyclic, isAtomicRef(refInner), lctx, buf, loc);
				}
				return;
			}
			// Pure strlit union is msString-backed (see isTaggedUnion below) —
			// same ops as a String field, never named tagged-union hooks.
			if (isStringLike(fieldType)) {
				stringOp(hook, xf, yf, fieldName, buf, loc);
			} else if (fieldType.typeName != "") {
				if (hook != "trace" || isCyclicType(fieldType, lctx, visited)) {
					ensureHooks(fieldType.typeName, fieldType, null as unknown as Type, fieldType, false, lctx, loc);
					if (namedTypeHasHooks(fieldType, lctx)) {
						namedObjOp(hook, fieldType, xf, yf, buf, loc);
					} else {
						defaultOp(hook, xf, yf, buf, loc);
					}
				}
			} else if (isPrimitiveOnlyUnion(fieldType)) {
				primitiveUnionOp(hook, fieldType, xf, yf, buf, loc);
			} else {
				const anonName = ensureAnonUnionHooks(fieldType, lctx, loc);
				if (anonName != "") namedObjOp(hook, fieldType, xf, yf, buf, loc);
			}
		},
		TypeKind.Distinct | TypeKind.Alias => {
			if (fieldType.kind == TypeKind.Distinct && hasAnyUserHook(fieldType, lctx)) {
				if (hook != "trace") {
					ensureHooks(fieldType.typeName, fieldType, null as unknown as Type, fieldType, false, lctx, loc);
					namedObjOp(hook, fieldType, xf, yf, buf, loc);
				}
			} else if (fieldType.typeReturn != null) {
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
		if (m != null && (m.kind == TypeKind.String || m.kind == TypeKind.StringLiteral)) return i;
		i += 1;
	}
	return -1;
}

function isPrimitiveOnlyUnion(t: Type): boolean {
	if (t.typeChildren == null || t.typeChildren.length == 0) return false;
	let strs = 0;
	let i = 0;
	while (i < t.typeChildren.length) {
		const m = t.typeChildren[i];
		if (!isPrimitiveUnionMember(m)) return false;
		if (m != null && (m.kind == TypeKind.String || m.kind == TypeKind.StringLiteral)) strs += 1;
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
	buf.items.push(makeIf(unionTagIs(xf, sIdx, loc), makeBlock(b.items, loc), null, loc));
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
	if (hook == "destroy") {
		tagGuardedStringCall("msStringDecref", xf, px, py, sIdx, buf, loc);
		return;
	}
	if (hook == "wasMoved") {
		tagGuardedStringCall("msStringWasMoved", xf, px, py, sIdx, buf, loc);
		return;
	}
	if (hook == "sink") {
		tagGuardedStringCall("msStringDecref", xf, px, py, sIdx, buf, loc);
		defaultOp(hook, clonePath(xf, loc), clonePath(yf, loc), buf, loc);
		return;
	}
	if (hook == "copy") {
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
		podBuf.items.push(makeIf(unionTagIs(xf, sIdx, loc), makeBlock(incBuf.items, loc), null, loc));
		buf.items.push(makeIf(unionTagIs(xf, sIdx, loc), makeBlock([xStr], loc), makeBlock(podBuf.items, loc), loc));
		return;
	}
	// trace: primitive unions hold no traced refs.
}

// A tagged (match-type) DU emits `struct { _tag; union{...} }` — its variants peel to
// structs. A primitive/string union (`"a" | "b"`) has no struct variants and is backed by
// msString at runtime, so it must NOT get tagged-union hooks (they'd touch `_tag`).
function isTaggedUnion(t: Type): boolean {
	if (t.kind != TypeKind.Union) return false;
	for (let vi = 0; vi < t.typeChildren.length; vi += 1) {
		const v = inlineVariantStruct(t.typeChildren[vi]);
		if (v != null && v.kind == TypeKind.Struct) return true;
	}
	return false;
}

// ===== Needs Hooks Check =====
// Probe: run fillBody("destroy") on throwaway buf. If it emits anything, type needs hooks.

function typeNeedsHooks(objType: Type, lctx: LiftCtx, loc: SourceLocation): boolean {
	if (objType.kind != TypeKind.Struct && objType.kind != TypeKind.Union) return false;
	const probe = newBuf();
	const selfSym = liftSym(lctx, SymbolKind.Variable, "self", null);
	if (objType.kind == TypeKind.Union) {
		if (!isTagCarriedUnion(objType)) return false;
		if (isPrimitiveOnlyUnion(objType) && primitiveUnionStringIdx(objType) >= 0) return true;
		for (let vi = 0; vi < objType.typeChildren.length; vi += 1) {
			const variant = inlineVariantStruct(objType.typeChildren[vi]);
			if (isScalarVariant(objType.typeChildren[vi], variant)) {
				const visited: NameSet = createNameSet();
				fillBody("destroy", makeTypedIdentResolved(selfSym, null, loc), makeTypedIdentResolved(selfSym, null, loc), "v" + vi.toString(), objType.typeChildren[vi], lctx, probe, visited, loc);
				if (probe.items.length > 0) return true;
			} else if (variant != null && variant.typeNames != null) {
				for (let fi = 0; fi < variant.typeNames.length; fi += 1) {
					const visited: NameSet = createNameSet();
					fillBody("destroy", makeTypedIdentResolved(selfSym, null, loc), makeTypedIdentResolved(selfSym, null, loc), variant.typeNames[fi], variant.typeChildren[fi], lctx, probe, visited, loc);
					if (probe.items.length > 0) return true;
				}
			}
		}
		return false;
	}
	for (let i = 0; i < objType.typeNames.length; i += 1) {
		const visited: NameSet = createNameSet();
		fillBody("destroy", makeTypedIdentResolved(selfSym, null, loc), makeTypedIdentResolved(selfSym, null, loc), objType.typeNames[i], objType.typeChildren[i], lctx, probe, visited, loc);
		if (probe.items.length > 0) return true;
	}
	return false;
}

// ===== Inheritance Helper (Standard reference pattern) =====

function classSymOf(t: Type | null): Symbol | null {
	if (t == null || t.sym == null || t.sym.symbolKind != SymbolKind.Class) return null;
	return t.sym;
}

function baseClassOf(t: Type): Type | null {
	if (classSymOf(t) == null || t.typeExtra == null) return null;
	const base = unwrapRef(t.typeExtra);
	return base.kind == TypeKind.Struct && base.typeName != "" ? base : null;
}

function baseSymOf(base: Type): Symbol {
	const sym = base.sym;
	if (sym == null || (sym.symbolKind != SymbolKind.Class && sym.symbolKind != SymbolKind.Interface)) {
		throw new Error(`internal: base '${base.typeName}' reached hook generation without a class or interface symbol`);
	}
	return sym;
}

function ensureClassHooks(body: Type, lctx: LiftCtx, loc: SourceLocation): void {
	ensureHooks(body.typeName, body, baseSymOf(body).symbolType, body, true, lctx, loc);
}

// ===== User-Defined Hook Dispatch (Reference considerUserDefinedOp) =====
// Maps each lifecycle op to its user-facing method name. A user hook is any
// method/extension with that name on the receiver type — class methods and
// free-function extensions both land in the extension registry (collectPass),
// each with the real callable sym attached; the receiver is the extension's first-parameter type.
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

function getUserDefinedHookSym(type: Type, hook: string, lctx: LiftCtx): Symbol | null {
	const methodName = userHookMethodName(hook);
	if (methodName == "") return null;
	const instHook = lookupInstanceHook(type, methodName);
	if (instHook != null) return instHook;
	const declSym = unwrapRef(type).sym;
	if (lctx.checkerCtx == null) return null;
	// A type may carry duplicate registry entries reached through different import
	// paths — distinct Symbol instances whose modulePath differs only by spelling
	// (e.g. `crypto/index` vs `crypto/tls/../index`), each mangling to a different
	// C name. Reference rule: a type-bound op is defined in the type's own module.
	// Prefer the sym whose module matches the type's so the emitted call resolves
	// to the emitted definition (a stale-path sym links to an undefined symbol).
	const typeModulePath = declSym != null ? declSym.modulePath : "";
	const registry = pickBodyCtx(typeModulePath, lctx.checkerCtx).extensionRegistry;
	if (registry == null) return null;
	let fallback: Symbol | null = null;
	for (const m of findAllExtensionsByName(registry, methodName)) {
		if (m.isStatic || m.sym == null) continue;
		if (declSym == null || extReceiverSym(m) != declSym) continue;
		if (typeModulePath != "" && m.sym.modulePath == typeModulePath) return m.sym;
		if (fallback == null) fallback = m.sym;
	}
	if (fallback != null) return fallback;
	return null;
}

function hasUserDefinedHook(type: Type, hook: string, lctx: LiftCtx): boolean {
	return getUserDefinedHookSym(type, hook, lctx) != null;
}

// Reference parity: declaring any lifecycle hook makes the type need lifecycle
// management (Nim sets tfHasAsgn in bindTypeHook). A handle-only type (e.g. a
// uint32 GPU buffer) has no RC fields, so typeNeedsHooks alone would skip it —
// the user hook would then never be wired into <T>Destroy.
function hasAnyUserHook(t: Type, lctx: LiftCtx): boolean {
	return hasUserDefinedHook(t, "destroy", lctx)
		|| hasUserDefinedHook(t, "copy", lctx)
		|| hasUserDefinedHook(t, "sink", lctx)
		|| hasUserDefinedHook(t, "wasMoved", lctx)
		|| hasUserDefinedHook(t, "dup", lctx)
		|| hasUserDefinedHook(t, "trace", lctx);
}

function baseHookOwner(t: Type, hook: string, lctx: LiftCtx): Type | null {
	let a = baseClassOf(t);
	while (a != null) {
		const own = hasUserDefinedHook(a, hook, lctx);
		const takes = hook == "destroy" || hook == "wasMoved"
			? own
			: own || hasUserDefinedHook(a, "destroy", lctx);
		if (takes) {
			if (hook != "trace") return a;
			return isCyclicType(a, lctx, createNameSet()) ? a : null;
		}
		a = baseClassOf(a);
	}
	return null;
}

function callBaseHook(owner: Type, hook: string, s1: Symbol, s2: Symbol, lctx: LiftCtx, buf: NodeBuf, loc: SourceLocation): void {
	ensureClassHooks(owner, lctx, loc);
	const ownerRef = baseSymOf(owner).symbolType;
	const a1 = makeHiddenSubConv(makeIdentResolved(s1, loc), ownerRef, loc);
	const args: Node[] = [a1];
	if (hook == "trace") {
		args.push(makeIdentResolved(s2, loc));
	} else if (hook == "copy" || hook == "sink") {
		args.push(makeHiddenSubConv(makeIdentResolved(s2, loc), ownerRef, loc));
	}
	const op = requireOpByKey(owner, attachedOpOf(hook));
	buf.items.push(makeExprStmt(makeCall(makeTypedIdentResolved(op, null, loc), args, loc), loc));
}

// ===== Union variant arm generation (if/else chain on _tag) =====

// Emit `dest._tag = src._tag` (variant discriminator copy). Used by sink and
// every non-unary hook that needs to mirror the source's active-variant tag.
// Value use of a Var<T> hook param — the deref the caller suppressed by
// keeping the ident raw (Reference liftdestructors.nim:1340 `newDeref`).
function hookParamDeref(sym: Symbol, loc: SourceLocation): Node {
	return makeHiddenDeref(makeIdentResolved(sym, loc), loc);
}

function userHookArg(hookSym: Symbol, index: number, param: Symbol, classType: Type | null, loc: SourceLocation): Node {
	if (classType != null) return makeIdentResolved(param, loc);
	const fnType = hookSym.symbolType;
	const want = fnType != null && fnType.typeChildren != null && index < fnType.typeChildren.length
		? fnType.typeChildren[index] : null;
	if (want != null && want.kind == TypeKind.Var) return makeIdentResolved(param, loc);
	return hookParamDeref(param, loc);
}

function emitTagCopy(buf: NodeBuf, dest: Symbol, src: Symbol, loc: SourceLocation): void {
	const lhs = makeMember(hookParamDeref(dest, loc), "_tag", loc);
	const rhs = makeMember(hookParamDeref(src, loc), "_tag", loc);
	buf.items.push(makeExprStmt(makeAssign(lhs, rhs, loc), loc));
}

function generateUnionArms(hook: string, typeName: string, objType: Type, s1: Symbol, s2: Symbol, lctx: LiftCtx, buf: NodeBuf, loc: SourceLocation): void {
	const isUnary = hook == "destroy" || hook == "wasMoved" || hook == "trace";

	// reference parity: sink must destroy old variant BEFORE reassigning _tag
	if (hook == "sink") {
		// 1. Destroy old fields (dispatch on dest._tag)
		const destroyChain = buildVariantDispatch("destroy", typeName, objType, s1, s1, true, lctx, loc);
		if (destroyChain != null) buf.items.push(destroyChain);
		// 2. Assign _tag
		emitTagCopy(buf, s1, s2, loc);
		// 3. Assign new fields (dispatch on src._tag, simple assign only)
		const assignChain = buildVariantChain("sinkAssign", objType, s1, s2, false, lctx, loc);
		if (assignChain != null) buf.items.push(assignChain);
		return;
	}

	// reference parity: =copy for case objects (liftdestructors.nim fillBodyObjT) —
	// blob = dest (snapshot old branch), wasMoved(dest) (whole-object zero: field copies
	// release old dest bits, which are foreign-variant garbage on unswitched memory),
	// copy tag + fields, destroy blob LAST (destroy-first frees src reachable through
	// dest's old branch).
	if (hook == "copy") {
		const ctr = lctx.tempCounter;
		lctx.tempCounter = ctr + 1;
		const blobName = "$blob_" + ctr.toString();
		const blobInit = hookParamDeref(s1, loc);
		blobInit.nodeType = objType;
		const blobSym = liftTempSym(lctx, blobName, objType);
		const blobDecl = makeVarDecl(blobName, blobInit, DeclKind.Let, loc);
		blobDecl.resolvedSym = blobSym;
		buf.items.push(blobDecl);
		const zeroDest = hookParamDeref(s1, loc);
		zeroDest.nodeType = objType;
		buf.items.push(makeExprStmt(makeAssign(zeroDest, makeNull(loc), loc), loc));
		emitTagCopy(buf, s1, s2, loc);
		const copyChain = buildVariantDispatch("copy", typeName, objType, s1, s2, false, lctx, loc);
		if (copyChain != null) buf.items.push(copyChain);
		buf.items.push(makeExprStmt(makeCall(makeTypedIdentResolved(requireOpByKey(objType, AttachedOp.AttachedDestructor), null, loc),
			[makeHiddenAddr(makeTypedIdentResolved(blobSym, null, loc), loc)], loc), loc));
		return;
	}

	// Build if/else chain dispatching on _tag via per-variant helpers
	const chain = buildVariantDispatch(hook, typeName, objType, s1, s2, isUnary, lctx, loc);
	if (chain != null) buf.items.push(chain);

	// For wasMoved: set _tag = -1 after dispatch
	if (hook == "wasMoved") {
		buf.items.push(makeExprStmt(makeAssign(makeMember(hookParamDeref(s1, loc), "_tag", loc), makeNumber(-1, loc), loc), loc));
	}
}

// Build if/else chain that dispatches to per-variant helper functions.
// Each variant's arm logic is extracted into its own function to keep stack frames small.
// (Without this, the monolithic function hoists ALL variants' locals → stack overflow at -O0)
function buildVariantDispatch(hook: string, typeName: string, objType: Type, s1: Symbol, s2: Symbol, isUnary: boolean, lctx: LiftCtx, loc: SourceLocation): Node {
	let chain = null as unknown as Node;
	let vi = objType.typeChildren.length - 1;
	while (vi >= 0) {
		const variant = inlineVariantStruct(objType.typeChildren[vi]);
		const scalar = isScalarVariant(objType.typeChildren[vi], variant);
		if ((variant != null && variant.typeNames != null) || scalar) {
			// Generate per-variant arm body
			const armBuf = newBuf();
			const vName = "v" + vi.toString();
			const h1 = liftSym(lctx, SymbolKind.Variable, s1.name, s1.symbolType);
			const h2 = hook == "trace"
				? liftSym(lctx, SymbolKind.Variable, s2.name, createPtr(voidType()))
				: (s2.name == s1.name ? h1 : liftSym(lctx, SymbolKind.Variable, s2.name, s2.symbolType));
			if (scalar) {
				buildScalarArmBody(hook, h1, h2, vName, objType.typeChildren[vi], lctx, armBuf, loc);
			} else {
				buildVariantArmBody(hook, objType, h1, h2, vi, vName, variant as Type, isUnary, lctx, armBuf, loc);
			}

			if (armBuf.items.length > 0) {
				// Generate helper function: TypeName_vN_Suffix(self) or TypeName_vN_Suffix(dest, src)
				// Dedup: sink hook internally dispatches destroy — reuse already-generated destroy helpers
				const suffix = hookSuffix(hook);
				const helperName = `${typeName}_${vName}${suffix}`;
				if (!lctx.helperOps.has(helperName)) {
					const isTrace = hook == "trace";
					let helperFn: Node | null = null;
					if (isTrace) {
						// Trace: (self, callback) — self is union type, callback is void*
						helperFn = makeFnDecl(helperName, [h1, h2], [typeName, "void*"], makeBlock(armBuf.items, loc), "", "void", loc);
					} else if (isUnary) {
						helperFn = makeFnDecl(helperName, [h1], [typeName], makeBlock(armBuf.items, loc), "", "void", loc);
					} else {
						helperFn = makeFnDecl(helperName, [h1, h2], [typeName, typeName], makeBlock(armBuf.items, loc), "", "void", loc);
					}
					setHookParamType(helperFn, 0, h1.symbolType);
					if (!isUnary || isTrace) setHookParamType(helperFn, 1, h2.symbolType);
					liftHelperOp(helperFn, helperName, hook, lctx);
					lctx.collector.push(helperFn);
				}

			// Dispatch: call the helper from the main if/else chain
			const tagAccess = makeMember(hookParamDeref(s1, loc), "_tag", loc);
			const cond = makeBinary(tagAccess, "===", makeNumber(vi, loc), loc);
			const a1 = makeIdentResolved(s1, loc);
			const a2 = makeIdentResolved(s2, loc);
			const callArgs: Node[] = (isUnary && hook != "trace")
				? [a1]
				: [a1, a2];
				const helperSym = lctx.helperOps.get(helperName);
				if (helperSym == null) throw new Error(`internal: union variant helper '${helperName}' has no symbol`);
				const callStmt = makeExprStmt(makeCall(makeTypedIdentResolved(helperSym, null, loc), callArgs, loc), loc);
				chain = makeIf(cond, makeBlock([callStmt], loc), chain, loc);
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
function emitVariantSinkAssign(armBuf: NodeBuf, s1: Symbol, s2: Symbol, vName: string, variant: Type, loc: SourceLocation): void {
	let fi = 0;
	while (fi < variant.typeNames.length) {
		const ft = fi < variant.typeChildren.length ? variant.typeChildren[fi] : null;
		if (ft != null && ft.kind == TypeKind.Void) { fi += 1; continue; }
		const xBase = makeMember(hookParamDeref(s1, loc), vName, loc);
		const yBase = makeMember(hookParamDeref(s2, loc), vName, loc);
		armBuf.items.push(makeExprStmt(makeAssign(
			makeMember(xBase, variant.typeNames[fi], loc),
			makeMember(yBase, variant.typeNames[fi], loc), loc), loc));
		fi += 1;
	}
}

function isScalarVariant(member: Type | null, variant: Type | null): boolean {
	if (member == null || (variant != null && variant.kind == TypeKind.Struct)) return false;
	return member.kind != TypeKind.Null && member.kind != TypeKind.Void;
}

function buildScalarArmBody(hook: string, s1: Symbol, s2: Symbol, vName: string, member: Type, lctx: LiftCtx, armBuf: NodeBuf, loc: SourceLocation): void {
	if (hook == "sinkAssign") {
		armBuf.items.push(makeExprStmt(makeAssign(
			makeMember(hookParamDeref(s1, loc), vName, loc),
			makeMember(hookParamDeref(s2, loc), vName, loc), loc), loc));
		return;
	}
	const x = hookParamDeref(s1, loc);
	const y = hook == "trace" ? makeIdentResolved(s2, loc)
		: (hook == "destroy" || hook == "wasMoved") ? hookParamDeref(s1, loc)
		: hookParamDeref(s2, loc);
	const visited: NameSet = createNameSet();
	fillBody(hook, x, y, vName, member, lctx, armBuf, visited, loc);
}

// Generate the body of a single variant's arm (used by both inline and helper patterns)
function buildVariantArmBody(hook: string, objType: Type, s1: Symbol, s2: Symbol, vi: number, vName: string, variant: Type, isUnary: boolean, lctx: LiftCtx, armBuf: NodeBuf, loc: SourceLocation): void {
	if (hook == "destroy") {
		let fi = variant.typeNames.length - 1;
		while (fi >= 0) {
			const xBase = makeMember(hookParamDeref(s1, loc), vName, loc);
			const yBase = makeMember(hookParamDeref(s1, loc), vName, loc);
			const visited: NameSet = createNameSet();
			fillBody(hook, xBase, yBase, variant.typeNames[fi], variant.typeChildren[fi], lctx, armBuf, visited, loc);
			fi -= 1;
		}
	} else if (hook == "sinkAssign") {
		emitVariantSinkAssign(armBuf, s1, s2, vName, variant, loc);
	} else {
		let fi = 0;
		while (fi < variant.typeNames.length) {
			const xBase = makeMember(hookParamDeref(s1, loc), vName, loc);
			const yBase = (hook == "trace") ? makeIdentResolved(s2, loc)
				: isUnary ? makeMember(hookParamDeref(s1, loc), vName, loc)
				: makeMember(hookParamDeref(s2, loc), vName, loc);
			const visited: NameSet = createNameSet();
			fillBody(hook, xBase, yBase, variant.typeNames[fi], variant.typeChildren[fi], lctx, armBuf, visited, loc);
			fi += 1;
		}
	}
}

// Build if/else chain over variant arms, dispatching on s1._tag
function buildVariantChain(hook: string, objType: Type, s1: Symbol, s2: Symbol, isUnary: boolean, lctx: LiftCtx, loc: SourceLocation): Node {
	let chain = null as unknown as Node;
	let vi = objType.typeChildren.length - 1;
	while (vi >= 0) {
		const variant = inlineVariantStruct(objType.typeChildren[vi]);
		const armBuf = newBuf();
		if (isScalarVariant(objType.typeChildren[vi], variant)) {
			buildScalarArmBody(hook, s1, s2, "v" + vi.toString(), objType.typeChildren[vi], lctx, armBuf, loc);
		} else if (variant != null && variant.typeNames != null) {
			const vName = "v" + vi.toString();
			buildVariantArmBody(hook, objType, s1, s2, vi, vName, variant, isUnary, lctx, armBuf, loc);
		}
		if (armBuf.items.length > 0) {
			const tagAccess = makeMember(hookParamDeref(s1, loc), "_tag", loc);
			const cond = makeBinary(tagAccess, "===", makeNumber(vi, loc), loc);
			chain = makeIf(cond, makeBlock(armBuf.items, loc), chain, loc);
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
function generateHook(hook: string, typeName: string, cName: string, objType: Type, subject: Type, classType: Type | null, lctx: LiftCtx, loc: SourceLocation): Symbol {
	const buf = newBuf();
	const isTrace = hook == "trace";
	const isUnary = hook == "destroy" || hook == "wasMoved" || isTrace;
	const hookParamT = classType != null ? classType : createVar(objType);
	const s1 = liftSym(lctx, SymbolKind.Variable, isUnary ? "self" : "dest", hookParamT);
	const n2 = match (hook) {
		"trace" => "callback",
		"destroy" | "wasMoved" => "self",
		_ => "src",
	};
	const s2Type = isTrace ? createPtr(voidType()) : hookParamT;
	const s2 = n2 == s1.name ? s1 : liftSym(lctx, SymbolKind.Variable, n2, s2Type);

	// Self-assignment guard for binary hooks (copy, sink): compare the raw
	// param pointers — Ref params are pointers already, Var<T> params read as
	// the bare T* now that ident auto-deref no longer applies.
	if (!isUnary && !isTrace) {
		const g1 = makeIdentResolved(s1, loc);
		const g2 = makeIdentResolved(s2, loc);
		buf.items.push(makeIf(
			makeBinary(g1, "===", g2, loc),
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
	const hookSym = getUserDefinedHookSym(subject, hook, lctx);
	if (hookSym != null) {
		const hookIdent = makeIdentResolved(hookSym, loc);
		const u1 = userHookArg(hookSym, 0, s1, classType, loc);
		if (isTrace) {
			buf.items.push(makeExprStmt(makeCall(hookIdent, [u1, makeIdentResolved(s2, loc)], loc), loc));
		} else if (isUnary) {
			buf.items.push(makeExprStmt(makeCall(hookIdent, [u1], loc), loc));
		} else {
			const u2 = userHookArg(hookSym, 1, s2, classType, loc);
			buf.items.push(makeExprStmt(makeCall(hookIdent, [u1, u2], loc), loc));
		}
	} else if (hook == "sink" && hasUserDefinedHook(subject, "destroy", lctx)) {
		genOpCall(requireOpByKey(objType, AttachedOp.AttachedDestructor), "destroy", makeIdentResolved(s1, loc), null as unknown as Node, buf, loc);
		buf.items.push(makeExprStmt(makeAssign(hookParamDeref(s1, loc), hookParamDeref(s2, loc), loc), loc));
	} else {
		const base = baseClassOf(objType);
		if (base != null) ensureClassHooks(base, lctx, loc);

		// Param accessors (Reference liftdestructors.nim:1340): deref at the
		// use site — Ref unwraps to Struct, Var<T> unwraps the T*. The trace
		// callback stays raw (a plain pointer, not a value).
		const x1 = hookParamDeref(s1, loc);
		const x2 = isTrace ? makeIdentResolved(s2, loc) : hookParamDeref(s2, loc);

		const fieldsFlattened = objType.typeFlags.has(TypeFlag.HasInheritedFields);
		const owner = fieldsFlattened ? baseHookOwner(objType, hook, lctx) : null;
		const firstOwn = owner != null ? owner.typeNames.length : 0;
		if (objType.kind == TypeKind.Union) {
			if (isPrimitiveOnlyUnion(objType)) {
				primitiveUnionOp(hook, objType, x1, x2, buf, loc);
			} else {
				generateUnionArms(hook, cName, objType, s1, s2, lctx, buf, loc);
			}
		} else if (objType.kind == TypeKind.Distinct) {
			fillBody(hook, x1, x2, "", objType.typeReturn!, lctx, buf, createNameSet(), loc);
		} else if (hook == "destroy") {
			// Destroy: fields first (reverse), then base class (LIFO — standard pattern)
			for (let i = objType.typeNames.length - 1; i >= firstOwn; i -= 1) {
				const visited: NameSet = createNameSet();
				fillBody(hook, x1, x2, objType.typeNames[i], objType.typeChildren[i], lctx, buf, visited, loc);
			}
			if (owner != null) {
				callBaseHook(owner, hook, s1, s2, lctx, buf, loc);
			} else if (!fieldsFlattened && base != null && namedTypeHasHooks(base, lctx)) {
				genOpCall(requireOpByKey(base, AttachedOp.AttachedDestructor), hook, x1, x2, buf, loc);
			}
		} else {
			// Copy/sink/trace/wasMoved: base class first, then fields (standard pattern)
			if (owner != null) {
				callBaseHook(owner, hook, s1, s2, lctx, buf, loc);
			} else if (!fieldsFlattened && base != null && namedTypeHasHooks(base, lctx)) {
				genOpCall(requireOpByKey(base, attachedOpOf(hook)), hook, x1, x2, buf, loc);
			}
			for (let i = firstOwn; i < objType.typeNames.length; i += 1) {
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
	if (hook == "destroy") {
		const wrapped: Node[] = [makeExprStmt(makeCall(runtimeRef("msOrcBeginTeardown", loc), [], loc), loc)];
		for (const it of buf.items) { wrapped.push(it); }
		wrapped.push(makeExprStmt(makeCall(runtimeRef("msOrcEndTeardown", loc), [], loc), loc));
		buf.items = wrapped;
	}

	const suffix = hookSuffix(hook);

	let fnNode: Node | null = null;
	if (isTrace) {
		fnNode = makeFnDecl(cName + suffix, [s1, s2], [typeName, "void*"], makeBlock(buf.items, loc), "", "void", loc);
	} else if (isUnary) {
		fnNode = makeFnDecl(cName + suffix, [s1], [typeName], makeBlock(buf.items, loc), "", "void", loc);
	} else {
		fnNode = makeFnDecl(cName + suffix, [s1, s2], [typeName, typeName], makeBlock(buf.items, loc), "", "void", loc);
	}
	// Set hook param types explicitly (reference parity: symPrototype sets dest.typ/src.typ directly).
	// For class types, use classType (Ref<Struct>) — already a pointer.
	// For value types, wrap in Var (= pointer) — Standard reference parity: =destroy(x: var T).
	const paramType = classType != null ? classType : createVar(objType);
	setHookParamType(fnNode, 0, paramType);
	if (!isUnary && !isTrace) {
		// copy/sink: both params are the struct type
		setHookParamType(fnNode, 1, paramType);
	}
	// trace param[1] is the raw callback/env pointer — reference: getSysType(pointer)
	if (isTrace) setHookParamType(fnNode, 1, createPtr(voidType()));
	const sym = liftOp(fnNode, objType, objType, attachedOpOf(hook), cName + suffix);
	lctx.collector.push(fnNode);
	return sym;
}

// ===== Ensure Type Hooks — unified entry (handles named class/interface,
// named struct, anonymous struct, generic instance, union) =====
//
// Contract:
//   - `typeName` — required (anonymous types with typeName === "" can't name hooks; early return).
//   - `objType` — the struct/union type whose fields the hooks walk.
//   - `refType` — non-null iff caller already knows this is a Ref<Struct> (class/interface).
//     When null, the function looks up the symbol by name and infers class/interface status.


// Emit the <T>Dup hook. Ref types (class/interface) get the incref shortcut;
// value types copy through <T>Copy. Signature identical to the paired Ref/val
// dup emission in the old Path A / Path B, just deduplicated.
function emitDup(typeName: string, cName: string, objType: Type, classType: Type | null, isRef: boolean, lctx: LiftCtx, loc: SourceLocation): Symbol {
	const dupStmts: Node[] = [];
	const srcSym = liftSym(lctx, SymbolKind.Variable, "src", classType != null ? classType : objType);
	const resultSym = liftSym(lctx, SymbolKind.Variable, "$result", classType != null ? classType : objType, true);
	const resultDecl = makeVarDecl("$result", makeIdentResolved(srcSym, loc), DeclKind.Let, loc);
	resultDecl.resolvedSym = resultSym;
	if (isRef) {
		// ref types: result = src; incref(result). No =copy call — just pointer copy + refcount.
		dupStmts.push(resultDecl);
		dupStmts.push(makeExprStmt(makeCall(runtimeRef("msIncref", loc), [makeTypedIdentResolved(resultSym, null, loc)], loc), loc));
		dupStmts.push(makeReturn(makeTypedIdentResolved(resultSym, null, loc), loc));
	} else {
		// Value types: result = src; TypeName_copy(&result, &src); return result.
		dupStmts.push(resultDecl);
		dupStmts.push(makeExprStmt(makeCall(makeTypedIdentResolved(requireOpByKey(objType, AttachedOp.AttachedAsgn), null, loc), [makeHiddenAddr(makeTypedIdentResolved(resultSym, null, loc), loc), makeHiddenAddr(makeIdentResolved(srcSym, loc), loc)], loc), loc));
		dupStmts.push(makeReturn(makeTypedIdentResolved(resultSym, null, loc), loc));
	}
	const dupNode = makeFnDecl(cName + "Dup", [srcSym], [typeName], makeBlock(dupStmts, loc), "", typeName, loc);
	const dupType = classType != null ? classType : objType;
	setHookParamType(dupNode, 0, dupType);
	setHookReturnType(dupNode, dupType);
	const sym = liftOp(dupNode, objType, objType, AttachedOp.AttachedDup, cName + "Dup");
	lctx.collector.push(dupNode);
	return sym;
}

function ensureHooks(typeName: string, objType: Type, refType: Type, orig: Type, declaring: boolean, lctx: LiftCtx, loc: SourceLocation): void {
	// ----- Guards (order matches old ensureTypeHooks for perf parity) -----
	if (typeName == "") return;
	if (hasGenericParams(objType)) return;
	const cName = hookCName(typeName, objType, lctx);
	const typeId = opTypeKey(objType);
	if (nameSetContains(lctx.generated, typeId) || nameSetContains(lctx.trivial, typeId)) {
		aliasLiftedOps(orig, objType);
		return;
	}
	if (hasLiftedOp(objType, AttachedOp.AttachedDestructor)) {
		aliasLiftedOps(orig, objType);
		return;
	}
	if (nameSetContains(lctx.generating, typeId)) return;
	nameSetAdd(lctx.generating, typeId);

	// ----- Resolve category via symbol lookup (matches old ensureTypeHooks) -----
	let isClassOrInterface = refType != null;
	let isCrossModuleClass = false;
	if (lctx.checkerCtx != null) {
		const sym = objType.sym;
		if (sym != null) {
			if (sym.symbolKind == SymbolKind.Class
				|| sym.symbolKind == SymbolKind.Actor
				|| sym.symbolKind == SymbolKind.Interface) {
				isClassOrInterface = true;
				if (refType == null) refType = sym.symbolType;
				isCrossModuleClass = sym.modulePath != "" && sym.modulePath != lctx.checkerCtx.modulePath;
			}
		}
	}

	if (objType.kind != TypeKind.Struct && objType.kind != TypeKind.Union && !(objType.kind == TypeKind.Distinct && hasAnyUserHook(orig, lctx))) return;

	if (isCrossModuleClass && !declaring) {
		aliasLiftedOps(orig, objType);
		nameSetAdd(lctx.generated, typeId);
		return;
	}

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
	if (!typeNeedsHooks(objType, lctx, loc) && !hasAnyUserHook(orig, lctx)) {
		const isPlainValueAggregate = !isClassOrInterface
			&& (objType.kind == TypeKind.Struct || isTaggedUnion(objType));
		if (!isPlainValueAggregate) {
			nameSetAdd(lctx.trivial, typeId);
			return;
		}
	}

	const classType = isClassOrInterface ? refType : null;
	let hasCycles = false;

	const destroySym = generateHook("destroy",  typeName, cName, objType, orig, classType, lctx, loc);
	setOpByKey(objType, AttachedOp.AttachedDestructor, destroySym);
	const copySym = generateHook("copy",     typeName, cName, objType, orig, classType, lctx, loc);
	setOpByKey(objType, AttachedOp.AttachedAsgn, copySym);
	const sinkSym = generateHook("sink",     typeName, cName, objType, orig, classType, lctx, loc);
	setOpByKey(objType, AttachedOp.AttachedSink, sinkSym);
	const wasMovedSym = generateHook("wasMoved", typeName, cName, objType, orig, classType, lctx, loc);
	setOpByKey(objType, AttachedOp.AttachedWasMoved, wasMovedSym);
	setAttachedOp(objType, AttachedOp.AttachedDestructor, destroySym);
	setAttachedOp(objType, AttachedOp.AttachedAsgn,       copySym);
	setAttachedOp(objType, AttachedOp.AttachedSink,       sinkSym);
	setAttachedOp(objType, AttachedOp.AttachedWasMoved,   wasMovedSym);

	const visited: NameSet = createNameSet();
	hasCycles = isCyclicType(objType, lctx, visited);
	if (hasCycles) {
		const traceSym = generateHook("trace", typeName, cName, objType, orig, classType, lctx, loc);
		setOpByKey(objType, AttachedOp.AttachedTrace, traceSym);
		setAttachedOp(objType, AttachedOp.AttachedTrace, traceSym);
	}

	const userDup = getUserDefinedHookSym(orig, "dup", lctx);
	if (userDup != null) {
		bindOpByKey(objType, AttachedOp.AttachedDup, userDup);
		setAttachedOp(objType, AttachedOp.AttachedDup, userDup);
	} else {
		const dupSym = emitDup(typeName, cName, objType, classType, isClassOrInterface, lctx, loc);
		setOpByKey(objType, AttachedOp.AttachedDup, dupSym);
		setAttachedOp(objType, AttachedOp.AttachedDup, dupSym);
	}
	aliasLiftedOps(orig, objType);

	nameSetAdd(lctx.generated, typeId);
}

// ===== Auto-Generated == (reference parity: generic proc `==`*[T: tuple|object]) =====
// Generates TypeName_eq(a, b): boolean with field-by-field comparison.
// Reference implementation uses compile-time `fields()` magic iterator unrolling; we do the same here
// by iterating typeNames/typeChildren at transform time.

function payloadUnionEqExpr(aField: Node, bField: Node, u: Type, loc: SourceLocation): Node {
	let acc = makeBinary(makeMember(clonePath(aField, loc), "_tag", loc), "===", makeMember(clonePath(bField, loc), "_tag", loc), loc);
	for (let vi = 0; vi < u.typeChildren.length; vi += 1) {
		const vName = `v${vi}`;
		const memberEq = unionMemberEq(makeMember(clonePath(aField, loc), vName, loc), makeMember(clonePath(bField, loc), vName, loc), u.typeChildren[vi], loc);
		const inactive = makeBinary(makeMember(clonePath(aField, loc), "_tag", loc), "!==", makeNumber(vi, loc), loc);
		acc = makeBinary(acc, "&&", makeBinary(inactive, "||", memberEq, loc), loc);
	}
	return acc;
}

function unionMemberEq(aMember: Node, bMember: Node, memberType: Type, loc: SourceLocation): Node {
	if (isStringLike(memberType)) {
		return makeCall(runtimeRef("msStringEquals", loc), [aMember, bMember], loc);
	}
	return makeBinary(aMember, "===", bMember, loc);
}

// ===== Ensure Eq (on-demand: only for unions actually compared) =====

// C links every module into one image, so one module owns each Eq; a JS module
// only sees its own top level, so each module that compares emits its own.
function claimEq(t: Type, op: AttachedOp, lctx: LiftCtx): boolean {
	const key = opKey(t, op);
	if (nameSetContains(lctx.generated, key)) return false;
	nameSetAdd(lctx.generated, key);
	if (lctx.jsBackend) return true;
	return !hasLiftedOp(t, op);
}

function ensureUnionEq(t: Type, lctx: LiftCtx, loc: SourceLocation): string {
	const cName = t.typeName == "" ? anonUnionCName(t) : hookCName(t.typeName, t, lctx);
	if (claimEq(t, AttachedOp.AttachedEq, lctx)) generateUnionEq(cName, t, lctx, loc);
	return cName + "Eq";
}

function generateUnionEq(typeName: string, t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const aSym = liftSym(lctx, SymbolKind.Variable, "a", t);
	const bSym = liftSym(lctx, SymbolKind.Variable, "b", t);
	const same = payloadUnionEqExpr(makeTypedIdentResolved(aSym, t, loc), makeTypedIdentResolved(bSym, t, loc), t, loc);
	const eqFn = makeFnDecl(typeName + "Eq", [aSym, bSym], [typeName, typeName], makeBlock([makeReturn(same, loc)], loc), "", "boolean", loc);
	setHookParamType(eqFn, 0, t);
	setHookParamType(eqFn, 1, t);
	liftOp(eqFn, t, t, AttachedOp.AttachedEq, typeName + "Eq");
	lctx.collector.push(eqFn);
}

// ===== Tuple Lifecycle Hooks (first-class value type) =====
// A tuple is a structural value type — codegen emits `struct msTuple_<hash> { T _0; U _1; }`
// — so its DRC hooks mirror a value-struct's: destroy/copy/sink/wasMoved over positional
// fields _0, _1, ... The name is tupleTypeName (the single source codegen + classify.ms also
// use, so they never drift). Without these the analyzer emits MS_NIL at tuple assignment
// sites and the overwritten tuple's heap payload leaks.

function generateTupleHook(hook: string, tupleName: string, t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const buf = newBuf();
	const isUnary = hook == "destroy" || hook == "wasMoved";
	const hookParamT = createVar(t);
	const s1 = liftSym(lctx, SymbolKind.Variable, isUnary ? "self" : "dest", hookParamT);
	const s2 = isUnary ? s1 : liftSym(lctx, SymbolKind.Variable, "src", hookParamT);

	if (!isUnary) {
		buf.items.push(makeIf(
			makeBinary(makeIdentResolved(s1, loc), "===", makeIdentResolved(s2, loc), loc),
			makeBlock([makeReturn(null as unknown as Node, loc)], loc), null as unknown as Node, loc));
	}

	const x1 = hookParamDeref(s1, loc);
	const x2 = hookParamDeref(s2, loc);
	if (hook == "destroy") {
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
		? makeFnDecl(tupleName + suffix, [s1], [tupleName], makeBlock(buf.items, loc), "", "void", loc)
		: makeFnDecl(tupleName + suffix, [s1, s2], [tupleName, tupleName], makeBlock(buf.items, loc), "", "void", loc);
	const paramType = createVar(t);
	setHookParamType(fnNode, 0, paramType);
	if (!isUnary) setHookParamType(fnNode, 1, paramType);
	liftOp(fnNode, t, t, attachedOpOf(hook), tupleName + suffix);
	lctx.collector.push(fnNode);
}

// Probe whether any tuple element emits cleanup (mirror typeNeedsHooks for structs).
function tupleNeedsHooks(t: Type, lctx: LiftCtx, loc: SourceLocation): boolean {
	const probe = newBuf();
	const selfSym = liftSym(lctx, SymbolKind.Variable, "self", null);
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		const visited: NameSet = createNameSet();
		fillBody("destroy", makeTypedIdentResolved(selfSym, null, loc), makeTypedIdentResolved(selfSym, null, loc), "_" + i.toString(), t.typeChildren[i], lctx, probe, visited, loc);
		if (probe.items.length > 0) return true;
	}
	return false;
}

// The four value-type hooks for a tuple, once per module + once globally (claimGlobal).
// No-RC tuples generate nothing — classify.ms returns noRcInfo, so no hook is referenced.
function ensureAnonUnionHooks(t: Type, lctx: LiftCtx, loc: SourceLocation): string {
	if (t.typeName != "" || t.typeChildren == null || t.typeChildren.length < 2) return "";
	let allPrimitive = true;
	for (const c of t.typeChildren) {
		if (c == null || c.kind == TypeKind.Null || c.kind == TypeKind.Ptr) return "";
		if (!isPrimitiveUnionMember(c)) allPrimitive = false;
	}
	if (allPrimitive) return "";
	const name = anonUnionCName(t);
	if (!nameSetContains(lctx.generated, opTypeKey(t)) && !hasLiftedOp(t, AttachedOp.AttachedDestructor)) {
		if (!typeNeedsHooks(t, lctx, loc)) return "";
		ensureHooks(name, t, null as unknown as Type, t, false, lctx, loc);
	}
	return namedTypeHasHooks(t, lctx) ? name : "";
}

function ensureTupleHooks(tupleName: string, t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	if (tupleName == "" || t == null || t.kind != TypeKind.Tuple) return;
	const typeId = opTypeKey(t);
	if (nameSetContains(lctx.generated, typeId) || hasLiftedOp(t, AttachedOp.AttachedDestructor)) {
		nameSetAdd(lctx.generated, typeId);
		return;
	}
	if (nameSetContains(lctx.generating, typeId)) return;
	if (!tupleNeedsHooks(t, lctx, loc)) return;
	nameSetAdd(lctx.generating, typeId);
	nameSetAdd(lctx.generated, typeId);
	generateTupleHook("destroy",  tupleName, t, lctx, loc);
	generateTupleHook("copy",     tupleName, t, lctx, loc);
	generateTupleHook("sink",     tupleName, t, lctx, loc);
	generateTupleHook("wasMoved", tupleName, t, lctx, loc);
}

function sizedArrayNeedsHooks(t: Type, lctx: LiftCtx, loc: SourceLocation): boolean {
	const elem = t.typeReturn;
	if (elem == null) return false;
	const probe = newBuf();
	const selfSym = liftSym(lctx, SymbolKind.Variable, "self", null);
	fillBody("destroy", makeTypedIdentResolved(selfSym, null, loc), makeTypedIdentResolved(selfSym, null, loc), "", elem, lctx, probe, createNameSet(), loc);
	return probe.items.length > 0;
}

function generateSizedArrayHook(hook: string, name: string, t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const elem = t.typeReturn;
	if (elem == null) return;
	const buf = newBuf();
	const isUnary = hook == "destroy" || hook == "wasMoved";
	const hookParamT = createVar(t);
	const s1 = liftSym(lctx, SymbolKind.Variable, isUnary ? "self" : "dest", hookParamT);
	const s2 = isUnary ? s1 : liftSym(lctx, SymbolKind.Variable, "src", hookParamT);
	if (!isUnary) {
		buf.items.push(makeIf(
			makeBinary(makeIdentResolved(s1, loc), "===", makeIdentResolved(s2, loc), loc),
			makeBlock([makeReturn(null as unknown as Node, loc)], loc), null, loc));
	}
	const x1 = hookParamDeref(s1, loc);
	x1.nodeType = t;
	const x2 = hookParamDeref(s2, loc);
	x2.nodeType = t;
	genElementLoop(hook, elem, makeNumber(t.typeValue as number, loc), x1, x2, lctx, buf, loc);
	const suffix = hookSuffix(hook);
	const fnNode = isUnary
		? makeFnDecl(name + suffix, [s1], [name], makeBlock(buf.items, loc), "", "void", loc)
		: makeFnDecl(name + suffix, [s1, s2], [name, name], makeBlock(buf.items, loc), "", "void", loc);
	setHookParamType(fnNode, 0, createVar(t));
	if (!isUnary) setHookParamType(fnNode, 1, createVar(t));
	liftOp(fnNode, t, t, attachedOpOf(hook), name + suffix);
	lctx.collector.push(fnNode);
}

function ensureSizedArrayHooks(t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	if (t == null || t.kind != TypeKind.SizedArray || t.typeReturn == null) return;
	const name = sizedArrayHookName(t);
	const typeId = opTypeKey(t);
	if (nameSetContains(lctx.generated, typeId) || hasLiftedOp(t, AttachedOp.AttachedDestructor)) {
		nameSetAdd(lctx.generated, typeId);
		return;
	}
	if (nameSetContains(lctx.generating, typeId)) return;
	if (!sizedArrayNeedsHooks(t, lctx, loc)) return;
	nameSetAdd(lctx.generating, typeId);
	nameSetAdd(lctx.generated, typeId);
	generateSizedArrayHook("destroy",  name, t, lctx, loc);
	generateSizedArrayHook("copy",     name, t, lctx, loc);
	generateSizedArrayHook("sink",     name, t, lctx, loc);
	generateSizedArrayHook("wasMoved", name, t, lctx, loc);
}

// ===== Tuple Comparison Operators (reference parity: reference core lines 1973-1996) =====
// Auto-generate ==, <, <= for tuples using positional field names (_0, _1, ...).
// Reference implementation uses `fields()` magic iterator; we unroll at transform time.

// Tuple field access helper: a._0, a._1, etc.
function tupleField(obj: Node, idx: number, lctx: LiftCtx, loc: SourceLocation): Node {
	const field = lctx.jsBackend ? makeArrayAccess(obj, makeNumber(idx, loc), loc) : makeMember(obj, "_" + idx.toString(), loc);
	const t = obj.nodeType;
	if (t != null && t.kind == TypeKind.Tuple && idx < t.typeChildren.length) field.nodeType = t.typeChildren[idx];
	return field;
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
	const aSym = liftSym(lctx, SymbolKind.Variable, "a", t);
	const bSym = liftSym(lctx, SymbolKind.Variable, "b", t);
	let i = 0;
	while (i < t.typeChildren.length) {
		const aField = tupleField(makeTypedIdentResolved(aSym, null, loc), i, lctx, loc);
		const bField = tupleField(makeTypedIdentResolved(bSym, null, loc), i, lctx, loc);
		// if (a._i < b._i) return true;
		buf.push(makeIf(makeBinary(aField, "<", bField, loc), makeBlock([makeReturn(makeBool(true, loc), loc)], loc), null, loc));
		// if (a._i > b._i) return false;
		const aField2 = tupleField(makeTypedIdentResolved(aSym, null, loc), i, lctx, loc);
		const bField2 = tupleField(makeTypedIdentResolved(bSym, null, loc), i, lctx, loc);
		buf.push(makeIf(makeBinary(aField2, ">", bField2, loc), makeBlock([makeReturn(makeBool(false, loc), loc)], loc), null, loc));
		i += 1;
	}
	buf.push(makeReturn(makeBool(false, loc), loc));
	const tltFn = makeFnDecl(tupleName + "Lt", [aSym, bSym], [tupleName, tupleName], makeBlock(buf, loc), "", "boolean", loc);
	setHookParamType(tltFn, 0, t);
	setHookParamType(tltFn, 1, t);
	liftOp(tltFn, t, t, AttachedOp.AttachedLt, tupleName + "Lt");
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
	const aSym = liftSym(lctx, SymbolKind.Variable, "a", t);
	const bSym = liftSym(lctx, SymbolKind.Variable, "b", t);
	let i = 0;
	while (i < t.typeChildren.length) {
		const aField = tupleField(makeTypedIdentResolved(aSym, null, loc), i, lctx, loc);
		const bField = tupleField(makeTypedIdentResolved(bSym, null, loc), i, lctx, loc);
		buf.push(makeIf(makeBinary(aField, "<", bField, loc), makeBlock([makeReturn(makeBool(true, loc), loc)], loc), null, loc));
		const aField2 = tupleField(makeTypedIdentResolved(aSym, null, loc), i, lctx, loc);
		const bField2 = tupleField(makeTypedIdentResolved(bSym, null, loc), i, lctx, loc);
		buf.push(makeIf(makeBinary(aField2, ">", bField2, loc), makeBlock([makeReturn(makeBool(false, loc), loc)], loc), null, loc));
		i += 1;
	}
	buf.push(makeReturn(makeBool(true, loc), loc));  // <= returns true when equal
	const tleFn = makeFnDecl(tupleName + "Le", [aSym, bSym], [tupleName, tupleName], makeBlock(buf, loc), "", "boolean", loc);
	setHookParamType(tleFn, 0, t);
	setHookParamType(tleFn, 1, t);
	liftOp(tleFn, t, t, AttachedOp.AttachedLe, tupleName + "Le");
	lctx.collector.push(tleFn);
}

// ===== Standalone Array Lifecycle Hooks (reference parity: reference sequence op) =====

function generateArrayHook(hook: string, arrayType: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const elemType = arrayType.typeReturn!;
	const isUnary = hook == "destroy" || hook == "wasMoved";
	const isTrace = hook == "trace";
	const sym = requireOpByKey(isTrace ? createRef(arrayType) : arrayType, attachedOpOf(hook));
	const buf = newBuf();
	const hookParamT = hook == "destroy" ? arrayType : createPtr(arrayType);
	const secondT = isTrace ? createPtr(voidType()) : arrayType;
	const s1 = liftSym(lctx, SymbolKind.Variable, isUnary || isTrace ? "self" : "dest", hookParamT);
	const s2 = isUnary ? s1 : liftSym(lctx, SymbolKind.Variable, isTrace ? "callback" : "src", secondT);

	if (hook == "destroy") {
		const selfNode = makeIdentResolved(s1, loc);
		selfNode.nodeType = arrayType;
		arrayOp(hook, elemType, selfNode, selfNode, lctx, buf, loc);
	} else if (hook == "wasMoved") {
		const d1 = makeHiddenDeref(makeIdentResolved(s1, loc), loc);
		d1.nodeType = arrayType;
		arrayOp(hook, elemType, d1, d1, lctx, buf, loc);
	} else if (hook == "copy") {
		const destNode = makeHiddenDeref(makeIdentResolved(s1, loc), loc);
		destNode.nodeType = arrayType;
		const srcNode = makeIdentResolved(s2, loc);
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
	} else if (isTrace) {
		const d1 = makeHiddenDeref(makeIdentResolved(s1, loc), loc);
		d1.nodeType = arrayType;
		arrayOp(hook, elemType, d1, makeIdentResolved(s2, loc), lctx, buf, loc);
	} else {
		const destNode = makeHiddenDeref(makeIdentResolved(s1, loc), loc);
		destNode.nodeType = arrayType;
		const srcNode = makeIdentResolved(s2, loc);
		srcNode.nodeType = arrayType;
		arrayOp(hook, elemType, destNode, srcNode, lctx, buf, loc);
	}

	const params = isUnary ? [s1] : [s1, s2];
	const paramTypes = isUnary ? [sym.name] : [sym.name, isTrace ? "void*" : sym.name];
	const fnNode = makeFnDecl(sym.name, params, paramTypes, makeBlock(buf.items, loc), "", "void", loc);
	const fnType = fnNode.nodeType!;
	fnType.typeChildren[0] = hookParamT;
	if (!isUnary) fnType.typeChildren[1] = secondT;
	sym.symbolType = fnType;
	sym.state = SymbolState.Checked;
	sym.declNode = fnNode;
	fnNode.resolvedSym = sym;
	lctx.collector.push(fnNode);
}

function generateArrayHooks(lctx: LiftCtx, loc: SourceLocation): void {
	let ti = 0;
	let wi = 0;
	while (ti < lctx.refCellTraces.length || wi < lctx.seqTypes.length) {
		if (ti < lctx.refCellTraces.length) {
			generateArrayHook("trace", lctx.refCellTraces[ti], lctx, loc);
			ti += 1;
			continue;
		}
		const arrT = lctx.seqTypes[wi];
		wi += 1;
		for (const hook of ["destroy", "copy", "sink", "wasMoved"]) generateArrayHook(hook, arrT, lctx, loc);
	}
}

// ===== Scan for Array Types =====

function registerRefCellTrace(arrT: Type, lctx: LiftCtx): void {
	const elem = arrayOpElement(arrT.typeReturn);
	if (elem == null || hasGenericParams(arrT) || !elemNeedsLoop(elem) || !isCyclicType(elem, lctx, createNameSet())) return;
	const canon = elem == arrT.typeReturn ? arrT : createArray(elem);
	const cell = createRef(canon);
	if (getOpByKey(cell, AttachedOp.AttachedTrace) != null) return;
	opPrototype(cell, AttachedOp.AttachedTrace, refArrayCellName(canon) + "Trace", lctx.checkerCtx);
	lctx.refCellTraces.push(canon);
}

function scanTypeForArrays(t: Type, lctx: LiftCtx, visited: HashSet<Type>): void {
	if (t == null || visited.has(t)) return;
	visited.add(t);
	if (t.kind == TypeKind.Ref && t.typeReturn != null && t.typeReturn.kind == TypeKind.Array) {
		registerRefCellTrace(t.typeReturn, lctx);
	}
	if (t.kind == TypeKind.Array) {
		if (t.typeReturn != null) registerArrayOps(t, lctx);
		return;
	}
	if (t.typeChildren != null) {
		for (const child of t.typeChildren) scanTypeForArrays(child, lctx, visited);
	}
	if (t.typeReturn != null) scanTypeForArrays(t.typeReturn, lctx, visited);
}

function scanRootForArrays(root: Type, lctx: LiftCtx): void {
	const epoch = instantiatedBodyCount();
	const seen = lctx.arrayRootEpochs.get(root);
	if (seen != null && seen == epoch) return;
	scanTypeForArrays(root, lctx, new HashSet<Type>());
	if (instantiatedBodyCount() == epoch) lctx.arrayRootEpochs.set(root, epoch);
}

function scanStmtForArrayTypes(stmt: Node, lctx: LiftCtx): void {
	if (stmt == null) return;
	match (stmt.kind) {
		NodeKind.VariableDecl => {
			if (stmt.nodeType != null) scanRootForArrays(stmt.nodeType, lctx);
		},
		NodeKind.FunctionDecl => {
			if (stmt.nodeType != null) scanRootForArrays(stmt.nodeType, lctx);
			// Recurse into function body to find local array types
			const fd = stmt.data as FunctionDeclData;
			if (fd.fnBody != null) scanBlockForArrayTypes(fd.fnBody, lctx);
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
	if (block == null || block.kind != NodeKind.BlockStmt) return;
	const bd = block.data as BlockStmtData;
	for (const s of bd.statements) {
		scanCtrlFlowForArrayTypes(s, lctx);
	}
}

function scanCtrlFlowForArrayTypes(s: Node, lctx: LiftCtx): void {
	if (s == null) return;
	match (s.kind) {
		NodeKind.VariableDecl => {
			if (s.nodeType != null) scanRootForArrays(s.nodeType, lctx);
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
			if (id.alternate != null) scanCtrlFlowForArrayTypes(id.alternate, lctx);
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
			if (td.catchBody != null) scanBlockForArrayTypes(td.catchBody, lctx);
			if (td.finallyBody != null) scanBlockForArrayTypes(td.finallyBody, lctx);
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

function scanTypeForOps(t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	while ((t.kind == TypeKind.Var || t.kind == TypeKind.Sink) && t.typeReturn != null) {
		t = t.typeReturn;
	}
	if (lctx.scannedTypes.has(t)) return;
	lctx.scannedTypes.add(t);
	if (t.kind == TypeKind.Function) {
		for (const pt of t.typeChildren) {
			if (pt != null) scanTypeForOps(pt, lctx, loc);
		}
	}
	liftTypeOps(t, lctx, loc);
}

function scanForAnonStructTypes(program: Node, lctx: LiftCtx): void {
	walkNode(program, (node: Node): Node => {
		if (node.nodeType != null) scanTypeForOps(node.nodeType, lctx, node.location);
		return node;
	});
}

function hookedDistinctElement(t: Type | null, lctx: LiftCtx, seen: HashSet<Type>): Type | null {
	if (t == null || seen.has(t)) return null;
	seen.add(t);
	const elem = t.kind == TypeKind.Array ? t.typeReturn : null;
	if (elem != null && elem.kind == TypeKind.Distinct && hasAnyUserHook(elem, lctx)) return elem;
	for (const child of t.typeChildren) {
		const hit = hookedDistinctElement(child, lctx, seen);
		if (hit != null) return hit;
	}
	return hookedDistinctElement(t.typeReturn, lctx, seen);
}

function refuseArrayOfHookedDistinct(t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	if (lctx.jsBackend || lctx.checkerCtx == null) return;
	const elem = hookedDistinctElement(t, lctx, new HashSet<Type>());
	if (elem == null || lctx.refusedArrayElems.has(elem)) return;
	lctx.refusedArrayElems.add(elem);
	addError(lctx.checkerCtx, "an array of the distinct type '" + elem.typeName + "' would never run its lifecycle hooks, because it is stored as an array of its base type: keep the values in a struct and make the array of those", loc.line, loc.column);
}

function liftTypeOps(t: Type, lctx: LiftCtx, loc: SourceLocation): void {
	refuseArrayOfHookedDistinct(t, lctx, loc);
		// Skip match-type variant structs (typeName like "Alias.Key") — their
		// hooks are emitted via the parent Union's `<Union>_v<N>` helper
		// dispatch, not as standalone `<Alias.Key>Copy` (which would be an
		// invalid C identifier anyway).
		if (t.kind == TypeKind.Struct && t.typeName != ""
			&& t.typeName.indexOf(".") < 0 && hasTypeIdentity(t)) {
			ensureHooks(t.typeName, t, null as unknown as Type, t, false, lctx, loc);
		} else if (t.kind == TypeKind.Struct && t.typeName == ""
			&& t.typeNames.length > 0
			&& !t.typeFlags.has(TypeFlag.DuVariant)) {
			// Nameless anon structs: classify OWNS these now (msAnon_<hash> hooks) —
			// generate their defs here or the analyzer's destroy/copy calls become
			// undefined symbols. DU-variant payloads excluded (classify defers them
			// to the DU machinery; a stray unstamped copy just makes a dead def).
			ensureHooks(anonTypeName(t), t, null as unknown as Type, t, false, lctx, loc);
		} else if (t.kind == TypeKind.Ref && t.typeReturn != null
			&& t.typeReturn.kind == TypeKind.Struct
			&& isAnonTypeName(t.typeReturn.typeName)
			&& t.typeReturn.typeNames.length > 0) {
			ensureHooks(anonTypeName(t.typeReturn), t.typeReturn, t, t.typeReturn, false, lctx, loc);
		} else if (t.kind == TypeKind.Union && t.typeName != ""
			&& hasAsgnFlag(t)
			&& !isAllStringLiteralUnion(t)
			&& unwrapRefNullUnion(t) == null) {
			ensureHooks(t.typeName, t, null as unknown as Type, t, false, lctx, loc);
		} else if (t.kind == TypeKind.Distinct && t.typeName != "") {
			ensureHooks(t.typeName, t, null as unknown as Type, t, false, lctx, loc);
		} else if (t.kind == TypeKind.Ref && t.typeReturn != null
			&& t.typeReturn.kind == TypeKind.Struct && t.typeReturn.typeName != "") {
			// Monomorphized class/interface: unwrap Ref, pass Ref as refType for HiddenDeref.
			ensureHooks(t.typeReturn.typeName, t.typeReturn, t, t.typeReturn, false, lctx, loc);
		} else if (t.kind == TypeKind.GenericInstance) {
			// Generic struct/class instance — unwrap to concrete Struct body with mangled
			// typeName so hook signatures match codegen's struct emission (types.ms:582-620).
			const unwrapped = unwrapGenericInstance(t);
			if (unwrapped.mangledName != "") {
				ensureHooks(unwrapped.mangledName, unwrapped.body, null as unknown as Type, t, false, lctx, loc);
			}
		} else if (t.kind == TypeKind.Ref && t.typeReturn != null
			&& t.typeReturn.kind == TypeKind.GenericInstance) {
			// Ref<GenericInstance> — class/interface of generic (e.g. Ref<Map<K,V>>).
			const unwrapped = unwrapGenericInstance(t.typeReturn);
			if (unwrapped.mangledName != "") {
				ensureHooks(unwrapped.mangledName, unwrapped.body, t, t.typeReturn, false, lctx, loc);
			}
		}
		// Array element hooks for any array used anywhere, including expression
		// position (literals, call args, returns). The decl-only scanStmtForArrayTypes
		// misses those, leaving a boxed T[]'s per-type <Name>ArrayDestroy walker
		// unemitted → undefined symbol once codegen references it.
		if (t.kind == TypeKind.Array
			|| (t.kind == TypeKind.Ref && t.typeReturn != null
				&& t.typeReturn.kind == TypeKind.Array)) {
			scanRootForArrays(t, lctx);
		}
		// A bare tuple local (reassigned or dropped) needs the same named hooks, but
		// fillBody only emits them for tuples that appear as a struct field — pre-register
		// here so classify.ms's msTuple_<hash>{Destroy,Sink} reference isn't undefined.
		if (t.kind == TypeKind.Tuple) {
			ensureTupleHooks(tupleTypeName(t), t, lctx, loc);
		}
		if (t.kind == TypeKind.SizedArray) {
			ensureSizedArrayHooks(t, lctx, loc);
		}
		if (t.kind == TypeKind.Union && t.typeName == "") {
			ensureAnonUnionHooks(t, lctx, loc);
		}
}

// ===== Process Declarations =====

// Look up the declared type's sym and dispatch to `ensureHooks`. Pulled out of
// processDecl's match arms so all three decl kinds share one resolve+dispatch.
function namesAnotherType(sym: Symbol, objType: Type, typeName: string): boolean {
	return sym.symbolKind == SymbolKind.TypeAlias
		&& sym.symbolType.kind != TypeKind.Ref
		&& objType.typeName != ""
		&& objType.typeName != typeName;
}

function declNameForError(node: Node): string {
	if (node.kind == NodeKind.ClassDecl) return (node.data as ClassDeclData).className;
	if (node.kind == NodeKind.TypeAliasDecl) return (node.data as TypeAliasDeclData).aliasName;
	return (node.data as InterfaceDeclData).interfaceName;
}

function ensureDeclaredHooks(sym: Symbol | null, node: Node, lctx: LiftCtx): void {
	if (lctx.checkerCtx == null) return;
	if (sym == null) {
		if (node.nodeType == null || node.nodeType.typeFlags.has(TypeFlag.Spelled)) return;
		throw new Error(`internal: ${node.kind as number} declaration '${declNameForError(node)}' at ${node.location.line}:${node.location.column} reached hook generation without a symbol`);
	}
	if (sym.symbolType == null || sym.instantiatedFrom != null) return;
	const objType = unwrapRef(sym.symbolType);
	if (objType == null) return;
	if (sym.symbolKind == SymbolKind.TypeAlias && sym.symbolType.kind == TypeKind.Ref) return;
	if (namesAnotherType(sym, objType, sym.name)) return;
	const refType = (sym.symbolKind == SymbolKind.Class || sym.symbolKind == SymbolKind.Actor || sym.symbolKind == SymbolKind.Interface)
		? sym.symbolType
		: null as unknown as Type;
	ensureHooks(sym.name, objType, refType, objType, true, lctx, node.location);
}

function processDecl(stmt: Node, lctx: LiftCtx): void {
	match (stmt.kind) {
		NodeKind.InterfaceDecl | NodeKind.StructDecl => {
			ensureDeclaredHooks(stmt.resolvedSym, stmt, lctx);
		},
		NodeKind.ClassDecl => {
			ensureDeclaredHooks(stmt.resolvedSym, stmt, lctx);
		},
		NodeKind.TypeAliasDecl => {
			ensureDeclaredHooks(stmt.resolvedSym, stmt, lctx);
		},
		NodeKind.ExportDecl => {
			const ed = stmt.data as ExportDeclData;
			processDecl(ed.exportedDecl, lctx);
		},
		_ => {},
	};
}

// A user hook declared for a distinct type binds to that type (reference bindHookToType accepts
// tyDistinct), so the distinct owns lifted ops of its own, lifted in the module that declares it.
function liftDistinctUserHooks(lctx: LiftCtx): void {
	const cc = lctx.checkerCtx;
	if (cc == null || cc.extensionRegistry == null) return;
	for (const hook of ["destroy", "copy", "sink", "wasMoved", "trace"]) {
		const methodName = userHookMethodName(hook);
		if (!hasExtensionByName(cc.extensionRegistry, methodName)) continue;
		for (const m of findAllExtensionsByName(cc.extensionRegistry, methodName)) {
			if (m.isStatic || m.sym == null || m.sym.modulePath != cc.modulePath) continue;
			const fnType = getExtFnType(m);
			if (fnType.kind != TypeKind.Function || fnType.typeChildren.length == 0) continue;
			let formal = fnType.typeChildren[0];
			while ((formal.kind == TypeKind.Var || formal.kind == TypeKind.Ref) && formal.typeReturn != null) formal = formal.typeReturn;
			if (formal.kind != TypeKind.Distinct || formal.sym == null || formal.sym.modulePath != cc.modulePath) continue;
			ensureHooks(formal.sym.name, formal, null as unknown as Type, formal, true, lctx, makeLoc(0, 0));
		}
	}
}

// ===== Main Entry Point =====

function newLiftCtx(ctx: TransformContext, jsBackend: boolean): LiftCtx {
	return {
		checkerCtx: ctx.checkerCtx,
		tempCounter: ctx.tempCounter,
		generated: createNameSet(),
		trivial: createNameSet(),
		generating: createNameSet(),
		helperOps: new HashMap<string, Symbol>(),
		collector: [],
		cyclicCache: createNameSet(),
		nonCyclicCache: createNameSet(),
		seqTypes: [],
		refCellTraces: [],
		scannedTypes: new HashSet<Type>(),
		arrayRootEpochs: new HashMap<Type, int32>(),
		refusedArrayElems: new HashSet<Type>(),
		jsBackend: jsBackend,
	};
}

// Comparison operators operatorLower routed to generated functions: tuple ordering and
// payload-union ==. reference parity: reference core:1980 (<=), :1989 (<) for tuples.
function tupleCompareOp(suffix: string): AttachedOp {
	return match (suffix) {
		"Lt" => AttachedOp.AttachedLt,
		_ => AttachedOp.AttachedLe,
	};
}

function liftComparisons(ctx: TransformContext, lctx: LiftCtx, loc: SourceLocation): void {
	for (const pending of ctx.pendingTupleOps) {
		for (const op of pending.ops) {
			if (!claimEq(pending.tupleType, tupleCompareOp(op), lctx)) {
				continue;
			}
			match (op) {
				"Lt" => { generateTupleLt(pending.tupleName, pending.tupleType, lctx, loc); },
				"Le" => { generateTupleLe(pending.tupleName, pending.tupleType, lctx, loc); },
				_ => {},
			};
		}
	}
	for (const unionType of ctx.pendingUnionEqs) {
		ensureUnionEq(unionType, lctx, loc);
	}
}

export function liftDestructors(program: Node, ctx: TransformContext, withHooks: boolean): Node {
	if (ctx.checkerCtx == null) return program;

	const pd = program.data as ProgramData;
	const lctx = newLiftCtx(ctx, !withHooks);

	if (withHooks) {
		for (const stmt of pd.programStmts) {
			processDecl(stmt, lctx);
		}
		liftDistinctUserHooks(lctx);

		// Scan for anonymous struct types (from ObjectLiterals with no declaration).
		// These have typeName like "__anon..." set by the checker but no InterfaceDecl.
		scanForAnonStructTypes(program, lctx);

		// Scan for standalone array type usage
		for (const stmt of pd.programStmts) {
			scanStmtForArrayTypes(stmt, lctx);
		}

		const defaultLoc = makeLoc(0, 0);
		generateArrayHooks(lctx, defaultLoc);
	}
	liftComparisons(ctx, lctx, makeLoc(0, 0));


	for (const decl of lctx.collector) {
		pd.programStmts.push(decl);
	}

	return program;
}

// ===== Tests =====

function liftWithChecker(input: string): Node {
	resetHookSyms();
	const pr = parseInput(input);
	if (!pr.ok) return null as unknown as Node;
	const checkerCtx = checkProgram(pr.value);
	const ctx = checkedCtx(checkerCtx);
	return liftDestructors(pr.value, ctx, true);
}


// Count generated lifecycle hook functions (5 base + optional trace)
function generatedFnCount(input: string): number {
	const prog = liftWithChecker(input);
	const pd = prog.data as ProgramData;
	let count = 0;
	for (const stmt of pd.programStmts) {
		if (stmt.kind == NodeKind.FunctionDecl) {
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

// Run the full lower→lift pipeline so a union `==` in the source drives on-demand Eq generation.
function liftWithCompare(input: string): Node {
	resetHookSyms();
	const pr = parseInput(input);
	if (!pr.ok) return null as unknown as Node;
	const checkerCtx = checkProgram(pr.value);
	const ctx = checkedCtx(checkerCtx);
	const lowered = lowerOperators(pr.value, ctx);
	return liftDestructors(lowered, ctx, true);
}

test "a payload union compared with == gets one generated Eq on C" {
	const src = "type NamedU = int32 | string; function same(a: NamedU, b: NamedU): boolean { return a == b; }";
	assert hasGeneratedFnIn(liftWithCompare(src), "Eq");
}

test "a struct compared with == gets no generated Eq: the std equality compares its fields" {
	const src = "struct Point { x: int32; y: int32; } function same(a: Point, b: Point): boolean { return a == b; }";
	assert !hasGeneratedFnIn(liftWithCompare(src), "PointEq");
}

function hasGeneratedFnIn(prog: Node, fnSuffix: string): boolean {
	const pd = prog.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind == NodeKind.FunctionDecl) {
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

function declaresTypeInfo(input: string, typeName: string): boolean {
	const prog = liftWithChecker(input);
	const pd = prog.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind == NodeKind.VariableDecl) {
			const d = stmt.data as VariableDeclData;
			if (d.declName == typeName + "TypeInfo") return true;
		}
	}
	return false;
}

test "the lifter declares no TypeInfo for an interface with a managed field" { assert !declaresTypeInfo("interface Token { value: string; }", "Token"); }

test "the lifter declares no TypeInfo for a primitive-only interface" { assert !declaresTypeInfo("interface Point { x: number; y: number; }", "Point"); }

test "the lifter declares no TypeInfo for a primitive-only struct" { assert !declaresTypeInfo("struct Point { x: number; y: number; }", "Point"); }

test "an alias spelling of an anonymous object type does not claim the structural type's hooks" { assert generatedFnCount("type Named = { name: string }; function f(a: Named[]): number { return a.length; } const xs: Named[] = [{ name: \"a\" }];") > 0; }

test "an anonymous object type used through two aliases gets one hook set" { assert generatedFnCount("type A = { name: string }; type B = { name: string }; const a: A = { name: \"x\" }; const b: B = { name: \"y\" }; const xs: A[] = [a]; const ys: B[] = [b];") == generatedFnCount("type A = { name: string }; const a: A = { name: \"x\" }; const xs: A[] = [a];"); }

test "primitive-only no hooks" { assert generatedFnCount("interface Point { x: number; y: number; }") == 0; }

test "string field generates 5 hooks" { assert generatedFnCount("interface Token { value: string; }") == 5; }

// canFormAcycle(Ref<Array<number>>) = false — no path back through number elements,
// so Data gets no _trace (destroy/copy/sink/wasMoved/dup only)
test "array field generates 5 hooks" { assert generatedFnCount("interface Data { items: number[]; }") == 5; }

// Ref<A> with acyclic pointee A{name:string} cannot be part of a cycle → no _trace on B
test "nested interface generates 10 hooks" { assert generatedFnCount("interface A { name: string; } interface B { a: A; }") == 10; }

test "no duplicates" { assert generatedFnCount("interface A { name: string; } interface B { a1: A; a2: A; }") == 10; }

// self-referential interface CAN form a cycle → keeps _trace (6th hook)
test "self-ref interface generates 6 hooks" { assert generatedFnCount("interface Node { value: number; next: Node | null; }") == 6; }

test "self-ref interface has trace" { assert hasGeneratedFn("interface Node { value: number; next: Node | null; }", "NodeTrace"); }

test "exported interface" { assert generatedFnCount("export interface Token { value: string; }") == 5; }

test "no interfaces passthrough" { assert generatedFnCount("const x = 1;") == 0; }
// =trace: Function fields are cyclic (closures capture refs)
test "trace NOT generated for flat string" { assert !hasGeneratedFn("interface Token { value: string; }", "TokenTrace"); }
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

test "eq NOT generated for interface" {
	assert !hasGeneratedFn("interface Token { value: string; }", "TokenEq");
}

test "eq NOT generated for class" {
	assert !hasGeneratedFn("class Obj { x: number; }", "ObjEq");
}

// Self-assign guard operand shape: both class (Ref) and value (Var<T>) hooks
// compare the raw param pointers — no ident auto-deref either way.
function copyGuardOperandKind(input: string, copyFnName: string): NodeKind {
	const prog = liftWithChecker(input);
	const pd = prog.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind != NodeKind.FunctionDecl) continue;
		const d = stmt.data as FunctionDeclData;
		if (d.fnName != copyFnName) continue;
		const body = d.fnBody.data as BlockStmtData;
		const guard = body.statements[0].data as IfStmtData;
		const cond = guard.condition.data as BinaryExprData;
		return cond.left.kind;
	}
	return NodeKind.FunctionDecl;
}

test "class copy guard compares param idents not param slots" {
	assert copyGuardOperandKind("interface Wrap { data: string; }", "WrapCopy") == NodeKind.Identifier;
}

test "value copy guard compares param pointers" {
	assert copyGuardOperandKind("struct SWrap { data: string; }", "SWrapCopy") == NodeKind.Identifier;
}

test "the parameters of a lifted hook are minted with an owner ordinal" {
	const prog = liftWithChecker("interface Wrap { data: string; }");
	let checked = 0;
	for (const stmt of (prog.data as ProgramData).programStmts) {
		if (stmt.kind != NodeKind.FunctionDecl || !(stmt.data as FunctionDeclData).fnName.endsWith("Destroy")) continue;
		assert stmt.paramSyms != null && stmt.paramSyms[0].item > 0;
		checked += 1;
	}
	assert checked == 1;
}

test "a lifted symbol cannot be minted without a checker context" {
	const lctx = newLiftCtx(createTransformContext(), false);
	let refused = "";
	try {
		liftSym(lctx, SymbolKind.Variable, "self", null);
	} catch (e) {
		refused = e.message;
	}
	assert refused.contains("self");
}
