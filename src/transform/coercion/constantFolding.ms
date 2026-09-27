// Constant Folding — compile-time evaluation of constant expressions
// Follows the standard reference implementation (constant folding)
//
// Folds:
//   2 + 3           → 5
//   "a" + "b"       → "ab"
//   !true            → false
//   5 > 3            → true
//
// Does NOT fold:
//   x + y            — non-constant operands
//   1 / 0            — division by zero (runtime)
//   "a" + 1          — mixed types

import { Node, NodeKind, BinaryExprData, UnaryExprData, MemberExprData, StringLiteralData } from "../../ast/node";
import { foldConstantExpression, foldBinaryLiterals, foldUnaryLiteral } from "../../checker/constFold";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeNumber } from "../util";
import { firstExprKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerConstFold(program: Node, ctx: TransformContext): Node {
	walkNode(program, foldNode);
	return program;
}

function foldNode(node: Node): Node {
	return match (node.kind) {
		NodeKind.BinaryExpr => foldBinary(node),
		NodeKind.UnaryExpr => foldUnary(node),
		NodeKind.MemberExpr => foldMember(node),
		NodeKind.Identifier => foldConstantExpression(node),
		NodeKind.TypeAssertion => foldConstantExpression(node),
		NodeKind.HiddenStdConv => foldConstantExpression(node),
		_ => node,
	};
}

// ===== Binary Folding =====

function foldBinary(node: Node): Node {
	const d = node.data as BinaryExprData;
	// NOTE: do NOT create `const op = d.operator` — DRC treats it as a move from d->operator,
	// which zeroes the node's operator field because d is a pointer alias into node.data.
	// Use d.operator directly everywhere instead.
	return foldBinaryLiterals(d.operator, d.left, d.right, node);
}

// ===== Unary Folding =====

function foldUnary(node: Node): Node {
	const d = node.data as UnaryExprData;
	// NOTE: do NOT copy d.unaryOp to local — same DRC alias issue as foldBinary.
	return foldUnaryLiteral(d.unaryOp, d.operand, node);
}

// ===== Member Folding =====
// "a".code → NumberLiteral(97) — compile-time character code

function foldMember(node: Node): Node {
	const d = node.data as MemberExprData;
	if (d.property == "code" && d.object.kind == NodeKind.StringLiteral) {
		const sd = d.object.data as StringLiteralData;
		if (sd.value.byteLength > 0) {
			const cc = sd.value.charCodeAt(0);
			return makeNumber(cc, node.location);
		}
	}
	return foldConstantExpression(node);
}

// ===== Tests =====
test "number addition" { assert firstExprKindAfter("2 + 3;", lowerConstFold) == NodeKind.NumberLiteral; }

test "string concat" { assert firstExprKindAfter("\"a\" + \"b\";", lowerConstFold) == NodeKind.StringLiteral; }

test "boolean negation" { assert firstExprKindAfter("!true;", lowerConstFold) == NodeKind.BooleanLiteral; }

test "comparison" { assert firstExprKindAfter("5 > 3;", lowerConstFold) == NodeKind.BooleanLiteral; }

test "non-constant unchanged" { assert firstExprKindAfter("x + y;", lowerConstFold) == NodeKind.BinaryExpr; }

test "nested constant folds bottom-up" { assert firstExprKindAfter("(2 + 3) * 4;", lowerConstFold) == NodeKind.NumberLiteral; }

test "mixed types unchanged" { assert firstExprKindAfter("1 + x;", lowerConstFold) == NodeKind.BinaryExpr; }

test "division by zero unchanged" { assert firstExprKindAfter("1 / 0;", lowerConstFold) == NodeKind.BinaryExpr; }
