// Nullish Coalesce Lowering — transforms x ?? y → x !== null ? x : y
// Follows reference nullish_coalesce.zig
//
// Must run AFTER optionalChain so obj?.prop ?? fallback is already lowered.
// Note: evaluates LHS twice for complex expressions (same limitation as reference).

import { Node, NodeKind, BinaryExprData, TypeKind } from "../../ast/node";
import { isMaybeType, unwrapMaybeType, isNumeric, isBoolType } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeNull, makeBinary, makeConditional, makeMember } from "../util";
import { firstExprKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerNullishCoalesce(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerNullishNode);
}

// ===== Visitor =====

function lowerNullishNode(node: Node): Node {
	if (node.kind != NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	if (d.operator != "??") return node;

	// A scalar left operand carries no null, and the lowered test would emit
	// `double !== NULL`, which is not valid C. TS keeps the expression legal and
	// its value is the left operand.
	const leftType = d.left.nodeType;
	if (leftType != null && !isMaybeType(leftType) && (isNumeric(leftType) || isBoolType(leftType))) {
		return d.left;
	}

	const loc = node.location;
	// x ?? y → x !== null ? x : y
	const cond = makeBinary(d.left, "!==", makeNull(loc), loc);

	// Value-carried nullable (Maybe struct in C): when the fallback is non-null the
	// result type is the UNWRAPPED T, so the then-arm must read x.value — raw x would
	// mix carrier and payload in the C ternary (and JS backend strips .value back to x).
	// Nullable fallback keeps both arms in the carrier — no rewrite.
	const lt = d.left.nodeType;
	const rt = d.right.nodeType;
	if (lt != null && isMaybeType(lt)
		&& rt != null && rt.kind != TypeKind.Null && !isMaybeType(rt)) {
		const val = makeMember(d.left, "value", loc);
		val.nodeType = unwrapMaybeType(lt);
		const c = makeConditional(cond, val, d.right, loc);
		c.nodeType = val.nodeType;
		return c;
	}
	const lowered = makeConditional(cond, d.left, d.right, loc);
	if (node.nodeType != null) lowered.nodeType = node.nodeType;
	return lowered;
}

// ===== Tests =====
test "nullish coalesce becomes conditional" { assert firstExprKindAfter("x ?? 42;", lowerNullishCoalesce) == NodeKind.ConditionalExpr; }

test "other binary unchanged" { assert firstExprKindAfter("x + y;", lowerNullishCoalesce) == NodeKind.BinaryExpr; }

test "logical or unchanged" { assert firstExprKindAfter("x || y;", lowerNullishCoalesce) == NodeKind.BinaryExpr; }
