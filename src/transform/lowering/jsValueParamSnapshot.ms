import {
	Node, NodeKind, Symbol, SymbolKind, BlockStmtData, BinaryExprData,
	FunctionDeclData, FunctionExprData, ArrowFunctionData, MethodDeclData,
} from "../../ast/node";
import { needsValueCopy } from "../../checker/types";
import { routineKindFlag } from "../../checker/context";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeIdentResolved, makeAssign, makeExprStmt } from "../util";
import { isRoutineNode } from "../../ast/shape";
import { isAssignOp } from "../../ast/operators";
import { anyDescendant, Visit } from "../../ast/visitor";
import { routineBodyBlock } from "./jsVarParamLower";

function runsAtFirstResume(routine: Node): boolean {
	const flags = match (routine.kind) {
		NodeKind.FunctionDecl => (routine.data as FunctionDeclData).fnFlags,
		NodeKind.FunctionExpr => (routine.data as FunctionExprData).funcExprFlags,
		NodeKind.ArrowFunction => (routine.data as ArrowFunctionData).arrowFlags,
		NodeKind.MethodDecl => (routine.data as MethodDeclData).methodFlags,
		_ => "",
	};
	const kind = routineKindFlag(flags);
	return kind == "generator" || kind == "async_generator";
}

function mayRunOtherCode(n: Node): Visit {
	match (n.kind) {
		NodeKind.CallExpr | NodeKind.NewExpr | NodeKind.AwaitExpr | NodeKind.YieldExpr | NodeKind.UpdateExpr
			| NodeKind.ForOfStmt | NodeKind.ForInStmt | NodeKind.ArrowFunction | NodeKind.FunctionExpr => { return Visit.Hit; },
		NodeKind.BinaryExpr => { return isAssignOp((n.data as BinaryExprData).operator) ? Visit.Hit : Visit.Descend; },
		NodeKind.MemberExpr => {
			const sym = n.resolvedSym;
			const decl = sym != null ? sym.declNode : null;
			return decl != null && decl.kind == NodeKind.MethodDecl ? Visit.Hit : Visit.Descend;
		},
		_ => { return Visit.Descend; },
	};
}

function snapshotSyms(routine: Node): Symbol[] {
	const out: Symbol[] = [];
	if (routine.paramSyms == null) return out;
	for (const s of routine.paramSyms!) {
		if (s.symbolKind == SymbolKind.Parameter && needsValueCopy(s.symbolType)) out.push(s);
	}
	return out;
}

// A by-value struct parameter binds the value the call passed, as the C parameter
// copy does, so a write through another path (a `ref` argument, a global, an
// element, a field) cannot reach it; the assignment is the parameter's own copy
// (it rebinds, like any assignment to a view binding). A body that only reads
// cannot be written under its parameter, so it keeps the caller's object.
export function lowerJsValueParamSnapshot(program: Node, ctx: TransformContext): Node {
	walkNode(program, (node: Node): Node => {
		if (!isRoutineNode(node) || runsAtFirstResume(node)) return node;
		const syms = snapshotSyms(node);
		if (syms.length == 0) return node;
		const body = routineBodyBlock(node);
		if (body == null || !anyDescendant(body, mayRunOtherCode)) return node;
		const bs = body.data as BlockStmtData;
		const pro: Node[] = [];
		for (const s of syms) {
			pro.push(makeExprStmt(makeAssign(makeIdentResolved(s, node.location), makeIdentResolved(s, node.location), node.location), node.location));
		}
		for (const st of bs.statements) pro.push(st);
		bs.statements = pro;
		return node;
	});
	return program;
}
