// On-Demand Generic Instantiation — generateInstance + replaceTypeVars pattern
//
// When a generic extension method is matched during type checking,
// immediately clone the function body, substitute types, and register
// the specialized version. No separate monomorphize pass needed.

import {
	Node, NodeKind,
	FunctionDeclData, ExportDeclData, DecoratedDeclData,
	BlockStmtData, IfStmtData, WhileStmtData, ForOfStmtData,
	ReturnStmtData, ExprStmtData, VariableDeclData,
	BinaryExprData, UnaryExprData, CallExprData, MemberExprData,
	ArrayAccessData, ObjectLiteralData, ArrayLiteralData,
	ConditionalExprData, TypeAssertionData, NewExprData,
	TryCatchStmtData, SwitchStmtData, SwitchCaseData,
	ArrowFunctionData, FunctionExprData, SpreadExprData,
	UpdateExprData, MatchExprData, MatchStmtData, MatchCaseData,
	DestructuringDeclData, DeferStmtData,
	HiddenDerefData, HiddenStdConvData,
} from "../ast/node";
import { Type, TypeKind, typeNameOf, instantiateGeneric, createTypeRef, substituteType } from "./types";
import { Symbol, SymbolKind, SymbolState, lookupSymbol, defineSymbol, makeSymbol, setFlag, SymbolFlag, hasFlag } from "./symbol";
import { CheckerContext } from "./context";
import { monoCloneNode, monoSubstAnnotation, monoConcreteTypeName } from "../monomorphize/collect";
import { checkFunctionBody } from "./checkPass";
import { getIdentId } from "./idents";

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

// Substitute type annotations in param types and return type
function substituteAnnotations(cd: FunctionDeclData, names: string[], types: Type[]): void {
	for (let i = 0; i < names.length; i += 1) {
		if (i >= types.length) break;
		const pname = names[i];
		const cname = monoConcreteTypeName(types[i]);
		for (let pi = 0; pi < cd.fnParamTypes.length; pi += 1) {
			cd.fnParamTypes[pi] = monoSubstAnnotation(cd.fnParamTypes[pi], pname, cname);
		}
		if (cd.fnReturnType !== "") {
			cd.fnReturnType = monoSubstAnnotation(cd.fnReturnType, pname, cname);
		}
	}
}

// ===== replaceTypeVars (Nim's replaceTypeVarsN) =====
// Walk every node in the cloned body, clear resolvedSym for re-resolution,
// and substitute GenericParam types with concrete types on nodeType.

function replaceTypeVars(node: Node, paramNames: string[], concreteTypes: Type[]): void {
	if (node === null) return;

	node.resolvedSym = null as unknown as Symbol;
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
		replaceTypeVars(d.declInit, paramNames, concreteTypes);
		return;
	}

	match (node.kind) {
		NodeKind.BlockStmt => { for (const stmt of (node.data as BlockStmtData).statements) { replaceTypeVars(stmt, paramNames, concreteTypes); } },
		NodeKind.ExprStmt => { replaceTypeVars((node.data as ExprStmtData).expression, paramNames, concreteTypes); },
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
		NodeKind.UnaryExpr => { replaceTypeVars((node.data as UnaryExprData).argument, paramNames, concreteTypes); },
		NodeKind.UpdateExpr => { replaceTypeVars((node.data as UpdateExprData).argument, paramNames, concreteTypes); },
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			replaceTypeVars(d.callee, paramNames, concreteTypes);
			for (const arg of d.arguments) { replaceTypeVars(arg, paramNames, concreteTypes); }
		},
		NodeKind.MemberExpr => { replaceTypeVars((node.data as MemberExprData).object, paramNames, concreteTypes); },
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			replaceTypeVars(d.object, paramNames, concreteTypes);
			replaceTypeVars(d.index, paramNames, concreteTypes);
		},
		NodeKind.ObjectLiteral => { for (const val of (node.data as ObjectLiteralData).values) { replaceTypeVars(val, paramNames, concreteTypes); } },
		NodeKind.ArrayLiteral => { for (const el of (node.data as ArrayLiteralData).elements) { replaceTypeVars(el, paramNames, concreteTypes); } },
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			replaceTypeVars(d.test, paramNames, concreteTypes);
			replaceTypeVars(d.consequent, paramNames, concreteTypes);
			replaceTypeVars(d.alternate, paramNames, concreteTypes);
		},
		NodeKind.TypeAssertion => { replaceTypeVars((node.data as TypeAssertionData).asExpr, paramNames, concreteTypes); },
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
		NodeKind.HiddenStdConv => { replaceTypeVars((node.data as HiddenStdConvData).expr, paramNames, concreteTypes); },
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			replaceTypeVars(d.switchExpr, paramNames, concreteTypes);
			for (const c of d.switchCases) {
				for (const s of (c.data as SwitchCaseData).caseStmts) { replaceTypeVars(s, paramNames, concreteTypes); }
			}
		},
		NodeKind.MatchExpr | NodeKind.MatchStmt => {
			const d = node.data as MatchExprData;
			replaceTypeVars(d.matchSubject, paramNames, concreteTypes);
			for (const c of d.matchCases) { replaceTypeVars((c.data as MatchCaseData).caseBody, paramNames, concreteTypes); }
		},
		_ => {},
	};
}

// ===== On-Demand Instantiation (Nim's generateInstance) =====

export function instantiateGenericFunction(sym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext): Symbol {
	if (ctx.genericInstDepth > 50) return null as unknown as Symbol;
	ctx.genericInstDepth = ctx.genericInstDepth + 1;

	const dedup = deduplicateBindings(paramNames, concreteTypes);
	const mangledName = buildMangledName(sym.name, dedup.types);

	// Cache check — skip if already instantiated
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

	// Create and register symbol in root scope
	const instSym = makeSymbol(mangledName, SymbolKind.Function, instType, false);
	instSym.state = SymbolState.Shaped;
	instSym.nativeName = "";
	instSym.modulePath = ctx.modulePath;
	instSym.declNode = cloned;
	instSym.originalName = mangledName;
	setFlag(instSym, SymbolFlag.Exported);
	let rootScope = ctx.table.current;
	while (rootScope.parent !== null) rootScope = rootScope.parent;
	instSym.nameId = getIdentId(ctx.table.identCache, mangledName);
	rootScope.symbols.push(instSym);
	cloned.resolvedSym = instSym;

	// Type-check body with friend module access
	if (cd.fnBody !== null) {
		if (ctx.preludeCtx !== null && ctx.genericInstDepth === 1) {
			const preludeSyms = ctx.preludeCtx.table.current.symbols;
			for (const ps of preludeSyms) {
				if (!hasFlag(ps, SymbolFlag.Exported) && lookupSymbol(ctx.table, ps.name) === null) {
					ps.nameId = getIdentId(ctx.table.identCache, ps.name);
					ctx.table.current.symbols.push(ps);
				}
			}
		}
		checkFunctionBody(ctx, instSym, cd.params, cd.fnBody, null);
	}

	ctx.generatedInstances.push(cloned);
	ctx.genericInstDepth = ctx.genericInstDepth - 1;
	return instSym;
}
