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
	Node, NodeKind, DeclKind, SourceLocation, Symbol, SymbolKind, SymbolState,
	VariableDeclData, ReturnStmtData, ExprStmtData, TryExprData,
} from "../../ast/node";
import { Type, TypeKind, booleanType, getProperty } from "../../checker/types";
import { makeSymbol, lookupSymbol } from "../../checker/symbol";
import { TransformContext, freshTemp } from "../context";
import { walkExpandBlocks } from "../walker";
import {
	makeIdent, makeVarDecl, makeBlock, makeExprStmt,
	makeReturn, makeIf, makeMember, makeCall, makeCallResolved, makeConditional,
	makeUnary,
} from "../util";
import { check } from "std/testing";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Helpers: Typed Result Access =====

// Create a member access on a Result variable with resolvedSym for the property.
// Uses getProperty(resType, propName) internally — single source of truth for type derivation.
function makeResultMember(tempName: string, resType: Type, propName: string, loc: SourceLocation): Node {
	const ref = makeIdent(tempName, loc);
	const mem = makeMember(ref, propName, loc);

	// Context-aware: derive type from Result type structure
	if (resType !== null) {
		const propType = getProperty(resType, propName);
		mem.nodeType = propType;
		// Synthetic property symbol (mirrors checkExprPass.ms line 703-707)
		const propSym = makeSymbol(propName, SymbolKind.Property, propType, false);
		propSym.state = SymbolState.Shaped;
		mem.resolvedSym = propSym;
	}
	return mem;
}

// Look up the Result.err symbol from checker context (returns null if unavailable)
function lookupResultErr(ctx: TransformContext): Symbol {
	if (ctx.checkerCtx === null) return null as unknown as Symbol;
	if (ctx.checkerCtx.table === null) return null as unknown as Symbol;
	return lookupSymbol(ctx.checkerCtx.table, "err");
}

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
		const okCheck = makeResultMember(tempName, resType, "ok", loc);
		const valueAccess = makeResultMember(tempName, resType, "value", loc);

		const condExpr = makeConditional(okCheck, valueAccess, tryData.catchVal, loc);
		condExpr.nodeType = stmt.nodeType;

		const varDecl = makeVarDecl(d.declName, condExpr, d.declKind, loc);
		varDecl.nodeType = stmt.nodeType;
		result.push(varDecl);
	} else {
		// if (!$result.ok) { return Result.err($result.error); }
		result.push(makeErrorCheck(tempName, resType, loc, ctx));
		// const x = $result.value;
		const valueAccess = makeResultMember(tempName, resType, "value", loc);

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
	result.push(makeErrorCheck(tempName, resType, loc, ctx));

	// return $result.value;
	const valueAccess = makeResultMember(tempName, resType, "value", loc);
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
	result.push(makeErrorCheck(tempName, resType, loc, ctx));

	return result;
}

// Build: if (!$result.ok) { return Result.err($result.error); }
function makeErrorCheck(tempName: string, resType: Type, loc: SourceLocation, ctx: TransformContext): Node {
	const okAccess = makeResultMember(tempName, resType, "ok", loc);
	const notOk = makeUnary("!", okAccess, loc);
	notOk.nodeType = booleanType();

	const errorAccess = makeResultMember(tempName, resType, "error", loc);

	// Result.err($result.error) — with resolvedSym for downstream builtinLower
	const errSym = lookupResultErr(ctx);
	let resultErr: Node = null as unknown as Node;
	if (errSym !== null) {
		const callee = makeIdent("err", loc);
		callee.resolvedSym = errSym;
		callee.nodeType = errSym.symbolType;
		resultErr = makeCallResolved(callee, [errorAccess], errSym, loc);
	} else {
		// Fallback: no checker context (test mode) — use unresolved call
		resultErr = makeCall(
			makeMember(makeIdent("Result", loc), "err", loc),
			[errorAccess],
			loc
		);
	}
	resultErr.nodeType = resType;

	const returnStmt = makeReturn(resultErr, loc);
	const thenBlock = makeBlock([returnStmt], loc);
	const emptyBlock = makeBlock([], loc);
	return makeIf(notOk, thenBlock, emptyBlock, loc);
}

