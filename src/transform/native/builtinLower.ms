// Builtin Lowering — rewrite @builtin calls + MemberExpr→direct call for extensions
//
// Runs post-analyzer, pre-codegen. Reads decorator metadata from Symbol
// (runtimeName, builtinKind set by collectPass).
//
// @runtime("c_name") → left for genCallExpr in codegen (handles &prefix, array suffix)
// @builtin("Name")   → inline expansion for known builtins
// MemberExpr callee  → Identifier callee (move receiver to first arg)
//
// This is an AST-to-AST transform — codegen sees only plain calls.

import {
	Node, NodeKind,
	CallExprData, MemberExprData, IdentifierData,
} from "../../ast/node";
import { TypeKind } from "../../checker/types";
import { TransformContext } from "../context";
import { lookupSymbol } from "../../checker/symbol";
import { walkNode } from "../walker";
import {
	makeIdent, makeCall, makeIdentResolved, makeCallResolved,
	makeObjectLiteral, makeBool,
} from "../util";
import { check } from "std/testing";
import { stmtCountAfter, firstStmtKindAfter, firstExprKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerBuiltins(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		if (node.kind === NodeKind.CallExpr) {
			return lowerCallExpr(node, ctx);
		}
		return node;
	});
}

// ===== Call Expression Lowering =====

function lowerCallExpr(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;

	// Check for @builtin or @runtime resolution via pre-resolved symbol
	const sym = node.resolvedSym;
	if (sym !== null) {
		// @builtin("Name") → inline expansion
		if (sym.builtinKind !== "") {
			return lowerBuiltinCall(node, sym.builtinKind, ctx);
		}
	}

	// Resolve class method calls (console.log, Math.floor) definitively.
	// These reach here as MemberExpr callees with a resolvedSym pointing to the method.
	if (cd.callee.kind === NodeKind.MemberExpr && cd.callee.resolvedSym !== null) {
		const methodSym = cd.callee.resolvedSym;
		if (methodSym.runtimeName !== "") {
			// Found a @runtime method (like console.log → msPrintln)
			// Rewrite to a direct call: msPrintln(s)
			const newCallee = makeIdentResolved(methodSym, loc);
			cd.callee = newCallee;
			node.resolvedSym = methodSym;
			cd.isDirectCall = true;
			return node;
		}
	}

	// Instance extension fallback: obj.method(args) → method(obj, args)
	if (cd.callee.kind === NodeKind.MemberExpr && ctx.checkerCtx !== null) {
		const me = cd.callee.data as MemberExprData;
		const sym = lookupSymbol(ctx.checkerCtx.table, me.property);
		if (sym !== null && sym.runtimeName !== "") {
			const newArgs: Node[] = [];
			newArgs.push(me.object);
			for (let j = 0; j < cd.arguments.length; j += 1) {
				newArgs.push(cd.arguments[j]);
			}
			const newCall = makeCallResolved(makeIdentResolved(sym, loc), newArgs, sym, loc);
			newCall.nodeType = node.nodeType;
			return newCall;
		}
	}

	return node;
}

// ===== Builtin Inline Expansion =====
// Handles @builtin("Name") — known compiler builtins get inline C patterns.

function lowerBuiltinCall(node: Node, builtinKind: string, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;

	if (builtinKind === "LengthStr" && cd.arguments.length === 1) {
		return makeCall(makeIdent("msStringLength", loc), cd.arguments, loc);
	}

	if (builtinKind === "msResultOk") {
		return rewriteResultToLiteral(node, true, ctx);
	}
	if (builtinKind === "msResultErr") {
		return rewriteResultToLiteral(node, false, ctx);
	}

	return node;
}

