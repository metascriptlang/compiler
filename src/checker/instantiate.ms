// On-Demand Generic Instantiation — generateInstance + replaceTypeVars pattern
//
// When a generic extension method is matched during type checking,
// immediately clone the function body, substitute types, and register
// the specialized version. No separate monomorphize pass needed.

import { Node, NodeKind, NodeData, SourceLocation, makeLoc, createNodeAt, FunctionDeclData, ClassDeclData, ConstructorDeclData, ExportDeclData, DecoratedDeclData, BlockStmtData, IfStmtData, WhileStmtData, ForOfStmtData, ReturnStmtData, ExprStmtData, VariableDeclData, BinaryExprData, UnaryExprData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, TypeAssertionData, NewExprData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, ArrowFunctionData, FunctionExprData, SpreadExprData, UpdateExprData, MatchExprData, MatchStmtData, MatchCaseData, DestructuringDeclData, DeferStmtData, HiddenDerefData, HiddenStdConvData, Type, TypeKind, Symbol, SymbolKind, SymbolState } from "../ast/node";
import { typeNameOf, instantiateGeneric, substituteType, createFunction } from "./types";
import { resolveAnnotation } from "./resolvePass";
import { lookupSymbol, defineSymbol, makeSymbol, setFlag, SymbolFlag, hasFlag } from "./symbol";
import { CheckerContext } from "./context";
import { monoCloneNode, monoSubstAnnotation, monoConcreteTypeName } from "../monomorphize/collect";
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

