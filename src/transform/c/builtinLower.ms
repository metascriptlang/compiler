// Builtin Lowering — rewrite @runtime/@builtin calls to C-compatible AST
//
// Runs post-analyzer, pre-codegen. Reads decorator metadata from Symbol
// (runtimeName, builtinKind set by collectPass).
//
// @runtime("c_name") → rewrite callee identifier to C function name
// @builtin("Name")   → inline expansion for known builtins
//
// This is an AST-to-AST transform — codegen sees only plain calls.

import {
	Node, NodeKind,
	ProgramData, FunctionDeclData, BlockStmtData,
	CallExprData, MemberExprData, IdentifierData,
	ExprStmtData, VariableDeclData, ReturnStmtData,
	BinaryExprData, UnaryExprData,
	IfStmtData, WhileStmtData, DoWhileStmtData,
	ForOfStmtData, TryCatchStmtData,
	ExportDeclData, DecoratedDeclData,
	ClassDeclData, MethodDeclData, ConstructorDeclData,
	ArrayLiteralData, ObjectLiteralData,
	ConditionalExprData, ArrayAccessData,
	MatchStmtData, MatchCaseData,
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
	let i = 0;
	while (i < cd.arguments.length) {
		cd.arguments[i] = walkLowerBuiltins(cd.arguments[i], ctx);
		i += 1;
	}

	// Walk callee recursively (handles nested calls like f(g(x)))
	cd.callee = walkLowerBuiltins(cd.callee, ctx);

	// Check if callee is an identifier that resolves to a @runtime symbol
	if (cd.callee.kind === NodeKind.Identifier && ctx.checkerCtx !== null) {
		const id = cd.callee.data as IdentifierData;
		const sym = lookupSymbol(ctx.checkerCtx.table, id.name);
		if (sym !== null) {
			// @runtime("c_name") → replace callee with C function name
			if (sym.runtimeName !== "") {
				cd.callee = makeIdent(sym.runtimeName, loc);
				return node;
			}
			// @builtin("Name") → inline expansion
			if (sym.builtinKind !== "") {
				return lowerBuiltinCall(node, sym.builtinKind, ctx);
			}
		}
	}

	// Check for method calls: obj.method(args) where method is @runtime
	if (cd.callee.kind === NodeKind.MemberExpr && ctx.checkerCtx !== null) {
		const me = cd.callee.data as MemberExprData;
		const sym = lookupSymbol(ctx.checkerCtx.table, me.property);
		if (sym !== null && sym.runtimeName !== "") {
			// Rewrite obj.method(args) → c_name(obj, args)
			const newArgs: Node[] = [];
			// Walk the object expression
			const objExpr = walkLowerBuiltins(me.object, ctx);
			newArgs.push(objExpr);
			let j = 0;
			while (j < cd.arguments.length) {
				newArgs.push(cd.arguments[j]);
				j += 1;
			}
			return makeCall(makeIdent(sym.runtimeName, loc), newArgs, loc);
		}
	}

	return node;
}

// ===== Builtin Inline Expansion =====
// Handles @builtin("Name") — known compiler builtins get inline C patterns.

function lowerBuiltinCall(node: Node, builtinKind: string, ctx: TransformContext): Node {
	// For now, pass through — individual builtins added as std/core.ms defines them.
	// Each builtin kind would get a match arm here:
	//   "LengthStr" → rewrite to ms_string_length(arg)
	//   "LengthArr" → rewrite to ms_array_length(arg)
	//   "Print"     → rewrite to ms_print(args...)
	//   etc.
	return node;
}

// ===== Statement/Declaration Walkers =====

function walkProgram(node: Node, ctx: TransformContext): Node {
	const pd = node.data as ProgramData;
	let i = 0;
	while (i < pd.programStmts.length) {
		pd.programStmts[i] = walkLowerBuiltins(pd.programStmts[i], ctx);
		i += 1;
	}
	return node;
}

function walkBlock(node: Node, ctx: TransformContext): Node {
	const bd = node.data as BlockStmtData;
	let i = 0;
	while (i < bd.statements.length) {
		bd.statements[i] = walkLowerBuiltins(bd.statements[i], ctx);
		i += 1;
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
});
