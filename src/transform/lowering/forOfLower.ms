// For-Of Lowering — transforms for-of loops into index-based while loops
// Follows reference for_of_lower.zig
//
// Arrays/Strings:
//   for (const item of arr) { body }
//   → { const $iter = arr; let $idx = 0; const $len = $iter.length;
//       while ($idx < $len) { const item = $iter[$idx]; body; $idx++; } }

import { Node, NodeKind, DeclKind, ForOfStmtData, SourceLocation, ArrayPatternData, IdentifierData, MemberExprData, NodeFlag, Type } from "../../ast/node";
import { TransformContext, freshTemp } from "../context";
import { int32Type } from "../../checker/types";
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
	const idxName = freshTemp(ctx, "idx");
	const lenName = freshTemp(ctx, "len");
	const iterType = d.forOfIterable.nodeType;

	// Stable lvalue check: Identifier/MemberExpr can be accessed directly without copy.
	// Value-based arrays in C are {len, p} structs — copying creates a stale p pointer
	// if the loop body pushes to the original (reallocation invalidates the copy).
	// For non-lvalue expressions (calls, etc.), still use a temp to evaluate once.
	const isStableLvalue = d.forOfIterable.kind === NodeKind.Identifier
		|| d.forOfIterable.kind === NodeKind.MemberExpr;

	const preamble: Node[] = [];

	// For non-stable expressions, copy to a temp (evaluated once)
	let iterExpr: Node = d.forOfIterable;
	if (!isStableLvalue) {
		const iterName = freshTemp(ctx, "iter");
		const iterDecl = makeVarDecl(iterName, d.forOfIterable, DeclKind.Const, loc);
		iterDecl.flags = iterDecl.flags | NodeFlag.Cursor;
		preamble.push(iterDecl);
		iterExpr = makeTypedIdent(iterName, iterType, loc);
	}

	// let $idx = 0;
	const idxDecl = makeVarDecl(idxName, makeNumber(0, loc), DeclKind.Let, loc);
	preamble.push(idxDecl);

	// const $len = <iter>.length;  — captured once (new elements from push won't be visited)
	const lenExpr = makeMember(cloneExpr(iterExpr, loc), "length", loc);
	const lenDecl = makeVarDecl(lenName, lenExpr, DeclKind.Const, loc);
	preamble.push(lenDecl);

	// $idx = $idx + 1;
	const increment = makeAssign(
		makeTypedIdent(idxName, int32Type(), loc),
		makeBinary(makeTypedIdent(idxName, int32Type(), loc), "+", makeNumber(1, loc), loc),
		loc
	);
	const incStmt = makeExprStmt(increment, loc);

	// Build while body — bindings scoped inside the loop iteration
	const whileStmts: Node[] = [];
	const itemDk = boolToDeclKind(d.forOfIsConst);

	if (d.forOfPattern !== null && d.forOfPattern.kind === NodeKind.ArrayPattern) {
		// Destructured: const $elem = <iter>[$idx]; const a = $elem[0]; const b = $elem[1]; ...
		const elemName = freshTemp(ctx, "elem");
		const elemAccess = makeArrayAccess(cloneExpr(iterExpr, loc), makeTypedIdent(idxName, int32Type(), loc), loc);
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
		// Simple binding: const item = <iter>[$idx];
		// NodeFlag.Cursor: for-of binding is a borrow from the array — DRC must skip destroy (reference: cursor flag)
		const itemAccess = makeArrayAccess(cloneExpr(iterExpr, loc), makeTypedIdent(idxName, int32Type(), loc), loc);
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

	const whileCond = makeBinary(makeTypedIdent(idxName, int32Type(), loc), "<", makeTypedIdent(lenName, int32Type(), loc), loc);
	const whileBody = makeBlock(whileStmts, loc);
	const whileNode = makeWhile(whileCond, whileBody, loc);

	preamble.push(whileNode);
	return makeBlock(preamble, loc);
}

// Clone a simple expression node (Identifier or MemberExpr) for reuse in lowered code.
// Avoids sharing a single AST node across multiple parents.
function cloneExpr(node: Node, loc: SourceLocation): Node {
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		const clone = makeTypedIdent(d.name, node.nodeType, loc);
		clone.resolvedSym = node.resolvedSym;
		return clone;
	}
	if (node.kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		const clone = makeMember(cloneExpr(d.object, loc), d.property, loc);
		clone.nodeType = node.nodeType;
		clone.resolvedSym = node.resolvedSym;
		return clone;
	}
	// Fallback: return as-is (temp ident from non-lvalue path)
	return node;
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
