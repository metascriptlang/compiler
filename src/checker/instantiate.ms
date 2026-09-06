// On-Demand Generic Instantiation — generateInstance + replaceTypeVars pattern
//
// When a generic extension method is matched during type checking,
// immediately clone the function body, substitute types, and register
// the specialized version. No separate monomorphize pass needed.

import { Node, NodeKind, NodeData, NodeFlag, SourceLocation, makeLoc, createNodeAt, FunctionDeclData, ReturnStmtData, MethodDeclData as MethodDeclDataLocal, ClassDeclData, ConstructorDeclData, ExportDeclData, DecoratedDeclData, VariableDeclData, TypeAssertionData, ArrowFunctionData, HiddenDerefData, HiddenStdConvData, SizeofExprData, Type, TypeKind, Symbol, SymbolKind, SymbolState } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { isUnresolvedType, instantiateGeneric, substituteType, createFunction, createRef, createStruct, isStructType, typeDisplayName, voidType } from "./types";
import { resolveAnnotation } from "./resolvePass";
import { lookupSymbol, makeSymbol, addSymbolToScope, SymbolFlag, hasFlag } from "./symbol";
import { CheckerContext, stripGenFlag, getExtReceiverType, isExtensionFlag, registerExtension, addError } from "./context";
import { monoCloneNode, monoSubstAnnotation, monoConcreteTypeName } from "../monomorphize/clone";
import { mangleMonoName } from "../monomorphize/registry";
import { callCheckFunctionBody, registerInstantiateGeneric } from "./checkerCallbacks";
import { getIdentId } from "./idents";
import { fitJoinedBranch } from "./fit";
import { bindFunctionFlow } from "../binder/index";

// ===== Global Instance Collection =====
// Module-level pending list — all instantiated ASTs go here.
// compile.ms drains this after each module's check.
let _pendingInstances: Node[] = [];
let _pendingNames: HashSet<string> = new HashSet<string>();

// ===== Module-Path → CheckerContext Registry =====
// When a generic body (function or class constructor) is cloned and re-checked
// during monomorphization, private module-level symbols in the defining module
// (e.g. `const INITIAL_CAPACITY` in std/core/struct.ms) must resolve. They live
// in the defining module's scope, not the caller's. This registry maps modulePath
// → ctx so the body re-check can target the correct scope.
//
// Reference parity: Nim's `graph.ifaces[itemId.module]` serves the same role.
//
// Populated by checkProgramCore (checkPass.ms) at the end of each module's check.
// Looked up by instantiateGenericFunction / instantiateClassConstructor.
let _moduleCtxMap: HashMap<string, CheckerContext> = new HashMap<string, CheckerContext>();

export function registerModuleCtx(modulePath: string, ctx: CheckerContext): void {
	if (modulePath == "") return;
	_moduleCtxMap.set(modulePath, ctx);
}

export function lookupModuleCtx(modulePath: string): CheckerContext | null {
	if (modulePath == "") return null;
	if (!_moduleCtxMap.has(modulePath)) return null;
	return _moduleCtxMap.get(modulePath);
}

// Module-level parsed Program registry. Populated post-parse by orchestrator.ms;
// looked up by macro VM (src/compiler/meta/expand.ms) to find PRIVATE same-module
// helpers (e.g. peelVariant, extractVariantKey in discDetect.ms) that the
// ExportRegistry can't surface (only exported symbols).
//
// Lightweight — stores reference, no snapshot. Macro inject walks programStmts
// for FunctionDecl reachable from macro body, then applies preprocessMacroBody
// to each (so NodeKind.X → int literal rewrite reaches helper bodies).
//
// Stored here (not as Module field) because src/module/graph.ms is forbidden
// from importing ast/ types. Same pattern as _moduleCtxMap above.
let _moduleProgramMap: HashMap<string, Node> = new HashMap<string, Node>();

export function registerModuleProgram(modulePath: string, program: Node): void {
	if (modulePath == "") return;
	_moduleProgramMap.set(modulePath, program);
}

export function lookupModuleProgram(modulePath: string): Node | null {
	if (modulePath == "") return null;
	if (!_moduleProgramMap.has(modulePath)) return null;
	return _moduleProgramMap.get(modulePath);
}

// Pick the right ctx for re-checking a body defined in `definingModulePath`:
//   1. Self-module (caller is also the defining module) — use ctx directly. The
//      module is currently being checked, so its scope is live but not yet in
//      the registry (registration happens at end of checkProgramCore).
//   2. Registry — another user module that has already finished checking.
//   3. preludeCtx — stdlib/prelude modules share a single ctx, not registered
//      via checkProgramCore. This fallback covers them.
//   4. Caller's ctx — last resort when all lookups miss.
// Reference parity: Nim's `graph.ifaces[module]` via the `symMap` for generic
// instantiation body re-check.
export function pickBodyCtx(definingModulePath: string, ctx: CheckerContext): CheckerContext {
	if (definingModulePath == "" || definingModulePath == ctx.modulePath) return ctx;
	const defining = lookupModuleCtx(definingModulePath);
	if (defining != null) return defining;
	if (ctx.preludeCtx != null) return ctx.preludeCtx;
	return ctx;
}