// Build mangled name: "set" + ["string","string"] → "set__string_string"
function buildMangledName(baseName: string, types: Type[]): string {
	let result = baseName;
	for (let i = 0; i < types.length; i += 1) {
		result = result + (i === 0 ? "__" : "_") + monoConcreteTypeName(types[i]);
	}
	return result;
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

// Substitute type annotations in param types and return type
function substituteAnnotations(cd: FunctionDeclData, names: string[], types: Type[]): void {
	substituteTypeStrings(cd.fnParamTypes, names, types);
	if (cd.fnReturnType !== "") {
		for (let i = 0; i < names.length; i += 1) {
			if (i >= types.length) break;
			cd.fnReturnType = monoSubstAnnotation(cd.fnReturnType, names[i], monoConcreteTypeName(types[i]));
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
// Walk every node in the cloned body, clear resolvedSym for re-resolution,
// and substitute GenericParam types with concrete types on nodeType.

function replaceTypeVars(node: Node, paramNames: string[], concreteTypes: Type[]): void {
	if (node === null) return;

	// copyTree parity: preserve resolvedSym from clone (non-generic refs stay intact).
	// Only substitute GenericParam types in nodeType — don't clear resolvedSym.
	if (node.nodeType !== null) {
		for (let i = 0; i < paramNames.length; i += 1) {
			if (i < concreteTypes.length) {
				node.nodeType = substituteType(node.nodeType, paramNames[i], concreteTypes[i]);
			}
		}
	}

	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		if (d.declType !== null && d.declType !== "") {
			for (let i = 0; i < paramNames.length; i += 1) {
				if (i < concreteTypes.length) {
					d.declType = monoSubstAnnotation(d.declType, paramNames[i], monoConcreteTypeName(concreteTypes[i]));
				}
			}
		}
		replaceTypeVars(d.initializer, paramNames, concreteTypes);
		return;
	}

	match (node.kind) {
		NodeKind.BlockStmt => { for (const stmt of (node.data as BlockStmtData).statements) { replaceTypeVars(stmt, paramNames, concreteTypes); } },
		NodeKind.ExprStmt => { replaceTypeVars((node.data as ExprStmtData).expr, paramNames, concreteTypes); },
		NodeKind.ReturnStmt => { replaceTypeVars((node.data as ReturnStmtData).argument, paramNames, concreteTypes); },
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			replaceTypeVars(d.condition, paramNames, concreteTypes);
			replaceTypeVars(d.consequent, paramNames, concreteTypes);
			replaceTypeVars(d.alternate, paramNames, concreteTypes);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			replaceTypeVars(d.whileCondition, paramNames, concreteTypes);
			replaceTypeVars(d.whileBody, paramNames, concreteTypes);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			replaceTypeVars(d.forOfIterable, paramNames, concreteTypes);
			replaceTypeVars(d.forOfBody, paramNames, concreteTypes);
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			replaceTypeVars(d.left, paramNames, concreteTypes);
			replaceTypeVars(d.right, paramNames, concreteTypes);
		},
		NodeKind.UnaryExpr => { replaceTypeVars((node.data as UnaryExprData).operand, paramNames, concreteTypes); },
		NodeKind.UpdateExpr => { replaceTypeVars((node.data as UpdateExprData).updateArg, paramNames, concreteTypes); },
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			replaceTypeVars(d.callee, paramNames, concreteTypes);
			for (const arg of d.arguments) { replaceTypeVars(arg, paramNames, concreteTypes); }
		},
		NodeKind.MemberExpr => { replaceTypeVars((node.data as MemberExprData).object, paramNames, concreteTypes); },
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			replaceTypeVars(d.array, paramNames, concreteTypes);
			replaceTypeVars(d.index, paramNames, concreteTypes);
		},
		NodeKind.ObjectLiteral => { for (const val of (node.data as ObjectLiteralData).properties) { replaceTypeVars(val, paramNames, concreteTypes); } },
		NodeKind.ArrayLiteral => { for (const el of (node.data as ArrayLiteralData).elements) { replaceTypeVars(el, paramNames, concreteTypes); } },
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			replaceTypeVars(d.ternaryCondition, paramNames, concreteTypes);
			replaceTypeVars(d.ternaryConsequent, paramNames, concreteTypes);
			replaceTypeVars(d.ternaryAlternate, paramNames, concreteTypes);
		},
		NodeKind.TypeAssertion => {
			const tad = node.data as TypeAssertionData;
			replaceTypeVars(tad.asExpr, paramNames, concreteTypes);
			if (tad.asType !== "") {
				for (let i = 0; i < paramNames.length; i += 1) {
					if (i < concreteTypes.length) {
						tad.asType = monoSubstAnnotation(tad.asType, paramNames[i], monoConcreteTypeName(concreteTypes[i]));
					}
				}
			}
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			replaceTypeVars(d.newCallee, paramNames, concreteTypes);
			for (const arg of d.newArguments) { replaceTypeVars(arg, paramNames, concreteTypes); }
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			replaceTypeVars(d.tryBody, paramNames, concreteTypes);
			replaceTypeVars(d.catchBody, paramNames, concreteTypes);
			replaceTypeVars(d.finallyBody, paramNames, concreteTypes);
		},
		NodeKind.SpreadExpr => { replaceTypeVars((node.data as SpreadExprData).spreadArg, paramNames, concreteTypes); },
		NodeKind.ArrowFunction => { replaceTypeVars((node.data as ArrowFunctionData).arrowBody, paramNames, concreteTypes); },
		NodeKind.FunctionExpr => { replaceTypeVars((node.data as FunctionExprData).funcExprBody, paramNames, concreteTypes); },
		NodeKind.DeferStmt => { replaceTypeVars((node.data as DeferStmtData).deferExpr, paramNames, concreteTypes); },
		NodeKind.HiddenDeref => { replaceTypeVars((node.data as HiddenDerefData).expr, paramNames, concreteTypes); },
		NodeKind.HiddenStdConv => { replaceTypeVars((node.data as HiddenStdConvData).convExpr, paramNames, concreteTypes); },
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			replaceTypeVars(d.switchDisc, paramNames, concreteTypes);
			for (const c of d.switchCases) {
				for (const s of (c.data as SwitchCaseData).caseStmts) { replaceTypeVars(s, paramNames, concreteTypes); }
			}
		},
		NodeKind.MatchExpr => {
			const d = node.data as MatchExprData;
			replaceTypeVars(d.matchDisc, paramNames, concreteTypes);
			for (const c of d.matchCases) { replaceTypeVars((c.data as MatchCaseData).caseBody, paramNames, concreteTypes); }
		},
		NodeKind.MatchStmt => {
			const d = node.data as MatchStmtData;
			replaceTypeVars(d.matchStmtDisc, paramNames, concreteTypes);
			for (const c of d.matchStmtCases) { replaceTypeVars((c.data as MatchCaseData).caseBody, paramNames, concreteTypes); }
		},
		_ => {},
	};
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
	const mangledName = buildMangledName(sym.name, dedup.types);

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

	// Clone AST + substitute annotations
	const cloned = monoCloneNode(fnNode);
	const cd = cloned.data as FunctionDeclData;
	substituteAnnotations(cd, dedup.names, dedup.types);

	// replaceTypeVars: substitute GenericParam types throughout the body
	if (cd.fnBody !== null) {
		replaceTypeVars(cd.fnBody, dedup.names, dedup.types);
	}

	// Rename + strip flags
	cd.fnName = mangledName;
	cd.fnFlags = "";

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

	// Reference parity (generateInstance): check body in the DEFINING module's scope,
	// not the calling module's. This gives access to private helpers (mapRawGet, etc.)
	if (cd.fnBody !== null) {
		const bodyCtx = ctx.preludeCtx !== null ? ctx.preludeCtx : ctx;
		// Register instance in body-check scope so recursive lookups find it
		instSym.nameId = getIdentId(bodyCtx.table.identCache, mangledName);
		bodyCtx.table.current.symbols.push(instSym);
		const savedModulePath = bodyCtx.modulePath;
		bodyCtx.modulePath = ctx.modulePath;
		callCheckFunctionBody(bodyCtx, instSym, cd.params, cd.fnBody, null as unknown as SourceLocation[]);
		bodyCtx.modulePath = savedModulePath;
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
	const mangledClass = buildMangledName(classSym.name, dedup.types);
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
