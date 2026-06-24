// On-Demand Generic Instantiation — generateInstance + replaceTypeVars pattern
//
// When a generic extension method is matched during type checking,
// immediately clone the function body, substitute types, and register
// the specialized version. No separate monomorphize pass needed.

import { Node, NodeKind, NodeData, SourceLocation, makeLoc, createNodeAt, FunctionDeclData, MethodDeclData as MethodDeclDataLocal, ClassDeclData, ConstructorDeclData, ExportDeclData, DecoratedDeclData, BlockStmtData, ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData, ForOfStmtData, VariableDeclData, BinaryExprData, UnaryExprData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, TypeAssertionData, NewExprData, HiddenDerefData, HiddenStdConvData, SizeofExprData, Type, TypeKind, Symbol, SymbolKind, SymbolState } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { instantiateGeneric, substituteType, createFunction, createGenericInstance, createRef } from "./types";
import { resolveAnnotation } from "./resolvePass";
import { lookupSymbol, makeSymbol, addSymbolToScope, SymbolFlag, hasFlag } from "./symbol";
import { CheckerContext, stripGenFlag, getExtReceiverType, isExtensionFlag } from "./context";
import { monoCloneNode, monoSubstAnnotation, monoConcreteTypeName } from "../monomorphize/clone";
import { mangleMonoName } from "../monomorphize/registry";
import { callCheckFunctionBody, registerInstantiateGeneric } from "./checkerCallbacks";
import { getIdentId } from "./idents";

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
	if (modulePath === "") return;
	_moduleCtxMap.set(modulePath, ctx);
}

export function lookupModuleCtx(modulePath: string): CheckerContext | null {
	if (modulePath === "") return null;
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
	if (modulePath === "") return;
	_moduleProgramMap.set(modulePath, program);
}

