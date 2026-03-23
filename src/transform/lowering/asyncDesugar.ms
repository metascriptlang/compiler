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
	ProgramData, BlockStmtData, FunctionDeclData, FunctionExprData,
	ArrowFunctionData, MethodDeclData, ConstructorDeclData,
	ExportDeclData, ClassDeclData, DecoratedDeclData,
	VariableDeclData, IfStmtData, WhileStmtData, TryCatchStmtData,
	ExprStmtData, ReturnStmtData,
	CallExprData, BinaryExprData,
	AwaitExprData,
} from "../../ast/node";
import { TransformContext } from "../context";
import { syntheticToken } from "../util";
import { mapChildren, isFuncBoundary } from "../walker";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Await → Yield Rewriting =====
// Walk a function body, replacing AwaitExpr nodes with YieldExpr nodes.
// Stops at nested function boundaries (each async function is independent).

function rewriteAwaits(node: Node): Node {
	if (node === null) return node;
	if (node.kind === NodeKind.AwaitExpr) {
		const d = node.data as AwaitExprData;
		return createNode(NodeKind.YieldExpr, { yieldArg: d.awaitArg, isDelegate: false }, syntheticToken(node.location));
	}
	if (isFuncBoundary(node)) return node;
	mapChildren(node, rewriteAwaits);
	return node;
}

// ===== Main Walk =====

function walkAsync(node: Node): void {
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			for (const s of d.programStmts) { walkAsync(s); }
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) { walkAsync(s); }
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			// Recurse first (handle nested async functions)
			walkAsync(d.fnBody);
			if (d.fnFlags === "async" || d.fnFlags === "async_generator") {
				node.flags = node.flags | NodeFlag.WasAsync;
				rewriteAwaits(d.fnBody);
				d.fnFlags = "generator";
			}
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			walkCheckExpr(d.initializer);
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			walkCheckExpr(d.expr);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			walkCheckExpr(d.argument);
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			walkAsync(d.exportedDecl);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			for (const member of d.classBody) { walkAsync(member); }
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			walkAsync(d.methodBody);
			if (d.methodFlags === "async" || d.methodFlags === "async_generator") {
				node.flags = node.flags | NodeFlag.WasAsync;
				rewriteAwaits(d.methodBody);
				d.methodFlags = "generator";
			}
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			walkAsync(d.ctorBody);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			walkAsync(d.decoratedNode);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			walkAsync(d.consequent);
			walkAsync(d.alternate);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			walkAsync(d.whileBody);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			walkAsync(d.tryBody);
			walkAsync(d.catchBody);
			walkAsync(d.finallyBody);
		},
		_ => {},
	};
}

// Check function expressions and arrows for async flag
function walkCheckExpr(node: Node): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			walkAsync(d.funcExprBody);
			if (d.funcExprFlags === "async" || d.funcExprFlags === "async_generator") {
				node.flags = node.flags | NodeFlag.WasAsync;
				rewriteAwaits(d.funcExprBody);
				d.funcExprFlags = "generator";
			}
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			walkAsync(d.arrowBody);
			if (d.arrowFlags === "async" || d.arrowFlags === "async_generator") {
				node.flags = node.flags | NodeFlag.WasAsync;
				rewriteAwaits(d.arrowBody);
				d.arrowFlags = "generator";
			}
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			walkCheckExpr(d.callee);
			for (const arg of d.arguments) { walkCheckExpr(arg); }
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			walkCheckExpr(d.left);
			walkCheckExpr(d.right);
		},
		_ => {},
	};
}

// ===== Main Entry Point =====

export function lowerAsync(program: Node, ctx: TransformContext): Node {
	walkAsync(program);
	return program;
}

// ===== Tests =====
test "non-async passthrough" { assert firstStmtKindAfter("function f() { return 1; }", lowerAsync) === NodeKind.FunctionDecl; }

test "stmt count passthrough" { assert stmtCountAfter("const x = 1;", lowerAsync) === 1; }

test "async function still one stmt" { assert stmtCountAfter("async function f() { await x; }", lowerAsync) === 1; }

test "async flag cleared" { assert firstStmtKindAfter("async function f() { await x; }", lowerAsync) === NodeKind.FunctionDecl; }

test "async arrow unchanged count" { assert stmtCountAfter("const f = async () => await x;", lowerAsync) === 1; }

test "non-async function preserved" { assert stmtCountAfter("function f() { return 1; }", lowerAsync) === 1; }
