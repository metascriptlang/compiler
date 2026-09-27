// Async/Await Desugaring — converts await to yield, lets generator handle state machine
//
// async function f() { const x = await p; return x; }
// → function* f() { const x = yield p; return x; }
// → (generatorLower then builds the state machine)
//
// Proven architectural insight: "await is just yield." This pass rewrites, generator does heavy lifting.
// V1: No Promise wrapper (runtime/codegen concern, not AST transform).

import {
	Node, NodeKind, NodeFlag, createNode,
	FunctionDeclData, FunctionExprData, ArrowFunctionData, MethodDeclData, AwaitExprData,
} from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { TransformContext } from "../context";
import { syntheticToken, makeReturn } from "../util";
import { mapChildren, isFuncBoundary } from "../walker";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Await → Yield Rewriting =====
// Walk a function body, replacing AwaitExpr nodes with YieldExpr nodes.
// Stops at nested function boundaries (each async function is independent).

function rewriteAwaits(node: Node): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.AwaitExpr) {
		const d = node.data as AwaitExprData;
		return createNode(NodeKind.YieldExpr, { yieldArg: d.awaitArg, isDelegate: false }, syntheticToken(node.location));
	}
	if (isFuncBoundary(node)) return node;
	mapChildren(node, rewriteAwaits);
	return node;
}

// ===== Main Walk =====

function isAsyncFlags(flags: string): boolean {
	return flags == "async" || flags == "async_generator";
}

function desugarAsyncBody(fn: Node, body: Node): void {
	fn.flags = fn.flags.incl(NodeFlag.WasAsync);
	rewriteAwaits(body);
}

function walkAsync(node: Node | null): void {
	if (node == null) return;
	const k = node.kind;
	if (k == NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		walkAsync(d.fnBody);
		if (isAsyncFlags(d.fnFlags)) {
			desugarAsyncBody(node, d.fnBody);
			d.fnFlags = "generator";
		}
	} else if (k == NodeKind.MethodDecl) {
		const d = node.data as MethodDeclData;
		walkAsync(d.methodBody);
		if (isAsyncFlags(d.methodFlags)) {
			desugarAsyncBody(node, d.methodBody);
			d.methodFlags = "generator";
		}
	} else if (k == NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		walkAsync(d.funcExprBody);
		if (isAsyncFlags(d.funcExprFlags)) {
			desugarAsyncBody(node, d.funcExprBody);
			d.funcExprFlags = "generator";
		}
	} else if (k == NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		if (isAsyncFlags(d.arrowFlags) && d.arrowBody != null && d.arrowBody.kind != NodeKind.BlockStmt) {
			const ret = makeReturn(d.arrowBody, node.location);
			d.arrowBody = createNode(NodeKind.BlockStmt, { statements: [ret] }, syntheticToken(node.location));
		}
		walkAsync(d.arrowBody);
		if (isAsyncFlags(d.arrowFlags)) {
			desugarAsyncBody(node, d.arrowBody);
			d.arrowFlags = "generator";
		}
	} else {
		forEachChild(node, (child: Node): void => { walkAsync(child); });
	}
}

// ===== Main Entry Point =====

export function lowerAsync(program: Node, ctx: TransformContext): Node {
	walkAsync(program);
	return program;
}

// ===== Tests =====
test "non-async passthrough" { assert firstStmtKindAfter("function f() { return 1; }", lowerAsync) == NodeKind.FunctionDecl; }

test "stmt count passthrough" { assert stmtCountAfter("const x = 1;", lowerAsync) == 1; }

test "async function still one stmt" { assert stmtCountAfter("async function f() { await x; }", lowerAsync) == 1; }

test "async flag cleared" { assert firstStmtKindAfter("async function f() { await x; }", lowerAsync) == NodeKind.FunctionDecl; }

test "async arrow unchanged count" { assert stmtCountAfter("const f = async () => await x;", lowerAsync) == 1; }

test "non-async function preserved" { assert stmtCountAfter("function f() { return 1; }", lowerAsync) == 1; }