// ===== Constructor Default Registry =====
// Cross-module registry for constructor function types + defaults.
// Each module has its own symbol table, so constructor symbols can't be shared
// via scope. This registry is module-level (shared across all checker invocations)
// and provides the concrete param types needed for default-fill in checkNewExpr.
interface CtorEntry {
	name: string;
	fnType: Type;
	defaults: Node[];
}
let _ctorRegistry: CtorEntry[] = [];

export function registerCtorDefaults(name: string, fnType: Type, defaults: Node[]): void {
	for (const e of _ctorRegistry) {
		if (e.name == name) return; // already registered
	}
	_ctorRegistry.push({ name, fnType, defaults });
}

export function lookupCtorDefaults(ctorFnName: string): CtorEntry {
	for (const e of _ctorRegistry) {
		if (e.name == ctorFnName) return e;
	}
	return null as unknown as CtorEntry;
}

function pendingInstanceKey(node: Node, name: string): string {
	const owner = node.resolvedSym != null ? node.resolvedSym.modulePath : "";
	return owner + "::" + name;
}

export function addPendingInstance(node: Node): void {
	let key = "";
	if (node.kind == NodeKind.FunctionDecl) {
		key = pendingInstanceKey(node, (node.data as FunctionDeclData).fnName);
	} else if (node.kind == NodeKind.ClassDecl) {
		key = pendingInstanceKey(node, (node.data as ClassDeclData).className);
	}
	if (key != "") {
		if (_pendingNames.has(key)) return;
		_pendingNames.add(key);
	}
	_pendingInstances.push(node);
}

export function drainPendingInstances(): Node[] {
	const result = _pendingInstances;
	_pendingInstances = [];
	_pendingNames = new HashSet<string>();
	return result;
}

// ===== Helpers =====

// Deduplicate unify bindings (K=string may appear twice from HashMap<K,V> + K params)
function deduplicateBindings(names: string[], types: Type[]): { names: string[], types: Type[] } {
	const outNames: string[] = [];
	const outTypes: Type[] = [];
	for (let i = 0; i < names.length; i += 1) {
		if (i >= types.length) break;
		let dup = false;
		for (const n of outNames) { if (n == names[i]) { dup = true; break; } }
		if (!dup) {
			outNames.push(names[i]);
			outTypes.push(types[i]);
		}
	}
	return { names: outNames, types: outTypes };
}

// Add a type symbol to scope if not already present. Returns true if injected.
// Prefers caller's authoritative symbol type; falls back to provided type.
function tryInjectTypeSym(name: string, fallbackType: Type, ctx: CheckerContext, callerCtx: CheckerContext, injected: Symbol[]): void {
	if (lookupSymbol(ctx.table, name) != null) return;
	const callerSym = lookupSymbol(callerCtx.table, name);
	const symType = callerSym != null ? callerSym.symbolType : fallbackType;
	const sym = makeSymbol(name, SymbolKind.TypeAlias, symType, false);
	sym.nameId = getIdentId(ctx.table.identCache, name);
	addSymbolToScope(ctx.table.current, sym);
	injected.push(sym);
}

