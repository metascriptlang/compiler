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
	ProgramData, FunctionDeclData, BlockStmtData,
	CallExprData, MemberExprData, IdentifierData,
	ExprStmtData, VariableDeclData, ReturnStmtData,
	IfStmtData, WhileStmtData, DoWhileStmtData,
	TryCatchStmtData, ExportDeclData,
	SourceLocation,
} from "../../ast/node";
import { TransformContext } from "../context";
import { lookupSymbol } from "../../checker/symbol";
import { makeIdent, makeCall } from "../util";
import { test, check, testGroup } from "std/testing";
import { stmtCountAfter, firstStmtKindAfter, firstExprKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerBuiltins(program: Node, ctx: TransformContext): Node {
	return walkLowerBuiltins(program, ctx);
}

// ===== Recursive Walker =====
// Rewrites CallExpr nodes where the callee resolves to a @runtime/@builtin symbol.

function walkLowerBuiltins(node: Node, ctx: TransformContext): Node {
	if (node === null) return node;

	return match (node.kind) {
		NodeKind.CallExpr => {
			lowerCallExpr(node, ctx);
		},
		NodeKind.Program => {
			walkProgram(node, ctx);
		},
		NodeKind.BlockStmt => {
			walkBlock(node, ctx);
		},
		NodeKind.FunctionDecl => {
			walkFunctionDecl(node, ctx);
		},
		NodeKind.IfStmt => {
			walkIf(node, ctx);
		},
		NodeKind.WhileStmt => {
			walkWhile(node, ctx);
		},
		NodeKind.DoWhileStmt => {
			walkDoWhile(node, ctx);
		},
		NodeKind.ExprStmt => {
			walkExprStmt(node, ctx);
		},
		NodeKind.VariableDecl => {
			walkVarDecl(node, ctx);
		},
		NodeKind.ReturnStmt => {
			walkReturn(node, ctx);
		},
		NodeKind.ExportDecl => {
			walkExport(node, ctx);
		},
		NodeKind.TryCatchStmt => {
			walkTryCatch(node, ctx);
		},
		_ => node,
	};
}

// ===== Call Expression Lowering =====

function lowerCallExpr(node: Node, ctx: TransformContext): Node {
	const cd = node.data as CallExprData;
	const loc = node.location;

	// Walk arguments recursively first
	for (let i = 0; i < cd.arguments.length; i += 1) {
		cd.arguments[i] = walkLowerBuiltins(cd.arguments[i], ctx);
	}

	// Walk callee recursively (handles nested calls like f(g(x)))
	cd.callee = walkLowerBuiltins(cd.callee, ctx);

	// Check if callee is an identifier that resolves to a @builtin symbol
	// @runtime is handled by genCallExpr in codegen (& prefix, array type suffix)
	if (cd.callee.kind === NodeKind.Identifier && ctx.checkerCtx !== null) {
		const id = cd.callee.data as IdentifierData;
		const sym = lookupSymbol(ctx.checkerCtx.table, id.name);
		if (sym !== null) {
			// @builtin("Name") → inline expansion
			if (sym.builtinKind !== "") {
				return lowerBuiltinCall(node, sym.builtinKind, ctx);
			}
		}
	}

	// Class method calls (console.log, Math.floor): handled at codegen time
	// (expressions.ms genCallExpr) to avoid DRC string corruption.

	// Instance extension fallback: obj.method(args) → method(obj, args)
	// Moves receiver to first arg, keeps MS function name for genCallExpr symbol lookup.
	// genCallExpr reads sym.runtimeName for C name, & prefix, and array suffix.
	if (cd.callee.kind === NodeKind.MemberExpr && ctx.checkerCtx !== null) {
		const me = cd.callee.data as MemberExprData;
		const sym = lookupSymbol(ctx.checkerCtx.table, me.property);
		if (sym !== null && sym.runtimeName !== "") {
			const objExpr = walkLowerBuiltins(me.object, ctx);
			const newArgs: Node[] = [];
			newArgs.push(objExpr);
			for (let j = 0; j < cd.arguments.length; j += 1) {
				newArgs.push(cd.arguments[j]);
			}
			return makeCall(makeIdent(me.property, loc), newArgs, loc);
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
		return makeCall(makeIdent("ms_string_length", loc), cd.arguments, loc);
	}
	return node;
}

// ===== Statement/Declaration Walkers =====

function walkProgram(node: Node, ctx: TransformContext): Node {
	const pd = node.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		pd.programStmts[i] = walkLowerBuiltins(pd.programStmts[i], ctx);
	}
	return node;
}

function walkBlock(node: Node, ctx: TransformContext): Node {
	const bd = node.data as BlockStmtData;
	for (let i = 0; i < bd.statements.length; i += 1) {
		bd.statements[i] = walkLowerBuiltins(bd.statements[i], ctx);
	}
	return node;
}

function walkFunctionDecl(node: Node, ctx: TransformContext): Node {
	const d = node.data as FunctionDeclData;
	if (d.fnBody !== null) {
		d.fnBody = walkLowerBuiltins(d.fnBody, ctx);
	}
	return node;
}

function walkIf(node: Node, ctx: TransformContext): Node {
	const d = node.data as IfStmtData;
	d.condition = walkLowerBuiltins(d.condition, ctx);
	d.consequent = walkLowerBuiltins(d.consequent, ctx);
	if (d.alternate !== null) {
		d.alternate = walkLowerBuiltins(d.alternate, ctx);
	}
	return node;
}

function walkWhile(node: Node, ctx: TransformContext): Node {
	const d = node.data as WhileStmtData;
	d.whileCondition = walkLowerBuiltins(d.whileCondition, ctx);
	d.whileBody = walkLowerBuiltins(d.whileBody, ctx);
	return node;
}

function walkDoWhile(node: Node, ctx: TransformContext): Node {
	const d = node.data as DoWhileStmtData;
	d.doBody = walkLowerBuiltins(d.doBody, ctx);
	d.doCondition = walkLowerBuiltins(d.doCondition, ctx);
	return node;
}

function walkExprStmt(node: Node, ctx: TransformContext): Node {
	const d = node.data as ExprStmtData;
	d.expr = walkLowerBuiltins(d.expr, ctx);
	return node;
}

function walkVarDecl(node: Node, ctx: TransformContext): Node {
	const d = node.data as VariableDeclData;
	if (d.initializer !== null) {
		d.initializer = walkLowerBuiltins(d.initializer, ctx);
	}
	return node;
}

function walkReturn(node: Node, ctx: TransformContext): Node {
	const d = node.data as ReturnStmtData;
	if (d.argument !== null) {
		d.argument = walkLowerBuiltins(d.argument, ctx);
	}
	return node;
}

function walkExport(node: Node, ctx: TransformContext): Node {
	const d = node.data as ExportDeclData;
	d.exportedDecl = walkLowerBuiltins(d.exportedDecl, ctx);
	return node;
}

function walkTryCatch(node: Node, ctx: TransformContext): Node {
	const d = node.data as TryCatchStmtData;
	d.tryBody = walkLowerBuiltins(d.tryBody, ctx);
	if (d.catchBody !== null) {
		d.catchBody = walkLowerBuiltins(d.catchBody, ctx);
	}
	if (d.finallyBody !== null) {
		d.finallyBody = walkLowerBuiltins(d.finallyBody, ctx);
	}
	return node;
}

// ===== Tests =====

import { runThreePasses } from "../../checker/checkPass";
import { createContext } from "../../checker/context";
import { openScope, ScopeKind } from "../../checker/symbol";
import { createTransformContextWithChecker } from "../context";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";

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

testGroup("Builtin Lower", () => {
	test("passthrough non-call", () => {
		check(stmtCountAfter("const x = 1;", lowerBuiltins) === 1);
	});
	test("passthrough plain call", () => {
		check(firstExprKindAfter("foo();", lowerBuiltins) === NodeKind.CallExpr);
	});
	test("passthrough function decl", () => {
		check(firstStmtKindAfter("function foo() {}", lowerBuiltins) === NodeKind.FunctionDecl);
	});
	test("passthrough if stmt", () => {
		check(firstStmtKindAfter("if (x) {}", lowerBuiltins) === NodeKind.IfStmt);
	});
	test("prelude class method stays as MemberExpr (codegen handles)", () => {
		const prelude = "class console { @runtime(\"ms_println\") log(value: string): void { unreachable; } }";
		const result = preludeLowerCallee(prelude, "console.log(\"hello\");");
		// Class method calls are NOT rewritten by builtinLower — codegen handles them
		// directly to avoid DRC string corruption. Result is STILL_MEMBER (MemberExpr callee).
		check(result === "STILL_MEMBER");
	});
	test("@runtime identifier callee left for codegen", () => {
		const prelude = "@runtime(\"ms_parse_int\") function parseInt(s: string): number { unreachable; }";
		const result = preludeLowerCallee(prelude, "parseInt(\"42\");");
		// @runtime on identifier callee is NOT rewritten — genCallExpr handles it
		check(result === "parseInt");
	});
});
