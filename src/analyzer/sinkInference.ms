import { Node, NodeKind, Symbol, SymbolKind, Type, TypeKind, CallingConvention, ProgramData, ExportDeclData, DecoratedDeclData, FunctionDeclData, BinaryExprData, CallExprData, MemberExprData, ObjectLiteralData, ArrayLiteralData, IfStmtData, ConditionalExprData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { RoutineFlag, hasFlag, routineFlagSet, SymbolFlag } from "../checker/symbol";
import { dispatchEntryFor, dispatchOverrideTable } from "../checker/context";
import { calledRoutineType } from "../checker/effects";
import { createSink } from "../checker/types";
import { TransformContext } from "../transform/context";
import { classifyType } from "./classify";
import { isGeneratorBody } from "./inject";

class Routine {
	decl: Node;
	sym: Symbol;
	ctx: TransformContext;
}

function routineDecl(stmt: Node): Node | null {
	if (stmt.kind == NodeKind.ExportDecl) return routineDecl((stmt.data as ExportDeclData).exportedDecl);
	if (stmt.kind == NodeKind.DecoratedDecl) return routineDecl((stmt.data as DecoratedDeclData).decoratedNode);
	return stmt.kind == NodeKind.FunctionDecl ? stmt : null;
}

function inferable(decl: Node, overriding: HashSet<Symbol>): boolean {
	const d = decl.data as FunctionDeclData;
	const sym = decl.resolvedSym;
	if (sym == null || sym.symbolKind != SymbolKind.Function || d.fnBody == null || d.fnBody.kind != NodeKind.BlockStmt) return false;
	const flags = routineFlagSet(d.fnFlags);
	if (flags.has(RoutineFlag.Generic) || flags.has(RoutineFlag.Extern)) return false;
	if (sym.overloads.length > 0 || sym.overloadIdx != 0 || sym.exportName != "" || sym.nativeName != "" || overriding.has(sym)) return false;
	const entry = dispatchEntryFor(sym);
	if (entry != null && entry.overloaded) return false;
	if (hasFlag(sym, SymbolFlag.ImportC) || hasFlag(sym, SymbolFlag.GeneratedOp) || hasFlag(sym, SymbolFlag.OverloadSig) || hasFlag(sym, SymbolFlag.Borrow) || hasFlag(sym, SymbolFlag.CompileTime)) return false;
	if (hasFlag(sym, SymbolFlag.Forward) || hasFlag(sym, SymbolFlag.WasForwarded) || hasFlag(sym, SymbolFlag.Async)) return false;
	const t = sym.symbolType;
	if (t == null || t.kind != TypeKind.Function || t.callConv == CallingConvention.CcInline || isGeneratorBody(d.fnBody)) return false;
	return decl.paramSyms != null && decl.paramSyms.length == t.typeChildren.length;
}

function noteObserved(n: Node, candidates: HashSet<Symbol>, observed: HashSet<Symbol>): void {
	if (n.kind == NodeKind.FunctionDecl || n.kind == NodeKind.ExportDecl || n.kind == NodeKind.DecoratedDecl) {
		forEachChild(n, (c: Node): void => noteObserved(c, candidates, observed));
		return;
	}
	if (n.kind == NodeKind.CallExpr) {
		const d = n.data as CallExprData;
		const callee = d.callee;
		if (callee.kind == NodeKind.MemberExpr) noteObserved((callee.data as MemberExprData).object, candidates, observed);
		else if (callee.kind != NodeKind.Identifier) noteObserved(callee, candidates, observed);
		for (const a of d.arguments) noteObserved(a, candidates, observed);
		return;
	}
	if (n.resolvedSym != null && candidates.has(n.resolvedSym)) observed.add(n.resolvedSym);
	forEachChild(n, (c: Node): void => noteObserved(c, candidates, observed));
}

function paramIndex(arg: Node, params: Symbol[]): int32 {
	if (arg == null || arg.kind != NodeKind.Identifier || arg.resolvedSym == null) return -1;
	return params.indexOf(arg.resolvedSym) as int32;
}

function isLocalOfFrame(target: Node): boolean {
	const sym = target.resolvedSym;
	if (target.kind != NodeKind.Identifier || sym == null) return false;
	if (sym.symbolKind == SymbolKind.Parameter) return true;
	return (sym.symbolKind == SymbolKind.Variable || sym.symbolKind == SymbolKind.Temp)
		&& !hasFlag(sym, SymbolFlag.Global) && !hasFlag(sym, SymbolFlag.StaticLocal);
}

function findSinks(n: Node, params: Symbol[], hits: boolean[], branched: boolean): void {
	if (n.kind == NodeKind.FunctionDecl || n.kind == NodeKind.ArrowFunction || n.kind == NodeKind.FunctionExpr) return;
	if (!branched) {
		if (n.kind == NodeKind.BinaryExpr) {
			const d = n.data as BinaryExprData;
			const at = paramIndex(d.right, params);
			if (d.operator == "=" && at >= 0 && !isLocalOfFrame(d.left)) hits[at] = true;
		} else if (n.kind == NodeKind.CallExpr) {
			const d = n.data as CallExprData;
			const formals = calledRoutineType(n)?.typeChildren ?? null;
			if (formals != null) {
				for (let i = 0; i < d.arguments.length && i < formals.length; i += 1) {
					const at = paramIndex(d.arguments[i], params);
					if (at >= 0 && formals[i].kind == TypeKind.Sink) hits[at] = true;
				}
			}
		} else if (n.kind == NodeKind.ObjectLiteral) {
			for (const p of (n.data as ObjectLiteralData).properties) {
				const at = paramIndex(p, params);
				if (at >= 0) hits[at] = true;
			}
		} else if (n.kind == NodeKind.ArrayLiteral) {
			for (const e of (n.data as ArrayLiteralData).elements) {
				const at = paramIndex(e, params);
				if (at >= 0) hits[at] = true;
			}
		}
	}
	if (n.kind == NodeKind.IfStmt) {
		const d = n.data as IfStmtData;
		findSinks(d.condition, params, hits, branched);
		if (d.consequent != null) findSinks(d.consequent, params, hits, true);
		if (d.alternate != null) findSinks(d.alternate, params, hits, true);
		return;
	}
	if (n.kind == NodeKind.ConditionalExpr) {
		const d = n.data as ConditionalExprData;
		findSinks(d.ternaryCondition, params, hits, branched);
		findSinks(d.ternaryConsequent, params, hits, true);
		findSinks(d.ternaryAlternate, params, hits, true);
		return;
	}
	const inside = branched || n.kind == NodeKind.SwitchStmt || n.kind == NodeKind.MatchExpr || n.kind == NodeKind.MatchStmt;
	forEachChild(n, (c: Node): void => findSinks(c, params, hits, inside));
}

function movable(t: Type, ctx: TransformContext): boolean {
	if (t.kind == TypeKind.Sink || t.kind == TypeKind.Var || t.kind == TypeKind.Lent || t.kind == TypeKind.Borrow || t.kind == TypeKind.Cursor || t.kind == TypeKind.Varargs) return false;
	return classifyType(t, ctx).needsCleanup;
}

export function inferSinkParams(trees: Node[], ctxs: TransformContext[]): void {
	const overriding = new HashSet<Symbol>();
	dispatchOverrideTable().forEach((overrides: Symbol[], base: Symbol): void => {
		overriding.add(base);
		for (const o of overrides) overriding.add(o);
	});
	const routines: Routine[] = [];
	const candidates = new HashSet<Symbol>();
	for (let i = 0; i < trees.length; i += 1) {
		for (const stmt of (trees[i].data as ProgramData).programStmts) {
			const decl = routineDecl(stmt);
			if (decl == null || !inferable(decl, overriding)) continue;
			routines.push({ decl, sym: decl.resolvedSym!, ctx: ctxs[i] });
			candidates.add(decl.resolvedSym!);
		}
	}
	const observed = new HashSet<Symbol>();
	for (const tree of trees) noteObserved(tree, candidates, observed);
	for (const r of routines) {
		if (observed.has(r.sym)) continue;
		const params = r.decl.paramSyms!;
		const formals = r.sym.symbolType.typeChildren;
		const hits: boolean[] = [];
		for (let i = 0; i < params.length; i += 1) hits.push(false);
		findSinks((r.decl.data as FunctionDeclData).fnBody, params, hits, false);
		for (let i = 0; i < formals.length; i += 1) {
			if (hits[i] && r.sym.symbolType.typeNames[i] != "this" && movable(formals[i], r.ctx)) formals[i] = createSink(formals[i]);
		}
	}
}