// ===== Tests =====
import {
	ProgramData, IfStmtData, BlockStmtData, ReturnStmtData as RetData,
	CallExprData as CData, MemberExprData as MData,
} from "../../ast/node";
import { parseInput, makeCtx, getStmts } from "../testUtil";
import { TypeKind as TK, createResult, numberType, stringType } from "../../checker/types";

// --- Structural tests (pipeline output shape) ---

test "var decl try expands to 3 stmts" { check(stmtCountAfter("const x = try f;", lowerTryExpr) === 3); }

test "var decl try first is VariableDecl" { check(firstStmtKindAfter("const x = try f;", lowerTryExpr) === NodeKind.VariableDecl); }

test "try catch expands to 2 stmts" { check(stmtCountAfter("const x = try f catch \"default\";", lowerTryExpr) === 2); }

test "no try passthrough" { check(stmtCountAfter("const x = 1;", lowerTryExpr) === 1); }

test "multiple stmts preserved" { check(stmtCountAfter("let a = 1; const x = try f; let b = 2;", lowerTryExpr) === 5); }

// --- Direct helper tests (bypass pipeline, verify resolvedSym/nodeType) ---

test "makeResultMember sets resolvedSym for .ok" {
	const resType = createResult(numberType(), stringType());
	const loc: SourceLocation = { line: 0, column: 0 };
	const mem = makeResultMember("$r", resType, "ok", loc);
	check(mem.kind === NodeKind.MemberExpr);
	check(mem.resolvedSym !== null);
	check(mem.nodeType !== null);
}

test "makeResultMember sets correct type for .value" {
	const resType = createResult(numberType(), stringType());
	const loc: SourceLocation = { line: 0, column: 0 };
	const mem = makeResultMember("$r", resType, "value", loc);
	check(mem.nodeType !== null);
	check(mem.nodeType.kind === TK.Number);
	check(mem.resolvedSym !== null);
}

test "makeResultMember sets correct type for .error" {
	const resType = createResult(numberType(), stringType());
	const loc: SourceLocation = { line: 0, column: 0 };
	const mem = makeResultMember("$r", resType, "error", loc);
	check(mem.nodeType !== null);
	check(mem.nodeType.kind === TK.String);
	check(mem.resolvedSym !== null);
}

test "makeResultMember with null resType is graceful" {
	const loc: SourceLocation = { line: 0, column: 0 };
	const mem = makeResultMember("$r", null as unknown as Type, "ok", loc);
	check(mem.kind === NodeKind.MemberExpr);
}

test "makeErrorCheck produces IfStmt with return" {
	const resType = createResult(numberType(), stringType());
	const loc: SourceLocation = { line: 0, column: 0 };
	const ifNode = makeErrorCheck("$r", resType, loc, makeCtx());
	check(ifNode.kind === NodeKind.IfStmt);
	const ifData = ifNode.data as IfStmtData;
	check(ifData.condition.kind === NodeKind.UnaryExpr);
	const thenBlock = ifData.consequent.data as BlockStmtData;
	check(thenBlock.statements.length === 1);
	check(thenBlock.statements[0].kind === NodeKind.ReturnStmt);
}

test "makeErrorCheck Result.err call has nodeType" {
	const resType = createResult(numberType(), stringType());
	const loc: SourceLocation = { line: 0, column: 0 };
	const ifNode = makeErrorCheck("$r", resType, loc, makeCtx());
	const ifData = ifNode.data as IfStmtData;
	const thenBlock = ifData.consequent.data as BlockStmtData;
	const retData = thenBlock.statements[0].data as RetData;
	check(retData.argument.nodeType !== null);
	check(retData.argument.nodeType.kind === TK.Result);
}
