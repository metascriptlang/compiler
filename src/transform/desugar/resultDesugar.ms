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
	CallExprData, MemberExprData, IdentifierData, HiddenDerefData,
	IfStmtData,
} from "../../ast/node";
import { Type, TypeKind, booleanType, getProperty } from "../../checker/types";
import { makeSymbol, lookupSymbol } from "../../checker/symbol";
import { TransformContext, freshTemp } from "../context";
import { walkNode, walkExpandBlocksHooked, containsExprKind, replaceInExpr } from "../walker";
import {
	makeIdent, makeVarDecl, makeBlock, makeExprStmt,
	makeReturn, makeIf, makeMember, makeCall, makeCallResolved, makeConditional,
	makeUnary, makeObjectLiteral, makeBool,
} from "../util";
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

// ===== Enclosing Function Return Type Tracking =====
// try error-path returns must be typed as the enclosing function's Result type,
// not the inner expression's Result type (e.g. Result<void, string> vs Result<Person, string>).
// Uses walkExpandBlocksHooked's FnEntry/FnExit callbacks to save/restore on function boundaries.

let enclosingFnRetType: Type = null;
let fnRetTypeStack: Type[] = [];

function onFnEntry(node: Node): void {
	fnRetTypeStack.push(enclosingFnRetType);
	enclosingFnRetType = node.nodeType !== null ? node.nodeType.typeReturn : null;
}

function onFnExit(node: Node): void {
	enclosingFnRetType = fnRetTypeStack.length > 0 ? fnRetTypeStack.pop() : null;
}

// ===== Main Entry Point =====

export function lowerTryExpr(program: Node, ctx: TransformContext): Node {
	enclosingFnRetType = null;
	fnRetTypeStack = [];
	walkExpandBlocksHooked(program, expandStmt, ctx, onFnEntry, onFnExit);
	lowerResultConstructors(program);
	return program;
}

// Lower Result.ok(val) / Result.err(e) → ObjectLiteral. Runs for all backends.
export function lowerResultConstructors(program: Node): Node {
	walkNode(program, rewriteResultCall);
	return program;
}

// ===== Result.ok / Result.err → ObjectLiteral =====
// Rewrites CallExpr where callee is MemberExpr(Identifier("Result"), "ok"|"err")
// Result.ok(val) → { ok: true, value: val }
// Result.err(e)  → { ok: false, error: e }
// Result.ok()    → { ok: true }              (void value case)

function rewriteResultCall(node: Node): Node {
	if (node.kind !== NodeKind.CallExpr) return node;
	const cd = node.data as CallExprData;
	if (cd.callee.kind !== NodeKind.MemberExpr) return node;
	const md = cd.callee.data as MemberExprData;
	// Checker wraps class refs in HiddenDeref — unwrap to find Identifier
	let callerObj = md.object;
	if (callerObj.kind === NodeKind.HiddenDeref) {
		callerObj = (callerObj.data as HiddenDerefData).expr;
	}
	if (callerObj.kind !== NodeKind.Identifier) return node;
	const id = callerObj.data as IdentifierData;
	if (id.name !== "Result") return node;

	const loc = node.location;
	const prop = md.property;

	if (prop === "ok") {
		return makeResultOk(cd.arguments, node.nodeType, loc);
	}
	if (prop === "err" && cd.arguments.length === 1) {
		return makeResultErr(cd.arguments[0], node.nodeType, loc);
	}
	return node;
}

// Shared helpers for Result construction — used by both rewriteResultCall and makeErrorCheck.

function makeResultOk(args: Node[], resType: Type, loc: SourceLocation): Node {
	if (args.length === 1) {
		// Propagate T from Result<T, E> onto the value arg if untyped or weakly typed
		// (e.g. ObjectLiteral { node: ..., pos: ... } for ParseResult)
		if (resType !== null && resType.typeReturn !== null && resType.typeReturn.kind === TypeKind.Struct) {
			if (args[0].nodeType === null || args[0].nodeType.kind === TypeKind.Unknown || args[0].nodeType.kind === TypeKind.GenericParam) {
				args[0].nodeType = resType.typeReturn;
			}
		}
		const lit = makeObjectLiteral(["ok", "value"], [makeBool(true, loc), args[0]], loc);
		lit.nodeType = resType;
		return lit;
	}
	// Result.ok() — void value
	const lit = makeObjectLiteral(["ok"], [makeBool(true, loc)], loc);
	lit.nodeType = resType;
	return lit;
}

