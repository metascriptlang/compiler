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

import {
	Node, NodeKind, SourceLocation,
	BinaryExprData, UnaryExprData, MemberExprData,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeNumber, makeIntNumber, makeString, makeBool } from "../util";
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
		_ => node,
	};
}

// ===== Binary Folding =====

function foldBinary(node: Node): Node {
	const d = node.data as BinaryExprData;
	const loc = node.location;
	// NOTE: do NOT create `const op = d.operator` — DRC treats it as a move from d->operator,
	// which zeroes the node's operator field because d is a pointer alias into node.data.
	// Use d.operator directly everywhere instead.

	// Both operands must be the same literal kind
	if (d.left.kind != d.right.kind) return node;

	const result = match (d.left.kind) {
		NodeKind.NumberLiteral => {
			const ld = d.left.data as NumberLiteralData;
			const rd = d.right.data as NumberLiteralData;
			// The fold table runs on doubles. Folding operands a double cannot hold
			// would bake in a wrong constant, so leave the expression alone and let
			// the backend's own integer arithmetic evaluate it.
			if (!fitsDouble(ld) || !fitsDouble(rd)) return node;
			return foldNumberBinary(d.operator, ld.value, rd.value, loc, node);
		},
		NodeKind.StringLiteral => {
			const ls = (d.left.data as StringLiteralData).value;
			const rs = (d.right.data as StringLiteralData).value;
			return foldStringBinary(d.operator, ls, rs, loc, node);
		},
		NodeKind.BooleanLiteral => {
			const lb = (d.left.data as BooleanLiteralData).boolValue;
			const rb = (d.right.data as BooleanLiteralData).boolValue;
			return foldBoolBinary(d.operator, lb, rb, loc, node);
		},
		_ => node,
	};
	// Preserve checker-stamped type through constant folding.
	// Reference parity: constant folding preserves original type on folded literals.
	if (result != node && node.nodeType != null) {
		result.nodeType = node.nodeType;
	}
	return result;
}

// True when the literal's exact value survives a round trip through a double.
function fitsDouble(d: NumberLiteralData): boolean {
	if (d.isFloat) return true;
	return ((d.intVal as number) as int64) == d.intVal;
}

function foldNumberBinary(op: string, lv: number, rv: number, loc: SourceLocation, fallback: Node): Node {
	// Guard: division by zero — leave as runtime
	if (rv == 0 && (op == "/" || op == "%")) return fallback;

	return match (op) {
		"+" => makeNumber(lv + rv, loc),
		"-" => makeNumber(lv - rv, loc),
		"*" => makeNumber(lv * rv, loc),
		"/" => makeNumber(lv / rv, loc),
		"%" => makeNumber(lv % rv, loc),
		"<" => makeBool(lv < rv, loc),
		"<=" => makeBool(lv <= rv, loc),
		">" => makeBool(lv > rv, loc),
		">=" => makeBool(lv >= rv, loc),
		"===" => makeBool(lv == rv, loc),
		"!==" => makeBool(lv != rv, loc),
		_ => fallback,
	};
}

function foldStringBinary(op: string, lv: string, rv: string, loc: SourceLocation, fallback: Node): Node {
	return match (op) {
		"+" => makeString(lv + rv, loc),
		"===" => makeBool(lv == rv, loc),
		"!==" => makeBool(lv != rv, loc),
		_ => fallback,
	};
}

function foldBoolBinary(op: string, lb: boolean, rb: boolean, loc: SourceLocation, fallback: Node): Node {
	return match (op) {
		"===" => makeBool(lb == rb, loc),
		"!==" => makeBool(lb != rb, loc),
		"&&" => makeBool(lb && rb, loc),
		"||" => makeBool(lb || rb, loc),
		_ => fallback,
	};
}

// ===== Unary Folding =====

function foldUnary(node: Node): Node {
	const d = node.data as UnaryExprData;
	const loc = node.location;
	// NOTE: do NOT copy d.unaryOp to local — same DRC alias issue as foldBinary.

	match (d.operand.kind) {
		NodeKind.BooleanLiteral => {
			if (d.unaryOp == "!") {
				const bv = (d.operand.data as BooleanLiteralData).boolValue;
				return makeBool(!bv, loc);
			}
		},
		NodeKind.NumberLiteral => {
			const od = d.operand.data as NumberLiteralData;
			const nv = od.value;
			const result = match (d.unaryOp) {
				"-" => od.isFloat ? makeNumber(0 - nv, loc) : makeIntNumber((0 - (od.intVal as uint64)) as int64, loc),
				"+" => od.isFloat ? makeNumber(nv, loc) : makeIntNumber(od.intVal, loc),
				_ => node,
			};
			// Preserve checker-stamped type through constant folding.
			// Reference parity: constant folding preserves original type on folded literals.
			if (result != node && node.nodeType != null) {
				result.nodeType = node.nodeType;
			}
			return result;
		},
		_ => {},
	};

	return node;
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
	return node;
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
