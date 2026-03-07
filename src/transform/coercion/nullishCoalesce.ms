// Nullish Coalesce Lowering — transforms x ?? y → x !== null ? x : y
// Follows reference nullish_coalesce.zig
//
// Must run AFTER optionalChain so obj?.prop ?? fallback is already lowered.
// Note: evaluates LHS twice for complex expressions (same limitation as reference).

import { Node, NodeKind, BinaryExprData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeNull, makeBinary, makeConditional } from "../util";
import { firstExprKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerNullishCoalesce(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerNullishNode);
}

// ===== Visitor =====

function lowerNullishNode(node: Node): Node {
	if (node.kind !== NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	if (d.operator !== "??") return node;

	const loc = node.location;
	// x ?? y → x !== null ? x : y
	const cond = makeBinary(d.left, "!==", makeNull(loc), loc);
	return makeConditional(cond, d.left, d.right, loc);
}

// ===== Tests =====
test "nullish coalesce becomes conditional" { expect(firstExprKindAfter("x ?? 42;", lowerNullishCoalesce) === NodeKind.ConditionalExpr); }

test "other binary unchanged" { expect(firstExprKindAfter("x + y;", lowerNullishCoalesce) === NodeKind.BinaryExpr); }

test "logical or unchanged" { expect(firstExprKindAfter("x || y;", lowerNullishCoalesce) === NodeKind.BinaryExpr); }
