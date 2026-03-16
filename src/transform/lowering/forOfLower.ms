// For-Of Lowering — transforms for-of loops into index-based while loops
// Follows reference for_of_lower.zig
//
// Arrays/Strings:
//   for (const item of arr) { body }
//   → { const $iter = arr; let $idx = 0; const $len = $iter.length;
//       while ($idx < $len) { const item = $iter[$idx]; body; $idx++; } }

import {
	Node, NodeKind, DeclKind, ForOfStmtData, SourceLocation,
	ArrayPatternData, IdentifierData, NodeFlag,
} from "../../ast/node";
import { TransformContext, freshTemp } from "../context";
import { Type, numberType } from "../../checker/types";
import { walkNode } from "../walker";
import {
	makeIdent, makeTypedIdent, makeNumber, makeBlock, makeVarDecl, makeWhile,
	makeBinary, makeAssign, makeExprStmt, makeMember, makeArrayAccess,
	extractBodyStmts, boolToDeclKind,
} from "../util";
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

		// Array/String: index-based pattern
		return lowerArrayForOf(d, ctx, loc);
	};
}

// ===== Array/String For-Of =====

function lowerArrayForOf(d: ForOfStmtData, ctx: TransformContext, loc: SourceLocation): Node {
	const iterName = freshTemp(ctx, "iter");
	const idxName = freshTemp(ctx, "idx");
	const lenName = freshTemp(ctx, "len");
	const iterType = d.forOfIterable.nodeType;

	// const $iter = arr; — cursor (borrow), DRC must not destroy (reference: cursor flag)
	const iterDecl = makeVarDecl(iterName, d.forOfIterable, DeclKind.Const, loc);
	iterDecl.flags = iterDecl.flags | NodeFlag.Cursor;

	// let $idx = 0;
	const idxDecl = makeVarDecl(idxName, makeNumber(0, loc), DeclKind.Let, loc);

	// const $len = $iter.length;
	const lenExpr = makeMember(makeTypedIdent(iterName, iterType, loc), "length", loc);
	const lenDecl = makeVarDecl(lenName, lenExpr, DeclKind.Const, loc);

	// $idx = $idx + 1;
	const increment = makeAssign(
		makeTypedIdent(idxName, numberType(), loc),
		makeBinary(makeTypedIdent(idxName, numberType(), loc), "+", makeNumber(1, loc), loc),
		loc
	);
	const incStmt = makeExprStmt(increment, loc);

	// Build while body — bindings scoped inside the loop iteration
	const whileStmts: Node[] = [];
	const itemDk = boolToDeclKind(d.forOfIsConst);

	if (d.forOfPattern !== null && d.forOfPattern.kind === NodeKind.ArrayPattern) {
		// Destructured: const $elem = $iter[$idx]; const a = $elem[0]; const b = $elem[1]; ...
		const elemName = freshTemp(ctx, "elem");
		const elemAccess = makeArrayAccess(makeTypedIdent(iterName, iterType, loc), makeTypedIdent(idxName, numberType(), loc), loc);
		const elemDecl = makeVarDecl(elemName, elemAccess, DeclKind.Const, loc);
		// Propagate element type for nativeLower (tuple → member access)
		if (iterType !== null && iterType.typeReturn !== null) {
			elemDecl.nodeType = iterType.typeReturn;
		}
		whileStmts.push(elemDecl);
		const bindings = expandArrayPattern(d.forOfPattern, makeIdent(elemName, loc), itemDk, loc);
		let pi = 0;
		while (pi < bindings.length) {
			whileStmts.push(bindings[pi]);
			pi += 1;
		}
	} else {
		// Simple binding: const item = $iter[$idx];
		// NodeFlag.Cursor: for-of binding is a borrow from the array — DRC must skip destroy (reference: cursor flag)
		const itemAccess = makeArrayAccess(makeTypedIdent(iterName, iterType, loc), makeTypedIdent(idxName, numberType(), loc), loc);
		const itemDecl = makeVarDecl(d.forOfBinding, itemAccess, itemDk, loc);
		itemDecl.flags = itemDecl.flags | NodeFlag.Cursor;
		whileStmts.push(itemDecl);
	}

	// Increment BEFORE body: continue in user code must not skip $idx++
	// (while-loop continue jumps to condition, skipping trailing statements)
	whileStmts.push(incStmt);

	const bodyStmts = extractBodyStmts(d.forOfBody);
	let bi = 0;
	while (bi < bodyStmts.length) {
		whileStmts.push(bodyStmts[bi]);
		bi += 1;
	}

	const whileCond = makeBinary(makeTypedIdent(idxName, numberType(), loc), "<", makeTypedIdent(lenName, numberType(), loc), loc);
	const whileBody = makeBlock(whileStmts, loc);
	const whileNode = makeWhile(whileCond, whileBody, loc);

	return makeBlock([iterDecl, idxDecl, lenDecl, whileNode], loc);
}

// ===== Pattern Expansion Helper =====

function expandArrayPattern(pattern: Node, baseExpr: Node, dk: DeclKind, loc: SourceLocation): Node[] {
	const apd = pattern.data as ArrayPatternData;
	const items: Node[] = [];
	let i = 0;
	while (i < apd.patternElements.length) {
		const elem = apd.patternElements[i];
		if (elem.kind === NodeKind.Identifier) {
			const id = elem.data as IdentifierData;
			if (id.name !== "_") {
				const access = makeArrayAccess(baseExpr, makeNumber(i, loc), loc);
				items.push(makeVarDecl(id.name, access, dk, loc));
			}
		}
		i += 1;
	}
	return items;
}

// ===== Tests =====
test "for-of becomes block" { assert firstStmtKindAfter("for (const x of arr) { use(x); }", lowerForOf) === NodeKind.BlockStmt; }

test "regular for unchanged" { assert firstStmtKindAfter("for (let i = 0; i < 10; i++) {}", lowerForOf) === NodeKind.ForStmt; }

test "for-of preserves surrounding stmts" { assert stmtCountAfter("x(); for (const i of arr) {} y();", lowerForOf) === 3; }

test "destructured for-of becomes block" { assert firstStmtKindAfter("for (const [a, b] of arr) { use(a); }", lowerForOf) === NodeKind.BlockStmt; }

test "destructured for-of preserves surrounding" { assert stmtCountAfter("x(); for (const [a, b] of arr) {} y();", lowerForOf) === 3; }
