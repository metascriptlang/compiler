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

import { Node, NodeKind, IfStmtData, WhileStmtData, DoWhileStmtData, ConditionalExprData, TypeKind } from "../../ast/node";
import { isStructType, isMaybeType, unwrapRefNullUnion, peelTransparentInstance } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeMember, makeNumber, makeBool, makeNull, makeUnary } from "../util";

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
	const ct = cond.nodeType != null ? peelTransparentInstance(cond.nodeType) : null;
	// Type-aware: boolean-typed nodes need no wrapping.
	// BooleanLiteral covers disc re-reads on narrowed bool-disc DU variants
	// (`ok: BooleanLiteral` injected by resolvePass) — same C repr as boolean.
	if (ct != null && (ct.kind == TypeKind.Boolean
		|| ct.kind == TypeKind.BooleanLiteral)) return cond;
	// Maybe<T> in boolean context → .present
	if (ct != null && isMaybeType(ct)) {
		return makeMember(cond, "present", cond.location);
	}
	// bigint → `!!b`. The inner `!` is what bigIntOpLower turns into msBigIntIsZero
	// on C; on js the double negation is already the native truthiness of 0n.
	if (ct != null && ct.kind == TypeKind.BigInt) {
		return makeUnary("!", makeUnary("!", cond, cond.location), cond.location);
	}
	// Non-nullable value types → always true (Reference: rejects objects in boolean context)
	if (ct != null && isStructType(ct)) return makeBool(true, cond.location);
	// Arrays → len > 0
	if (ct != null && ct.kind == TypeKind.Array) {
		return makeBinary(makeMember(cond, "len", cond.location), ">", makeNumber(0, cond.location), cond.location);
	}
	// Ref values and nullable-pointer unions (Ref/Ptr/unknown | null — the Maybe
	// split leaves pointers unwrapped) → null-sentinel check; without this arm
	// both shapes fell into the string byteLength fallback below.
	if (ct != null && (ct.kind == TypeKind.Ref
			|| unwrapRefNullUnion(ct) != null)) {
		return makeBinary(cond, "!==", makeNull(cond.location), cond.location);
	}
	if (isAlreadyBoolean(cond)) return cond;
	if (cond.kind == NodeKind.Identifier || cond.kind == NodeKind.MemberExpr) {
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
test "if with comparison unchanged" { assert firstStmtKindAfter("if (x > 0) {}", lowerStringTruthiness) == NodeKind.IfStmt; }

test "while bool unchanged" { assert firstStmtKindAfter("while (true) {}", lowerStringTruthiness) == NodeKind.WhileStmt; }

test "call condition unchanged" { assert firstStmtKindAfter("if (f()) {}", lowerStringTruthiness) == NodeKind.IfStmt; }

test "binary expr unchanged" { assert firstExprKindAfter("x + y;", lowerStringTruthiness) == NodeKind.BinaryExpr; }

test "non-condition passthrough" { assert stmtCountAfter("const x = 1;", lowerStringTruthiness) == 1; }

test "already boolean passthrough" { assert firstStmtKindAfter("if (x === y) {}", lowerStringTruthiness) == NodeKind.IfStmt; }
