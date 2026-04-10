// On-Demand Generic Instantiation — generateInstance + replaceTypeVars pattern
//
// When a generic extension method is matched during type checking,
// immediately clone the function body, substitute types, and register
// the specialized version. No separate monomorphize pass needed.

import { Node, NodeKind, NodeData, SourceLocation, makeLoc, createNodeAt, FunctionDeclData, ClassDeclData, ConstructorDeclData, ExportDeclData, DecoratedDeclData, BlockStmtData, ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData, ForOfStmtData, VariableDeclData, BinaryExprData, UnaryExprData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, TypeAssertionData, NewExprData, HiddenDerefData, HiddenStdConvData, Type, TypeKind, Symbol, SymbolKind, SymbolState } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { instantiateGeneric, substituteType, createFunction } from "./types";
import { resolveAnnotation } from "./resolvePass";
import { lookupSymbol, makeSymbol, SymbolFlag, hasFlag } from "./symbol";
import { CheckerContext, stripGenFlag } from "./context";
import { monoCloneNode, monoSubstAnnotation, monoConcreteTypeName } from "../monomorphize/clone";
import { mangleMonoName } from "../monomorphize/registry";
import { callCheckFunctionBody, registerInstantiateGeneric } from "./checkerCallbacks";
import { getIdentId } from "./idents";

// ===== Global Instance Collection =====
// Module-level pending list — all instantiated ASTs go here.
// compile.ms drains this after each module's check.
let _pendingInstances: Node[] = [];

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
		for (const existing of _pendingInstances) {
			if (existing.kind === NodeKind.FunctionDecl && (existing.data as FunctionDeclData).fnName === fd.fnName) return;
		}
	} else if (node.kind === NodeKind.ClassDecl) {
		const cd = node.data as ClassDeclData;
		for (const existing of _pendingInstances) {
			if (existing.kind === NodeKind.ClassDecl && (existing.data as ClassDeclData).className === cd.className) return;
		}
	}
	_pendingInstances.push(node);
}

export function drainPendingInstances(): Node[] {
	const result = _pendingInstances;
	_pendingInstances = [];
	return result;
}

// ===== Helpers =====

// Deduplicate unify bindings (K=string may appear twice from Map<K,V> + K params)
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
	ctx.table.current.symbols.push(sym);
	injected.push(sym);
}

// Inject concrete type symbols into scope so resolveAnnotation finds them during re-check.
// For Array<Ref<Item>>, extracts "Item" and adds Ref<Struct("Item")> to scope.
// Reference parity (instantiateGenericParamList): concrete types added to scope.
function injectConcreteTypeSyms(t: Type, ctx: CheckerContext, callerCtx: CheckerContext, injected: Symbol[]): void {
	if (t === null) return;
	match (t.kind) {
		TypeKind.Ref when (t.typeReturn !== null) => {
			if (t.typeReturn.kind === TypeKind.Struct && t.typeReturn.typeName !== "") {
				tryInjectTypeSym(t.typeReturn.typeName, t, ctx, callerCtx, injected);
			}
			injectConcreteTypeSyms(t.typeReturn, ctx, callerCtx, injected);
		},
		TypeKind.Array when (t.typeReturn !== null) => {
			injectConcreteTypeSyms(t.typeReturn, ctx, callerCtx, injected);
		},
		TypeKind.Struct when (t.typeName !== "") => {
			tryInjectTypeSym(t.typeName, t, ctx, callerCtx, injected);
		},
		TypeKind.GenericInstance when (t.typeChildren !== null) => {
			for (const child of t.typeChildren) {
				injectConcreteTypeSyms(child, ctx, callerCtx, injected);
			}
		},
		_ => {},
	};
}

function removeInjectedSyms(ctx: CheckerContext, injected: Symbol[]): void {
	for (const sym of injected) {
		let i = 0;
		while (i < ctx.table.current.symbols.length) {
			if (ctx.table.current.symbols[i] === sym) {
				ctx.table.current.symbols[i] = ctx.table.current.symbols[ctx.table.current.symbols.length - 1];
				ctx.table.current.symbols.pop();
				break;
			}
			i = i + 1;
		}
	}
}


