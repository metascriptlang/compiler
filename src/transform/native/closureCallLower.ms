// Closure Call Lowering — rewrite indirect closure calls to direct calls with explicit fn/env extraction
// Runs AFTER closureCallMarker (which sets isDirectCall = false), BEFORE codegen.
//
// Rewrites:
//   cb(args)  where isDirectCall === false
//   → ((msClosureFn)(cb.fn))(cb.env, args)
//
// This moves closure-calling logic from codegen (TAG_CALL_CLOSURE) to the transform layer,
// keeping codegen as a dumb emitter (only TAG_CALL_DIRECT).
//
// The fn pointer is cast to msClosureFn (typedef void (*msClosureFn)(void*, ...)) via TypeAssertion.
// Setting nodeType = null on the TypeAssertion forces codegen to use mangle(asType) path,
// and mangle("msClosureFn") passes through unchanged since it's all alphanumeric.

import {
	Node, NodeKind, SourceLocation, DeclKind,
	CallExprData, TypeAssertionData,
} from "../../ast/node";
import { createNode } from "../../ast/node";
import { Type, TypeKind } from "../../checker/types";
import { TransformContext, freshTemp } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeMember, makeVarDecl, makeExprStmt, syntheticToken } from "../util";

// ===== Main Entry Point =====

export function lowerClosureCalls(program: Node, ctx: TransformContext): Node {
	walkNode(program, rewriteClosureCall);
	return program;
}

// ===== Rewriter =====

function rewriteClosureCall(node: Node): Node {
	if (node.kind !== NodeKind.CallExpr) return node;
	const cd = node.data as CallExprData;
	if (cd.isDirectCall) return node;

	const loc = node.location;
	const callee = cd.callee;

	// EvalOnce: Identifier callees are safe to read twice (no side effects).
	// For any other callee kind (future-proofing), we'd need a temp variable.
	// Currently closureCallMarker only marks Identifier callees, so this is always safe.

	// Extract fn pointer: callee.fn
	const fnMember = makeMember(callee, "fn", loc);

	// Cast to msClosureFn: ((msClosureFn)(callee.fn))
	// nodeType = null forces codegen to use mangle(asType) path → "msClosureFn" unchanged
	const fnCast = createNode(NodeKind.TypeAssertion, { asExpr: fnMember, asType: "msClosureFn" }, syntheticToken(loc));
	fnCast.nodeType = null as unknown as Type;

	// Extract env pointer: callee.env
	const envMember = makeMember(callee, "env", loc);

	// Build new args: [env, ...originalArgs]
	const newArgs: Node[] = [envMember];
	let i = 0;
	while (i < cd.arguments.length) {
		newArgs.push(cd.arguments[i]);
		i = i + 1;
	}

	// Create direct call: ((msClosureFn)(cb.fn))(cb.env, arg1, arg2, ...)
	const call = makeCall(fnCast, newArgs, loc);
	call.nodeType = node.nodeType;
	// Force isDirectCall = true on the new call
	const newCd = call.data as CallExprData;
	newCd.isDirectCall = true;

	return call;
}

// ===== Tests =====
import { check } from "std/testing";
import { createFunction, numberType, voidType } from "../../checker/types";
import { makeSymbol, SymbolKind } from "../../checker/symbol";
import { Token } from "../../lexer/token";
import { makeBlock } from "../util";
import { makeCtx } from "../testUtil";

function wrapProgram(stmts: Node[]): Node {
	return createNode(NodeKind.Program, { programStmts: stmts, programImports: [] }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
}

function makeClosureCall(calleeName: string, args: Node[]): { prog: Node, cd: CallExprData } {
	const loc: SourceLocation = { line: 1, column: 0 };
	const callee = makeIdent(calleeName, loc);
	const fnType = createFunction([numberType()], [], voidType());
	callee.nodeType = fnType;
	const callNode = makeCall(callee, args, loc);
	const cd = callNode.data as CallExprData;
	cd.isDirectCall = false;
	const exprStmt = createNode(NodeKind.ExprStmt, { expr: callNode }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
	const prog = wrapProgram([exprStmt]);
	return { prog, cd };
}

test "closure call is rewritten to direct call" {
	const t = makeClosureCall("cb", []);
	lowerClosureCalls(t.prog, makeCtx());
	// After lowering, the ExprStmt should contain a direct call
	const exprStmt = (t.prog.data as { programStmts: Node[] }).programStmts[0];
	const newCall = (exprStmt.data as { expr: Node }).expr;
	check(newCall.kind === NodeKind.CallExpr);
	const newCd = newCall.data as CallExprData;
	check(newCd.isDirectCall === true);
}

test "closure call has env prepended to args" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const arg1 = makeIdent("x", loc);
	const t = makeClosureCall("cb", [arg1]);
	lowerClosureCalls(t.prog, makeCtx());
	const exprStmt = (t.prog.data as { programStmts: Node[] }).programStmts[0];
	const newCall = (exprStmt.data as { expr: Node }).expr;
	const newCd = newCall.data as CallExprData;
	// Should have env + original arg = 2 args
	check(newCd.arguments.length === 2);
	// First arg is env (MemberExpr .env)
	check(newCd.arguments[0].kind === NodeKind.MemberExpr);
}

test "closure call callee is TypeAssertion with msClosureFn" {
	const t = makeClosureCall("cb", []);
	lowerClosureCalls(t.prog, makeCtx());
	const exprStmt = (t.prog.data as { programStmts: Node[] }).programStmts[0];
	const newCall = (exprStmt.data as { expr: Node }).expr;
	const newCd = newCall.data as CallExprData;
	// Callee should be TypeAssertion
	check(newCd.callee.kind === NodeKind.TypeAssertion);
	const ta = newCd.callee.data as TypeAssertionData;
	check(ta.asType === "msClosureFn");
	// Inner should be MemberExpr .fn
	check(ta.asExpr.kind === NodeKind.MemberExpr);
}

test "direct call is not rewritten" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const callee = makeIdent("directFn", loc);
	const callNode = makeCall(callee, [], loc);
	const cd = callNode.data as CallExprData;
	cd.isDirectCall = true;
	const exprStmt = createNode(NodeKind.ExprStmt, { expr: callNode }, { kind: 0, value: "", line: 0, column: 0 } as unknown as Token);
	const prog = wrapProgram([exprStmt]);
	lowerClosureCalls(prog, makeCtx());
	// Should remain unchanged
	const newCd = ((prog.data as { programStmts: Node[] }).programStmts[0].data as { expr: Node }).expr.data as CallExprData;
	check(newCd.isDirectCall === true);
	check(newCd.callee.kind === NodeKind.Identifier);
}
