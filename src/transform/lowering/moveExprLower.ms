// Move Expression Lowering — rewrite `move x` to just `x`
//
// `move` is an ownership transfer hint. Phase 4 DRC analyzer already recognizes
// MoveExpr as a "fresh expression" (no incref) and injects ms_was_moved(&x)
// after the move site. By the time we reach C codegen, the move semantics are
// fully expressed via DRC-injected calls.
//
// This transform strips the MoveExpr wrapper so codegen sees a plain expression.
// Follows Nim's pattern: move is assignment + wasMoved hook (injected by liftdestructors).

import { Node, NodeKind, MoveExprData } from "../../ast/node";
import { TransformContext, createTransformContext } from "../context";
import { walkNode } from "../walker";
import { test, check, testGroup } from "std/testing";
import { firstExprKindAfter, stmtCountAfter, parseInput, getStmts } from "../testUtil";
import { ExprStmtData } from "../../ast/node";

// ===== Visitor =====

function lowerMoveNode(node: Node): Node {
	if (node.kind !== NodeKind.MoveExpr) return node;
	const d = node.data as MoveExprData;
	// Unwrap: `move x` → `x`
	return d.moveArg;
}

// ===== Entry Point =====

export function lowerMoveExpr(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerMoveNode);
}

// ===== Tests =====

testGroup("Move Expr Lowering", () => {
	test("move x becomes Identifier", () => {
		check(firstExprKindAfter("move x;", lowerMoveExpr) === NodeKind.Identifier);
	});
	test("move f() becomes CallExpr", () => {
		check(firstExprKindAfter("move f();", lowerMoveExpr) === NodeKind.CallExpr);
	});
	test("non-move unchanged", () => {
		check(firstExprKindAfter("x;", lowerMoveExpr) === NodeKind.Identifier);
	});
	test("stmt count preserved", () => {
		check(stmtCountAfter("move a; move b;", lowerMoveExpr) === 2);
	});
});
