// Update Expression Lowering — rewrite x++/--x in statement position to assignment
//
// In statement position (ExprStmt), `x++;` is lowered to `x = x + 1;`
// and `--x;` is lowered to `x = x - 1;`.
//
// In expression position (e.g. `f(x++)`), update is preserved
// since C supports ++/-- natively.

import { Node, NodeKind, ExprStmtData, UpdateExprData } from "../../ast/node";
import { TransformContext, createTransformContext } from "../context";
import { walkNode } from "../walker";
import { makeExprStmt, makeAssign, makeBinary, makeNumber } from "../util";
import { firstStmtKindAfter, stmtCountAfter, firstExprKindAfter, parseInput, getStmts } from "../testUtil";

// ===== Visitor =====

function lowerUpdateNode(node: Node): Node {
	if (node.kind != NodeKind.ExprStmt) return node;
	const d = node.data as ExprStmtData;
	if (d.expr.kind != NodeKind.UpdateExpr) return node;
	const ud = d.expr.data as UpdateExprData;
	const loc = node.location;
	const delta = match (ud.updateOp) {
		"++" => "+",
		_ => "-",
	};
	// x++ or ++x in statement position → x = x + 1 (or x = x - 1)
	return makeExprStmt(
		makeAssign(ud.updateArg, makeBinary(ud.updateArg, delta, makeNumber(1, loc), loc), loc),
	loc);
}

// ===== Entry Point =====

export function lowerUpdateExpr(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerUpdateNode);
}

// ===== Test Helpers =====

function innerExprKindAfterUpdate(input: string): NodeKind {
	const result = parseInput(input);
	if (!result.ok) return NodeKind.Program;
	const ctx = createTransformContext();
	const prog = lowerUpdateExpr(result.value, ctx);
	const stmts = getStmts(prog);
	if (stmts.length == 0) return NodeKind.Program;
	if (stmts[0].kind != NodeKind.ExprStmt) return stmts[0].kind;
	const sd = stmts[0].data as ExprStmtData;
	return sd.expr.kind;
}

// ===== Tests =====
test "x++ becomes assignment" { assert innerExprKindAfterUpdate("x++;") == NodeKind.BinaryExpr; }

test "--x becomes assignment" { assert innerExprKindAfterUpdate("--x;") == NodeKind.BinaryExpr; }

test "x-- becomes assignment" { assert innerExprKindAfterUpdate("x--;") == NodeKind.BinaryExpr; }

test "++x becomes assignment" { assert innerExprKindAfterUpdate("++x;") == NodeKind.BinaryExpr; }

test "non-update ExprStmt unchanged" { assert firstExprKindAfter("f();", lowerUpdateExpr) == NodeKind.CallExpr; }

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", lowerUpdateExpr) == NodeKind.WhileStmt; }

test "stmt count preserved" { assert stmtCountAfter("let a = 1; let b = 2;", lowerUpdateExpr) == 2; }
