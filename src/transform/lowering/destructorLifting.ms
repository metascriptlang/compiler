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

import {
	Node, NodeKind, DeclKind, ProgramData, FunctionDeclData, SourceLocation,
	InterfaceDeclData, ClassDeclData, ExportDeclData, VariableDeclData, TypeAliasDeclData,
	IdentifierData, MemberExprData, ArrayAccessData, HiddenDerefData,
} from "../../ast/node";
import { TransformContext, NameSet, nameSetContains, nameSetAdd, createTransformContextWithChecker, freshTemp } from "../context";
import { makeIdent, makeBlock, makeExprStmt, makeCall, makeMember, makeAssign, makeFnDecl, makeVarDecl, makeReturn, makeIf, makeBinary, makeUnary, makeNull, makeString, makeBool, makeNumber, makeObjectLiteral, makeHiddenAddr, makeHiddenDeref, makeWhile, makeArrayAccess } from "../util";
import { Type, TypeKind, isPrimitiveKind, AttachedOp, setAttachedOp, unwrapRef, createArray, createPtr, createPrimitive, stringType } from "../../checker/types";
import { wrapBodyIdentifiers } from "../native/pointerParam";
import { lookupSymbol, SymbolKind } from "../../checker/symbol";
import { checkProgram } from "../../checker/checkPass";
import { parseInput } from "../testUtil";

// ===== Lift Context (reference TLiftCtx) =====

interface LiftCtx {
	ctx: TransformContext;
	generated: NameSet;    // fully generated types (dedup)
	generating: NameSet;   // currently generating (cycle guard)
	collector: Node[];
	cyclicCache: NameSet;     // types confirmed cyclic
	nonCyclicCache: NameSet;  // types confirmed non-cyclic
	neededSeqHooks: NameSet;  // array hook families needed (e.g., "msStringArray", "msRefArray")
}

function namedTypeHasHooks(typeName: string, lctx: LiftCtx): boolean {
	return nameSetContains(lctx.generated, typeName) || nameSetContains(lctx.generating, typeName);
}

// ===== Cycle Detection (reference cyclicType) =====
// Determines if a type can form reference cycles (needed for =trace hook).