// Inject concrete type symbols into scope so resolveAnnotation finds them during re-check.
// For Array<Ref<Item>>, extracts "Item" and adds Ref<Struct("Item")> to scope.
// Reference parity (instantiateGenericParamList): concrete types added to scope.
function injectConcreteTypeSyms(t: Type | null, ctx: CheckerContext, callerCtx: CheckerContext, injected: Symbol[]): void {
	if (t == null) return;
	const tr = t.typeReturn;
	// Hand-rolled dispatch: match `when` guards don't propagate narrowing into
	// the arm body in the current binder, so we can't safely access `tr.kind`
	// inside `TypeKind.Ref when (tr !== null) => { ... tr.kind ... }`. The
	// if-chain below makes the narrowing scope explicit and matches the binder's
	// flow-based narrowing exactly.
	if (t.kind == TypeKind.Ref && tr != null) {
		if (tr.kind == TypeKind.Struct && tr.typeName != "") {
			tryInjectTypeSym(tr.typeName, t, ctx, callerCtx, injected);
		}
		injectConcreteTypeSyms(tr, ctx, callerCtx, injected);
		return;
	}
	if (t.kind == TypeKind.Array && tr != null) {
		injectConcreteTypeSyms(tr, ctx, callerCtx, injected);
		return;
	}
	// Named user types — Struct (interface/class), Enum, Distinct (type alias).
	// Cross-module body re-check needs the concrete type symbol injected so
	// `resolveAnnotation("Color[]")` resolves to ColorArray instead of falling
	// back to Unknown → msRefArray. Without these, a helper
	// `function f<T>(...): T[] { const out: T[] = []; ... }` called with
	// T=Color emits the function signature mangled correctly but the body's
	// `out` declared as untyped msRefArray, breaking the assignment site at
	// C compile time.
	if ((t.kind == TypeKind.Struct || t.kind == TypeKind.Enum || t.kind == TypeKind.Distinct)
			&& t.typeName != "") {
		tryInjectTypeSym(t.typeName, t, ctx, callerCtx, injected);
		return;
	}
	if (t.kind == TypeKind.Union) {
		if (t.typeName != "") {
			tryInjectTypeSym(t.typeName, t, ctx, callerCtx, injected);
		}
		injectConcreteTypeSyms(t.typeExtra, ctx, callerCtx, injected);
		if (t.typeChildren != null) {
			for (const child of t.typeChildren) {
				injectConcreteTypeSyms(child, ctx, callerCtx, injected);
			}
		}
		return;
	}
	if (t.kind == TypeKind.GenericInstance && t.typeChildren != null) {
		for (const child of t.typeChildren) {
			injectConcreteTypeSyms(child, ctx, callerCtx, injected);
		}
	}
}

function removeInjectedSyms(ctx: CheckerContext, injected: Symbol[]): void {
	for (const sym of injected) {
		// Each injected sym has a real nameId (set in injectConcreteTypeSyms before push);
		// O(1) removal by key instead of linear-scan-swap-pop.
		if (sym.nameId != 0) {
			ctx.table.current.symbols.delete(sym.nameId);
		}
	}
}

// Nim `mixin` semantics for convention protocols (docs/PROTOCOLS.md Part II):
// the instantiating module's extensions are visible while the generic body is
// re-checked in the defining module's ctx, then removed. Exported only — the
// instance is emitted in the defining module's TU, so a private extension
// would resolve here but fail at link; skipping it surfaces a check-time
// "no member" error with the instantiation note instead.
function injectCallerExtensions(bodyCtx: CheckerContext, ctx: CheckerContext): int32 {
	if (bodyCtx == ctx) return -1;
	if (bodyCtx.extensionRegistry == null || ctx.extensionRegistry == null) return -1;
	const preCount = bodyCtx.extensionRegistry.methods.length;
	for (const m of ctx.extensionRegistry.methods) {
		// Drop only KNOWN-private extensions of the instantiating module itself.
		// Import-derived entries are exported by construction but their local
		// sym view does NOT carry the Exported flag — discriminate by the sym's
		// defining modulePath instead of the flag alone.
		if (m.sym != null
				&& (m.sym.modulePath == "" || m.sym.modulePath == ctx.modulePath)
				&& !hasFlag(m.sym, SymbolFlag.Exported)) {
			continue;
		}
		registerExtension(bodyCtx.extensionRegistry, m);
	}
	return preCount;
}

function truncateCallerExtensions(bodyCtx: CheckerContext, preCount: int32): void {
	if (preCount < 0) return;
	bodyCtx.extensionRegistry.methods.length = preCount;
}

function displayTypeArgs(types: Type[]): string {
	if (types.length == 0) return "";
	let s = "<";
	for (let i = 0; i < types.length; i += 1) {
		if (i > 0) s = s + ", ";
		s = s + typeDisplayName(types[i]);
	}
	return s + ">";
}


// Unwrap ExportDecl/DecoratedDecl to get the inner FunctionDecl. For class
// methods (static OR instance) synthesize an equivalent FunctionDecl from the
// MethodDecl so the existing instantiation flow drives mono on it. Instance
// methods already carry `this` as param 0 (prepended in collectClassMethod).
function unwrapToFunctionDecl(node: Node): Node {
	if (node == null) return null as unknown as Node;
	let n = node;
	if (n.kind == NodeKind.ExportDecl) n = (n.data as ExportDeclData).exportedDecl;
	if (n != null && n.kind == NodeKind.DecoratedDecl) n = (n.data as DecoratedDeclData).decoratedNode;
	if (n != null && n.kind == NodeKind.FunctionDecl) return n;
	if (n != null && n.kind == NodeKind.MethodDecl) {
		const md = n.data as MethodDeclDataLocal;
		// Synthesize a FunctionDecl-shaped Node mirroring this method. The class
		// name is woven in through the symbol's name (set by collectMethodMember
		// as `${className}_${methodName}`) — mangleMonoName uses sym.name, so no
		// need to repeat the prefix here.
		const fnData: NodeData = {
			fnName: md.methodName,
			params: md.methodParams,
			fnParamTypes: md.methodParamTypes,
			fnBody: md.methodBody,
			fnFlags: md.methodFlags,
			fnReturnType: md.methodReturnType,
			fnDefaults: [],
			nativeName: md.nativeName,
			nameLocation: md.nameLocation,
		};
		const synth = createNodeAt(NodeKind.FunctionDecl, fnData, n.location);
		synth.nodeType = n.nodeType;
		return synth;
	}
	return null as unknown as Node;
}

