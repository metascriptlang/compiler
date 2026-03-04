// Result Desugar — transforms TryExpr → VariableDecl + IfStmt + value extraction
// Follows reference result_desugar.zig
//
// Case 1: const x = try f();
//   → const $result_0 = f();
//     if (!$result_0.ok) { return Result.err($result_0.error); }
//     const x = $result_0.value;
//
// Case 2: const x = try f() catch defaultVal;
//   → const $result_0 = f();
//     const x = $result_0.ok ? $result_0.value : defaultVal;
//
// Case 3: return try f();
//   → const $result_0 = f();
//     if (!$result_0.ok) { return Result.err($result_0.error); }
//     return $result_0.value;
//
// Case 4: try f(); (standalone ExprStmt)
//   → const $result_0 = f();
//     if (!$result_0.ok) { return Result.err($result_0.error); }

import {
	Node, NodeKind, DeclKind, SourceLocation,
	VariableDeclData, ReturnStmtData, ExprStmtData, TryExprData,
} from "../../ast/node";
import { Type, TypeKind, booleanType } from "../../checker/types";
import { TransformContext, freshTemp } from "../context";
import { walkExpandBlocks } from "../walker";
import {
	makeIdent, makeVarDecl, makeBlock, makeExprStmt,
	makeReturn, makeIf, makeMember, makeCall, makeConditional,
	makeUnary,
} from "../util";
import { check } from "std/testing";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerTryExpr(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandStmt, ctx);
	return program;
}

// Expand a single statement. Returns [stmt] for passthrough, or multiple stmts for try expansion.
function expandStmt(stmt: Node, ctx: TransformContext): Node[] {
	match (stmt.kind) {
		NodeKind.VariableDecl => {
			const d = stmt.data as VariableDeclData;
			if (d.initializer.kind === NodeKind.TryExpr) {
				return expandVarDeclTry(stmt, ctx);
			}
		},
		NodeKind.ReturnStmt => {
			const d = stmt.data as ReturnStmtData;
			if (d.argument.kind === NodeKind.TryExpr) {
				return expandReturnTry(stmt, ctx);
			}
		},
		NodeKind.ExprStmt => {
			const d = stmt.data as ExprStmtData;
			if (d.expr.kind === NodeKind.TryExpr) {
				return expandExprStmtTry(stmt, ctx);
			}
		},
		_ => {},
	};
	return [stmt];
}

// Case 1: const x = try f();
function expandVarDeclTry(stmt: Node, ctx: TransformContext): Node[] {
	const d = stmt.data as VariableDeclData;
	const tryExpr = d.initializer;
	const tryData = tryExpr.data as TryExprData;
	const loc = stmt.location;
	const tempName = freshTemp(ctx, "result");
	const result: Node[] = [];

	// const $result_N = f();
	const resType = tryExpr.nodeType; // Result<T, E>
	const resDecl = makeVarDecl(tempName, tryData.tryArg, DeclKind.Const, loc);
	resDecl.nodeType = resType;
	result.push(resDecl);

	if (tryData.hasCatch) {
		// Case 2: const x = $result.ok ? $result.value : catchVal;
		const okCheck = makeMember(makeIdent(tempName, loc), "ok", loc);
		okCheck.nodeType = booleanType();
		const valueAccess = makeMember(makeIdent(tempName, loc), "value", loc);
		if (resType !== null) valueAccess.nodeType = resType.typeReturn;

		const condExpr = makeConditional(okCheck, valueAccess, tryData.catchVal, loc);
		condExpr.nodeType = stmt.nodeType; // the type of the variable being declared

		const varDecl = makeVarDecl(d.declName, condExpr, d.declKind, loc);
		varDecl.nodeType = stmt.nodeType;
		result.push(varDecl);
	} else {
		// if (!$result.ok) { return Result.err($result.error); }
		result.push(makeErrorCheck(tempName, resType, loc));
		// const x = $result.value;
		const valueAccess = makeMember(makeIdent(tempName, loc), "value", loc);
		if (resType !== null) valueAccess.nodeType = resType.typeReturn;

		const varDecl = makeVarDecl(d.declName, valueAccess, d.declKind, loc);
		varDecl.nodeType = stmt.nodeType;
		result.push(varDecl);
	}

	return result;
}