function isCyclicType(t: Type, lctx: LiftCtx, visited: NameSet): boolean {
	if (t === null) return false;
	if (isPrimitiveKind(t.kind) || t.kind === TypeKind.String) return false;

	match (t.kind) {
		TypeKind.Ref | TypeKind.Ptr | TypeKind.Function => { return true; },
		TypeKind.Array | TypeKind.Distinct => {
			if (t.typeReturn === null) return false;
			return isCyclicType(t.typeReturn, lctx, visited);
		},
		TypeKind.Object => {
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
		TypeKind.TypeReference => {
			if (t.typeName === "") return false;
			if (nameSetContains(visited, t.typeName)) return false;
			nameSetAdd(visited, t.typeName);
			const sym = lookupSymbol(lctx.ctx.checkerCtx.table, t.typeName);
			if (sym === null) return false;
			return isCyclicType(sym.symbolType, lctx, visited);
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

// ===== Reference defaultOp =====
// Primitives: copy/sink => assign, destroy/wasMoved => no-op

function defaultOp(hook: string, x: Node, y: Node, buf: Node[], loc: SourceLocation): void {
	if (hook === "copy" || hook === "sink") {
		buf.push(makeExprStmt(makeAssign(x, y, loc), loc));
	}
}

// ===== Node Path Cloning (Nim parity: dotField always creates fresh trees) =====
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
	// Nim parity: at(a, i, elemType) always creates fresh nkBracketExpr nodes
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
function genCall(name: string, hook: string, x: Node, y: Node, buf: Node[], loc: SourceLocation): void {
	if (hook === "destroy" || hook === "wasMoved") {
		buf.push(makeExprStmt(makeCall(makeIdent(name, loc), [x], loc), loc));
	} else {
		buf.push(makeExprStmt(makeCall(makeIdent(name, loc), [x, y], loc), loc));
	}
}

// Copy-ref pattern: incref source, then assign (Nim parity: incRef(y) → assign(x, y))
function genCopyRef(increfFn: string, x: Node, y: Node, fieldName: string, buf: Node[], loc: SourceLocation): void {
	buf.push(makeExprStmt(makeCall(makeIdent(increfFn, loc), [y], loc), loc));
	buf.push(makeExprStmt(makeAssign(x, clonePath(y, loc), loc), loc));
}

// Inline sink: destroy old value + raw assign (eliminates per-field function call)
function genInlineSink(destroyFn: string, xf: Node, yf: Node, buf: Node[], loc: SourceLocation): void {
	genCall(destroyFn, "destroy", xf, yf, buf, loc);
	// Clone xf for assign to avoid AST sharing (markPointerParams mutates in-place)
	buf.push(makeExprStmt(makeAssign(clonePath(xf, loc), yf, loc), loc));
}

// ===== Type Family Helpers (Modular pattern) =====
// Each helper owns all runtime names for its type family.

// --- Standard string hook generator ---
function stringOp(hook: string, xf: Node, yf: Node, fieldName: string, buf: Node[], loc: SourceLocation): void {
	match (hook) {
		"destroy" => { genCall("msStringDecref", hook, xf, yf, buf, loc); },
		"copy" => { genCopyRef("msStringIncref", xf, yf, fieldName, buf, loc); },
		"sink" => { genInlineSink("msStringDecref", xf, yf, buf, loc); },
		"wasMoved" => { genCall("msStringWasMoved", hook, xf, yf, buf, loc); },
		_ => {},
	};
}

// --- Inline element loop (Nim parity: forallElements + fillSeqOp) ---
// Generates: var $i = 0; while ($i < arr.length) { fillBody(elem, arr[$i], ...); $i = $i + 1; }
function genArrayLoop(hook: string, elemType: Type, xf: Node, yf: Node, lctx: LiftCtx, buf: Node[], loc: SourceLocation): void {
	const counterName = freshTemp(lctx.ctx, "i");
	buf.push(makeVarDecl(counterName, makeNumber(0, loc), DeclKind.Let, loc));

	// Nim parity: at(a, i, elemType) sets result.typ = elemType.
	// Set nodeType on cloned array expressions so nativeLower can rewrite arr[i] → msXxxArrayAccess(arr, i).
	const arrType = xf.nodeType;
	const xClone = clonePath(xf, loc);
	if (xClone.nodeType === null && arrType !== null) { xClone.nodeType = arrType; }
	const lenAccess = makeMember(clonePath(xf, loc), "length", loc);
	const cond = makeBinary(makeIdent(counterName, loc), "<", lenAccess, loc);

	const xi = makeArrayAccess(xClone, makeIdent(counterName, loc), loc);
	const bodyStmts: Node[] = [];
	const visited: NameSet = [];

	if (hook === "trace") {
		// Nim line 587: trace passes raw callback (y), not y[i]
		fillBody(hook, xi, yf, "", elemType, lctx, bodyStmts, visited, loc);
	} else if (hook === "copy") {
		const yClone = clonePath(yf, loc);
		if (yClone.nodeType === null && yf.nodeType !== null) { yClone.nodeType = yf.nodeType; }
		const yi = makeArrayAccess(yClone, makeIdent(counterName, loc), loc);
		fillBody(hook, xi, yi, "", elemType, lctx, bodyStmts, visited, loc);
	} else if (hook === "destroy") {
		fillBody(hook, xi, xi, "", elemType, lctx, bodyStmts, visited, loc);
	}

	// $i = $i + 1
	bodyStmts.push(makeExprStmt(makeAssign(
		makeIdent(counterName, loc),
		makeBinary(makeIdent(counterName, loc), "+", makeNumber(1, loc), loc),
		loc
	), loc));

	buf.push(makeWhile(cond, makeBlock(bodyStmts, loc), loc));
}

// --- Standard sequence/array hook generator (Nim parity: fillSeqOp) ---
// Primitive elements: runtime macros (no per-element cleanup).
// Non-primitive elements: inline loops via genArrayLoop (Nim's forallElements).
function arrayOp(hook: string, elem: Type, xf: Node, yf: Node, lctx: LiftCtx, buf: Node[], loc: SourceLocation): void {
	const needsElemLoop = elem !== null && !isPrimitiveKind(elem.kind);
	if (needsElemLoop && elem !== null) {
		if (elem.kind === TypeKind.String) {
			nameSetAdd(lctx.neededSeqHooks, "msStringArray");
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
			// Nim parity (genMove lines 2745-2751): if (dest.p != src.p) { destroy(dest) }; dest = src
			const guardCond = makeBinary(
				makeMember(clonePath(xf, loc), "p", loc),
				"!==",
				makeMember(clonePath(yf, loc), "p", loc),
				loc
			);
			const destroyStmt: Node[] = [];
			genCall("msArrayDestroy", "destroy", clonePath(xf, loc), yf, destroyStmt, loc);
			buf.push(makeIf(guardCond, makeBlock(destroyStmt, loc), null as unknown as Node, loc));
			buf.push(makeExprStmt(makeAssign(clonePath(xf, loc), clonePath(yf, loc), loc), loc));
		},
		"wasMoved" => { genCall("msArrayWasMoved", hook, xf, yf, buf, loc); },
		"trace" => {
			if (needsElemLoop) { genArrayLoop("trace", elem, xf, yf, lctx, buf, loc); }
		},
		_ => {},
	};
}

// --- Standard atomic reference hook generator ---
// isCyclic: true for types that can form reference cycles (reference parity: atomicRefOp)
// Cyclic types use msDecrefCyclic/msIncrefCyclic (ORC-aware when MS_ORC defined)
function refOp(hook: string, xf: Node, yf: Node, fieldName: string, isCyclic: boolean, buf: Node[], loc: SourceLocation): void {
	const decrefFn = isCyclic ? "msDecrefCyclic" : "msDecref";
	const increfFn = isCyclic ? "msIncrefCyclic" : "msIncref";
	match (hook) {
		"destroy" => { genCall(decrefFn, hook, xf, yf, buf, loc); },
		"copy" => { genCopyRef(increfFn, xf, yf, fieldName, buf, loc); },
		"sink" => { buf.push(makeExprStmt(makeAssign(xf, yf, loc), loc)); },
		"wasMoved" => { genCall("msPtrWasMoved", hook, xf, yf, buf, loc); },
		"trace" => {
			// Nim parity: nimTraceRef(addr(x), env) / nimTraceRefDyn(addr(x), env)
			// Our runtime: msOrcTraceRef(child, env)
			buf.push(makeExprStmt(makeCall(makeIdent("msOrcTraceRef", loc), [xf, yf], loc), loc));
		},
		_ => {},
	};
}

// --- Standard value-type object hook generator ---
// Reference parity: Named-type hooks take pointer params (ccgIntroducedPtr).
// Wrap field accesses in HiddenAddr so codegen emits &(self.field).
function namedObjOp(hook: string, typeName: string, xf: Node, yf: Node, buf: Node[], loc: SourceLocation): void {
	if (hook === "sink") {
		// Inline sink: destroy(&xf) + assign(xf = yf)
		buf.push(makeExprStmt(makeCall(makeIdent(typeName + "_destroy", loc), [makeHiddenAddr(xf, loc)], loc), loc));
		buf.push(makeExprStmt(makeAssign(xf, yf, loc), loc));
		return;
	}
	const name = hook === "wasMoved" ? "msObjectWasMoved" : typeName + hookSuffix(hook);
	// Named-type hooks expect pointers — wrap in HiddenAddr
	const ax = makeHiddenAddr(xf, loc);
	if (hook === "destroy" || hook === "wasMoved") {
		buf.push(makeExprStmt(makeCall(makeIdent(name, loc), [ax], loc), loc));
	} else if (hook === "trace") {
		// Nim parity: trace passes env through as-is (not &env)
		buf.push(makeExprStmt(makeCall(makeIdent(name, loc), [ax, yf], loc), loc));
	} else {
		const ay = makeHiddenAddr(yf, loc);
		buf.push(makeExprStmt(makeCall(makeIdent(name, loc), [ax, ay], loc), loc));
	}
}

// --- Parameterized runtime op (shared by closure, map) ---
function runtimeOp(prefix: string, destroyName: string, copySuffix: string, wasMovedSuffix: string, traceSuffix: string, hasTrace: boolean, hook: string, xf: Node, yf: Node, buf: Node[], loc: SourceLocation): void {
	match (hook) {
		"destroy" => { genCall(destroyName, hook, xf, yf, buf, loc); },
		"copy" => { genCall(prefix + copySuffix, hook, xf, yf, buf, loc); },
		"sink" => { genInlineSink(destroyName, xf, yf, buf, loc); },
		"wasMoved" => { genCall(prefix + wasMovedSuffix, hook, xf, yf, buf, loc); },
		"trace" => { if (hasTrace) genCall(prefix + traceSuffix, hook, xf, yf, buf, loc); },
		_ => {},
	};
}

// --- Set lifecycle ---
function setOp(hook: string, xf: Node, yf: Node, buf: Node[], loc: SourceLocation): void {
	match (hook) {
		"destroy" => { genCall("msSetFree", hook, xf, yf, buf, loc); },
		"copy" => { genCall("msSetCopy", hook, xf, yf, buf, loc); },
		"sink" => { genInlineSink("msSetFree", xf, yf, buf, loc); },
		_ => { defaultOp(hook, xf, yf, buf, loc); },
	};
}

// ===== fillBody — pure routing table (Standard pattern) =====
// Routes TypeKind to type family helper. No inline hook logic.

function fillBody(hook: string, x: Node, y: Node, fieldName: string, fieldType: Type, lctx: LiftCtx, buf: Node[], visited: NameSet, loc: SourceLocation): void {
	let xf = fieldName !== ""
		? makeMember(x, fieldName, loc)
		: x;
	if (fieldName !== "") { xf.nodeType = fieldType; }
	// Nim parity (liftdestructors.nim:165): trace keeps y as raw callback, not y.dotField(f)
	let yf = (fieldName !== "" && hook !== "trace")
		? makeMember(y, fieldName, loc)
		: y;
	if (fieldName !== "" && hook !== "trace") { yf.nodeType = fieldType; }

	// Tuple case extracted from match (MetaScript match arm limitation with block-scoped vars)
	if (fieldType.kind === TypeKind.Tuple) {
		let ti = 0;
		while (ti < fieldType.typeChildren.length) {
			const visited2: NameSet = [];
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
		TypeKind.Object => {
			if (fieldType.typeName !== "") {
				ensureTypeHooks(fieldType.typeName, lctx, loc);
				if (namedTypeHasHooks(fieldType.typeName, lctx)) {
					namedObjOp(hook, fieldType.typeName, xf, yf, buf, loc);
				} else {
					defaultOp(hook, xf, yf, buf, loc);
				}
			} else {
				defaultOp(hook, xf, yf, buf, loc);
			}
		},
		TypeKind.Ref | TypeKind.Ptr => {
			const cyclic = isCyclicType(fieldType, lctx, visited);
			refOp(hook, xf, yf, fieldName, cyclic, buf, loc);
		},
		TypeKind.Function => { runtimeOp("msClosure", "msClosureDestroy", "Copy", "WasMoved", "Trace", true, hook, xf, yf, buf, loc); },
		TypeKind.Map => { runtimeOp("msMap", "msMapFree", "Copy", "WasMoved", "Trace", false, hook, xf, yf, buf, loc); },
		TypeKind.Set => { setOp(hook, xf, yf, buf, loc); },
		TypeKind.Result => {},
		TypeKind.Union => {
			if (fieldType.typeName !== "") {
				ensureTypeHooks(fieldType.typeName, lctx, loc);
				if (namedTypeHasHooks(fieldType.typeName, lctx)) {
					namedObjOp(hook, fieldType.typeName, xf, yf, buf, loc);
				}
			}
		},
		TypeKind.Distinct => {
			if (fieldType.typeReturn !== null) {
				fillBody(hook, x, y, fieldName, fieldType.typeReturn, lctx, buf, visited, loc);
			}
		},
		TypeKind.TypeReference => {
			if (fieldType.typeName === "") return;
			if (nameSetContains(visited, fieldType.typeName)) return;
			nameSetAdd(visited, fieldType.typeName);
			const sym = lookupSymbol(lctx.ctx.checkerCtx.table, fieldType.typeName);
			if (sym === null) return;
			fillBody(hook, x, y, fieldName, sym.symbolType, lctx, buf, visited, loc);
		},
		_ => { defaultOp(hook, xf, yf, buf, loc); },
	};
}

// ===== Needs Hooks Check =====
// Probe: run fillBody("destroy") on throwaway buf. If it emits anything, type needs hooks.

function typeNeedsHooks(objType: Type, lctx: LiftCtx, loc: SourceLocation): boolean {
	if (objType.kind !== TypeKind.Object && objType.kind !== TypeKind.Union) return false;
	const probe: Node[] = [];
	if (objType.kind === TypeKind.Union) {
		// Probe each variant's fields
		for (let vi = 0; vi < objType.typeChildren.length; vi += 1) {
			const variant = objType.typeChildren[vi];
			if (variant !== null && variant.typeNames !== null) {
				for (let fi = 0; fi < variant.typeNames.length; fi += 1) {
					const visited: NameSet = [];
					fillBody("destroy", makeIdent("self", loc), makeIdent("self", loc), variant.typeNames[fi], variant.typeChildren[fi], lctx, probe, visited, loc);
					if (probe.length > 0) return true;
				}
			}
		}
		return false;
	}
	for (let i = 0; i < objType.typeNames.length; i += 1) {
		const visited: NameSet = [];
		fillBody("destroy", makeIdent("self", loc), makeIdent("self", loc), objType.typeNames[i], objType.typeChildren[i], lctx, probe, visited, loc);
		if (probe.length > 0) return true;
	}
	return false;
}

// ===== Inheritance Helper (Standard reference pattern) =====

function getBaseClass(typeName: string, lctx: LiftCtx): string {
	const sym = lookupSymbol(lctx.ctx.checkerCtx.table, typeName);
	if (sym === null) return "";
	if (sym.symbolKind !== SymbolKind.Class) return "";
	const inner = unwrapRef(sym.symbolType);
	if (inner.typeExtra === null) return "";
	if (inner.typeExtra.kind !== TypeKind.TypeReference) return "";
	return inner.typeExtra.typeName;
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
	const sym = lookupSymbol(lctx.ctx.checkerCtx.table, name);
	return sym !== null;
}

// ===== Union variant arm generation (if/else chain on _tag) =====

function generateUnionArms(hook: string, objType: Type, p1: string, p2: string, lctx: LiftCtx, buf: Node[], loc: SourceLocation): void {
	const isUnary = hook === "destroy" || hook === "wasMoved" || hook === "trace";

	// Nim parity (liftdestructors.nim:176-187): sink must destroy old variant BEFORE reassigning _tag
	if (hook === "sink") {
		// 1. Destroy old fields (dispatch on dest._tag)
		const destroyChain = buildVariantChain("destroy", objType, p1, p1, true, lctx, loc);
		if (destroyChain !== null) buf.push(destroyChain);
		// 2. Assign _tag
		buf.push(makeExprStmt(makeAssign(makeMember(makeIdent(p1, loc), "_tag", loc), makeMember(makeIdent(p2, loc), "_tag", loc), loc), loc));
		// 3. Assign new fields (dispatch on src._tag, simple assign only)
		const assignChain = buildVariantChain("sinkAssign", objType, p1, p2, false, lctx, loc);
		if (assignChain !== null) buf.push(assignChain);
		return;
	}

	// For copy: assign dest._tag = src._tag first
	if (!isUnary) {
		buf.push(makeExprStmt(makeAssign(makeMember(makeIdent(p1, loc), "_tag", loc), makeMember(makeIdent(p2, loc), "_tag", loc), loc), loc));
	}

	// Build if/else chain dispatching on _tag
	const chain = buildVariantChain(hook, objType, p1, p2, isUnary, lctx, loc);
	if (chain !== null) buf.push(chain);

	// For wasMoved: set _tag = -1 after dispatch
	if (hook === "wasMoved") {
		buf.push(makeExprStmt(makeAssign(makeMember(makeIdent(p1, loc), "_tag", loc), makeNumber(-1, loc), loc), loc));
	}
}

// Build if/else chain over variant arms, dispatching on p1._tag
function buildVariantChain(hook: string, objType: Type, p1: string, p2: string, isUnary: boolean, lctx: LiftCtx, loc: SourceLocation): Node {
	let chain = null as unknown as Node;
	let vi = objType.typeChildren.length - 1;
	while (vi >= 0) {
		const variant = objType.typeChildren[vi];
		const armBuf: Node[] = [];
		if (variant !== null && variant.typeNames !== null) {
			const vName = "v" + vi.toString();
			if (hook === "destroy") {
				// Reverse field order (LIFO)
				let fi = variant.typeNames.length - 1;
				while (fi >= 0) {
					const xBase = makeMember(makeIdent(p1, loc), vName, loc);
					const yBase = makeMember(makeIdent(p1, loc), vName, loc);
					const visited: NameSet = [];
					fillBody(hook, xBase, yBase, variant.typeNames[fi], variant.typeChildren[fi], lctx, armBuf, visited, loc);
					fi -= 1;
				}
			} else if (hook === "sinkAssign") {
				// Raw assign only (no RC ops — source ownership transferred)
				let fi = 0;
				while (fi < variant.typeNames.length) {
					const xBase = makeMember(makeIdent(p1, loc), vName, loc);
					const yBase = makeMember(makeIdent(p2, loc), vName, loc);
					armBuf.push(makeExprStmt(makeAssign(
						makeMember(xBase, variant.typeNames[fi], loc),
						makeMember(yBase, variant.typeNames[fi], loc), loc), loc));
					fi += 1;
				}
			} else {
				// Forward field order for copy/wasMoved/trace
				let fi = 0;
				while (fi < variant.typeNames.length) {
					const xBase = makeMember(makeIdent(p1, loc), vName, loc);
					// Nim parity: trace keeps y as raw callback, others use variant member
					const yBase = (hook === "trace") ? makeIdent(p2, loc)
						: isUnary ? makeMember(makeIdent(p1, loc), vName, loc)
						: makeMember(makeIdent(p2, loc), vName, loc);
					const visited: NameSet = [];
					fillBody(hook, xBase, yBase, variant.typeNames[fi], variant.typeChildren[fi], lctx, armBuf, visited, loc);
					fi += 1;
				}
			}
		}
		if (armBuf.length > 0) {
			const tagAccess = makeMember(makeIdent(p1, loc), "_tag", loc);
			const cond = makeBinary(tagAccess, "===", makeNumber(vi, loc), loc);
			chain = makeIf(cond, makeBlock(armBuf, loc), chain !== null ? chain : makeNull(loc), loc);
		}
		vi -= 1;
	}
	return chain;
}

// ===== Generate a single hook (Reference produceSym per op) =====

function generateHook(hook: string, typeName: string, objType: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const buf: Node[] = [];
	const isTrace = hook === "trace";
	const isUnary = hook === "destroy" || hook === "wasMoved" || isTrace;
	const p1 = isUnary ? "self" : "dest";
	const p2 = match (hook) {
		"trace" => "callback",
		"destroy" | "wasMoved" => "self",
		_ => "src",
	};

	// reference parity: no self-assignment check for simple objects (reference destructor lifting:311).
	// Reference only checks for case objects (which MetaScript doesn't have).
	// Field-by-field copy is self-assignment safe because each field's =copy handles it.

	// User-defined hook dispatch (Reference considerUserDefinedOp)
	if (hasUserDefinedHook(typeName, hook, lctx)) {
		const uName = userHookName(typeName, hook);
		if (isUnary) {
			buf.push(makeExprStmt(makeCall(makeIdent(uName, loc), [makeIdent(p1, loc)], loc), loc));
		} else {
			buf.push(makeExprStmt(makeCall(makeIdent(uName, loc), [makeIdent(p1, loc), makeIdent(p2, loc)], loc), loc));
		}
	} else {
		// Inheritance: ensure base class hooks exist (Implementation parity)
		const baseTypeName = getBaseClass(typeName, lctx);
		if (baseTypeName !== "") {
			ensureTypeHooks(baseTypeName, lctx, loc);
		}

		if (objType.kind === TypeKind.Union) {
			// Union: if/else chain on _tag, per-variant field iteration
			generateUnionArms(hook, objType, p1, p2, lctx, buf, loc);
		} else if (hook === "destroy") {
			// Destroy: fields first (reverse), then base class (LIFO — standard pattern)
			for (let i = objType.typeNames.length - 1; i >= 0; i -= 1) {
				const visited: NameSet = [];
				fillBody(hook, makeIdent(p1, loc), makeIdent(p2, loc), objType.typeNames[i], objType.typeChildren[i], lctx, buf, visited, loc);
			}
			if (baseTypeName !== "" && namedTypeHasHooks(baseTypeName, lctx)) {
				genCall(baseTypeName + "_destroy", hook, makeIdent(p1, loc), makeIdent(p2, loc), buf, loc);
			}
		} else {
			// Copy/sink/trace/wasMoved: base class first, then fields (standard pattern)
			if (baseTypeName !== "" && namedTypeHasHooks(baseTypeName, lctx)) {
				genCall(baseTypeName + hookSuffix(hook), hook, makeIdent(p1, loc), makeIdent(p2, loc), buf, loc);
			}
			for (let i = 0; i < objType.typeNames.length; i += 1) {
				const visited: NameSet = [];
				fillBody(hook, makeIdent(p1, loc), makeIdent(p2, loc), objType.typeNames[i], objType.typeChildren[i], lctx, buf, visited, loc);
			}
		}
	}

	const suffix = hookSuffix(hook);

	let fnNode: Node = null as unknown as Node;
	if (isTrace) {
		// trace(self, callback) — callback is a function pointer (void*)
		fnNode = makeFnDecl(typeName + suffix, [p1, p2], [typeName, "void*"], makeBlock(buf, loc), "", "void", loc);
	} else if (isUnary) {
		fnNode = makeFnDecl(typeName + suffix, [p1], [typeName], makeBlock(buf, loc), "", "void", loc);
	} else {
		fnNode = makeFnDecl(typeName + suffix, [p1, p2], [typeName, typeName], makeBlock(buf, loc), "", "void", loc);
	}
	// Replace TypeReference params with actual type so markPointerParams sees Union/Object correctly
	if (fnNode.nodeType !== null && fnNode.nodeType.typeChildren !== null) {
		for (let pi = 0; pi < fnNode.nodeType.typeChildren.length; pi += 1) {
			if (fnNode.nodeType.typeChildren[pi].kind === TypeKind.TypeReference) {
				fnNode.nodeType.typeChildren[pi] = objType;
			}
		}
	}
	lctx.collector.push(fnNode);
}

// ===== Ensure Type Hooks (Reference produceSym + fillBody) =====

function ensureTypeHooks(typeName: string, lctx: LiftCtx, loc: SourceLocation): void {
	if (nameSetContains(lctx.generated, typeName)) return;
	if (nameSetContains(lctx.generating, typeName)) return;
	nameSetAdd(lctx.generating, typeName);

	const sym = lookupSymbol(lctx.ctx.checkerCtx.table, typeName);
	if (sym === null) return;
	const objType = unwrapRef(sym.symbolType);
	if (objType.kind !== TypeKind.Object && objType.kind !== TypeKind.Union) return;
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
		}
		return;
	}

	// 4 core hooks via fillBody dispatch
	generateHook("destroy", typeName, objType, lctx, loc);
	generateHook("copy", typeName, objType, lctx, loc);
	generateHook("sink", typeName, objType, lctx, loc);
	generateHook("wasMoved", typeName, objType, lctx, loc);

	// Register hooks on the type (Standard reference parity)
	setAttachedOp(objType, AttachedOp.AttachedDestructor, typeName + "_destroy");
	setAttachedOp(objType, AttachedOp.AttachedAsgn, typeName + "_copy");
	setAttachedOp(objType, AttachedOp.AttachedSink, typeName + "_sink");
	setAttachedOp(objType, AttachedOp.AttachedWasMoved, typeName + "_wasMoved");

	// =trace: ORC cycle detection (only for cyclic types)
	const visited: NameSet = [];
	const hasCycles = isCyclicType(objType, lctx, visited);
	if (hasCycles) {
		generateHook("trace", typeName, objType, lctx, loc);
		setAttachedOp(objType, AttachedOp.AttachedTrace, typeName + "_trace");
	}

	// =dup: init + copy, return
	const dupStmts: Node[] = [];
	const isClass = sym.symbolKind === SymbolKind.Class;
	if (isClass) {
		// Nim parity (atomicRefOp attachedDup, liftdestructors.nim:793-801):
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
	lctx.collector.push(makeFnDecl(typeName + "_dup", ["src"], [typeName], makeBlock(dupStmts, loc), "", typeName, loc));
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
}

// ===== Auto-Generated == (reference parity: generic proc `==`*[T: tuple|object]) =====
// Generates TypeName_eq(a, b): boolean with field-by-field comparison.
// Reference implementation uses compile-time `fields()` magic iterator unrolling; we do the same here
// by iterating typeNames/typeChildren at transform time.

function fieldEqExpr(aField: Node, bField: Node, fieldType: Type, lctx: LiftCtx, loc: SourceLocation): Node {
	// For nested value-type objects, call their _eq function
	if (fieldType.kind === TypeKind.Object && fieldType.typeName !== "") {
		return makeCall(makeIdent(fieldType.typeName + "_eq", loc), [makeHiddenAddr(aField, loc), makeHiddenAddr(bField, loc)], loc);
	}
	// For TypeReference, resolve and recurse
	if (fieldType.kind === TypeKind.TypeReference && fieldType.typeName !== "") {
		const sym = lookupSymbol(lctx.ctx.checkerCtx.table, fieldType.typeName);
		if (sym !== null) {
			return fieldEqExpr(aField, bField, sym.symbolType, lctx, loc);
		}
	}
	// For all other types (primitives, strings, enums, etc): use === directly
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
	lctx.collector.push(makeFnDecl(typeName + "_eq", ["a", "b"], [typeName, typeName], makeBlock(buf, loc), "", "boolean", loc));
}

// ===== Ensure Eq (called for ALL interface types, even primitive-only) =====

function ensureEq(typeName: string, lctx: LiftCtx, loc: SourceLocation): void {
	if (nameSetContains(lctx.generated, typeName + "_eq")) return;
	nameSetAdd(lctx.generated, typeName + "_eq");

	const sym = lookupSymbol(lctx.ctx.checkerCtx.table, typeName);
	if (sym === null) return;
	// Only for value-type objects (interfaces), not ref-type classes (Ref<Object>)
	if (sym.symbolType.kind !== TypeKind.Object) return;

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
	lctx.collector.push(makeFnDecl(tupleName + "_eq", ["a", "b"], [tupleName, tupleName], makeBlock(buf, loc), "", "boolean", loc));
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
	lctx.collector.push(makeFnDecl(tupleName + "_lt", ["a", "b"], [tupleName, tupleName], makeBlock(buf, loc), "", "boolean", loc));
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
	lctx.collector.push(makeFnDecl(tupleName + "_le", ["a", "b"], [tupleName, tupleName], makeBlock(buf, loc), "", "boolean", loc));
}

// ===== Standalone Array Lifecycle Hooks (Nim parity: produceSym + fillSeqOp) =====

function generateArrayHook(hook: string, seqName: string, elemType: Type, arrayType: Type, lctx: LiftCtx, loc: SourceLocation): void {
	const buf: Node[] = [];
	const isUnary = hook === "destroy" || hook === "wasMoved";
	const p1 = isUnary ? "self" : "dest";
	const p2 = isUnary ? "self" : "src";

	// Nim parity (symPrototype lines 1138-1147):
	//   destroy: dest.typ = typ (by-value for seq in ARC/ORC)
	//   wasMoved: dest.typ = makeVarType (by-pointer)
	//   copy/sink: dest = makeVarType (by-pointer), src.typ = typ (by-value)
	// Nim parity (produceSym line 1193):
	//   d = if firstParamType == tyVar: newDeref(dest) else: dest
	//   src = newSymNode(src) — always raw (by-value)

	if (hook === "destroy") {
		// destroy(self: seq) — by-value, no deref
		const selfNode = makeIdent(p1, loc);
		selfNode.nodeType = arrayType;
		arrayOp(hook, elemType, selfNode, selfNode, lctx, buf, loc);
	} else if (hook === "wasMoved") {
		// wasMoved(self: var seq) — by-pointer, deref in body
		const d1 = makeHiddenDeref(makeIdent(p1, loc), loc);
		d1.nodeType = arrayType;
		arrayOp(hook, elemType, d1, d1, lctx, buf, loc);
	} else if (hook === "copy") {
		// copy(dest: var seq, src: seq) — dest deref, src raw
		const destNode = makeHiddenDeref(makeIdent(p1, loc), loc);
		destNode.nodeType = arrayType;
		const srcNode = makeIdent(p2, loc);
		srcNode.nodeType = arrayType;
		// Nim parity (checkSelfAssignment): if dest.p == src.p return
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
		buf.push(selfCheck);
		arrayOp(hook, elemType, destNode, srcNode, lctx, buf, loc);
	} else {
		// sink(dest: var seq, src: seq) — dest deref, src raw
		const destNode = makeHiddenDeref(makeIdent(p1, loc), loc);
		destNode.nodeType = arrayType;
		const srcNode = makeIdent(p2, loc);
		srcNode.nodeType = arrayType;
		arrayOp(hook, elemType, destNode, srcNode, lctx, buf, loc);
	}

	const suffix = hookSuffix(hook);

	let fnNode: Node = null as unknown as Node;
	if (isUnary) {
		fnNode = makeFnDecl(seqName + suffix, [p1], [seqName], makeBlock(buf, loc), "", "void", loc);
	} else {
		fnNode = makeFnDecl(seqName + suffix, [p1, p2], [seqName, seqName], makeBlock(buf, loc), "", "void", loc);
	}

	// Nim parity (symPrototype): set param types based on hook kind.
	// Arrays are 16 bytes < ccgIntroducedPtr threshold, so markPointerParams won't handle them.
	// destroy: by-value (no Ptr wrap)
	// wasMoved: by-pointer (Ptr wrap)
	// copy/sink: dest by-pointer, src by-value
	if (fnNode.nodeType !== null && fnNode.nodeType.typeChildren !== null) {
		if (hook === "destroy") {
			// All params stay as arrayType (by-value)
			let pi = 0;
			while (pi < fnNode.nodeType.typeChildren.length) {
				fnNode.nodeType.typeChildren[pi] = arrayType;
				pi += 1;
			}
		} else if (hook === "wasMoved") {
			// self → Ptr<Array>
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
	if (nameSetContains(lctx.neededSeqHooks, "msStringArray") && !nameSetContains(lctx.generated, "msStringArray")) {
		nameSetAdd(lctx.generated, "msStringArray");
		const strElemType = stringType();
		const strArrayType = createArray(strElemType);
		generateArrayHook("destroy", "msStringArray", strElemType, strArrayType, lctx, loc);
		generateArrayHook("copy", "msStringArray", strElemType, strArrayType, lctx, loc);
		generateArrayHook("sink", "msStringArray", strElemType, strArrayType, lctx, loc);
		generateArrayHook("wasMoved", "msStringArray", strElemType, strArrayType, lctx, loc);
	}

	if (nameSetContains(lctx.neededSeqHooks, "msRefArray") && !nameSetContains(lctx.generated, "msRefArray")) {
		nameSetAdd(lctx.generated, "msRefArray");
		const refElemType = createPrimitive(TypeKind.Ref);
		const refArrayType = createArray(refElemType);
		generateArrayHook("destroy", "msRefArray", refElemType, refArrayType, lctx, loc);
		generateArrayHook("copy", "msRefArray", refElemType, refArrayType, lctx, loc);
		generateArrayHook("sink", "msRefArray", refElemType, refArrayType, lctx, loc);
		generateArrayHook("wasMoved", "msRefArray", refElemType, refArrayType, lctx, loc);
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
	const visited: NameSet = [];
	match (stmt.kind) {
		NodeKind.VariableDecl => {
			if (stmt.nodeType !== null) scanTypeForArrays(stmt.nodeType, lctx, visited);
		},
		NodeKind.FunctionDecl => {
			if (stmt.nodeType !== null) scanTypeForArrays(stmt.nodeType, lctx, visited);
		},
		NodeKind.ExportDecl => {
			const ed = stmt.data as ExportDeclData;
			scanStmtForArrayTypes(ed.exportedDecl, lctx);
		},
		_ => {},
	};
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
		ctx,
		generated: [],
		generating: [],
		collector: [],
		cyclicCache: [],
		nonCyclicCache: [],
		neededSeqHooks: [],
	};

	for (const stmt of pd.programStmts) {
		processDecl(stmt, lctx);
	}

	// Scan for standalone array type usage
	for (const stmt of pd.programStmts) {
		scanStmtForArrayTypes(stmt, lctx);
	}

	// Generate standalone array lifecycle hooks
	const defaultLoc: SourceLocation = { file: "", line: 0, column: 0 };
	generateArrayHooks(lctx, defaultLoc);

	// Process pending tuple comparison ops (collected by operatorLower).
	// reference parity: reference core:1973 (==), :1980 (<=), :1989 (<) for tuples.
	for (const pending of ctx.pendingTupleOps) {
		for (const op of pending.ops) {
			const key = pending.tupleName + op;
			if (nameSetContains(lctx.generated, key)) continue;
			nameSetAdd(lctx.generated, key);
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