// Substitute type param names in an array of type annotation strings.
function substituteTypeStrings(strs: string[], names: string[], types: Type[]): void {
	for (let i = 0; i < names.length; i += 1) {
		if (i >= types.length) break;
		const pname = names[i];
		const cname = monoConcreteTypeName(types[i]);
		for (let si = 0; si < strs.length; si += 1) {
			strs[si] = monoSubstAnnotation(strs[si], pname, cname);
		}
	}
}

// ===== clearCheckerState =====
// Collapse HiddenDeref/HiddenAddr/HiddenStdConv wrappers and clear resolvedSym/flags on a
// cloned AST so the re-check regenerates them against concrete types. forEachChild drives
// the recursion so EVERY NodeKind is covered — a manual match silently missed ForStmt/Switch/
// Match etc., stacking a second deref on loop/array accesses in instantiated method bodies.
function clearCheckerState(node: Node): void {
	if (node == null) return;
	while (node.kind == NodeKind.HiddenDeref || node.kind == NodeKind.HiddenAddr || node.kind == NodeKind.HiddenStdConv) {
		const inner = node.kind == NodeKind.HiddenStdConv
			? (node.data as HiddenStdConvData).convExpr
			: (node.data as HiddenDerefData).expr;
		if (inner == null) break;
		node.kind = inner.kind;
		node.data = inner.data;
		node.nodeType = inner.nodeType;
	}
	// Enum member access is a mangled Identifier ("E_M") whose name is never bound
	// in scope — resolvedSym is its ONLY resolution path (checkExprPass honors it,
	// clone.ms preserves it). The enum member type is concrete, never generic, so
	// it needs no regeneration against the instance's concrete types. Keep it.
	// See NIM-REF.md §1 "Enum member repr & generic-instantiation survival".
	const keepBound = (node.flags & NodeFlag.BoundSym) != 0 && node.resolvedSym != null;
	if (!keepBound && (node.resolvedSym == null || node.resolvedSym.symbolKind != SymbolKind.EnumMember)) {
		node.resolvedSym = null;
	}
	node.flags = node.flags & NodeFlag.BoundSym;
	forEachChild(node, (child: Node): void => { clearCheckerState(child); });
}

// ===== replaceTypeVars =====
// Walk every node in the cloned body and substitute GenericParam types with
// concrete types on nodeType plus any string-form annotations.
//
// Reference parity: replaceTypeVarsN iterates all children uniformly.
// We delegate child enumeration to forEachChild (the canonical walker in
// src/ast/visitor.ms) so every NodeKind is covered by construction — adding a
// new NodeKind cannot silently break generic instantiation.

// Substitute all generic param names → concrete types in a single annotation string.
function substAnnotationAll(ann: string, paramNames: string[], concreteTypes: Type[]): string {
	if (ann == "") return ann;
	let out = ann;
	for (let i = 0; i < paramNames.length; i += 1) {
		if (i < concreteTypes.length) {
			out = monoSubstAnnotation(out, paramNames[i], monoConcreteTypeName(concreteTypes[i]));
		}
	}
	return out;
}

// Apply substitutions to node-local state (nodeType + per-kind string annotations).
// Does NOT descend into children — that's forEachChild's job.
function substNodeLocal(node: Node, paramNames: string[], concreteTypes: Type[]): void {
	if (node.nodeType != null) {
		for (let i = 0; i < paramNames.length; i += 1) {
			if (i < concreteTypes.length) {
				node.nodeType = substituteType(node.nodeType, paramNames[i], concreteTypes[i]);
			}
		}
	}
	// Substitute explicit type args on the node (e.g. "K, V" in new HashMap<K, V>()).
	// Without this, the checker's NewExpr/CallExpr generic resolution falls back
	// to a location-keyed side channel that still holds the original (unsubstituted)
	// strings, producing HashMap<Unknown, Unknown> during re-check of cloned bodies.
	if (node.typeArg != null && node.typeArg != "") {
		node.typeArg = substAnnotationAll(node.typeArg, paramNames, concreteTypes);
	}
	if (node.kind == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		d.declType = substAnnotationAll(d.declType, paramNames, concreteTypes);
	} else if (node.kind == NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		d.asType = substAnnotationAll(d.asType, paramNames, concreteTypes);
	} else if (node.kind == NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		d.fnReturnType = substAnnotationAll(d.fnReturnType, paramNames, concreteTypes);
		for (let p = 0; p < d.fnParamTypes.length; p += 1) {
			d.fnParamTypes[p] = substAnnotationAll(d.fnParamTypes[p], paramNames, concreteTypes);
		}
	} else if (node.kind == NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		d.arrowReturnType = substAnnotationAll(d.arrowReturnType, paramNames, concreteTypes);
		for (let p = 0; p < d.arrowParamTypes.length; p += 1) {
			d.arrowParamTypes[p] = substAnnotationAll(d.arrowParamTypes[p], paramNames, concreteTypes);
		}
	} else if (node.kind == NodeKind.SizeofExpr) {
		const d = node.data as SizeofExprData;
		d.sizeofType = substAnnotationAll(d.sizeofType, paramNames, concreteTypes);
	}
}