// Unwrap ExportDecl/DecoratedDecl to get the inner FunctionDecl
function unwrapToFunctionDecl(node: Node): Node {
	if (node === null) return null as unknown as Node;
	let n = node;
	if (n.kind === NodeKind.ExportDecl) n = (n.data as ExportDeclData).exportedDecl;
	if (n !== null && n.kind === NodeKind.DecoratedDecl) n = (n.data as DecoratedDeclData).decoratedNode;
	if (n !== null && n.kind === NodeKind.FunctionDecl) return n;
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
	// Substitute explicit type args on the node (e.g. "K, V" in new Map<K, V>()).
	// Without this, the checker's NewExpr/CallExpr generic resolution falls back
	// to a location-keyed side channel that still holds the original (unsubstituted)
	// strings, producing Map<Unknown, Unknown> during re-check of cloned bodies.
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
	const mangledName = mangleMonoName(sym.name, dedup.types);

	// Cache check — skip if already instantiated.
	// Reference parity (genericCacheGet + findPendingModule): return cached symbol only.
	// The first module that created the instance has it in generatedInstances.
	// Other modules get forward declarations via ensureCrossModuleProto at call sites.
	// No AST re-injection — prevents shared-mutation by DRC across modules.
	const existing = lookupSymbol(ctx.table, mangledName);
	if (existing !== null) {
		ctx.genericInstDepth = ctx.genericInstDepth - 1;
		return existing;
	}

	// Get the original function AST
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

	// Build instantiated function type
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
	rootScope.symbols.push(instSym);
	cloned.resolvedSym = instSym;

	// Reference parity (semProcBody): check body in the DEFINING module's scope
	// (for private helpers like mapRawGet), but with concrete type symbols injected so
	// user types (Item, Foo, etc.) are visible during type annotation resolution.
	if (cd.fnBody !== null) {
		const bodyCtx = ctx.preludeCtx !== null ? ctx.preludeCtx : ctx;
		// Register instance in body-check scope so recursive lookups find it
		instSym.nameId = getIdentId(bodyCtx.table.identCache, mangledName);
		bodyCtx.table.current.symbols.push(instSym);
		const savedModulePath = bodyCtx.modulePath;
		bodyCtx.modulePath = ctx.modulePath;
		// Reference parity (instantiateGenericParamList): inject concrete type
		// symbols into scope so resolveAnnotation("Item") finds the user type during re-check.
		// Without this, Map<string, Item[]> methods resolve "Item" to Unknown.
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
	_pendingInstances.push(cloned);

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

	// Find ConstructorDecl in class body
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

	// Re-check constructor body with concrete types.
	// Strip HiddenDeref/HiddenAddr wrappers first — re-check regenerates them correctly.
	if (clonedBody !== null) {
		const savedModulePath = ctx.modulePath;
		if (classSym.modulePath !== "") ctx.modulePath = classSym.modulePath;
		clearCheckerState(clonedBody);
		// Replicate checkPass.ms:264-284: prepend `this` with concrete class type
		const ctorParams: string[] = ["this"];
		for (const p of fnParams) { ctorParams.push(p); }
		const concreteClassType = instantiateGeneric(classSym.symbolType, dedup.names, dedup.types);
		const ctorChildren: Type[] = [concreteClassType];
		for (const pt of resolvedParamTypes) { ctorChildren.push(pt); }
		const ctorFnType = createFunction(ctorChildren, ctorParams, null as unknown as Type);
		const ctorSym = makeSymbol("constructor", SymbolKind.Method, ctorFnType, false);
		ctorSym.state = SymbolState.Checked;
		callCheckFunctionBody(ctx, ctorSym, ctorParams, clonedBody, null as unknown as SourceLocation[]);
		ctx.modulePath = savedModulePath;
	}

	// Store constructor type + defaults for cross-module default-fill lookup.
	// Can't use symbol table (each module has its own). Use shared _ctorRegistry instead.
	registerCtorDefaults(ctorFnName, ctorDeclNode.nodeType, fnDefaults);

	// Emit ClassDecl with just the constructor (struct already emitted by monoEmitTypeInstNodes)
	const classBody: Node[] = [];
	classBody.push(ctorDeclNode);
	const classNodeData: NodeData = { className: mangledClass, classExtends: "", classBody, nameLocation: loc };
	const classNode = createNodeAt(NodeKind.ClassDecl, classNodeData, loc);
	addPendingInstance(classNode);
}

// Register callback at module load time
registerInstantiateGeneric((sym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext): Symbol => { return instantiateGenericFunction(sym, paramNames, concreteTypes, ctx); });
