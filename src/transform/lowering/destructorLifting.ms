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

import { Node, NodeKind, NodeFlag, DeclKind, ProgramData, FunctionDeclData, SourceLocation, makeLoc, InterfaceDeclData, ClassDeclData, ExportDeclData, VariableDeclData, TypeAliasDeclData, IdentifierData, MemberExprData, ArrayAccessData, HiddenDerefData, BlockStmtData, Type, TypeKind, AttachedOp, Symbol, SymbolKind } from "../../ast/node";
import { TransformContext, NameSet, nameSetContains, nameSetAdd, createNameSet, createTransformContextWithChecker } from "../context";
import { makeIdent, makeIdentResolved, makeBlock, makeExprStmt, makeCall, makeMember, makeAssign, makeFnDecl, makeVarDecl, makeReturn, makeIf, makeBinary, makeUnary, makeNull, makeString, makeBool, makeNumber, makeObjectLiteral, makeHiddenAddr, makeHiddenDeref, makeWhile, makeArrayAccess } from "../util";
import { isPrimitiveKind, setAttachedOp, unwrapRef, createArray, createPtr, createRef, createVar, createPrimitive, stringType, getTypeSize } from "../../checker/types";
import { walkNode } from "../walker";
import { lookupSymbol } from "../../checker/symbol";
import { CheckerContext } from "../../checker/context";
import { checkProgram } from "../../checker/checkPass";
import { parseInput } from "../testUtil";

// ===== Global Hook Ownership Registry =====
// Reference parity: attachedOps[] is global — hooks generated once per canonical type.
// First module to need a type's hooks generates the bodies; other modules skip.
// Consuming modules get extern forward declarations via ensureDrcProto in codegen.
let _globalHookOwners: NameSet = createNameSet();

export function setGlobalHookOwners(owners: NameSet): void {
	_globalHookOwners = owners;
}

function isGloballyOwned(typeName: string): boolean {
	return nameSetContains(_globalHookOwners, typeName);
}

function claimGlobal(typeName: string): void {
	nameSetAdd(_globalHookOwners, typeName);
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
		"destroy" => "_destroy",
		"copy" => "_copy",
		"sink" => "_sink",
		"trace" => "_trace",
		_ => "_wasMoved",
	};
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
	// Unary incref types: decref old, assign, incref new
	const decrefFn = increfFn === "msIncref" ? "msDecref"
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

