// For-Of Lowering — transforms for-of loops into index-based while loops
// Follows reference for_of_lower.zig
//
// Input:  for (const item of arr) { body }
// Output: {
//   const $iter_0 = arr;
//   let $idx_1 = 0;
//   const $len_2 = $iter_0.length;
//   while ($idx_1 < $len_2) {
//     const item = $iter_0[$idx_1];
//     ...body...
//     $idx_1 = $idx_1 + 1;
//   }
// }

import {
	Node, NodeKind, DeclKind, ForOfStmtData,
} from "../../ast/node";
import { TransformContext, freshTemp } from "../context";
import { walkNode } from "../walker";
import {
	makeIdent, makeTypedIdent, makeNumber, makeBlock, makeVarDecl, makeWhile,
	makeBinary, makeAssign, makeExprStmt, makeMember, makeArrayAccess,
	extractBodyStmts, boolToDeclKind,
} from "../util";
import { numberType } from "../../checker/types";
import { check } from "std/testing";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerForOf(program: Node, ctx: TransformContext): Node {
	return walkNode(program, forOfVisitor(ctx));
}

// Closure-returning visitor to capture ctx
function forOfVisitor(ctx: TransformContext): (node: Node) => Node {
	return (node: Node): Node => {
		if (node.kind !== NodeKind.ForOfStmt) return node;
		const d = node.data as ForOfStmtData;
		const loc = node.location;

		// Generate temp names
		const iterName = freshTemp(ctx, "iter");
		const idxName = freshTemp(ctx, "idx");
		const lenName = freshTemp(ctx, "len");

		// const $iter = arr;
		const iterDecl = makeVarDecl(iterName, d.forOfIterable, DeclKind.Const, loc);
		const iterType = d.forOfIterable.nodeType;

		// let $idx = 0;
		const idxDecl = makeVarDecl(idxName, makeNumber(0, loc), DeclKind.Let, loc);

		// const $len = $iter.length;
		const lenExpr = makeMember(makeTypedIdent(iterName, iterType, loc), "length", loc);
		const lenDecl = makeVarDecl(lenName, lenExpr, DeclKind.Const, loc);

		// const item = $iter[$idx];
		const itemAccess = makeArrayAccess(makeTypedIdent(iterName, iterType, loc), makeTypedIdent(idxName, numberType(), loc), loc);
		const itemDk = boolToDeclKind(d.forOfIsConst);
		const itemDecl = makeVarDecl(d.forOfBinding, itemAccess, itemDk, loc);

		// $idx = $idx + 1;
		const increment = makeAssign(
			makeTypedIdent(idxName, numberType(), loc),
			makeBinary(makeTypedIdent(idxName, numberType(), loc), "+", makeNumber(1, loc), loc),
			loc
		);
		const incStmt = makeExprStmt(increment, loc);

		// Build while body: [item decl, ...original body stmts, idx increment]
		const whileStmts: Node[] = [];
		whileStmts.push(itemDecl);

		const bodyStmts = extractBodyStmts(d.forOfBody);
		for (let bi = 0; bi < bodyStmts.length; bi += 1) {
			whileStmts.push(bodyStmts[bi]);
		}
		whileStmts.push(incStmt);

		// while ($idx < $len) { ... }
		const whileCond = makeBinary(makeTypedIdent(idxName, numberType(), loc), "<", makeTypedIdent(lenName, numberType(), loc), loc);
		const whileBody = makeBlock(whileStmts, loc);
		const whileNode = makeWhile(whileCond, whileBody, loc);

		// Wrap in block: { iterDecl, idxDecl, lenDecl, while }
		return makeBlock([iterDecl, idxDecl, lenDecl, whileNode], loc);
	};
}

// ===== Tests =====
test "for-of becomes block" { check(firstStmtKindAfter("for (const x of arr) { use(x); }", lowerForOf) === NodeKind.BlockStmt); }

test "regular for unchanged" { check(firstStmtKindAfter("for (let i = 0; i < 10; i++) {}", lowerForOf) === NodeKind.ForStmt); }

test "for-of preserves surrounding stmts" { check(stmtCountAfter("x(); for (const i of arr) {} y();", lowerForOf) === 3); }