function rewriteResultToLiteral(node: Node, isOk: boolean, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;
	const resType = node.nodeType;
	if (resType === null || resType.kind !== TypeKind.Result) {
		console.log("Result lowering: missing or non-Result nodeType at line " + loc.line);
		return node;
	}

	const keys: string[] = ["ok"];
	const values: Node[] = [makeBool(isOk, loc)];

	if (isOk) {
		// Only add value if T is not void
		if (resType.typeReturn.kind !== TypeKind.Void) {
			keys.push("value");
			values.push(cd.arguments[0]);
		}
	} else {
		// Only add error if E is not void
		if (resType.typeExtra.kind !== TypeKind.Void) {
			keys.push("error");
			values.push(cd.arguments[0]);
		}
	}

	const literal = makeObjectLiteral(keys, values, loc);
	// V4: CRITICAL — preserve the monomorphized Result type from the call node
	literal.nodeType = resType;
	return literal;
}

// ===== Tests =====

import { runThreePasses } from "../../checker/checkPass";
import { createContext } from "../../checker/context";
import { openScope, ScopeKind } from "../../checker/symbol";
import { createTransformContextWithChecker } from "../context";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { ProgramData, ExprStmtData } from "../../ast/node";

// Simulate the full prelude → check → builtinLower pipeline.
// Returns the callee name of the first CallExpr in user code after lowering.
function preludeLowerCallee(preludeSrc: string, userSrc: string): string {
	// 1. Create checker context, parse+check prelude in Global scope
	const ctx = createContext();
	const ppr = parseSource(preludeSrc);
	if (!ppr.ok) return "PRELUDE_PARSE_ERR";
	runThreePasses(ctx, ppr.value);

	// 2. Open Module scope, parse+check user code
	openScope(ctx.table, ScopeKind.Module);
	const upr = parseSource(userSrc);
	if (!upr.ok) return "USER_PARSE_ERR";
	runThreePasses(ctx, upr.value);

	// 3. Run builtinLower on user AST with checker context
	const tctx = createTransformContextWithChecker(ctx);
	const lowered = lowerBuiltins(upr.value, tctx);

	// 4. Extract callee name from first ExprStmt's CallExpr
	const pd = lowered.data as ProgramData;
	if (pd.programStmts.length === 0) return "NO_STMTS";
	const stmt = pd.programStmts[0];
	if (stmt.kind !== NodeKind.ExprStmt) return "NOT_EXPR";
	const es = stmt.data as ExprStmtData;
	if (es.expr.kind !== NodeKind.CallExpr) return "NOT_CALL";
	const cd = es.expr.data as CallExprData;
	if (cd.callee.kind === NodeKind.Identifier) {
		const id = cd.callee.data as IdentifierData;
		return id.name;
	}
	if (cd.callee.kind === NodeKind.MemberExpr) return "STILL_MEMBER";
	return "OTHER_KIND";
}

test "passthrough non-call" { check(stmtCountAfter("const x = 1;", lowerBuiltins) === 1); }

test "passthrough plain call" { check(firstExprKindAfter("foo();", lowerBuiltins) === NodeKind.CallExpr); }

test "passthrough function decl" { check(firstStmtKindAfter("function foo() {}", lowerBuiltins) === NodeKind.FunctionDecl); }

test "passthrough if stmt" { check(firstStmtKindAfter("if (x) {}", lowerBuiltins) === NodeKind.IfStmt); }

test "prelude class method is rewritten to runtime call" {
	const prelude = "class console { @runtime(\"msPrintln\") log(value: string): void { unreachable; } }";
	const result = preludeLowerCallee(prelude, "console.log(\"hello\");");
	// Class method calls ARE now rewritten by builtinLower definitively.
	check(result === "msPrintln");
}

test "@runtime identifier callee left for codegen" {
	const prelude = "@runtime(\"msStringParseInt\") function parseInt(s: string): number { unreachable; }";
	const result = preludeLowerCallee(prelude, "parseInt(\"42\");");
	// @runtime on identifier callee is NOT rewritten — genCallExpr handles it
	check(result === "parseInt");
}
