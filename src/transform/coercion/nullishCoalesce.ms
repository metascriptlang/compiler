// Nullish Coalesce Lowering — transforms x ?? y → x !== null ? x : y
// Follows reference nullish_coalesce.zig
//
// Must run AFTER optionalChain so obj?.prop ?? fallback is already lowered.
// Note: evaluates LHS twice for complex expressions (same limitation as reference).

import { Node, NodeKind, BinaryExprData, TypeAssertionData, TypeKind, SourceLocation, Type, createNodeAt } from "../../ast/node";
import { isMaybeType, unwrapMaybeType, isNumeric, isBoolType, isStringLike, unknownType } from "../../checker/types";
import { fitJoinedBranch, nullishPayloadType } from "../../checker/fit";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeNull, makeBinary, makeConditional, makeMember } from "../util";
import { firstExprKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerNullishCoalesce(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => lowerNullishNode(node, ctx));
}

// ===== Visitor =====

function nullishPresence(left: Node, loc: SourceLocation, ctx: TransformContext): Node {
	let checked = left;
	if (ctx.jsBackend) {
		checked = createNodeAt(NodeKind.TypeAssertion, { asExpr: left, asType: "unknown" } as TypeAssertionData, loc);
		checked.nodeType = unknownType();
	} else if (left.nodeType != null && isStringLike(left.nodeType)) {
		checked = makeMember(left, "p", loc);
		checked.nodeType = unknownType();
	}
	return makeBinary(checked, "!==", makeNull(loc), loc);
}

export function nullishLowered(left: Node, right: Node, loc: SourceLocation, resultType: Type | null, ctx: TransformContext): Node {
	// A scalar left operand carries no null, and the lowered test would emit
	// `double !== NULL`, which is not valid C. TS keeps the expression legal and
	// its value is the left operand.
	const leftType = left.nodeType;
	if (leftType != null && !isMaybeType(leftType) && (isNumeric(leftType) || isBoolType(leftType))) {
		return left;
	}

	// x ?? y → x !== null ? x : y
	const cond = nullishPresence(left, loc, ctx);

	// Value-carried nullable (Maybe struct in C): when the fallback is non-null the
	// result type is the UNWRAPPED T, so the then-arm must read x.value — raw x would
	// mix carrier and payload in the C ternary (and JS backend strips .value back to x).
	// Nullable fallback keeps both arms in the carrier — no rewrite.
	const lt = left.nodeType;
	const rt = right.nodeType;
	const joined = resultType != null && nullishPayloadType(resultType) == null ? resultType : null;
	if (lt != null && isMaybeType(lt)
		&& rt != null && rt.kind != TypeKind.Null && !isMaybeType(rt)) {
		const read = makeMember(left, "value", loc);
		read.nodeType = unwrapMaybeType(lt);
		const val = payloadArm(read, joined, ctx);
		const c = makeConditional(cond, val, right, loc);
		c.nodeType = joined != null ? joined : val.nodeType;
		return c;
	}
	const payload = nullishPayloadType(lt);
	if (payload != null && joined != null && rt != null && nullishPayloadType(rt) == null && rt.kind != TypeKind.Null) {
		const asserted = createNodeAt(NodeKind.TypeAssertion, { asExpr: left, asType: "!" } as TypeAssertionData, loc);
		asserted.nodeType = payload;
		const val = payloadArm(asserted, joined, ctx);
		if (val != asserted) {
			const c = makeConditional(cond, val, right, loc);
			c.nodeType = joined;
			return c;
		}
	}
	const lowered = makeConditional(cond, left, right, loc);
	if (resultType != null) lowered.nodeType = resultType;
	return lowered;
}

function payloadArm(read: Node, joined: Type | null, ctx: TransformContext): Node {
	if (joined == null || ctx.checkerCtx == null) return read;
	return fitJoinedBranch(ctx.checkerCtx, read, joined);
}

function lowerNullishNode(node: Node, ctx: TransformContext): Node {
	if (node.kind != NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	if (d.operator != "??") return node;
	return nullishLowered(d.left, d.right, node.location, node.nodeType, ctx);
}

// ===== Tests =====
test "nullish coalesce becomes conditional" { assert firstExprKindAfter("x ?? 42;", lowerNullishCoalesce) == NodeKind.ConditionalExpr; }

test "other binary unchanged" { assert firstExprKindAfter("x + y;", lowerNullishCoalesce) == NodeKind.BinaryExpr; }

test "logical or unchanged" { assert firstExprKindAfter("x || y;", lowerNullishCoalesce) == NodeKind.BinaryExpr; }
