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
test "ternary in stmt becomes if" { assert firstStmtKindAfter("a ? b : c;", lowerConditionalExpr) === NodeKind.IfStmt; }

test "non-ternary ExprStmt unchanged" { assert firstStmtKindAfter("f();", lowerConditionalExpr) === NodeKind.ExprStmt; }

test "variable decl with ternary unchanged" { assert firstStmtKindAfter("const x = a ? b : c;", lowerConditionalExpr) === NodeKind.VariableDecl; }

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", lowerConditionalExpr) === NodeKind.WhileStmt; }

test "stmt count preserved" { assert stmtCountAfter("let a = 1; let b = 2;", lowerConditionalExpr) === 2; }

test "binary expr unchanged" { assert firstExprKindAfter("x + y;", lowerConditionalExpr) === NodeKind.BinaryExpr; }
