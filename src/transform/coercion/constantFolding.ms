// Constant Folding — compile-time evaluation of constant expressions
// Follows Nim's commonOptimizations + getConstExpr (transf.nim)
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
	Node, NodeKind,
	BinaryExprData, UnaryExprData, MemberExprData,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeNumber, makeString, makeBool } from "../util";
import { test, check, testGroup } from "std/testing";
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
	const op = d.operator;

	// Both operands must be the same literal kind
	if (d.left.kind !== d.right.kind) return node;

	return match (d.left.kind) {
		NodeKind.NumberLiteral => {
			const lv = (d.left.data as NumberLiteralData).value;
			const rv = (d.right.data as NumberLiteralData).value;
			foldNumberBinary(op, lv, rv, loc, node)
		},
		NodeKind.StringLiteral => {
			const lv = (d.left.data as StringLiteralData).value;
			const rv = (d.right.data as StringLiteralData).value;
			foldStringBinary(op, lv, rv, loc, node)
		},
		NodeKind.BooleanLiteral => {
			const lb = (d.left.data as BooleanLiteralData).boolValue;
			const rb = (d.right.data as BooleanLiteralData).boolValue;
			foldBoolBinary(op, lb, rb, loc, node)
		},
		_ => node,
	};
}

function foldNumberBinary(op: string, lv: number, rv: number, loc: Node["location"], fallback: Node): Node {
	// Guard: division by zero — leave as runtime
	if (rv === 0 && (op === "/" || op === "%")) return fallback;

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
		"===" => makeBool(lv === rv, loc),
		"!==" => makeBool(lv !== rv, loc),
		_ => fallback,
	};
}

function foldStringBinary(op: string, lv: string, rv: string, loc: Node["location"], fallback: Node): Node {
	return match (op) {
		"+" => makeString(lv + rv, loc),
		"===" => makeBool(lv === rv, loc),
		"!==" => makeBool(lv !== rv, loc),
		_ => fallback,
	};
}

function foldBoolBinary(op: string, lb: boolean, rb: boolean, loc: Node["location"], fallback: Node): Node {
	return match (op) {
		"===" => makeBool(lb === rb, loc),
		"!==" => makeBool(lb !== rb, loc),
		"&&" => makeBool(lb && rb, loc),
		"||" => makeBool(lb || rb, loc),
		_ => fallback,
	};
}

// ===== Unary Folding =====

function foldUnary(node: Node): Node {
	const d = node.data as UnaryExprData;
	const loc = node.location;
	const op = d.unaryOp;

	match (d.operand.kind) {
		NodeKind.BooleanLiteral => {
			if (op === "!") {
				const bv = (d.operand.data as BooleanLiteralData).boolValue;
				return makeBool(!bv, loc);
			}
		},
		NodeKind.NumberLiteral => {
			const nv = (d.operand.data as NumberLiteralData).value;
			return match (op) {
				"-" => makeNumber(0 - nv, loc),
				"+" => makeNumber(nv, loc),
				_ => node,
			};
		},
		_ => {},
	};

	return node;
}

// ===== Member Folding =====
// "a".code → NumberLiteral(97) — compile-time character code

function foldMember(node: Node): Node {
	const d = node.data as MemberExprData;
	if (d.property === "code" && d.object.kind === NodeKind.StringLiteral) {
		const sd = d.object.data as StringLiteralData;
		if (sd.value.length > 0) {
			const cc = sd.value.charCodeAt(0);
			return makeNumber(cc, node.location);
		}
	}
	return node;
}

// ===== Tests =====

testGroup("Constant Folding", () => {
	test("number addition", () => {
		check(firstExprKindAfter("2 + 3;", lowerConstFold) === NodeKind.NumberLiteral);
	});
	test("string concat", () => {
		check(firstExprKindAfter("\"a\" + \"b\";", lowerConstFold) === NodeKind.StringLiteral);
	});
	test("boolean negation", () => {
		check(firstExprKindAfter("!true;", lowerConstFold) === NodeKind.BooleanLiteral);
	});
	test("comparison", () => {
		check(firstExprKindAfter("5 > 3;", lowerConstFold) === NodeKind.BooleanLiteral);
	});
	test("non-constant unchanged", () => {
		check(firstExprKindAfter("x + y;", lowerConstFold) === NodeKind.BinaryExpr);
	});
	test("nested constant folds bottom-up", () => {
		check(firstExprKindAfter("(2 + 3) * 4;", lowerConstFold) === NodeKind.NumberLiteral);
	});
	test("mixed types unchanged", () => {
		check(firstExprKindAfter("1 + x;", lowerConstFold) === NodeKind.BinaryExpr);
	});
	test("division by zero unchanged", () => {
		check(firstExprKindAfter("1 / 0;", lowerConstFold) === NodeKind.BinaryExpr);
	});
});