function makeResultErr(errExpr: Node, resType: Type, loc: SourceLocation): Node {
	const lit = makeObjectLiteral(["ok", "error"], [makeBool(false, loc), errExpr], loc);
	lit.nodeType = resType;
	return lit;
}

// ===== TryExpr Hoisting via shared walker =====
// Uses replaceInExpr from walker.ms — single expression tree walker shared with matchLower.

// Hoist all TryExpr from an expression tree into preceding statements.
function hoistTryExpr(expr: Node, hoisted: Node[], ctx: TransformContext): Node {
	return replaceInExpr(expr, (node: Node): Node => {
		if (node.kind !== NodeKind.TryExpr) return node;
		const tryData = node.data as TryExprData;
		const loc = node.location;
		const tempName = freshTemp(ctx, "result");
		const resType = tryData.tryArg.nodeType;

		// const $result_N = tryArg;
		const resDecl = makeVarDecl(tempName, tryData.tryArg, DeclKind.Const, loc);
		resDecl.nodeType = resType;
		hoisted.push(resDecl);

		if (tryData.hasCatch) {
			// $result.ok ? $result.value : catchVal
			const okCheck = makeResultMember(tempName, resType, "ok", loc);
			const valueAccess = makeResultMember(tempName, resType, "value", loc);
			// Stamp catchVal with value type so ternary branches have matching C types
			if (tryData.catchVal.nodeType === null && valueAccess.nodeType !== null) {
				tryData.catchVal.nodeType = valueAccess.nodeType;
			}
			const condExpr = makeConditional(okCheck, valueAccess, tryData.catchVal, loc);
			condExpr.nodeType = node.nodeType;
			return condExpr;
		}

		// if (!$result.ok) { return { ok: false, error: $result.error }; }
		hoisted.push(makeErrorCheck(tempName, resType, loc, ctx));

		// Replace TryExpr with $result.value
		return makeResultMember(tempName, resType, "value", loc);
	});
}

// Expand a single statement — unified through hoistTryExpr.
// Matches reference desugarStatement: all cases dispatch to desugarExpression.
function expandStmt(stmt: Node, ctx: TransformContext): Node[] {
	match (stmt.kind) {
		NodeKind.VariableDecl => {
			const d = stmt.data as VariableDeclData;
			if (d.initializer !== null && containsExprKind(d.initializer, NodeKind.TryExpr)) {
				const hoisted: Node[] = [];
				d.initializer = hoistTryExpr(d.initializer, hoisted, ctx);
				hoisted.push(stmt);
				return hoisted;
			}
		},
		NodeKind.ReturnStmt => {
			const d = stmt.data as ReturnStmtData;
			if (d.argument !== null && containsExprKind(d.argument, NodeKind.TryExpr)) {
				const hoisted: Node[] = [];
				d.argument = hoistTryExpr(d.argument, hoisted, ctx);
				hoisted.push(stmt);
				return hoisted;
			}
		},
		NodeKind.ExprStmt => {
			const d = stmt.data as ExprStmtData;
			if (containsExprKind(d.expr, NodeKind.TryExpr)) {
				const hoisted: Node[] = [];
				d.expr = hoistTryExpr(d.expr, hoisted, ctx);
				hoisted.push(stmt);
				return hoisted;
			}
		},
		NodeKind.IfStmt => {
			const d = stmt.data as IfStmtData;
			if (containsExprKind(d.condition, NodeKind.TryExpr)) {
				const hoisted: Node[] = [];
				d.condition = hoistTryExpr(d.condition, hoisted, ctx);
				hoisted.push(stmt);
				return hoisted;
			}
		},
		_ => {},
	};
	return [stmt];
}

