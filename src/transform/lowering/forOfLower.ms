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
	Node, NodeKind, ForOfStmtData, BlockStmtData,
} from "../../ast/node";
import { TransformContext, freshTemp } from "../context";
import { walkNode } from "../walker";
import {
	makeIdent, makeNumber, makeBlock, makeVarDecl, makeWhile,
	makeBinary, makeAssign, makeExprStmt, makeMember, makeArrayAccess,
} from "../util";
import { test, check, testGroup } from "std/testing";
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
		const iterDecl = makeVarDecl(iterName, d.forOfIterable, true, loc);

		// let $idx = 0;
		const idxDecl = makeVarDecl(idxName, makeNumber(0, loc), false, loc);

		// const $len = $iter.length;
		const lenExpr = makeMember(makeIdent(iterName, loc), "length", loc);
		const lenDecl = makeVarDecl(lenName, lenExpr, true, loc);

		// const item = $iter[$idx];
		const itemAccess = makeArrayAccess(makeIdent(iterName, loc), makeIdent(idxName, loc), loc);
		const itemDecl = makeVarDecl(d.forOfBinding, itemAccess, d.forOfIsConst, loc);

		// $idx = $idx + 1;
		const increment = makeAssign(
			makeIdent(idxName, loc),
			makeBinary(makeIdent(idxName, loc), "+", makeNumber(1, loc), loc),
			loc
		);
		const incStmt = makeExprStmt(increment, loc);

		// Build while body: [item decl, ...original body stmts, idx increment]
		const whileStmts: Node[] = [];
		whileStmts.push(itemDecl);

		// Extract stmts from body if it's a block
		if (d.forOfBody.kind === NodeKind.BlockStmt) {
			const bodyData = d.forOfBody.data as BlockStmtData;
			let i = 0;
			while (i < bodyData.statements.length) {
				whileStmts.push(bodyData.statements[i]);
				i += 1;
			}
		} else {
			whileStmts.push(d.forOfBody);
		}
		whileStmts.push(incStmt);

		// while ($idx < $len) { ... }
		const whileCond = makeBinary(makeIdent(idxName, loc), "<", makeIdent(lenName, loc), loc);
		const whileBody = makeBlock(whileStmts, loc);
		const whileNode = makeWhile(whileCond, whileBody, loc);

		// Wrap in block: { iterDecl, idxDecl, lenDecl, while }
		return makeBlock([iterDecl, idxDecl, lenDecl, whileNode], loc);
	};
}

// ===== Tests =====

testGroup("ForOf Lowering", () => {
	test("for-of becomes block", () => {
		check(firstStmtKindAfter("for (const x of arr) { use(x); }", lowerForOf) === NodeKind.BlockStmt);
	});
	test("regular for unchanged", () => {
		check(firstStmtKindAfter("for (let i = 0; i < 10; i++) {}", lowerForOf) === NodeKind.ForStmt);
	});
	test("while unchanged", () => {
		check(firstStmtKindAfter("while (true) {}", lowerForOf) === NodeKind.WhileStmt);
	});
	test("for-of preserves surrounding stmts", () => {
		check(stmtCountAfter("x(); for (const i of arr) {} y();", lowerForOf) === 3);
	});
});
