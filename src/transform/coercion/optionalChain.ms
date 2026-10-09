// Optional Chain Lowering — transforms obj?.prop → obj !== null ? obj.prop : null
// Follows reference optional_chain.zig
//
// Uses bottom-up walk via walker.ms so chained a?.b?.c works naturally:
// inner ?.b transforms first, outer ?.c sees the conditional result.

import { Node, NodeKind, MemberExprData, BinaryExprData, ConditionalExprData, ExprStmtData } from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { TransformContext } from "../context";
import { walkNode, walkExpandBlocks, walkWithinStatement, walkOutsideInstanceFieldInits } from "../walker";
import { makeMember, makeNull, makeBinary, makeConditional, makeIdentResolved } from "../util";
import { firstExprKindAfter, parseInput, makeCtx, getStmts } from "../testUtil";
import { rereadOperand, bindOnce, blockifyArrowsReading } from "./nullishCoalesce";
import { cloneIfPure } from "./intArithJS";

// ===== Main Entry Point =====

export function lowerOptionalChain(program: Node, ctx: TransformContext): Node {
	blockifyArrowsReading(program, (node: Node): boolean => sharedProbe(node) != null);
	walkExpandBlocks(program, (stmt: Node, c: TransformContext): Node[] => bindReadProbes(stmt, c), ctx);
	return walkOutsideInstanceFieldInits(program, lowerOptionalNode);
}

function bindReadProbes(stmt: Node, ctx: TransformContext): Node[] {
	const temps: Node[] = [];
	const lowered = walkWithinStatement(stmt, (node: Node): Node => bindReadProbe(node, ctx, temps));
	temps.push(lowered);
	return temps;
}

// The checker reads `x?.f` as `x !== null ? x.f : null` with one `x` node in both
// places when `x` is not a name path.
function sharedProbe(node: Node): Node | null {
	if (node.kind != NodeKind.ConditionalExpr) return null;
	const arms = node.data as ConditionalExprData;
	if (arms.ternaryCondition.kind != NodeKind.BinaryExpr) return null;
	const test = arms.ternaryCondition.data as BinaryExprData;
	if (test.operator != "!==" || cloneIfPure(test.left) != null || !reads(arms.ternaryConsequent, test.left)) return null;
	return test.left;
}

function bindReadProbe(node: Node, ctx: TransformContext, temps: Node[]): Node {
	const read = sharedProbe(node);
	if (read == null) return node;
	const arms = node.data as ConditionalExprData;
	const test = arms.ternaryCondition.data as BinaryExprData;
	const loc = node.location;
	const bound = bindOnce(read, ctx, temps, loc);
	const sym = (bound.data as BinaryExprData).left.resolvedSym!;
	test.left = bound;
	arms.ternaryConsequent = walkNode(arms.ternaryConsequent, (n: Node): Node => n == read ? makeIdentResolved(sym, loc) : n);
	return node;
}

function reads(tree: Node, shared: Node): boolean {
	if (tree == shared) return true;
	let found = false;
	forEachChild(tree, (child: Node): void => {
		if (!found && child != null && reads(child, shared)) found = true;
	});
	return found;
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