export function replaceTypeVars(node: Node, paramNames: string[], concreteTypes: Type[]): void {
	if (node == null) return;
	substNodeLocal(node, paramNames, concreteTypes);
	forEachChild(node, (child: Node): void => { replaceTypeVars(child, paramNames, concreteTypes); });
}

// ===== On-Demand Instantiation =====

// PROFILE: instantiation counters for the -t summary. The cache in
// instantiateGenericFunction is scoped to the CURRENT module's symbol table
// (lookupSymbol(ctx.table, ...)), so a later module re-instantiates the same
// (generic, typeArgs) pair from scratch. These counters expose that.
let _igfCalls: int64 = 0;
let _igfHits: int64 = 0;
let _igfMisses: int64 = 0;
let _igfTime: float64 = 0;
let _igfBodyTime: float64 = 0;
export function instantiateProfile(): int64[] {
	return [_igfCalls, _igfHits, _igfMisses];
}
export function instantiateTimings(): float64[] {
	return [_igfTime, _igfBodyTime];
}

export function instantiateGenericFunction(sym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext, callLoc: SourceLocation): Symbol {
	if (ctx.genericInstDepth > 50) return null as unknown as Symbol;
	_igfCalls = _igfCalls + 1;

	// Extern/ImportC generic functions are handled by the C runtime (nativeName binding).
	// Don't instantiate — the runtime provides the implementation.
	if (hasFlag(sym, SymbolFlag.ImportC)) return null as unknown as Symbol;
	if (sym.nativeName != "") return null as unknown as Symbol;

	// Reference parity: refuse to instantiate if any type arg
	// is still a GenericParam (inference didn't complete). Unknown is allowed
	// through because `unknown` is a real user-facing concrete type (TS parity:
	// type-erased handles like `type HostNode = unknown`), represented as void*
	// in C. Blocking Unknown here forced callers to fall back to a wrong cached
	// instance — see nullableFunction.ms regression coverage.
	for (const ct of concreteTypes) {
		if (ct == null || ct.kind == TypeKind.GenericParam) {
			return null as unknown as Symbol;
		}
	}

	ctx.genericInstDepth = ctx.genericInstDepth + 1;

	const dedup = deduplicateBindings(paramNames, concreteTypes);
	// Extension method disambiguation: two overloads with the same function name and
	// generic arity (e.g. `set<K,V>(this Map<K,V>)` and `set<K,V>(this HashMap<K,V>)`)
	// produce distinct mangled names. Without this prefix, `set__string_int32` collides
	// across Map and HashMap, and the later instantiation overwrites the earlier one.
	// Prefix with the receiver class name (e.g. `Map_set__string_int32`).
	let mangleBase = sym.name;
	if (sym.declNode != null && sym.declNode.kind == NodeKind.FunctionDecl) {
		const fd = sym.declNode.data as FunctionDeclData;
		if (isExtensionFlag(fd.fnFlags)) {
			const recv = getExtReceiverType(fd.fnFlags);
			if (recv != "") mangleBase = recv + "_" + sym.name;
		}
	}
	const mangledName = mangleMonoName(mangleBase, dedup.types);

	// Cache check — skip if already instantiated.
	// Reference parity (genericCacheGet + findPendingModule): return cached symbol only.
	const existing = lookupSymbol(ctx.table, mangledName);
	if (existing != null) {
		ctx.genericInstDepth = ctx.genericInstDepth - 1;
		_igfHits = _igfHits + 1;
		return existing;
	}

	const _ig0 = performance.now();
	_igfMisses = _igfMisses + 1;
	const fnNode = unwrapToFunctionDecl(sym.declNode);
	if (fnNode == null) {
		ctx.genericInstDepth = ctx.genericInstDepth - 1;
		return null as unknown as Symbol;
	}

	// Clone AST + substitute annotations.
	// replaceTypeVars handles the top-level FunctionDecl's fnParamTypes/fnReturnType
	// (via substNodeLocal) and walks the body via forEachChild.
	const cloned = monoCloneNode(fnNode);
	const cd = cloned.data as FunctionDeclData;
	replaceTypeVars(cloned, dedup.names, dedup.types);

	// Rename + strip flags
	cd.fnName = mangledName;
	// Preserve generator flag — generatorLower needs it after instantiation.
	// Strip gen: (type params) and ext: (extension metadata) but keep generator/async.
	cd.fnFlags = stripGenFlag(cd.fnFlags);

	const instType = sym.symbolType != null ? instantiateGeneric(sym.symbolType, dedup.names, dedup.types) : sym.symbolType;
	cloned.nodeType = instType;

	// Create and register symbol in root scope.
	// Instance is OWNED by the generic's defining module (reference parity:
	// generateInstance setOwner(result, fn)). It is emitted in that module's TU, so the
	// generic body's module-private helpers (static functions, lifted closures) are visible
	// to it — co-location, not cross-TU. The mangled C name becomes module-qualified
	// (`gen__int32__<M>`) via mangledFunctionName; DCE/dedup predicates still key on the
	// unqualified `fnName` containing `__`. Used-but-not-defining modules forward-decl it
	// through the standard cross-module proto path.
	const instSym = makeSymbol(mangledName, SymbolKind.Function, instType, false);
	instSym.state = SymbolState.Shaped;
	instSym.nativeName = "";
	instSym.modulePath = sym.modulePath != "" ? sym.modulePath : ctx.modulePath;
	instSym.declNode = cloned;
	instSym.originalName = mangledName;
	let rootScope = ctx.table.current;
	while (rootScope.parent != null) rootScope = rootScope.parent;
	instSym.nameId = getIdentId(ctx.table.identCache, mangledName);
	addSymbolToScope(rootScope, instSym);
	cloned.resolvedSym = instSym;

	// Reference parity (semProcBody): check body in the DEFINING module's scope
	// (for private helpers like mapRawGet), but with concrete type symbols injected so
	// user types (Item, Foo, etc.) are visible during type annotation resolution.
	if (cd.fnBody != null) {
		const bodyCtx = pickBodyCtx(sym.modulePath, ctx);
		// Register instance in body-check scope so recursive lookups find it
		instSym.nameId = getIdentId(bodyCtx.table.identCache, mangledName);
		addSymbolToScope(bodyCtx.table.current, instSym);
		const savedModulePath = bodyCtx.modulePath;
		bodyCtx.modulePath = ctx.modulePath;
		// Reference parity (instantiateGenericParamList): inject concrete type
		// symbols into scope so resolveAnnotation("Item") finds the user type during re-check.
		// Without this, HashMap<string, Item[]> methods resolve "Item" to Unknown.
		const injectedSyms: Symbol[] = [];
		for (const ct of dedup.types) {
			injectConcreteTypeSyms(ct, bodyCtx, ctx, injectedSyms);
		}
		const extPreCount = injectCallerExtensions(bodyCtx, ctx);
		const errBefore = bodyCtx.errors.length;
		// Strip stale HiddenDeref/resolvedSym from the clone so re-check regenerates them
		// against concrete types — a class-method body already checked once (this: Class<T>
		// is a Ref) otherwise keeps its deref and the re-check stacks a second one.
		clearCheckerState(cd.fnBody);
		bindFunctionFlow(cloned, cd.fnBody);
		// Mirror checkFunctionDecl's return-inference setup: seed inferredReturn
		// from the instance type. checkFunctionBody does NOT reset it — without
		// this the body's returns mutate a stale slot and an un-annotated return
		// stays Inferred into codegen (C: internal error kind=48, JS: <object>).
		const savedReturn = bodyCtx.inferredReturn;
		const savedReturnStmts = bodyCtx.inferredReturnStmts;
		bodyCtx.inferredReturn = instType.typeReturn;
		bodyCtx.inferredReturnStmts = [];
		const _igb0 = performance.now();
		callCheckFunctionBody(bodyCtx, instSym, cd.params, cd.fnBody, null as unknown as SourceLocation[]);
		_igfBodyTime = _igfBodyTime + (performance.now() - _igb0);
		// Mirror the decl-side apply: an unresolved (un-annotated) return
		// adopts the body's inferred return so the instance is fully typed.
		if (instType.kind == TypeKind.Function
				&& instType.typeReturn != null
				&& isUnresolvedType(instType.typeReturn)) {
			if (bodyCtx.inferredReturn.kind != TypeKind.Inferred) {
				instType.typeReturn = bodyCtx.inferredReturn;
				for (const rs of bodyCtx.inferredReturnStmts) {
					const rsd = rs.data as ReturnStmtData;
					if (rsd.argument != null) rsd.argument = fitJoinedBranch(bodyCtx, rsd.argument, bodyCtx.inferredReturn);
				}
			} else {
				instType.typeReturn = voidType();
			}
		}
		bodyCtx.inferredReturn = savedReturn;
		bodyCtx.inferredReturnStmts = savedReturnStmts;
		if (bodyCtx != ctx && bodyCtx.errors.length > errBefore) {
			addError(ctx, "in instantiation of '" + sym.name + displayTypeArgs(dedup.types) + "': " + bodyCtx.errors[errBefore].message, callLoc.line, callLoc.column);
		}
		bodyCtx.modulePath = savedModulePath;
		// Clean up injected symbols to avoid polluting prelude scope
		removeInjectedSyms(bodyCtx, injectedSyms);
		truncateCallerExtensions(bodyCtx, extPreCount);
	}

	// Push to global pending list — reliable regardless of context save/restore.
	addPendingInstance(cloned);

	ctx.genericInstDepth = ctx.genericInstDepth - 1;
	_igfTime = _igfTime + (performance.now() - _ig0);
	return instSym;
}

