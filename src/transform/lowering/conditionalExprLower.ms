// Conditional Expression Lowering — rewrite ternary in statement position to if-else
//
// In statement position (ExprStmt), `a ? b : c;` is lowered to:
//   if (a) { b; } else { c; }
//
// In expression position (e.g. `const x = a ? b : c`), ternary is preserved
// since C supports `?:` natively.
//
// Runs AFTER optionalChain/nullishCoalesce (which produce ternaries),
// stringTruthiness and generatorLower (which process them).

import { Node, NodeKind, ExprStmtData, ConditionalExprData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeIf, makeBlock, makeExprStmt } from "../util";
import { test, check, testGroup } from "std/testing";
import { firstStmtKindAfter, stmtCountAfter, firstExprKindAfter } from "../testUtil";

// ===== Visitor =====

function lowerConditionalNode(node: Node): Node {
	if (node.kind !== NodeKind.ExprStmt) return node;
	const d = node.data as ExprStmtData;
	if (d.expr.kind !== NodeKind.ConditionalExpr) return node;
	const cd = d.expr.data as ConditionalExprData;
	const loc = node.location;
	const thenStmts: Node[] = [];
	thenStmts.push(makeExprStmt(cd.ternaryConsequent, loc));
	const elseStmts: Node[] = [];
	elseStmts.push(makeExprStmt(cd.ternaryAlternate, loc));
	return makeIf(cd.ternaryCondition, makeBlock(thenStmts, loc), makeBlock(elseStmts, loc), loc);
}

// ===== Entry Point =====

export function lowerConditionalExpr(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerConditionalNode);
}

// ===== Tests =====

testGroup("Conditional Expr Lowering", () => {
	test("ternary in stmt becomes if", () => {
		check(firstStmtKindAfter("a ? b : c;", lowerConditionalExpr) === NodeKind.IfStmt);
	});
	test("non-ternary ExprStmt unchanged", () => {
		check(firstStmtKindAfter("f();", lowerConditionalExpr) === NodeKind.ExprStmt);
	});
	test("variable decl with ternary unchanged", () => {
		check(firstStmtKindAfter("const x = a ? b : c;", lowerConditionalExpr) === NodeKind.VariableDecl);
	});
	test("while unchanged", () => {
		check(firstStmtKindAfter("while (true) {}", lowerConditionalExpr) === NodeKind.WhileStmt);
	});
	test("stmt count preserved", () => {
		check(stmtCountAfter("let a = 1; let b = 2;", lowerConditionalExpr) === 2);
	});
	test("binary expr unchanged", () => {
		check(firstExprKindAfter("x + y;", lowerConditionalExpr) === NodeKind.BinaryExpr);
	});
});