// Case 3: return try f();
function expandReturnTry(stmt: Node, ctx: TransformContext): Node[] {
	const d = stmt.data as ReturnStmtData;
	const tryExpr = d.argument;
	const tryData = tryExpr.data as TryExprData;
	const loc = stmt.location;
	const tempName = freshTemp(ctx, "result");
	const result: Node[] = [];

	// const $result_N = f();
	const resType = tryExpr.nodeType; // Result<T, E>
	const resDecl = makeVarDecl(tempName, tryData.tryArg, DeclKind.Const, loc);
	resDecl.nodeType = resType;
	result.push(resDecl);

	// if (!$result.ok) { return Result.err($result.error); }
	result.push(makeErrorCheck(tempName, resType, loc));

	// return $result.value;
	const valueAccess = makeMember(makeIdent(tempName, loc), "value", loc);
	if (resType !== null) valueAccess.nodeType = resType.typeReturn;
	result.push(makeReturn(valueAccess, loc));

	return result;
}

// Case 4: try f(); (standalone ExprStmt)
function expandExprStmtTry(stmt: Node, ctx: TransformContext): Node[] {
	const d = stmt.data as ExprStmtData;
	const tryExpr = d.expr;
	const tryData = tryExpr.data as TryExprData;
	const loc = stmt.location;
	const tempName = freshTemp(ctx, "result");
	const result: Node[] = [];

	// const $result_N = f();
	const resType = tryExpr.nodeType; // Result<T, E>
	const resDecl = makeVarDecl(tempName, tryData.tryArg, DeclKind.Const, loc);
	resDecl.nodeType = resType;
	result.push(resDecl);

	// if (!$result.ok) { return Result.err($result.error); }
	result.push(makeErrorCheck(tempName, resType, loc));

	return result;
}

// Build: if (!$result.ok) { return Result.err($result.error); }
function makeErrorCheck(tempName: string, resType: Type, loc: SourceLocation): Node {
	const okAccess = makeMember(makeIdent(tempName, loc), "ok", loc);
	okAccess.nodeType = booleanType();
	const notOk = makeUnary("!", okAccess, loc);
	notOk.nodeType = booleanType();

	const errorAccess = makeMember(makeIdent(tempName, loc), "error", loc);
	if (resType !== null) errorAccess.nodeType = resType.typeExtra;

	// Result.err($result.error)
	const resultErr = makeCall(
		makeMember(makeIdent("Result", loc), "err", loc),
		[errorAccess],
		loc
	);
	// V4 FIX: Ensure Result.err call has the same Result type as the original call
	resultErr.nodeType = resType;

	const returnStmt = makeReturn(resultErr, loc);
	const thenBlock = makeBlock([returnStmt], loc);
	const emptyBlock = makeBlock([], loc);
	return makeIf(notOk, thenBlock, emptyBlock, loc);
}

// ===== Tests =====
test "var decl try expands to 3 stmts" { check(stmtCountAfter("const x = try f;", lowerTryExpr) === 3); }

test "var decl try first is VariableDecl" { check(firstStmtKindAfter("const x = try f;", lowerTryExpr) === NodeKind.VariableDecl); }

test "try catch expands to 2 stmts" { check(stmtCountAfter("const x = try f catch \"default\";", lowerTryExpr) === 2); }

test "no try passthrough" { check(stmtCountAfter("const x = 1;", lowerTryExpr) === 1); }

test "multiple stmts preserved" { check(stmtCountAfter("let a = 1; const x = try f; let b = 2;", lowerTryExpr) === 5); }
