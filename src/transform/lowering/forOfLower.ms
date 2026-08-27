// For-Of Lowering — transforms for-of loops into index-based while loops
// Follows reference for_of_lower.zig
//
// Arrays/Strings:
//   for (const item of arr) { body }
//   → { const $iter = arr; let $idx = 0; const $len = $iter.length;
//       while ($idx < $len) { const item = $iter[$idx]; body; $idx++; } }

import { Node, NodeKind, DeclKind, ForOfStmtData, SourceLocation, ArrayPatternData, IdentifierData, MemberExprData, NodeFlag, Type, TypeKind, Symbol } from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { int32Type, noneType, isIterator, getIteratorNextFnType } from "../../checker/types";
import { walkNode } from "../walker";
import {
	makeIdentResolved, makeTypedIdent, makeNumber, makeBlock, makeVarDecl, makeWhile,
	makeBinary, makeUnary, makeAssign, makeExprStmt, makeMember, makeArrayAccess, makeCall,
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
		const bindingSym = node.resolvedSym;
		// Detach symbol from ForOfStmt before it's orphaned — prevents DRC double-free
		// (the lowered VarDecl takes ownership of the symbol reference)
		node.resolvedSym = null;

		// Iterator<T>: while + next() pattern (for function* generators)
		const iterType = d.forOfIterable.nodeType;
		if (iterType !== null && isIterator(iterType)) {
			return lowerIteratorForOf(d, ctx, loc, bindingSym);
		}

		// Array/String: index-based pattern
		return lowerArrayForOf(d, ctx, loc, bindingSym);
	};
}

// ===== Iterator For-Of (function* generators) =====
// for (const x of iter) { body }
// → { const $iter = iter; let $r = $iter.next();
//     while (!$r.done) { const x = $r.value; body; $r = $iter.next(); } }

function makeNextCallSym(iterSym: Symbol, resultType: Type | null, loc: SourceLocation): Node {
	const call = makeCall(makeMember(makeIdentResolved(iterSym, loc), "next", loc), [], loc);
	if (resultType !== null) call.nodeType = resultType;
	return call;
}

function lowerIteratorForOf(d: ForOfStmtData, ctx: TransformContext, loc: SourceLocation, bindingSym: Symbol | null): Node {
	const iterType = d.forOfIterable.nodeType;
	const iterSym = freshTempSym(ctx, "iter", iterType !== null ? iterType : noneType());
	const nextFnType = getIteratorNextFnType(d.forOfIterable.nodeType);
	const resultType = nextFnType !== null ? nextFnType.typeReturn : null;
	const rSym = freshTempSym(ctx, "r", resultType !== null ? resultType : noneType());

	const stmts: Node[] = [];
	const iterDecl = makeVarDecl(iterSym.name, d.forOfIterable, DeclKind.Const, loc);
	iterDecl.resolvedSym = iterSym;
	stmts.push(iterDecl);
	const rDecl = makeVarDecl(rSym.name, makeNextCallSym(iterSym, resultType, loc), DeclKind.Let, loc);
	rDecl.resolvedSym = rSym;
	if (resultType !== null) rDecl.nodeType = resultType;
	stmts.push(rDecl);

	const cond = makeUnary("!", makeMember(makeIdentResolved(rSym, loc), "done", loc), loc);
	const bodyStmts: Node[] = [];
	const itemDecl = makeVarDecl(d.forOfBinding, makeMember(makeIdentResolved(rSym, loc), "value", loc), boolToDeclKind(d.forOfIsConst), loc);
	if (bindingSym !== null) itemDecl.resolvedSym = bindingSym;
	// Stamp the binding's resolved element type so downstream passes (generatorLower's
	// collectDeclTypes → env field types, lambdaLifting's typeToEnvStr) see the
	// monomorphized T. Without this, env fields fall back to `void*` and DRC hooks
	// reference `<Type>__unknown` instead of `<Type>__string` etc.
	if (resultType !== null && resultType.typeChildren !== null && resultType.typeChildren.length > 0) {
		itemDecl.nodeType = resultType.typeChildren[0];
	}
	bodyStmts.push(itemDecl);
	for (const s of extractBodyStmts(d.forOfBody)) { bodyStmts.push(s); }
	bodyStmts.push(makeExprStmt(makeAssign(makeIdentResolved(rSym, loc), makeNextCallSym(iterSym, resultType, loc), loc), loc));

	stmts.push(makeWhile(cond, makeBlock(bodyStmts, loc), loc));
	return makeBlock(stmts, loc);
}

// ===== Array/String For-Of =====

