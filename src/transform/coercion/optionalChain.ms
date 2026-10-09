// Optional Chain Lowering — transforms obj?.prop → obj !== null ? obj.prop : null
// Follows reference optional_chain.zig
//
// Uses bottom-up walk via walker.ms so chained a?.b?.c works naturally:
// inner ?.b transforms first, outer ?.c sees the conditional result.

import { Node, NodeKind, DeclKind, MemberExprData, BinaryExprData, ConditionalExprData, ExprStmtData } from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { TransformContext, freshTempSym } from "../context";
import { walkNode, walkExpandBlocks } from "../walker";
import { makeMember, makeNull, makeBinary, makeConditional, makeVarDecl, makeAssign, makeIdentResolved } from "../util";
import { firstExprKindAfter, parseInput, makeCtx, getStmts } from "../testUtil";
import { rereadOperand, asUnknown } from "./nullishCoalesce";

// ===== Main Entry Point =====

export function lowerOptionalChain(program: Node, ctx: TransformContext): Node {
	if (ctx.jsBackend) {
		walkExpandBlocks(program, (stmt: Node, c: TransformContext): Node[] => bindReadProbes(stmt, c), ctx);
	}
	return walkNode(program, lowerOptionalNode);
}

function bindReadProbes(stmt: Node, ctx: TransformContext): Node[] {
	const temps: Node[] = [];
	const lowered = walkNode(stmt, (node: Node): Node => bindReadProbe(node, ctx, temps));
	temps.push(lowered);
	return temps;
}

// The checker reads `x?.f` as `x !== null ? x.f : null` with one `x` node in both
// places when `x` is not a name path; C hoists that call once, JS binds it here.
function bindReadProbe(node: Node, ctx: TransformContext, temps: Node[]): Node {
	if (node.kind != NodeKind.ConditionalExpr) return node;
	const arms = node.data as ConditionalExprData;
	if (arms.ternaryCondition.kind != NodeKind.BinaryExpr) return node;
	const test = arms.ternaryCondition.data as BinaryExprData;
	const read = test.left;
	if (test.operator != "!==" || !reads(arms.ternaryConsequent, read)) return node;
	const loc = node.location;
	const sym = freshTempSym(ctx, "optional", read.nodeType);
	const decl = makeVarDecl(sym.name, makeNull(loc), DeclKind.Var, loc);
	decl.resolvedSym = sym;
	decl.nodeType = sym.symbolType;
	temps.push(decl);
	test.left = makeAssign(makeIdentResolved(sym, loc), asUnknown(read, loc), loc);
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
