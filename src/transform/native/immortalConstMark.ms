// Immortal Const Mark — marks the heap graph of a deep-Readonly module const immortal right after
// its initializer, so every thread may count it through the Ro flavor of the RC ops without writing
// its header. The checker judged the const at the end of its module (builtFresh: no task starts
// before that statement, the graph holds only cells the initializer built); a later judgement
// would read a transformed initializer.

import { Node, NodeKind, ProgramData, VariableDeclData, ExportDeclData, DecoratedDeclData, Symbol, SymbolFlag, Type, TypeKind, SourceLocation } from "../../ast/node";
import { isSendableFunction } from "../../checker/types";
import { immortalConstShape } from "../../checker/effects";
import { hasFlag } from "../../checker/symbol";
import { isBakeableAggregateConst } from "../../checker/reachability";
import { valueReachOp } from "../../codegen/c/types";
import { TransformContext } from "../context";
import { runtimeRef, makeCall, makeExprStmt, makeIdentResolved, makeTypedIdentResolved, makeHiddenAddr } from "../util";

export function markImmortalConsts(program: Node, ctx: TransformContext): Node {
	if (ctx.raiserBackend) return program;
	const pd = program.data as ProgramData;
	const out: Node[] = [];
	for (const stmt of pd.programStmts) {
		out.push(stmt);
		const decl = moduleVarDecl(stmt);
		if (decl == null) continue;
		const sym = decl.resolvedSym;
		if (sym == null || !judgedImmutable(sym) || isBakeableAggregateConst(decl)) continue;
		if ((decl.data as VariableDeclData).initializer == null) continue;
		for (const mark of immortalizeCalls(sym, decl.location)) out.push(makeExprStmt(mark, decl.location));
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

function judgedImmutable(sym: Symbol): boolean {
	return hasFlag(sym, SymbolFlag.ImmutableModuleConst) && immortalConstShape(sym.symbolType);
}

function immortalizeCalls(sym: Symbol, loc: SourceLocation): Node[] {
	const t = sym.symbolType as Type;
	if (isSendableFunction(t)) return [makeCall(runtimeRef("msImmortalizeClosure", loc), [makeIdentResolved(sym, loc)], loc)];
	if (t.kind != TypeKind.Struct) return [makeCall(runtimeRef("msImmortalize", loc), [makeIdentResolved(sym, loc)], loc)];
	const reach = valueReachOp(t);
	if (reach == null) throw new Error(`internal: the struct const '${sym.name}' the checker shares across threads has no reach op to mark it immortal`);
	const walk = makeCall(makeTypedIdentResolved(reach, null, loc), [makeHiddenAddr(makeIdentResolved(sym, loc), loc), makeCall(runtimeRef("msImmortalBegin", loc), [], loc)], loc);
	return [walk, makeCall(runtimeRef("msImmortalEnd", loc), [], loc)];
}
