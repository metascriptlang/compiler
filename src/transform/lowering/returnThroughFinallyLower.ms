// The reference holds a returned value in the routine's result until the routine exits, so a
// finally that raises or returns again releases it by the ordinary scope-exit and assignment rules.
// The Raiser re-runs its Ret after the finally bodies, so there every returned value is held,
// counted or not, and a finally that writes the returned variable leaves the result alone.

import {
	Node, NodeKind, DeclKind, Symbol, TypeKind,
	FunctionDeclData, MethodDeclData, ArrowFunctionData, FunctionExprData,
	TryCatchStmtData, ReturnStmtData, createNode,
} from "../../ast/node";
import { TransformContext, freshOwnedSym } from "../context";
import { walkNode, mapChildren, isFuncBoundary } from "../walker";
import { makeBool, makeBlock, makeBreak, makeVarDecl, makeIdentResolved, makeAssign, makeExprStmt, makeReturn, syntheticToken } from "../util";
import { isGenericFn, routineKindFlag } from "../../checker/context";
import { classifyType, RcKind } from "../../analyzer/classify";

export function lowerReturnThroughFinally(program: Node, ctx: TransformContext, everyValue: boolean = false): Node {
	walkNode(program, (node: Node): Node => {
		match (node.kind) {
			NodeKind.FunctionDecl => {
				const d = node.data as FunctionDeclData;
				if (plainRoutine(d.fnFlags)) d.fnBody = processBody(node, d.fnBody, ctx, everyValue);
			},
			NodeKind.MethodDecl => {
				const d = node.data as MethodDeclData;
				if (plainRoutine(d.methodFlags)) d.methodBody = processBody(node, d.methodBody, ctx, everyValue);
			},
			NodeKind.ArrowFunction => {
				const d = node.data as ArrowFunctionData;
				if (plainRoutine(d.arrowFlags)) d.arrowBody = processBody(node, d.arrowBody, ctx, everyValue);
			},
			NodeKind.FunctionExpr => {
				const d = node.data as FunctionExprData;
				if (plainRoutine(d.funcExprFlags)) d.funcExprBody = processBody(node, d.funcExprBody, ctx, everyValue);
			},
			_ => {},
		};
		return node;
	});
	return program;
}

function plainRoutine(flags: string): boolean {
	return !isGenericFn(flags) && routineKindFlag(flags) == "";
}

function processBody(fn: Node, body: Node, ctx: TransformContext, everyValue: boolean): Node {
	if (body == null || body.kind != NodeKind.BlockStmt) return body;
	if (fn.nodeType == null || fn.nodeType.kind != TypeKind.Function) return body;
	const retType = fn.nodeType.typeReturn;
	if (retType == null || (!everyValue && classifyType(retType, ctx, false).rcKind == RcKind.None)) return body;
	if (!returnsThroughFinally(body, false)) return body;

	const loc = body.location;
	const result = freshOwnedSym(ctx, "result", retType);
	const wrapped = rewriteReturns(body, result, false);
	const decl = makeVarDecl(result.name, null as unknown as Node, DeclKind.Let, loc);
	decl.nodeType = retType;
	decl.resolvedSym = result;
	const block = createNode(NodeKind.DoWhileStmt, { doBody: wrapped, doCondition: makeBool(false, loc), dwLabel: result.name, dwSwitchWrapper: false }, syntheticToken(loc));
	return makeBlock([decl, block, makeReturn(makeIdentResolved(result, loc), loc)], loc);
}

function returnsThroughFinally(n: Node | null, inside: boolean): boolean {
	if (n == null || isFuncBoundary(n) || n.kind == NodeKind.MethodDecl || n.kind == NodeKind.ClassDecl) return false;
	if (n.kind == NodeKind.ReturnStmt) return inside && (n.data as ReturnStmtData).argument != null;
	const within = inside || (n.kind == NodeKind.TryCatchStmt && (n.data as TryCatchStmtData).finallyBody != null);
	let found = false;
	mapChildren(n, (c: Node): Node => {
		if (!found) found = returnsThroughFinally(c, within);
		return c;
	});
	return found;
}

function rewriteReturns(n: Node, result: Symbol, inside: boolean): Node {
	if (n == null || isFuncBoundary(n) || n.kind == NodeKind.MethodDecl || n.kind == NodeKind.ClassDecl) return n;
	if (n.kind == NodeKind.ReturnStmt) {
		const arg = (n.data as ReturnStmtData).argument;
		if (!inside || arg == null) return n;
		const brk = makeBreak(n.location);
		(brk.data as { breakLabel: string }).breakLabel = result.name;
		return makeBlock([makeExprStmt(makeAssign(makeIdentResolved(result, n.location), arg, n.location), n.location), brk], n.location);
	}
	const within = inside || (n.kind == NodeKind.TryCatchStmt && (n.data as TryCatchStmtData).finallyBody != null);
	mapChildren(n, (c: Node): Node => rewriteReturns(c, result, within));
	return n;
}
