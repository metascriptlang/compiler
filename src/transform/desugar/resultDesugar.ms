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
	Node, NodeKind, DeclKind,
	VariableDeclData, ReturnStmtData, ExprStmtData, TryExprData,
} from "../../ast/node";
import { TransformContext, freshTemp } from "../context";
import { walkExpandBlocks } from "../walker";
import {
	makeIdent, makeVarDecl, makeBlock, makeExprStmt,
	makeReturn, makeIf, makeMember, makeCall, makeConditional,
	makeUnary,
} from "../util";
import { test, check, testGroup } from "std/testing";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerResult(program: Node, ctx: TransformContext): Node {
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
	const tryData = d.initializer.data as TryExprData;
	const loc = stmt.location;
	const tempName = freshTemp(ctx, "result");
	const result: Node[] = [];

	// const $result_N = f();
	result.push(makeVarDecl(tempName, tryData.tryArg, DeclKind.Const, loc));

	if (tryData.hasCatch) {
		// Case 2: const x = $result.ok ? $result.value : catchVal;
		const okCheck = makeMember(makeIdent(tempName, loc), "ok", loc);
		const valueAccess = makeMember(makeIdent(tempName, loc), "value", loc);
		const condExpr = makeConditional(okCheck, valueAccess, tryData.catchVal, loc);
		result.push(makeVarDecl(d.declName, condExpr, d.declKind, loc));
	} else {
		// if (!$result.ok) { return Result.err($result.error); }
		result.push(makeErrorCheck(tempName, loc));
		// const x = $result.value;
		const valueAccess = makeMember(makeIdent(tempName, loc), "value", loc);
		result.push(makeVarDecl(d.declName, valueAccess, d.declKind, loc));
	}

	return result;
}

// Case 3: return try f();
function expandReturnTry(stmt: Node, ctx: TransformContext): Node[] {
	const d = stmt.data as ReturnStmtData;
	const tryData = d.argument.data as TryExprData;
	const loc = stmt.location;
	const tempName = freshTemp(ctx, "result");
	const result: Node[] = [];

	// const $result_N = f();
	result.push(makeVarDecl(tempName, tryData.tryArg, DeclKind.Const, loc));
	// if (!$result.ok) { return Result.err($result.error); }
	result.push(makeErrorCheck(tempName, loc));
	// return $result.value;
	const valueAccess = makeMember(makeIdent(tempName, loc), "value", loc);
	result.push(makeReturn(valueAccess, loc));

	return result;
}

// Case 4: try f(); (standalone ExprStmt)
function expandExprStmtTry(stmt: Node, ctx: TransformContext): Node[] {
	const d = stmt.data as ExprStmtData;
	const tryData = d.expr.data as TryExprData;
	const loc = stmt.location;
	const tempName = freshTemp(ctx, "result");
	const result: Node[] = [];

	// const $result_N = f();
	result.push(makeVarDecl(tempName, tryData.tryArg, DeclKind.Const, loc));
	// if (!$result.ok) { return Result.err($result.error); }
	result.push(makeErrorCheck(tempName, loc));

	return result;
}

// Build: if (!$result.ok) { return Result.err($result.error); }
function makeErrorCheck(tempName: string, loc: Node["location"]): Node {
	const okAccess = makeMember(makeIdent(tempName, loc), "ok", loc);
	const notOk = makeUnary("!", okAccess, loc);
	const errorAccess = makeMember(makeIdent(tempName, loc), "error", loc);

	// Result.err($result.error)
	const resultErr = makeCall(
		makeMember(makeIdent("Result", loc), "err", loc),
		[errorAccess],
		loc
	);

	const returnStmt = makeReturn(resultErr, loc);
	const thenBlock = makeBlock([returnStmt], loc);
	const emptyBlock = makeBlock([], loc);
	return makeIf(notOk, thenBlock, emptyBlock, loc);
}

// ===== Tests =====

testGroup("Result Desugar", () => {
	test("var decl try expands to 3 stmts", () => {
		check(stmtCountAfter("const x = try f;", lowerResult) === 3);
	});
	test("var decl try first is VariableDecl", () => {
		check(firstStmtKindAfter("const x = try f;", lowerResult) === NodeKind.VariableDecl);
	});
	test("try catch expands to 2 stmts", () => {
		check(stmtCountAfter("const x = try f catch \"default\";", lowerResult) === 2);
	});
	test("no try passthrough", () => {
		check(stmtCountAfter("const x = 1;", lowerResult) === 1);
	});
	test("multiple stmts preserved", () => {
		check(stmtCountAfter("let a = 1; const x = try f; let b = 2;", lowerResult) === 5);
	});
});
