// Tail Call Lowering — transforms tail-recursive functions into while loops
//
// function factorial(n, acc) {
//     if (n <= 1) return acc;
//     return factorial(n - 1, n * acc);
// }
// →
// function factorial(n, acc) {
//     while (true) {
//         if (n <= 1) return acc;
//         const $tc_0 = n - 1;
//         const $tc_1 = n * acc;
//         n = $tc_0;
//         acc = $tc_1;
//         continue;
//     }
// }

import {
	Node, NodeKind, DeclKind,
	FunctionDeclData, ReturnStmtData, CallExprData,
	IdentifierData, BlockStmtData, IfStmtData,
} from "../../ast/node";
import { TransformContext, freshTemp } from "../context";
import { walkNode } from "../walker";
import {
	makeBool, makeBlock, makeWhile, makeVarDecl,
	makeIdent, makeAssign, makeExprStmt, makeContinue,
	extractBodyStmts,
} from "../util";
import { test, check, testGroup } from "std/testing";
import { firstStmtKindAfter, stmtCountAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerTailCall(program: Node, ctx: TransformContext): Node {
	walkNode(program, tailCallVisitor(ctx));
	return program;
}

function tailCallVisitor(ctx: TransformContext): (node: Node) => Node {
	return (node: Node): Node => {
		if (node.kind !== NodeKind.FunctionDecl) return node;
		const d = node.data as FunctionDeclData;
		if (d.fnName === "") return node;

		// Check if body contains any tail calls to this function
		if (!hasTailCall(d.fnBody, d.fnName)) return node;

		// Transform: wrap body in while(true), replace tail calls with reassign+continue
		const loc = node.location;
		const bodyStmts = extractBodyStmts(d.fnBody);
		const newStmts: Node[] = [];

		for (let i = 0; i < bodyStmts.length; i += 1) {
			newStmts.push(transformStmt(bodyStmts[i], d.fnName, d.params, ctx));
		}

		const whileBody = makeBlock(newStmts, loc);
		const whileNode = makeWhile(makeBool(true, loc), whileBody, loc);
		d.fnBody = makeBlock([whileNode], loc);

		return node;
	};
}

// Check if a function body contains any tail calls (return f(args) where f === name)
function hasTailCall(body: Node, fnName: string): boolean {
	return match (body.kind) {
		NodeKind.BlockStmt => {
			const bd = body.data as BlockStmtData;
			let i = 0;
			while (i < bd.statements.length) {
				if (hasTailCall(bd.statements[i], fnName)) return true;
				i += 1;
			}
			false
		},
		NodeKind.ReturnStmt => {
			const rd = body.data as ReturnStmtData;
			isTailCallExpr(rd.argument, fnName)
		},
		NodeKind.IfStmt => {
			const id = body.data as IfStmtData;
			if (hasTailCall(id.consequent, fnName)) return true;
			if (id.alternate !== null) return hasTailCall(id.alternate, fnName);
			false
		},
		_ => false,
	};
}

// Check if an expression is a call to fnName
function isTailCallExpr(expr: Node, fnName: string): boolean {
	if (expr.kind !== NodeKind.CallExpr) return false;
	const cd = expr.data as CallExprData;
	if (cd.callee.kind !== NodeKind.Identifier) return false;
	const id = cd.callee.data as IdentifierData;
	return id.name === fnName;
}

// Transform a statement: replace tail-call returns with reassign+continue
function transformStmt(stmt: Node, fnName: string, params: string[], ctx: TransformContext): Node {
	return match (stmt.kind) {
		NodeKind.ReturnStmt => {
			const rd = stmt.data as ReturnStmtData;
			if (isTailCallExpr(rd.argument, fnName)) {
				return buildTailCallReplacement(rd.argument, params, stmt.location, ctx);
			}
			stmt
		},
		NodeKind.IfStmt => {
			const id = stmt.data as IfStmtData;
			id.consequent = transformBody(id.consequent, fnName, params, ctx);
			if (id.alternate !== null) {
				id.alternate = transformBody(id.alternate, fnName, params, ctx);
			}
			stmt
		},
		_ => stmt,
	};
}

// Transform a block body (recurse into statements)
function transformBody(body: Node, fnName: string, params: string[], ctx: TransformContext): Node {
	return match (body.kind) {
		NodeKind.BlockStmt => {
			const bd = body.data as BlockStmtData;
			let i = 0;
			while (i < bd.statements.length) {
				bd.statements[i] = transformStmt(bd.statements[i], fnName, params, ctx);
				i += 1;
			}
			body
		},
		_ => transformStmt(body, fnName, params, ctx),
	};
}

// Build replacement for tail call: temp vars for args, reassign params, continue
function buildTailCallReplacement(callExpr: Node, params: string[], loc: Node["location"], ctx: TransformContext): Node {
	const cd = callExpr.data as CallExprData;
	const stmts: Node[] = [];

	// 1. Evaluate all arguments into temps (avoid order-of-evaluation issues)
	const tempNames: string[] = [];
	for (let i = 0; i < cd.arguments.length && i < params.length; i += 1) {
		const tempName = freshTemp(ctx, "tc");
		tempNames.push(tempName);
		stmts.push(makeVarDecl(tempName, cd.arguments[i], DeclKind.Const, loc));
	}

	// 2. Reassign params from temps
	for (let j = 0; j < tempNames.length; j += 1) {
		const assignExpr = makeAssign(makeIdent(params[j], loc), makeIdent(tempNames[j], loc), loc);
		stmts.push(makeExprStmt(assignExpr, loc));
	}

	// 3. Continue (back to top of while loop)
	stmts.push(makeContinue(loc));

	return makeBlock(stmts, loc);
}

// ===== Tests =====

testGroup("Tail Call Lowering", () => {
	test("non-recursive unchanged", () => {
		check(firstStmtKindAfter("function foo(x: number): number { return x + 1; }", lowerTailCall) === NodeKind.FunctionDecl);
	});
	test("simple passthrough", () => {
		check(stmtCountAfter("const x = 1;", lowerTailCall) === 1);
	});
	test("while unchanged", () => {
		check(firstStmtKindAfter("while (true) {}", lowerTailCall) === NodeKind.WhileStmt);
	});
	test("if stmt unchanged", () => {
		check(firstStmtKindAfter("if (x) {}", lowerTailCall) === NodeKind.IfStmt);
	});
	test("non-function passthrough", () => {
		check(stmtCountAfter("let a = 1; let b = 2;", lowerTailCall) === 2);
	});
	test("arrow function unchanged", () => {
		check(firstStmtKindAfter("const f = (x: number): number => x + 1;", lowerTailCall) === NodeKind.VariableDecl);
	});
});