export function lookupModuleProgram(modulePath: string): Node | null {
	if (modulePath === "") return null;
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
function pickBodyCtx(definingModulePath: string, ctx: CheckerContext): CheckerContext {
	if (definingModulePath === "" || definingModulePath === ctx.modulePath) return ctx;
	const defining = lookupModuleCtx(definingModulePath);
	if (defining !== null) return defining;
	if (ctx.preludeCtx !== null) return ctx.preludeCtx;
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

function registerCtorDefaults(name: string, fnType: Type, defaults: Node[]): void {
	for (const e of _ctorRegistry) {
		if (e.name === name) return; // already registered
	}
	_ctorRegistry.push({ name, fnType, defaults });
}

export function lookupCtorDefaults(ctorFnName: string): CtorEntry {
	for (const e of _ctorRegistry) {
		if (e.name === ctorFnName) return e;
	}
	return null as unknown as CtorEntry;
}

export function addPendingInstance(node: Node): void {
	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		if (_pendingNames.has(fd.fnName)) return;
		_pendingNames.add(fd.fnName);
	} else if (node.kind === NodeKind.ClassDecl) {
		const cd = node.data as ClassDeclData;
		if (_pendingNames.has(cd.className)) return;
		_pendingNames.add(cd.className);
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
		for (const n of outNames) { if (n === names[i]) { dup = true; break; } }
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
	if (lookupSymbol(ctx.table, name) !== null) return;
	const callerSym = lookupSymbol(callerCtx.table, name);
	const symType = callerSym !== null ? callerSym.symbolType : fallbackType;
	const sym = makeSymbol(name, SymbolKind.TypeAlias, symType, false);
	sym.nameId = getIdentId(ctx.table.identCache, name);
	addSymbolToScope(ctx.table.current, sym);
	injected.push(sym);
}

// Inject concrete type symbols into scope so resolveAnnotation finds them during re-check.
// For Array<Ref<Item>>, extracts "Item" and adds Ref<Struct("Item")> to scope.
// Reference parity (instantiateGenericParamList): concrete types added to scope.
function injectConcreteTypeSyms(t: Type | null, ctx: CheckerContext, callerCtx: CheckerContext, injected: Symbol[]): void {
	if (t === null) return;
	const tr = t.typeReturn;
	// Hand-rolled dispatch: match `when` guards don't propagate narrowing into
	// the arm body in the current binder, so we can't safely access `tr.kind`
	// inside `TypeKind.Ref when (tr !== null) => { ... tr.kind ... }`. The
	// if-chain below makes the narrowing scope explicit and matches the binder's
	// flow-based narrowing exactly.
	if (t.kind === TypeKind.Ref && tr !== null) {
		if (tr.kind === TypeKind.Struct && tr.typeName !== "") {
			tryInjectTypeSym(tr.typeName, t, ctx, callerCtx, injected);
		}
		injectConcreteTypeSyms(tr, ctx, callerCtx, injected);
		return;
	}
	if (t.kind === TypeKind.Array && tr !== null) {
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
	if ((t.kind === TypeKind.Struct || t.kind === TypeKind.Enum || t.kind === TypeKind.Distinct)
			&& t.typeName !== "") {
		tryInjectTypeSym(t.typeName, t, ctx, callerCtx, injected);
		return;
	}
	if (t.kind === TypeKind.GenericInstance && t.typeChildren !== null) {
		for (const child of t.typeChildren) {
			injectConcreteTypeSyms(child, ctx, callerCtx, injected);
		}
	}
}

function removeInjectedSyms(ctx: CheckerContext, injected: Symbol[]): void {
	for (const sym of injected) {
		// Each injected sym has a real nameId (set in injectConcreteTypeSyms before push);
		// O(1) removal by key instead of linear-scan-swap-pop.
		if (sym.nameId !== 0) {
			ctx.table.current.symbols.delete(sym.nameId);
		}
	}
}


// Unwrap ExportDecl/DecoratedDecl to get the inner FunctionDecl. For
// generic STATIC class methods, synthesize an equivalent FunctionDecl from
// the MethodDecl so the existing instantiation flow can drive mono on it.
//
// Limitation: only static methods are handled. Generic INSTANCE methods on
// non-generic classes (e.g., `class Foo { method<T>(x: T): T }`) fall
// through to null — the call site won't mono and the body emits with
// T=Unknown. Reference parity (the reference handles skMethod natively
// alongside skProc); long-term fix is to extend instantiateGenericFunction
// to dispatch on declNode.kind directly instead of synthesizing.
function unwrapToFunctionDecl(node: Node): Node {
	if (node === null) return null as unknown as Node;
	let n = node;
	if (n.kind === NodeKind.ExportDecl) n = (n.data as ExportDeclData).exportedDecl;
	if (n !== null && n.kind === NodeKind.DecoratedDecl) n = (n.data as DecoratedDeclData).decoratedNode;
	if (n !== null && n.kind === NodeKind.FunctionDecl) return n;
	if (n !== null && n.kind === NodeKind.MethodDecl) {
		const md = n.data as MethodDeclDataLocal;
		if (!md.methodIsStatic) return null as unknown as Node;
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
// Strip HiddenDeref/HiddenAddr/HiddenStdConv wrappers and clear resolvedSym/flags
// on a cloned AST so the checker re-processes it fresh.
// Reference parity: standard re-check tolerates stale HiddenDeref by reading child types.
// We strip them entirely — the re-check regenerates correct wrappers with concrete types.

function stripHidden(node: Node): Node {
	if (node === null) return node;
	if (node.kind === NodeKind.HiddenDeref || node.kind === NodeKind.HiddenAddr) {
		return stripHidden((node.data as HiddenDerefData).expr);
	}
	if (node.kind === NodeKind.HiddenStdConv) {
		return stripHidden((node.data as HiddenStdConvData).convExpr);
	}
	return node;
}

// Strip hidden wrappers and clear checker state on a single child, returning the cleaned node.
function cleanChild(child: Node): Node {
	const stripped = stripHidden(child);
	clearCheckerState(stripped);
	return stripped;
}

function clearCheckerState(node: Node): void {
	if (node === null) return;
	node.resolvedSym = null as unknown as Symbol;
	node.flags = 0;
	match (node.kind) {
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (let i = 0; i < d.statements.length; i += 1) { d.statements[i] = cleanChild(d.statements[i]); }
		},
		NodeKind.ExprStmt => { const d = node.data as ExprStmtData; d.expr = cleanChild(d.expr); },
		NodeKind.ReturnStmt => { const d = node.data as ReturnStmtData; d.argument = cleanChild(d.argument); },
		NodeKind.IfStmt => { const d = node.data as IfStmtData; d.condition = cleanChild(d.condition); d.consequent = cleanChild(d.consequent); d.alternate = cleanChild(d.alternate); },
		NodeKind.WhileStmt => { const d = node.data as WhileStmtData; d.whileCondition = cleanChild(d.whileCondition); clearCheckerState(d.whileBody); },
		NodeKind.ForOfStmt => { const d = node.data as ForOfStmtData; d.forOfIterable = cleanChild(d.forOfIterable); clearCheckerState(d.forOfBody); },
		NodeKind.BinaryExpr => { const d = node.data as BinaryExprData; d.left = cleanChild(d.left); d.right = cleanChild(d.right); },
		NodeKind.UnaryExpr => { const d = node.data as UnaryExprData; d.operand = cleanChild(d.operand); },
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			d.callee = cleanChild(d.callee);
			for (let i = 0; i < d.arguments.length; i += 1) { d.arguments[i] = cleanChild(d.arguments[i]); }
		},
		NodeKind.MemberExpr => { const d = node.data as MemberExprData; d.object = cleanChild(d.object); },
		NodeKind.ArrayAccess => { const d = node.data as ArrayAccessData; d.array = cleanChild(d.array); d.index = cleanChild(d.index); },
		NodeKind.VariableDecl => { const d = node.data as VariableDeclData; d.initializer = cleanChild(d.initializer); },
		NodeKind.ObjectLiteral => { for (const p of (node.data as ObjectLiteralData).properties) { clearCheckerState(p); } },
		NodeKind.ArrayLiteral => { for (const e of (node.data as ArrayLiteralData).elements) { clearCheckerState(e); } },
		NodeKind.ConditionalExpr => { const d = node.data as ConditionalExprData; d.ternaryCondition = cleanChild(d.ternaryCondition); d.ternaryConsequent = cleanChild(d.ternaryConsequent); d.ternaryAlternate = cleanChild(d.ternaryAlternate); },
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			d.newCallee = cleanChild(d.newCallee);
			for (let i = 0; i < d.newArguments.length; i += 1) { d.newArguments[i] = cleanChild(d.newArguments[i]); }
		},
		_ => {},
	};
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
	if (ann === "") return ann;
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
	if (node.nodeType !== null) {
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
	if (node.typeArg !== null && node.typeArg !== "") {
		node.typeArg = substAnnotationAll(node.typeArg, paramNames, concreteTypes);
	}
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		d.declType = substAnnotationAll(d.declType, paramNames, concreteTypes);
	} else if (node.kind === NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		d.asType = substAnnotationAll(d.asType, paramNames, concreteTypes);
	} else if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		d.fnReturnType = substAnnotationAll(d.fnReturnType, paramNames, concreteTypes);
		for (let p = 0; p < d.fnParamTypes.length; p += 1) {
			d.fnParamTypes[p] = substAnnotationAll(d.fnParamTypes[p], paramNames, concreteTypes);
		}
	} else if (node.kind === NodeKind.SizeofExpr) {
		const d = node.data as SizeofExprData;
		d.sizeofType = substAnnotationAll(d.sizeofType, paramNames, concreteTypes);
	}
}

export function replaceTypeVars(node: Node, paramNames: string[], concreteTypes: Type[]): void {
	if (node === null) return;
	substNodeLocal(node, paramNames, concreteTypes);
	forEachChild(node, (child: Node): void => { replaceTypeVars(child, paramNames, concreteTypes); });
}

// ===== On-Demand Instantiation =====

export function instantiateGenericFunction(sym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext): Symbol {
	if (ctx.genericInstDepth > 50) return null as unknown as Symbol;

	// Extern/ImportC generic functions are handled by the C runtime (nativeName binding).
	// Don't instantiate — the runtime provides the implementation.
	if (hasFlag(sym, SymbolFlag.ImportC)) return null as unknown as Symbol;
	if (sym.nativeName !== "") return null as unknown as Symbol;

	// Reference parity: refuse to instantiate if any type arg
	// is still unresolved (GenericParam, Unknown). Only concrete types produce valid C.
	for (const ct of concreteTypes) {
		if (ct === null || ct.kind === TypeKind.GenericParam || ct.kind === TypeKind.Unknown) {
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
	if (sym.declNode !== null && sym.declNode.kind === NodeKind.FunctionDecl) {
		const fd = sym.declNode.data as FunctionDeclData;
		if (isExtensionFlag(fd.fnFlags)) {
			const recv = getExtReceiverType(fd.fnFlags);
			if (recv !== "") mangleBase = recv + "_" + sym.name;
		}
	}
	const mangledName = mangleMonoName(mangleBase, dedup.types);

	// Cache check — skip if already instantiated.
	// Reference parity (genericCacheGet + findPendingModule): return cached symbol only.
	const existing = lookupSymbol(ctx.table, mangledName);
	if (existing !== null) {
		ctx.genericInstDepth = ctx.genericInstDepth - 1;
		return existing;
	}

	const fnNode = unwrapToFunctionDecl(sym.declNode);
	if (fnNode === null) {
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

	const instType = sym.symbolType !== null ? instantiateGeneric(sym.symbolType, dedup.names, dedup.types) : sym.symbolType;
	cloned.nodeType = instType;

	// Create and register symbol in root scope.
	// Instance symbols get empty modulePath — codegen emits unqualified names
	// and deduplicates across modules (first module to emit wins, others get forward decl).
	// This matches the reference generateInstance where instances are identified by mangled name alone.
	const instSym = makeSymbol(mangledName, SymbolKind.Function, instType, false);
	instSym.state = SymbolState.Shaped;
	instSym.nativeName = "";
	instSym.modulePath = "";
	instSym.declNode = cloned;
	instSym.originalName = mangledName;
	let rootScope = ctx.table.current;
	while (rootScope.parent !== null) rootScope = rootScope.parent;
	instSym.nameId = getIdentId(ctx.table.identCache, mangledName);
	addSymbolToScope(rootScope, instSym);
	cloned.resolvedSym = instSym;

	// Reference parity (semProcBody): check body in the DEFINING module's scope
	// (for private helpers like mapRawGet), but with concrete type symbols injected so
	// user types (Item, Foo, etc.) are visible during type annotation resolution.
	if (cd.fnBody !== null) {
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
		callCheckFunctionBody(bodyCtx, instSym, cd.params, cd.fnBody, null as unknown as SourceLocation[]);
		bodyCtx.modulePath = savedModulePath;
		// Clean up injected symbols to avoid polluting prelude scope
		removeInjectedSyms(bodyCtx, injectedSyms);
	}

	// Push to global pending list — reliable regardless of context save/restore.
	addPendingInstance(cloned);

	ctx.genericInstDepth = ctx.genericInstDepth - 1;
	return instSym;
}

// ===== On-Demand Constructor Instantiation =====
// Reference parity: on-demand proc instantiation (same pattern as standard generateInstance).
// For classes with constructors, we generate a standalone FunctionDecl named ClassName_new.

export function instantiateClassConstructor(classSym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext): void {
	// Refuse unresolved types
	for (const ct of concreteTypes) {
		if (ct === null || ct.kind === TypeKind.GenericParam || ct.kind === TypeKind.Unknown) return;
	}

	const dedup = deduplicateBindings(paramNames, concreteTypes);
	const mangledClass = mangleMonoName(classSym.name, dedup.types);
	const ctorFnName = mangledClass + "_new";

	// Cache check — already instantiated?
	const existingSym = lookupSymbol(ctx.table, ctorFnName);
	if (existingSym !== null) return;
	for (const existing of _pendingInstances) {
		if (existing.kind === NodeKind.FunctionDecl && (existing.data as FunctionDeclData).fnName === ctorFnName) return;
		if (existing.kind === NodeKind.ClassDecl && (existing.data as ClassDeclData).className === mangledClass) return;
	}

	if (classSym.declNode === null || classSym.declNode.kind !== NodeKind.ClassDecl) return;
	const classData = classSym.declNode.data as ClassDeclData;
	let ctorNode: Node = null as unknown as Node;
	for (const member of classData.classBody) {
		if (member.kind === NodeKind.ConstructorDecl) { ctorNode = member; }
	}
	if (ctorNode === null) return;
	const ctorData = ctorNode.data as ConstructorDeclData;

	// Clone the constructor body
	const clonedBody = ctorData.ctorBody !== null ? monoCloneNode(ctorData.ctorBody) : null as unknown as Node;

	// Build FunctionDecl params from constructor params with type substitution
	const fnParams: string[] = [];
	const fnParamTypes: string[] = [];
	for (const p of ctorData.ctorParams) { fnParams.push(p); }
	for (const pt of ctorData.ctorParamTypes) { fnParamTypes.push(pt); }
	substituteTypeStrings(fnParamTypes, dedup.names, dedup.types);

	// Substitute type vars in body
	if (clonedBody !== null) {
		replaceTypeVars(clonedBody, dedup.names, dedup.types);
	}

	// Clone constructor defaults (for default-fill at call sites)
	const fnDefaults: Node[] = [];
	if (ctorData.ctorDefaults !== null) {
		for (const d of ctorData.ctorDefaults) {
			fnDefaults.push(d !== null ? monoCloneNode(d) : null as unknown as Node);
		}
	}

	// Create FunctionDecl: the codegen's genConstructor handles alloc + body + return this.
	// We emit a ClassDecl with just the constructor so genClassDecl generates ClassName_new().
	const loc = ctorNode.location !== null ? ctorNode.location : makeLoc(0, 0);
	const clonedCtor: NodeData = { ctorParams: fnParams, ctorParamTypes: fnParamTypes, ctorBody: clonedBody, ctorDefaults: fnDefaults };
	const ctorDeclNode = createNodeAt(NodeKind.ConstructorDecl, clonedCtor, loc);

	// Set constructor node type (param types for codegen)
	const resolvedParamTypes: Type[] = [];
	for (let pi = 0; pi < fnParamTypes.length; pi += 1) {
		const pt = resolveAnnotation(fnParamTypes[pi], ctx, loc.line, loc.column);
		resolvedParamTypes.push(pt);
	}
	ctorDeclNode.nodeType = createFunction(resolvedParamTypes, fnParams, null as unknown as Type);

	// Mono'd receiver type for `this` and the synthetic ClassDecl. Wrapped
	// as Ref<GenericInstance> so codegen renders `Class__args*` (e.g.
	// `HashSet__string*`) rather than the un-instantiated `HashSet*` — the
	// latter shares its field layout with whichever mono instance landed
	// first, so cross-mono field assignments would type-mismatch in C.
	const concreteClassType = createRef(createGenericInstance(classSym.symbolType, dedup.types));

	// Re-check constructor body with concrete types in the class's DEFINING module ctx
	// (from _moduleCtxMap registry). This resolves private module-level symbols
	// referenced by the body — e.g. `let cap = INITIAL_CAPACITY;` in `HashSet.constructor`.
	// Fallback chain: registry → preludeCtx → caller's ctx. Reference parity: Nim's
	// `graph.ifaces[module]` lookup. Inject concrete type symbols so user types in type
	// args (e.g. Item in `new HashSet<Item>(...)`) are visible during resolveAnnotation.
	if (clonedBody !== null) {
		const bodyCtx = pickBodyCtx(classSym.modulePath, ctx);
		const savedModulePath = bodyCtx.modulePath;
		bodyCtx.modulePath = classSym.modulePath !== "" ? classSym.modulePath : ctx.modulePath;
		clearCheckerState(clonedBody);
		// Inject concrete type symbols (parity with instantiateGenericFunction).
		const injectedSyms: Symbol[] = [];
		for (const ct of dedup.types) {
			injectConcreteTypeSyms(ct, bodyCtx, ctx, injectedSyms);
		}
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
	}

	// Store constructor type + defaults for cross-module default-fill lookup.
	// Can't use symbol table (each module has its own). Use shared _ctorRegistry instead.
	registerCtorDefaults(ctorFnName, ctorDeclNode.nodeType, fnDefaults);

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
	addPendingInstance(classNode);
}

// Register callback at module load time
registerInstantiateGeneric((sym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext): Symbol => { return instantiateGenericFunction(sym, paramNames, concreteTypes, ctx); });
