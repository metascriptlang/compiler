// Immortal Const Mark — marks the heap graph of a deep-Readonly module const immortal right after
// its initializer, so every thread may count it through the Ro flavor of the RC ops without writing
// its header. The checker judged the const at the end of its module (builtFresh: no task starts
// before that statement, the graph holds only cells the initializer built); a later judgement
// would read a transformed initializer.

import { Node, NodeKind, ProgramData, VariableDeclData, ExportDeclData, DecoratedDeclData, Symbol, SymbolKind, SymbolFlag, Type, TypeKind } from "../../ast/node";
import { isReadonlyView, isAtomicRef, unwrapRefNullUnion } from "../../checker/types";
import { hasFlag } from "../../checker/symbol";
import { isBakeableAggregateConst } from "../../checker/reachability";
import { TransformContext } from "../context";
import { runtimeRef, makeCall, makeExprStmt, makeIdentResolved } from "../util";

export function markImmortalConsts(program: Node, ctx: TransformContext): Node {
	if (ctx.raiserBackend) return program;
	const pd = program.data as ProgramData;
	const out: Node[] = [];
	for (const stmt of pd.programStmts) {
		out.push(stmt);
		const decl = moduleVarDecl(stmt);
		if (decl == null) continue;
		const sym = decl.resolvedSym;
		if (sym == null || !marksImmortal(sym) || isBakeableAggregateConst(decl)) continue;
		if ((decl.data as VariableDeclData).initializer == null) continue;
		out.push(makeExprStmt(makeCall(runtimeRef("msImmortalize", decl.location), [makeIdentResolved(sym, decl.location)], decl.location), decl.location));
	}
	pd.programStmts = out;
	return program;
}

function moduleVarDecl(stmt: Node | null): Node | null {
	let n = stmt;
	if (n != null && n.kind == NodeKind.DecoratedDecl) n = (n.data as DecoratedDeclData).decoratedNode;
	if (n != null && n.kind == NodeKind.ExportDecl) n = (n.data as ExportDeclData).exportedDecl;
	return n != null && n.kind == NodeKind.VariableDecl ? n : null;
}

function marksImmortal(sym: Symbol): boolean {
	const t = sym.symbolType;
	if (t == null || !isReadonlyView(t) || !hasFlag(sym, SymbolFlag.ImmutableModuleConst)) return false;
	return isCountedCell(t) || isCountedCell(unwrapRefNullUnion(t));
}

function isCountedCell(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.Ref && !isAtomicRef(t) && (t.sym == null || t.sym.symbolKind != SymbolKind.Actor);
}
