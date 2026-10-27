// Update Expression Lowering — statement `x++` becomes `x += 1`.

import { Node, NodeKind, ExprStmtData, UpdateExprData, BinaryExprData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeExprStmt, makeBinary, makeNumber } from "../util";
import { makeCtx, firstStmtKindAfter, stmtCountAfter, firstExprKindAfter, parseInput, getStmts } from "../testUtil";

function lowerUpdateNode(node: Node): Node {
	if (node.kind != NodeKind.ExprStmt) return node;
	const d = node.data as ExprStmtData;
	if (d.expr.kind != NodeKind.UpdateExpr) return node;
	const ud = d.expr.data as UpdateExprData;
	const loc = node.location;
	if (ud.updateOp != "++" && ud.updateOp != "--") {
		throw new Error(`internal: update expression with operator '${ud.updateOp}'`);
	}
	const op = ud.updateOp == "++" ? "+=" : "-=";
	return makeExprStmt(makeBinary(ud.updateArg, op, makeNumber(1, loc), loc), loc);
}

export function lowerUpdateExpr(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerUpdateNode);
}

function innerExprKindAfterUpdate(input: string): NodeKind {
	const result = parseInput(input);
	if (!result.ok) return NodeKind.Program;
	const ctx = makeCtx();
	const prog = lowerUpdateExpr(result.value, ctx);
	const stmts = getStmts(prog);
	if (stmts.length == 0) return NodeKind.Program;
	if (stmts[0].kind != NodeKind.ExprStmt) return stmts[0].kind;
	const sd = stmts[0].data as ExprStmtData;
	return sd.expr.kind;
}

function updateOperatorAfter(input: string): string {
	const result = parseInput(input);
	if (!result.ok) return "";
	const prog = lowerUpdateExpr(result.value, makeCtx());
	const stmts = getStmts(prog);
	if (stmts.length == 0 || stmts[0].kind != NodeKind.ExprStmt) return "";
	const sd = stmts[0].data as ExprStmtData;
	if (sd.expr.kind != NodeKind.BinaryExpr) return "";
	return (sd.expr.data as BinaryExprData).operator;
}

test "x++ becomes assignment" { assert innerExprKindAfterUpdate("x++;") == NodeKind.BinaryExpr; }

test "--x becomes assignment" { assert innerExprKindAfterUpdate("--x;") == NodeKind.BinaryExpr; }

test "x-- becomes assignment" { assert innerExprKindAfterUpdate("x--;") == NodeKind.BinaryExpr; }

test "++x becomes assignment" { assert innerExprKindAfterUpdate("++x;") == NodeKind.BinaryExpr; }

test "non-update ExprStmt unchanged" { assert firstExprKindAfter("f();", lowerUpdateExpr) == NodeKind.CallExpr; }

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", lowerUpdateExpr) == NodeKind.WhileStmt; }

test "stmt count preserved" { assert stmtCountAfter("let a = 1; let b = 2;", lowerUpdateExpr) == 2; }

test "a[f()]++ updates its location in place" { assert updateOperatorAfter("a[f()]++;") == "+="; }

test "--g().v updates its location in place" { assert updateOperatorAfter("--g().v;") == "-="; }
