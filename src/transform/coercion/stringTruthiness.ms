// String Truthiness — normalizes string conditions to explicit length checks
// Follows reference string_truthiness.zig + Nim's forceBool pattern
//
// if (str) { ... }   →  if (str.length > 0) { ... }
// while (str) { ... } →  while (str.length > 0) { ... }
// !str               →  str.length === 0
//
// Only transforms bare Identifier/MemberExpr conditions that aren't
// already boolean expressions (comparisons, calls, literals).
// Conservative syntactic heuristic — no type info needed.

import {
	Node, NodeKind,
	IfStmtData, WhileStmtData, DoWhileStmtData,
	ConditionalExprData, UnaryExprData, BinaryExprData,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeMember, makeNumber } from "../util";
import { check } from "std/testing";
import { firstStmtKindAfter, firstExprKindAfter, stmtCountAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerStringTruthiness(program: Node, ctx: TransformContext): Node {
	walkNode(program, truthifyNode);
	return program;
}

function truthifyNode(node: Node): Node {
	return match (node.kind) {
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			d.condition = wrapTruthiness(d.condition);
			node
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			d.whileCondition = wrapTruthiness(d.whileCondition);
			node
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			d.doCondition = wrapTruthiness(d.doCondition);
			node
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			d.ternaryCondition = wrapTruthiness(d.ternaryCondition);
			node
		},
		_ => node,
	};
}

// Wrap a bare identifier/member condition with .length > 0
// Only wraps if the condition is NOT already a boolean expression
function wrapTruthiness(cond: Node): Node {
	if (isAlreadyBoolean(cond)) return cond;
	if (cond.kind === NodeKind.Identifier || cond.kind === NodeKind.MemberExpr) {
		const loc = cond.location;
		const lengthAccess = makeMember(cond, "length", loc);
		return makeBinary(lengthAccess, ">", makeNumber(0, loc), loc);
	}
	return cond;
}

// Check if an expression already produces a boolean (no wrapping needed)
function isAlreadyBoolean(node: Node): boolean {
	return match (node.kind) {
		NodeKind.BooleanLiteral | NodeKind.NumberLiteral | NodeKind.NullLiteral => true,
		NodeKind.CallExpr | NodeKind.BinaryExpr | NodeKind.UnaryExpr => true,
		NodeKind.ArrayAccess | NodeKind.ConditionalExpr => true,
		_ => false,
	};
}

// ===== Tests =====
test "if with comparison unchanged" { check(firstStmtKindAfter("if (x > 0) {}", lowerStringTruthiness) === NodeKind.IfStmt); }

test "while bool unchanged" { check(firstStmtKindAfter("while (true) {}", lowerStringTruthiness) === NodeKind.WhileStmt); }

test "call condition unchanged" { check(firstStmtKindAfter("if (f()) {}", lowerStringTruthiness) === NodeKind.IfStmt); }

test "binary expr unchanged" { check(firstExprKindAfter("x + y;", lowerStringTruthiness) === NodeKind.BinaryExpr); }

test "non-condition passthrough" { check(stmtCountAfter("const x = 1;", lowerStringTruthiness) === 1); }

test "already boolean passthrough" { check(firstStmtKindAfter("if (x === y) {}", lowerStringTruthiness) === NodeKind.IfStmt); }
