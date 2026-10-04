// Optional Chain Lowering — transforms obj?.prop → obj !== null ? obj.prop : null
// Follows reference optional_chain.zig
//
// Uses bottom-up walk via walker.ms so chained a?.b?.c works naturally:
// inner ?.b transforms first, outer ?.c sees the conditional result.

import { Node, NodeKind, MemberExprData, BinaryExprData, ConditionalExprData, ExprStmtData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeMember, makeNull, makeBinary, makeConditional } from "../util";
import { firstExprKindAfter, parseInput, makeCtx, getStmts } from "../testUtil";
import { rereadOperand } from "./nullishCoalesce";

// ===== Main Entry Point =====

export function lowerOptionalChain(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerOptionalNode);
}

// ===== Visitor =====

function lowerOptionalNode(node: Node): Node {
	if (node.kind != NodeKind.MemberExpr) return node;
	const d = node.data as MemberExprData;
	if (!d.isOptional) return node;

	const loc = node.location;
	// obj?.prop → obj !== null ? obj.prop : null
	const cond = makeBinary(d.object, "!==", makeNull(loc), loc);
	const cons = makeMember(rereadOperand(d.object), d.property, loc);
	const alt = makeNull(loc);
	return makeConditional(cond, cons, alt, loc);
}

// ===== Tests =====
test "regular member unchanged" { assert firstExprKindAfter("a.b;", lowerOptionalChain) == NodeKind.MemberExpr; }

test "optional chain becomes conditional" { assert firstExprKindAfter("a?.b;", lowerOptionalChain) == NodeKind.ConditionalExpr; }

test "call expr unchanged" { assert firstExprKindAfter("f();", lowerOptionalChain) == NodeKind.CallExpr; }

test "a pure object is read again through its own node" {
	for (const input of ["q?.c;", "q.b?.c;", "q.rows[i]?.c;"]) {
		const parsed = parseInput(input);
		assert parsed.ok, input;
		if (parsed.ok) {
			const stmts = getStmts(lowerOptionalChain(parsed.value, makeCtx()));
			const expr = (stmts[0].data as ExprStmtData).expr;
			assert expr.kind == NodeKind.ConditionalExpr, input;
			const arms = expr.data as ConditionalExprData;
			const tested = (arms.ternaryCondition.data as BinaryExprData).left;
			const read = (arms.ternaryConsequent.data as MemberExprData).object;
			assert read != tested && read.kind == tested.kind, input;
		}
	}
}
