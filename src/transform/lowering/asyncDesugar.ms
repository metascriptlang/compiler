// Async/Await Desugaring — converts await to yield, lets generator handle state machine
//
// async function f() { const x = await p; return x; }
// → function* f() { const x = yield p; return x; }
// → (generatorLower then builds the state machine)
//
// Proven architectural insight: "await is just yield." This pass rewrites, generator does heavy lifting.
// V1: No Promise wrapper (runtime/codegen concern, not AST transform).

import {
	Node, NodeKind, NodeFlag, DeclKind, createNode,
	ProgramData, BlockStmtData, FunctionDeclData, FunctionExprData,
	ArrowFunctionData, MethodDeclData, ConstructorDeclData,
	ExportDeclData, ClassDeclData, DecoratedDeclData,
	VariableDeclData, IfStmtData, WhileStmtData, TryCatchStmtData,
	ExprStmtData, ReturnStmtData,
	CallExprData, BinaryExprData,
	AwaitExprData,
} from "../../ast/node";
import { TransformContext } from "../context";
import { syntheticToken, makeVarDecl, makeIdent, makeReturn } from "../util";
import { mapChildren, isFuncBoundary } from "../walker";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Pre-pass: Split `return await expr` =====
// Before await→yield rewriting, split `return await expr` into two statements:
//   const $retAwait = await expr;
//   return $retAwait;
// This ensures the yield (from await→yield) ends up in a VarDecl initializer,
// which splitStmts (generatorLower.ms:183) handles correctly. Without this split,
// the yield ends up nested inside msFutureCompleteT's argument (asyncBridge embeds
// rd.argument into the completion call), which codegen can't emit (YieldExpr is
// control flow, not a value expression).
let _retAwaitCounter: number = 0;

function splitReturnAwait(node: Node): void {
	if (node === null) return;
	if (isFuncBoundary(node)) return;
	match (node.kind) {
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			splitReturnAwaitInStmts(d.statements);
			for (const s of d.statements) splitReturnAwait(s);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			splitReturnAwait(d.consequent);
			splitReturnAwait(d.alternate);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			splitReturnAwait(d.whileBody);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			splitReturnAwait(d.tryBody);
			splitReturnAwait(d.catchBody);
			splitReturnAwait(d.finallyBody);
		},
		_ => {},
	};
}

function splitReturnAwaitInStmts(stmts: Node[]): void {
	let i = 0;
	while (i < stmts.length) {
		const stmt = stmts[i];
		if (stmt !== null && stmt.kind === NodeKind.ReturnStmt) {
			const rd = stmt.data as ReturnStmtData;
			if (rd.argument !== null && rd.argument.kind === NodeKind.AwaitExpr) {
				const loc = stmt.location;
				const tmpName = "$retAwait" + _retAwaitCounter.toString();
				_retAwaitCounter = _retAwaitCounter + 1;
				// const $retAwaitN = await expr;
				const decl = makeVarDecl(tmpName, rd.argument, DeclKind.Const, loc);
				decl.nodeType = rd.argument.nodeType;
				// return $retAwaitN;
				const retIdent = makeIdent(tmpName, loc);
				retIdent.nodeType = rd.argument.nodeType;
				const ret = makeReturn(retIdent, loc);
				// Splice: replace stmts[i] with [decl, ret]
				const tail: Node[] = [];
				for (let j = i + 1; j < stmts.length; j += 1) tail.push(stmts[j]);
				while (stmts.length > i) stmts.pop();
				stmts.push(decl);
				stmts.push(ret);
				for (const t of tail) stmts.push(t);
				i = i + 2;
				continue;
			}
		}
		i = i + 1;
	}
}

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
				// Pre-pass: split `return await expr` → `const $retAwait = await expr; return $retAwait;`
				// Must run BEFORE rewriteAwaits so the VarDecl is in the body for collectDeclNames.
				splitReturnAwait(d.fnBody);
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
				splitReturnAwait(d.methodBody);
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
				splitReturnAwait(d.funcExprBody);
				rewriteAwaits(d.funcExprBody);
				d.funcExprFlags = "generator";
			}
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			walkAsync(d.arrowBody);
			if (d.arrowFlags === "async" || d.arrowFlags === "async_generator") {
				node.flags = node.flags | NodeFlag.WasAsync;
				splitReturnAwait(d.arrowBody);
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
