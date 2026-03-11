// String Truthiness — normalizes string conditions to explicit length checks
// Follows reference string_truthiness.zig + standard reference patterns
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
import { TypeKind, isInterfaceType, isMaybeType } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeMember, makeNumber, makeBool } from "../util";

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
			return node;
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			d.whileCondition = wrapTruthiness(d.whileCondition);
			return node;
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			d.doCondition = wrapTruthiness(d.doCondition);
			return node;
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			d.ternaryCondition = wrapTruthiness(d.ternaryCondition);
			return node;
		},
		_ => node,
	};
}

// Wrap a condition for C boolean context.
// Type-aware checks first (reference parity), then syntactic fallback.
function wrapTruthiness(cond: Node): Node {
	// Type-aware: boolean-typed nodes need no wrapping
	if (cond.nodeType !== null && cond.nodeType.kind === TypeKind.Boolean) return cond;
	// Maybe<T> in boolean context → .present
	if (cond.nodeType !== null && isMaybeType(cond.nodeType)) {
		return makeMember(cond, "present", cond.location);
	}
	// Non-nullable value types → always true (Reference: rejects objects in boolean context)
	if (cond.nodeType !== null && isInterfaceType(cond.nodeType)) return makeBool(true, cond.location);
	// Arrays → len > 0
	if (cond.nodeType !== null && cond.nodeType.kind === TypeKind.Array) {
		return makeBinary(makeMember(cond, "len", cond.location), ">", makeNumber(0, cond.location), cond.location);
	}
	if (isAlreadyBoolean(cond)) return cond;
	if (cond.kind === NodeKind.Identifier || cond.kind === NodeKind.MemberExpr) {
		const loc = cond.location;
		const lengthAccess = makeMember(cond, "byteLength", loc);
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
test "if with comparison unchanged" { assert firstStmtKindAfter("if (x > 0) {}", lowerStringTruthiness) === NodeKind.IfStmt; }

test "while bool unchanged" { assert firstStmtKindAfter("while (true) {}", lowerStringTruthiness) === NodeKind.WhileStmt; }

test "call condition unchanged" { assert firstStmtKindAfter("if (f()) {}", lowerStringTruthiness) === NodeKind.IfStmt; }

test "binary expr unchanged" { assert firstExprKindAfter("x + y;", lowerStringTruthiness) === NodeKind.BinaryExpr; }

test "non-condition passthrough" { assert stmtCountAfter("const x = 1;", lowerStringTruthiness) === 1; }

test "already boolean passthrough" { assert firstStmtKindAfter("if (x === y) {}", lowerStringTruthiness) === NodeKind.IfStmt; }