// Build: if (!$result.ok) { return { ok: false, error: $result.error }; }
// Uses enclosingFnRetType for the return literal's type (not resType) so the error-path
// return matches the function's signature (e.g. Result<void, string>, not Result<Person, string>).
function makeErrorCheck(tempName: string, resType: Type, loc: SourceLocation, ctx: TransformContext): Node {
	const okAccess = makeResultMember(tempName, resType, "ok", loc);
	const notOk = makeUnary("!", okAccess, loc);
	notOk.nodeType = booleanType();

	const errorAccess = makeResultMember(tempName, resType, "error", loc);
	// Use enclosing function's return type for the error literal, falling back to resType
	const errRetType = (enclosingFnRetType !== null && enclosingFnRetType.kind === TypeKind.Result)
		? enclosingFnRetType : resType;
	const resultErr = makeResultErr(errorAccess, errRetType, loc);

	const returnStmt = makeReturn(resultErr, loc);
	const thenBlock = makeBlock([returnStmt], loc);
	const emptyBlock = makeBlock([], loc);
	return makeIf(notOk, thenBlock, emptyBlock, loc);
}

// ===== Tests =====
import {
	ReturnStmtData as RetData, BlockStmtData,
	CallExprData as CData, MemberExprData as MData,
} from "../../ast/node";
import { parseInput, makeCtx, getStmts } from "../testUtil";
import { TypeKind as TK, createResult, numberType, stringType } from "../../checker/types";

// --- Structural tests (pipeline output shape) ---

test "var decl try expands to 3 stmts" { assert stmtCountAfter("const x = try f;", lowerTryExpr) === 3; }

test "var decl try first is VariableDecl" { assert firstStmtKindAfter("const x = try f;", lowerTryExpr) === NodeKind.VariableDecl; }

test "try catch expands to 2 stmts" { assert stmtCountAfter("const x = try f catch \"default\";", lowerTryExpr) === 2; }

test "no try passthrough" { assert stmtCountAfter("const x = 1;", lowerTryExpr) === 1; }

test "multiple stmts preserved" { assert stmtCountAfter("let a = 1; const x = try f; let b = 2;", lowerTryExpr) === 5; }

// --- Direct helper tests (bypass pipeline, verify resolvedSym/nodeType) ---

test "makeResultMember sets resolvedSym for .ok" {
	const resType = createResult(numberType(), stringType());
	const loc: SourceLocation = { line: 0, column: 0 };
	const mem = makeResultMember("$r", resType, "ok", loc);
	assert mem.kind === NodeKind.MemberExpr;
	assert mem.resolvedSym !== null;
	assert mem.nodeType !== null;
}

test "makeResultMember sets correct type for .value" {
	const resType = createResult(numberType(), stringType());
	const loc: SourceLocation = { line: 0, column: 0 };
	const mem = makeResultMember("$r", resType, "value", loc);
	assert mem.nodeType !== null;
	assert mem.nodeType.kind === TK.Number;
	assert mem.resolvedSym !== null;
}

test "makeResultMember sets correct type for .error" {
	const resType = createResult(numberType(), stringType());
	const loc: SourceLocation = { line: 0, column: 0 };
	const mem = makeResultMember("$r", resType, "error", loc);
	assert mem.nodeType !== null;
	assert mem.nodeType.kind === TK.String;
	assert mem.resolvedSym !== null;
}

test "makeResultMember with null resType is graceful" {
	const loc: SourceLocation = { line: 0, column: 0 };
	const mem = makeResultMember("$r", null, "ok", loc);
	assert mem.kind === NodeKind.MemberExpr;
}

test "makeErrorCheck produces IfStmt with return" {
	const resType = createResult(numberType(), stringType());
	const loc: SourceLocation = { line: 0, column: 0 };
	const ifNode = makeErrorCheck("$r", resType, loc, makeCtx());
	assert ifNode.kind === NodeKind.IfStmt;
	const ifData = ifNode.data as IfStmtData;
	assert ifData.condition.kind === NodeKind.UnaryExpr;
	const thenBlock = ifData.consequent.data as BlockStmtData;
	assert thenBlock.statements.length === 1;
	assert thenBlock.statements[0].kind === NodeKind.ReturnStmt;
}

test "makeErrorCheck Result.err call has nodeType" {
	const resType = createResult(numberType(), stringType());
	const loc: SourceLocation = { line: 0, column: 0 };
	const ifNode = makeErrorCheck("$r", resType, loc, makeCtx());
	const ifData = ifNode.data as IfStmtData;
	const thenBlock = ifData.consequent.data as BlockStmtData;
	const retData = thenBlock.statements[0].data as RetData;
	assert retData.argument.nodeType !== null;
	assert retData.argument.nodeType.kind === TK.Result;
}
