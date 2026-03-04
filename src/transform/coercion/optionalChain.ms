// Optional Chain Lowering — transforms obj?.prop → obj !== null ? obj.prop : null
// Follows reference optional_chain.zig
//
// Uses bottom-up walk via walker.ms so chained a?.b?.c works naturally:
// inner ?.b transforms first, outer ?.c sees the conditional result.

import { Node, NodeKind, MemberExprData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeMember, makeNull, makeBinary, makeConditional } from "../util";
import { check } from "std/testing";
import { firstExprKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerOptionalChain(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerOptionalNode);
}

// ===== Visitor =====

function lowerOptionalNode(node: Node): Node {
	if (node.kind !== NodeKind.MemberExpr) return node;
	const d = node.data as MemberExprData;
	if (!d.isOptional) return node;

	const loc = node.location;
	// obj?.prop → obj !== null ? obj.prop : null
	const cond = makeBinary(d.object, "!==", makeNull(loc), loc);
	const cons = makeMember(d.object, d.property, loc);
	const alt = makeNull(loc);
	return makeConditional(cond, cons, alt, loc);
}

// ===== Tests =====
test "regular member unchanged" { check(firstExprKindAfter("a.b;", lowerOptionalChain) === NodeKind.MemberExpr); }

test "optional chain becomes conditional" { check(firstExprKindAfter("a?.b;", lowerOptionalChain) === NodeKind.ConditionalExpr); }

test "call expr unchanged" { check(firstExprKindAfter("f();", lowerOptionalChain) === NodeKind.CallExpr); }