// ===== On-Demand Constructor Instantiation =====
// Reference parity: on-demand proc instantiation (same pattern as standard generateInstance).
// For classes with constructors, we generate a standalone FunctionDecl named ClassName_new.

export function instantiateClassConstructor(classSym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext): void {
	// Refuse unresolved types
	for (const ct of concreteTypes) {
		if (ct == null || ct.kind == TypeKind.GenericParam || isUnresolvedType(ct)) return;
	}

	const dedup = deduplicateBindings(paramNames, concreteTypes);
	const mangledClass = mangleMonoName(classSym.name, dedup.types);
	const ctorFnName = mangledClass + "_new";

	// Cache check — already instantiated?
	const existingSym = lookupSymbol(ctx.table, ctorFnName);
	if (existingSym != null) return;
	for (const existing of _pendingInstances) {
		if (existing.kind == NodeKind.FunctionDecl && (existing.data as FunctionDeclData).fnName == ctorFnName) return;
		if (existing.kind == NodeKind.ClassDecl && (existing.data as ClassDeclData).className == mangledClass) return;
	}

	// An imported class symbol carries the ImportDecl, not the ClassDecl — export
	// deliberately drops class declaration nodes (context.ms: shipping them makes the
	// importer re-resolve member types in its own scope and pollute the type registry).
	// Ask the DEFINING module for the real declaration through the same module-ctx
	// registry this function already uses to re-check the constructor body below.
	let classDeclNode: Node | null = classSym.declNode;
	if (classDeclNode == null || classDeclNode.kind != NodeKind.ClassDecl) {
		const declCtx = pickBodyCtx(classSym.modulePath, ctx);
		const declName = classSym.originalName != "" ? classSym.originalName : classSym.name;
		const declSym = lookupSymbol(declCtx.table, declName);
		classDeclNode = declSym != null ? declSym.declNode : null;
	}
	if (classDeclNode == null || classDeclNode.kind != NodeKind.ClassDecl) return;
	const classData = classDeclNode.data as ClassDeclData;
	let ctorNode: Node | null = null;
	for (const member of classData.classBody) {
		if (member.kind == NodeKind.ConstructorDecl) { ctorNode = member; }
	}
	if (ctorNode == null) return;
	const ctorData = ctorNode.data as ConstructorDeclData;

	// Clone the constructor body
	const clonedBody = ctorData.ctorBody != null ? monoCloneNode(ctorData.ctorBody) : null as unknown as Node;

	// Build FunctionDecl params from constructor params with type substitution
	const fnParams: string[] = [];
	const fnParamTypes: string[] = [];
	for (const p of ctorData.ctorParams) { fnParams.push(p); }
	for (const pt of ctorData.ctorParamTypes) { fnParamTypes.push(pt); }
	substituteTypeStrings(fnParamTypes, dedup.names, dedup.types);

	// Substitute type vars in body
	if (clonedBody != null) {
		replaceTypeVars(clonedBody, dedup.names, dedup.types);
	}

	// Clone constructor defaults (for default-fill at call sites)
	const fnDefaults: Node[] = [];
	if (ctorData.ctorDefaults != null) {
		for (const d of ctorData.ctorDefaults) {
			fnDefaults.push(d != null ? monoCloneNode(d) : null as unknown as Node);
		}
	}

	// We emit a ClassDecl with just the constructor; methodToFunction lifts it into a
	// top-level `<Class>_init` FunctionDecl, and NewExpr inlines alloc + `_init` call.
	const loc = ctorNode.location != null ? ctorNode.location : makeLoc(0, 0);
	const clonedCtor: NodeData = { ctorParams: fnParams, ctorParamTypes: fnParamTypes, ctorBody: clonedBody, ctorDefaults: fnDefaults };
	const ctorDeclNode = createNodeAt(NodeKind.ConstructorDecl, clonedCtor, loc);

	// Set constructor node type (param types for codegen)
	const resolvedParamTypes: Type[] = [];
	for (let pi = 0; pi < fnParamTypes.length; pi += 1) {
		const pt = resolveAnnotation(fnParamTypes[pi], ctx, loc.line, loc.column);
		resolvedParamTypes.push(pt);
	}
	ctorDeclNode.nodeType = createFunction(resolvedParamTypes, fnParams, null as unknown as Type);

	// Mono receiver: Ref<Struct{substituted fields}> named `mangledClass`. genClassDecl
	// reads non-static fields from node.nodeType's struct (typeNames/typeChildren); a
	// Ref<GenericInstance> peels to type-args not fields → an empty struct in the ctor's TU.
	let structBase: Type = classSym.symbolType;
	if (structBase.kind == TypeKind.Ref && structBase.typeReturn != null) structBase = structBase.typeReturn;
	let substStruct: Type = structBase;
	for (let si = 0; si < dedup.names.length; si += 1) {
		if (si < dedup.types.length) substStruct = substituteType(substStruct, dedup.names[si].trim(), dedup.types[si]);
	}
	if (substStruct == structBase) {
		const newNames: string[] = [];
		for (const n of substStruct.typeNames) newNames.push(n);
		const newChildren: Type[] = [];
		for (const c of substStruct.typeChildren) newChildren.push(c);
		substStruct = createStruct(mangledClass, newNames, newChildren, isStructType(substStruct));
	} else {
		substStruct.typeName = mangledClass;
	}
	const concreteClassType = createRef(substStruct);

	// Re-check constructor body with concrete types in the class's DEFINING module ctx
	// (from _moduleCtxMap registry). This resolves private module-level symbols
	// referenced by the body — e.g. `let cap = INITIAL_CAPACITY;` in `HashSet.constructor`.
	// Fallback chain: registry → preludeCtx → caller's ctx. Reference parity: Nim's
	// `graph.ifaces[module]` lookup. Inject concrete type symbols so user types in type
	// args (e.g. Item in `new HashSet<Item>(...)`) are visible during resolveAnnotation.
	if (clonedBody != null) {
		const bodyCtx = pickBodyCtx(classSym.modulePath, ctx);
		const savedModulePath = bodyCtx.modulePath;
		bodyCtx.modulePath = classSym.modulePath != "" ? classSym.modulePath : ctx.modulePath;
		clearCheckerState(clonedBody);
		bindFunctionFlow(clonedBody, clonedBody);
		// Inject concrete type symbols (parity with instantiateGenericFunction).
		const injectedSyms: Symbol[] = [];
		for (const ct of dedup.types) {
			injectConcreteTypeSyms(ct, bodyCtx, ctx, injectedSyms);
		}
		const extPreCount = injectCallerExtensions(bodyCtx, ctx);
		// Replicate checkPass.ms:264-284: prepend `this` with concrete class type
		const ctorParams: string[] = ["this"];
		for (const p of fnParams) { ctorParams.push(p); }
		const ctorChildren: Type[] = [concreteClassType];
		for (const pt of resolvedParamTypes) { ctorChildren.push(pt); }
		const ctorFnType = createFunction(ctorChildren, ctorParams, null as unknown as Type);
		const ctorSym = makeSymbol("constructor", SymbolKind.Method, ctorFnType, false);
		ctorSym.state = SymbolState.Checked;
		callCheckFunctionBody(bodyCtx, ctorSym, ctorParams, clonedBody, null as unknown as SourceLocation[]);
		bodyCtx.modulePath = savedModulePath;
		removeInjectedSyms(bodyCtx, injectedSyms);
		truncateCallerExtensions(bodyCtx, extPreCount);
	}

	// Store constructor type + defaults for cross-module default-fill lookup.
	// Can't use symbol table (each module has its own). Use shared _ctorRegistry instead.
	registerCtorDefaults(ctorFnName, ctorDeclNode.nodeType!, fnDefaults);

	// Emit ClassDecl with just the constructor (struct already emitted by monoEmitTypeInstNodes).
	// Set classNode.nodeType to the concrete (instantiated) class type so the
	// methodToFunction transform can pull the right receiver type when lifting
	// the ctor — without it, `this` falls back to `void*` in the generated
	// `<MangledClass>_init` signature and `(*this).field` accesses fail to type
	// check at the C level.
	const classBody: Node[] = [];
	classBody.push(ctorDeclNode);
	const classNodeData: NodeData = { className: mangledClass, classExtends: "", classBody, nameLocation: loc };
	const classNode = createNodeAt(NodeKind.ClassDecl, classNodeData, loc);
	classNode.nodeType = concreteClassType;
	classNode.resolvedSym = classSym;
	addPendingInstance(classNode);
}

// Register callback at module load time
registerInstantiateGeneric((sym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext, callLoc: SourceLocation): Symbol => { return instantiateGenericFunction(sym, paramNames, concreteTypes, ctx, callLoc); });