// --- Standard sequence/array hook generator (reference parity: reference sequence op) ---
// Primitive elements: runtime macros (no per-element cleanup).
// Non-primitive elements: inline loops via genArrayLoop (reference loop pattern).
function arrayOp(hook: string, elem: Type, xf: Node, yf: Node, lctx: LiftCtx, buf: NodeBuf, loc: SourceLocation): void {
	const needsElemLoop = elem !== null && !isPrimitiveKind(elem.kind);
	if (needsElemLoop && elem !== null) {
		if (elem.kind === TypeKind.String) {
			nameSetAdd(lctx.neededSeqHooks, "msStringArray");
		} else if (elem.kind === TypeKind.Struct && elem.typeName !== "") {
			const seqName = elem.typeName + "Array";
			nameSetAdd(lctx.neededSeqHooks, seqName);
			lctx.seqElemTypes.push({ name: seqName, elemType: elem });
		} else {
			nameSetAdd(lctx.neededSeqHooks, "msRefArray");
		}
	}
	match (hook) {
		"destroy" => {
			if (needsElemLoop) { genArrayLoop("destroy", elem, xf, yf, lctx, buf, loc); }
			genCall("msArrayDestroy", hook, xf, yf, buf, loc);
		},
		"copy" => {
			if (needsElemLoop) {
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
// Cyclic types use msDecrefCyclic/msIncrefCyclic (ORC-aware when MS_ORC defined)
function refOp(hook: string, xf: Node, yf: Node, fieldName: string, isCyclic: boolean, buf: NodeBuf, loc: SourceLocation): void {
	const decrefFn = isCyclic ? "msDecrefCyclic" : "msDecref";
	const increfFn = isCyclic ? "msIncrefCyclic" : "msIncref";
	match (hook) {
		"destroy" => { genCall(decrefFn, hook, xf, yf, buf, loc); },
		"copy" => { genCopyRef(increfFn, xf, yf, fieldName, buf, loc); },
		"sink" => { buf.items.push(makeExprStmt(makeAssign(xf, yf, loc), loc)); },
		"wasMoved" => { genCall("msPtrWasMoved", hook, xf, yf, buf, loc); },
		"trace" => {
			buf.items.push(makeExprStmt(makeCall(makeIdent("msOrcTraceRef", loc), [xf, yf], loc), loc));
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
		buf.items.push(makeExprStmt(makeCall(makeIdent(typeName + "_destroy", loc), [makeHiddenAddr(xf, loc)], loc), loc));
		buf.items.push(makeExprStmt(makeAssign(xf, yf, loc), loc));
		return;
	}
	const name = hook === "wasMoved" ? "msObjectWasMoved" : typeName + hookSuffix(hook);
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
		let ti = 0;
		while (ti < fieldType.typeChildren.length) {
			const visited2: NameSet = createNameSet();
			// Use named field if available, otherwise positional _0, _1 pattern
			const tupleFn = (ti < fieldType.typeNames.length && fieldType.typeNames[ti].length > 0)
				? fieldType.typeNames[ti]
				: "_" + ti.toString();
			fillBody(hook, xf, yf, tupleFn, fieldType.typeChildren[ti], lctx, buf, visited2, loc);
			ti += 1;
		}
		return;
	}

	// Primitives fall through to _ => defaultOp (isPrimitiveKind is canonical list)
	match (fieldType.kind) {
		TypeKind.String => { stringOp(hook, xf, yf, fieldName, buf, loc); },
		TypeKind.Array => { arrayOp(hook, fieldType.typeReturn, xf, yf, lctx, buf, loc); },
		TypeKind.Struct => {
			if (fieldType.typeName !== "") {
				// Reference parity: trace only emits for cyclic field types (defaultOp is no-op for trace)
				if (hook !== "trace" || isCyclicType(fieldType, lctx, visited)) {
					ensureTypeHooks(fieldType.typeName, lctx, loc);
					if (namedTypeHasHooks(fieldType.typeName, lctx)) {
						namedObjOp(hook, fieldType.typeName, xf, yf, buf, loc);
					} else {
						defaultOp(hook, xf, yf, buf, loc);
					}
				}
			} else {
				defaultOp(hook, xf, yf, buf, loc);
			}
		},
		TypeKind.Ref => {
			const cyclic = isCyclicType(fieldType, lctx, visited);
			refOp(hook, xf, yf, fieldName, cyclic, buf, loc);
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
		TypeKind.GenericInstance => {},
		TypeKind.Union => {
			if (fieldType.typeName !== "") {
				if (hook !== "trace" || isCyclicType(fieldType, lctx, visited)) {
					ensureTypeHooks(fieldType.typeName, lctx, loc);
					if (namedTypeHasHooks(fieldType.typeName, lctx)) {
						namedObjOp(hook, fieldType.typeName, xf, yf, buf, loc);
					}
				}
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

// ===== Needs Hooks Check =====
// Probe: run fillBody("destroy") on throwaway buf. If it emits anything, type needs hooks.

function typeNeedsHooks(objType: Type, lctx: LiftCtx, loc: SourceLocation): boolean {
	if (objType.kind !== TypeKind.Struct && objType.kind !== TypeKind.Union) return false;
	const probe = newBuf();
	if (objType.kind === TypeKind.Union) {
		// Probe each variant's fields
		for (let vi = 0; vi < objType.typeChildren.length; vi += 1) {
			const variant = objType.typeChildren[vi];
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
// Maps lifecycle hooks to user extension method names.

function userHookName(typeName: string, hook: string): string {
	const suffix = match (hook) {
		"destroy" => "_onDestroy",
		"copy" => "_onCopy",
		"sink" => "_onMove",
		"wasMoved" => "_onMoved",
		"dup" => "_onClone",
		"trace" => "_onTrace",
		_ => "",
	};
	if (suffix === "") return "";
	return typeName + suffix;
}

function hasUserDefinedHook(typeName: string, hook: string, lctx: LiftCtx): boolean {
	const name = userHookName(typeName, hook);
	if (name === "") return false;
	const sym = lookupSymbol(lctx.checkerCtx.table, name);
	return sym !== null;
}

function getUserDefinedHookSym(typeName: string, hook: string, lctx: LiftCtx): Symbol {
	const name = userHookName(typeName, hook);
	if (name === "") return null as unknown as Symbol;
	return lookupSymbol(lctx.checkerCtx.table, name);
}

// ===== Union variant arm generation (if/else chain on _tag) =====

function generateUnionArms(hook: string, objType: Type, p1: string, p2: string, lctx: LiftCtx, buf: NodeBuf, loc: SourceLocation): void {
	const isUnary = hook === "destroy" || hook === "wasMoved" || hook === "trace";

	// reference parity: sink must destroy old variant BEFORE reassigning _tag
	if (hook === "sink") {
		// 1. Destroy old fields (dispatch on dest._tag)
		const destroyChain = buildVariantChain("destroy", objType, p1, p1, true, lctx, loc);
		if (destroyChain !== null) buf.items.push(destroyChain);
		// 2. Assign _tag
		buf.items.push(makeExprStmt(makeAssign(makeMember(makeIdent(p1, loc), "_tag", loc), makeMember(makeIdent(p2, loc), "_tag", loc), loc), loc));
		// 3. Assign new fields (dispatch on src._tag, simple assign only)
		const assignChain = buildVariantChain("sinkAssign", objType, p1, p2, false, lctx, loc);
		if (assignChain !== null) buf.items.push(assignChain);
		return;
	}

	// For copy: assign dest._tag = src._tag first
	if (!isUnary) {
		buf.items.push(makeExprStmt(makeAssign(makeMember(makeIdent(p1, loc), "_tag", loc), makeMember(makeIdent(p2, loc), "_tag", loc), loc), loc));
	}

	// Build if/else chain dispatching on _tag
	const chain = buildVariantChain(hook, objType, p1, p2, isUnary, lctx, loc);
	if (chain !== null) buf.items.push(chain);

	// For wasMoved: set _tag = -1 after dispatch
	if (hook === "wasMoved") {
		buf.items.push(makeExprStmt(makeAssign(makeMember(makeIdent(p1, loc), "_tag", loc), makeNumber(-1, loc), loc), loc));
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
			if (hook === "destroy") {
				// Reverse field order (LIFO)
				let fi = variant.typeNames.length - 1;
				while (fi >= 0) {
					const xBase = makeMember(makeIdent(p1, loc), vName, loc);
					const yBase = makeMember(makeIdent(p1, loc), vName, loc);
					const visited: NameSet = createNameSet();
					fillBody(hook, xBase, yBase, variant.typeNames[fi], variant.typeChildren[fi], lctx, armBuf, visited, loc);
					fi -= 1;
				}
			} else if (hook === "sinkAssign") {
				// Raw assign only (no RC ops — source ownership transferred)
				let fi = 0;
				while (fi < variant.typeNames.length) {
					const xBase = makeMember(makeIdent(p1, loc), vName, loc);
					const yBase = makeMember(makeIdent(p2, loc), vName, loc);
					armBuf.items.push(makeExprStmt(makeAssign(
						makeMember(xBase, variant.typeNames[fi], loc),
						makeMember(yBase, variant.typeNames[fi], loc), loc), loc));
					fi += 1;
				}
			} else {
				// Forward field order for copy/wasMoved/trace
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

	// User-defined hook dispatch (Reference considerUserDefinedOp)
	const hookSym = getUserDefinedHookSym(typeName, hook, lctx);
	if (hookSym !== null) {
		const hookIdent = makeIdentResolved(hookSym, loc);
		if (isUnary) {
			buf.items.push(makeExprStmt(makeCall(hookIdent, [makeIdent(p1, loc)], loc), loc));
		} else {
			buf.items.push(makeExprStmt(makeCall(hookIdent, [makeIdent(p1, loc), makeIdent(p2, loc)], loc), loc));
		}
	} else {
		// Inheritance: ensure base class hooks exist (Implementation parity)
		const baseTypeName = getBaseClass(typeName, lctx);
		if (baseTypeName !== "") {
			ensureTypeHooks(baseTypeName, lctx, loc);
		}

		const isRef = classType !== null;
		const x1 = isRef ? makeHiddenDeref(makeIdent(p1, loc), loc) : makeIdent(p1, loc);
		const x2 = (isRef && !isTrace) ? makeHiddenDeref(makeIdent(p2, loc), loc) : makeIdent(p2, loc);

		if (objType.kind === TypeKind.Union) {
			generateUnionArms(hook, objType, p1, p2, lctx, buf, loc);
		} else if (hook === "destroy") {
			// Destroy: fields first (reverse), then base class (LIFO — standard pattern)
			for (let i = objType.typeNames.length - 1; i >= 0; i -= 1) {
				const visited: NameSet = createNameSet();
				fillBody(hook, x1, x2, objType.typeNames[i], objType.typeChildren[i], lctx, buf, visited, loc);
			}
			if (baseTypeName !== "" && namedTypeHasHooks(baseTypeName, lctx)) {
				genCall(baseTypeName + "_destroy", hook, x1, x2, buf, loc);
			}
		} else {
			// Copy/sink/trace/wasMoved: base class first, then fields (standard pattern)
			if (baseTypeName !== "" && namedTypeHasHooks(baseTypeName, lctx)) {
				genCall(baseTypeName + hookSuffix(hook), hook, x1, x2, buf, loc);
			}
			for (let i = 0; i < objType.typeNames.length; i += 1) {
				const visited: NameSet = createNameSet();
				fillBody(hook, x1, x2, objType.typeNames[i], objType.typeChildren[i], lctx, buf, visited, loc);
			}
		}
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
	lctx.collector.push(fnNode);
}

// ===== Ensure Type Hooks (Reference produceSym + fillBody) =====

function ensureTypeHooks(typeName: string, lctx: LiftCtx, loc: SourceLocation): void {
	if (nameSetContains(lctx.generated, typeName)) return;
	// Reference parity: global dedup — another module already generated these hooks.
	// Consuming module gets extern forward declarations via ensureDrcProto in codegen.
	if (isGloballyOwned(typeName)) return;
	if (nameSetContains(lctx.generating, typeName)) return;
	nameSetAdd(lctx.generating, typeName);

	const sym = lookupSymbol(lctx.checkerCtx.table, typeName);
	if (sym === null) {
		// No symbol — may be an anonymous struct type. Skip (handled by ensureTypeHooksForType).
		return;
	}
	// Type alias to a class (Ref type): skip hook generation.
	// The canonical class type's RC ops (incref/decref) handle it.
	// Reference parity: `type Alias = ref T` shares the same ref semantics, no separate =destroy.
	if (sym.symbolKind === SymbolKind.TypeAlias && sym.symbolType !== null && sym.symbolType.kind === TypeKind.Ref) {
		nameSetAdd(lctx.generated, typeName);
		return;
	}
	const objType = unwrapRef(sym.symbolType);
	if (objType.kind !== TypeKind.Struct && objType.kind !== TypeKind.Union) return;
	if (!typeNeedsHooks(objType, lctx, loc)) {
		// Classes still need a minimal _typeInfo for msAllocTyped (even without RC hooks)
		if (sym.symbolKind === SymbolKind.Class) {
			const typeInfoObj = makeObjectLiteral(
				["name", "isCyclic", "traceFn", "destroyFn"],
				[makeString(typeName, loc), makeBool(false, loc), makeNull(loc), makeNull(loc)],
				loc,
			);
			lctx.collector.push(makeVarDecl(typeName + "_typeInfo", typeInfoObj, DeclKind.Const, loc));
			nameSetAdd(lctx.generated, typeName);
			claimGlobal(typeName);
		}
		return;
	}

	// Class types: hooks receive Ref<Struct> (pointer) — see generateHook comment
	const classType = sym.symbolKind === SymbolKind.Class ? sym.symbolType : null;

	// 4 core hooks via fillBody dispatch
	generateHook("destroy", typeName, objType, classType, lctx, loc);
	generateHook("copy", typeName, objType, classType, lctx, loc);
	generateHook("sink", typeName, objType, classType, lctx, loc);
	generateHook("wasMoved", typeName, objType, classType, lctx, loc);

	// Register hooks on the type (Standard reference parity)
	setAttachedOp(objType, AttachedOp.AttachedDestructor, typeName + "_destroy");
	setAttachedOp(objType, AttachedOp.AttachedAsgn, typeName + "_copy");
	setAttachedOp(objType, AttachedOp.AttachedSink, typeName + "_sink");
	setAttachedOp(objType, AttachedOp.AttachedWasMoved, typeName + "_wasMoved");

	// =trace: ORC cycle detection (only for cyclic types)
	const visited: NameSet = createNameSet();
	const hasCycles = isCyclicType(objType, lctx, visited);
	if (hasCycles) {
		generateHook("trace", typeName, objType, classType, lctx, loc);
		setAttachedOp(objType, AttachedOp.AttachedTrace, typeName + "_trace");
	}

	// =dup: init + copy, return
	const dupStmts: Node[] = [];
	const isClass = sym.symbolKind === SymbolKind.Class;
	if (isClass) {
		// reference parity (reference atomic ref op):
		// ref types: result = src; incref(result). No =copy call — just pointer copy + refcount.
		dupStmts.push(makeVarDecl("$result", makeIdent("src", loc), DeclKind.Let, loc));
		dupStmts.push(makeExprStmt(makeCall(makeIdent("msIncref", loc), [makeIdent("$result", loc)], loc), loc));
		dupStmts.push(makeReturn(makeIdent("$result", loc), loc));
	} else {
		// Value types: result = src; TypeName_copy(&result, &src); return result.
		dupStmts.push(makeVarDecl("$result", makeIdent("src", loc), DeclKind.Let, loc));
		dupStmts.push(makeExprStmt(makeCall(makeIdent(typeName + "_copy", loc), [makeHiddenAddr(makeIdent("$result", loc), loc), makeHiddenAddr(makeIdent("src", loc), loc)], loc), loc));
		dupStmts.push(makeReturn(makeIdent("$result", loc), loc));
	}
	const dupNode = makeFnDecl(typeName + "_dup", ["src"], [typeName], makeBlock(dupStmts, loc), "", typeName, loc);
	// Fix up _dup param/return types — classType for classes, objType for value types
	// _dup: param[0] = type, return = type (reference: symDupPrototype)
	const dupType = classType !== null ? classType : objType;
	setHookParamType(dupNode, 0, dupType);
	setHookReturnType(dupNode, dupType);
	lctx.collector.push(dupNode);
	setAttachedOp(objType, AttachedOp.AttachedDup, typeName + "_dup");

	// msTypeInfo generation for ORC runtime
	const traceFn = hasCycles ? makeIdent(typeName + "_trace", loc) : makeNull(loc);
	const typeInfoObj = makeObjectLiteral(
		["name", "isCyclic", "traceFn", "destroyFn"],
		[makeString(typeName, loc), makeBool(hasCycles, loc), traceFn, makeIdent(typeName + "_destroy", loc)],
		loc,
	);
	lctx.collector.push(makeVarDecl(typeName + "_typeInfo", typeInfoObj, DeclKind.Const, loc));

	nameSetAdd(lctx.generated, typeName);
	claimGlobal(typeName);
}

// Generate hooks for a type directly (no symbol table lookup needed).
// Used for anonymous struct types that have no InterfaceDecl/ClassDecl.
function ensureTypeHooksForType(objType: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const typeName = objType.typeName;
	if (typeName === "") return;
	if (nameSetContains(lctx.generated, typeName)) return;
	if (isGloballyOwned(typeName)) return;
	if (nameSetContains(lctx.generating, typeName)) return;
	nameSetAdd(lctx.generating, typeName);

	if (objType.kind !== TypeKind.Struct) return;
	if (!typeNeedsHooks(objType, lctx, loc)) return;

	// Anonymous structs are always value types (no classType)
	generateHook("destroy", typeName, objType, null, lctx, loc);
	generateHook("copy", typeName, objType, null, lctx, loc);
	generateHook("sink", typeName, objType, null, lctx, loc);
	generateHook("wasMoved", typeName, objType, null, lctx, loc);

	setAttachedOp(objType, AttachedOp.AttachedDestructor, typeName + "_destroy");
	setAttachedOp(objType, AttachedOp.AttachedAsgn, typeName + "_copy");
	setAttachedOp(objType, AttachedOp.AttachedSink, typeName + "_sink");
	setAttachedOp(objType, AttachedOp.AttachedWasMoved, typeName + "_wasMoved");

	// Value type _dup: result = src; TypeName_copy(&result, &src); return result.
	const dupStmts: Node[] = [];
	dupStmts.push(makeVarDecl("$result", makeIdent("src", loc), DeclKind.Let, loc));
	dupStmts.push(makeExprStmt(makeCall(makeIdent(typeName + "_copy", loc), [makeHiddenAddr(makeIdent("$result", loc), loc), makeHiddenAddr(makeIdent("src", loc), loc)], loc), loc));
	dupStmts.push(makeReturn(makeIdent("$result", loc), loc));
	const dupNode = makeFnDecl(typeName + "_dup", ["src"], [typeName], makeBlock(dupStmts, loc), "", typeName, loc);
	setHookParamType(dupNode, 0, objType);
	setHookReturnType(dupNode, objType);
	lctx.collector.push(dupNode);
	setAttachedOp(objType, AttachedOp.AttachedDup, typeName + "_dup");

	// No ORC typeInfo needed for anonymous value types (can't be cyclic)
	nameSetAdd(lctx.generated, typeName);
	claimGlobal(typeName);
}

// ===== Auto-Generated == (reference parity: generic proc `==`*[T: tuple|object]) =====
// Generates TypeName_eq(a, b): boolean with field-by-field comparison.
// Reference implementation uses compile-time `fields()` magic iterator unrolling; we do the same here
// by iterating typeNames/typeChildren at transform time.

function fieldEqExpr(aField: Node, bField: Node, fieldType: Type, lctx: LiftCtx, loc: SourceLocation): Node {
	// For nested value-type objects, call their _eq function
	if (fieldType.kind === TypeKind.Struct && fieldType.typeName !== "") {
		return makeCall(makeIdent(fieldType.typeName + "_eq", loc), [aField, bField], loc);
	}
	// String fields — reference parity: genStrEquals → eqStrings().
	// msString is a C struct, so === doesn't work. Call msStringEquals(a, b).
	if (fieldType.kind === TypeKind.String) {
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
	const eqFn = makeFnDecl(typeName + "_eq", ["a", "b"], [typeName, typeName], makeBlock(buf, loc), "", "boolean", loc);
	setHookParamType(eqFn, 0, objType);
	setHookParamType(eqFn, 1, objType);
	lctx.collector.push(eqFn);
}

// ===== Ensure Eq (called for ALL interface types, even primitive-only) =====

function ensureEq(typeName: string, lctx: LiftCtx, loc: SourceLocation): void {
	if (nameSetContains(lctx.generated, typeName + "_eq")) return;
	if (isGloballyOwned(typeName + "_eq")) return;
	nameSetAdd(lctx.generated, typeName + "_eq");
	claimGlobal(typeName + "_eq");

	const sym = lookupSymbol(lctx.checkerCtx.table, typeName);
	if (sym === null) return;
	// Only for value-type objects (interfaces), not ref-type classes (Ref<Object>)
	if (sym.symbolType.kind !== TypeKind.Struct) return;

	generateEq(typeName, sym.symbolType, lctx, loc);
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
	const teqFn = makeFnDecl(tupleName + "_eq", ["a", "b"], [tupleName, tupleName], makeBlock(buf, loc), "", "boolean", loc);
	setHookParamType(teqFn, 0, t);
	setHookParamType(teqFn, 1, t);
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
	const tltFn = makeFnDecl(tupleName + "_lt", ["a", "b"], [tupleName, tupleName], makeBlock(buf, loc), "", "boolean", loc);
	setHookParamType(tltFn, 0, t);
	setHookParamType(tltFn, 1, t);
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
	const tleFn = makeFnDecl(tupleName + "_le", ["a", "b"], [tupleName, tupleName], makeBlock(buf, loc), "", "boolean", loc);
	setHookParamType(tleFn, 0, t);
	setHookParamType(tleFn, 1, t);
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
			if (elem.kind === TypeKind.String) {
				nameSetAdd(lctx.neededSeqHooks, "msStringArray");
			} else if (elem.kind === TypeKind.Struct && elem.typeName !== "") {
				const seqName = elem.typeName + "Array";
				nameSetAdd(lctx.neededSeqHooks, seqName);
				lctx.seqElemTypes.push({ name: seqName, elemType: elem });
			} else {
				nameSetAdd(lctx.neededSeqHooks, "msRefArray");
			}
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
// Intentional divergence from reference (which is demand-driven).
// Our architecture requires pre-registration of array hooks before codegen.
function scanBlockForArrayTypes(block: Node, lctx: LiftCtx): void {
	if (block === null || block.kind !== NodeKind.BlockStmt) return;
	const bd = block.data as BlockStmtData;
	for (const s of bd.statements) {
		if (s === null) continue;
		const visited: NameSet = createNameSet();
		if (s.kind === NodeKind.VariableDecl) {
			if (s.nodeType !== null) scanTypeForArrays(s.nodeType, lctx, visited);
		} else if (s.kind === NodeKind.FunctionDecl) {
			scanStmtForArrayTypes(s, lctx);
		} else if (s.kind === NodeKind.BlockStmt) {
			scanBlockForArrayTypes(s, lctx);
		}
		// After transforms, if/while/try bodies are BlockStmt nodes.
		// We handle those via the BlockStmt branch above. Variable declarations
		// inside conditionals are always wrapped in blocks by lowering passes.
	}
}

// ===== Anonymous Struct Type Scanning =====

// Walk the AST to find anonymous struct types (typeName starts with "__anon").
// These have no InterfaceDecl so processDecl doesn't see them.
// Ensures lifecycle hooks are generated so DRC destroy calls link correctly.
function scanForAnonStructTypes(program: Node, lctx: LiftCtx, loc: SourceLocation): void {
	// Walk entire AST; check every node's type for anonymous structs
	walkNode(program, (node: Node): Node => {
		if (node.nodeType !== null && node.nodeType.kind === TypeKind.Struct
			&& node.nodeType.typeName !== "" && node.nodeType.typeName.length > 6
			&& node.nodeType.typeName.slice(0, 6) === "__anon") {
			ensureTypeHooksForType(node.nodeType, lctx, node.location);
		}
		return node;
	});
}

// ===== Process Declarations =====

function processDecl(stmt: Node, lctx: LiftCtx): void {
	match (stmt.kind) {
		NodeKind.InterfaceDecl => {
			const d = stmt.data as InterfaceDeclData;
			ensureTypeHooks(d.interfaceName, lctx, stmt.location);
			ensureEq(d.interfaceName, lctx, stmt.location);
		},
		NodeKind.ClassDecl => {
			const d = stmt.data as ClassDeclData;
			ensureTypeHooks(d.className, lctx, stmt.location);
		},
		NodeKind.TypeAliasDecl => {
			const d = stmt.data as TypeAliasDeclData;
			ensureTypeHooks(d.aliasName, lctx, stmt.location);
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

	// Generate standalone array lifecycle hooks
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
			if (op === "_eq") {
				generateTupleEq(pending.tupleName, pending.tupleType, lctx, defaultLoc);
			} else if (op === "_lt") {
				generateTupleLt(pending.tupleName, pending.tupleType, lctx, defaultLoc);
			} else if (op === "_le") {
				generateTupleLe(pending.tupleName, pending.tupleType, lctx, defaultLoc);
			}
		}
	}

	for (const decl of lctx.collector) {
		pd.programStmts.push(decl);
	}

	return program;
}

// ===== Tests =====

function liftWithChecker(input: string): Node {
	// Reset global registry for isolated test runs
	_globalHookOwners = createNameSet();
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
			if (d.fnName.endsWith("_destroy")
				|| d.fnName.endsWith("_copy")
				|| d.fnName.endsWith("_sink")
				|| d.fnName.endsWith("_wasMoved")
				|| d.fnName.endsWith("_dup")
				|| d.fnName.endsWith("_trace")) {
				count += 1;
			}
		}
	}
	return count;
}

// Check if a specific named function was generated
function hasGeneratedFn(input: string, fnSuffix: string): boolean {
	const prog = liftWithChecker(input);
	const pd = prog.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.FunctionDecl) {
			const d = stmt.data as FunctionDeclData;
			if (d.fnName.endsWith( fnSuffix)) return true;
		}
	}
	return false;
}

// Check if a TypeInfo variable was generated
function hasTypeInfo(input: string, typeName: string): boolean {
	const prog = liftWithChecker(input);
	const pd = prog.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.VariableDecl) {
			const d = stmt.data as VariableDeclData;
			if (d.declName === typeName + "_typeInfo") return true;
		}
	}
	return false;
}

test "primitive-only no hooks" { assert generatedFnCount("interface Point { x: number; y: number; }") === 0; }

test "string field generates 5 hooks" { assert generatedFnCount("interface Token { value: string; }") === 5; }

test "array field generates 5 hooks" { assert generatedFnCount("interface Data { items: number[]; }") === 5; }

test "nested interface generates 10 hooks" { assert generatedFnCount("interface A { name: string; } interface B { a: A; }") === 10; }

test "no duplicates" { assert generatedFnCount("interface A { name: string; } interface B { a1: A; a2: A; }") === 10; }

test "exported interface" { assert generatedFnCount("export interface Token { value: string; }") === 5; }

test "no interfaces passthrough" { assert generatedFnCount("const x = 1;") === 0; }
// =trace: Function fields are cyclic (closures capture refs)
test "trace NOT generated for flat string" { assert !hasGeneratedFn("interface Token { value: string; }", "Token_trace"); }
// TypeInfo generated alongside hooks
test "typeInfo generated" { assert hasTypeInfo("interface Token { value: string; }", "Token"); }

test "typeInfo NOT generated for primitives" { assert !hasTypeInfo("interface Point { x: number; y: number; }", "Point"); }
// Inheritance: child with own hookable field + base both generate hooks
test "inheritance generates parent hooks" {
	const src = "interface Base { name: string; } class Child extends Base { extra: string; }";
	assert hasGeneratedFn(src, "Base_destroy");
}
// All 5 core hooks present for a hookable type
test "all core hooks generated" {
	const src = "interface Wrap { data: string; }";
	assert hasGeneratedFn(src, "_destroy");
	assert hasGeneratedFn(src, "_copy");
	assert hasGeneratedFn(src, "_sink");
	assert hasGeneratedFn(src, "_wasMoved");
	assert hasGeneratedFn(src, "_dup");
}

// Auto-generated == (reference parity: generic proc `==`*[T: tuple|object])
test "eq generated for primitive-only interface" {
	assert hasGeneratedFn("interface Point { x: number; y: number; }", "Point_eq");
}

test "eq generated for string-field interface" {
	assert hasGeneratedFn("interface Token { value: string; }", "Token_eq");
}

test "eq generated for exported interface" {
	assert hasGeneratedFn("export interface Loc { line: number; col: number; }", "Loc_eq");
}

test "eq NOT generated for class" {
	assert !hasGeneratedFn("class Obj { x: number; }", "Obj_eq");
}