function lowerArrayForOf(d: ForOfStmtData, ctx: TransformContext, loc: SourceLocation, bindingSym: Symbol | null): Node {
	const idxSym = freshTempSym(ctx, "idx", int32Type());
	const lenSym = freshTempSym(ctx, "len", int32Type());
	const iterType = d.forOfIterable.nodeType;
	// reference array: the iter expr keeps its Ref<Array> type (nativeLower derefs the
	// synthesized .length/[idx] access), but element-type stamping must read through the
	// Ref to the value array so `.typeReturn` yields the element type, not the inner array.
	const elemArrType = (iterType !== null && iterType.kind === TypeKind.Ref
			&& iterType.typeReturn !== null && iterType.typeReturn.kind === TypeKind.Array)
		? iterType.typeReturn : iterType;

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
		const iterSym = freshTempSym(ctx, "iter", iterType !== null ? iterType : noneType());
		const iterDecl = makeVarDecl(iterSym.name, d.forOfIterable, DeclKind.Const, loc);
		iterDecl.resolvedSym = iterSym;
		// A fresh owned value (call result / array literal) has no other owner, so the
		// temp must own+destroy it (like `const t = f(); for..of t`). Cursor here would
		// skip destroy and leak the array every iteration. Aliasing rvalues (conditional,
		// type-assertion of an lvalue) stay Cursor to avoid double-free.
		const producesFreshOwned = d.forOfIterable.kind === NodeKind.CallExpr
			|| d.forOfIterable.kind === NodeKind.ArrayLiteral;
		if (!producesFreshOwned) {
			iterDecl.flags = iterDecl.flags | NodeFlag.Cursor;
		}
		preamble.push(iterDecl);
		iterExpr = makeIdentResolved(iterSym, loc);
	}

	// let $idx = 0;
	const idxDecl = makeVarDecl(idxSym.name, makeNumber(0, loc), DeclKind.Let, loc);
	idxDecl.resolvedSym = idxSym;
	preamble.push(idxDecl);

	// const $len = <iter>.length;  — captured once (new elements from push won't be visited)
	const lenExpr = makeMember(cloneExpr(iterExpr, loc), "length", loc);
	const lenDecl = makeVarDecl(lenSym.name, lenExpr, DeclKind.Const, loc);
	lenDecl.resolvedSym = lenSym;
	preamble.push(lenDecl);

	// $idx = $idx + 1;
	const increment = makeAssign(
		makeIdentResolved(idxSym, loc),
		makeBinary(makeIdentResolved(idxSym, loc), "+", makeNumber(1, loc), loc),
		loc
	);
	const incStmt = makeExprStmt(increment, loc);

	// Build while body — bindings scoped inside the loop iteration
	const whileStmts: Node[] = [];
	const itemDk = boolToDeclKind(d.forOfIsConst);

	if (d.forOfPattern !== null && d.forOfPattern.kind === NodeKind.ArrayPattern) {
		// Destructured: const $elem = <iter>[$idx]; const a = $elem[0]; const b = $elem[1]; ...
		const elemType = elemArrType !== null && elemArrType.typeReturn !== null ? elemArrType.typeReturn : noneType();
		const elemSym = freshTempSym(ctx, "elem", elemType);
		const elemAccess = makeArrayAccess(cloneExpr(iterExpr, loc), makeIdentResolved(idxSym, loc), loc);
		const elemDecl = makeVarDecl(elemSym.name, elemAccess, DeclKind.Const, loc);
		elemDecl.resolvedSym = elemSym;
		// Propagate element type for nativeLower (tuple → member access)
		if (elemArrType !== null && elemArrType.typeReturn !== null) {
			elemDecl.nodeType = elemArrType.typeReturn;
			// Untyped access + Maybe-carried element makes codegen re-wrap the already
			// wrapped element (lit.value = Maybe struct — clang error)
			elemAccess.nodeType = elemArrType.typeReturn;
		}
		whileStmts.push(elemDecl);
		const bindings = expandArrayPattern(d.forOfPattern, makeIdentResolved(elemSym, loc), itemDk, loc);
		let pi = 0;
		while (pi < bindings.length) {
			whileStmts.push(bindings[pi]);
			pi += 1;
		}
	} else {
		// Simple binding: const item = <iter>[$idx];
		// NodeFlag.Cursor: for-of binding is a borrow from the array — DRC must skip destroy (reference: cursor flag)
		const itemAccess = makeArrayAccess(cloneExpr(iterExpr, loc), makeIdentResolved(idxSym, loc), loc);
		const itemDecl = makeVarDecl(d.forOfBinding, itemAccess, itemDk, loc);
		itemDecl.flags = itemDecl.flags | NodeFlag.Cursor;
		if (bindingSym !== null) itemDecl.resolvedSym = bindingSym;
		// Stamp the element type (Array<T>.typeReturn = T after mono) so downstream
		// passes can see the monomorphized binding type. Same reason as the iterator
		// path above — without this, generic for..of bindings degrade to `void*` in
		// generated C and break DRC hook resolution.
		if (elemArrType !== null && elemArrType.typeReturn !== null) {
			itemDecl.nodeType = elemArrType.typeReturn;
			itemAccess.nodeType = elemArrType.typeReturn;
		}
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

	const whileCond = makeBinary(makeIdentResolved(idxSym, loc), "<", makeIdentResolved(lenSym, loc), loc);
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
