// For-Of Lowering — transforms for-of loops into index-based while loops
// Follows reference for_of_lower.zig
//
// Arrays/Strings (a string yields its bytes as char; arrays and strings check
// their length after each element, as Nim's items in lib/system/iterators.nim):
//   for (const item of arr) { body }
//   → { let $idx = 0; const $len = arr.length;
//       while (true) { if (arr.length != $len) throw "..."; if (!($idx < $len)) break;
//                      const item = arr[$idx]; $idx++; body } }

import {
	Node, NodeKind, NodeData, DeclKind, ForOfStmtData, SourceLocation, ArrayPatternData, IdentifierData, MemberExprData, Type, TypeKind, Symbol, createNodeAt,
	BlockStmtData, WhileStmtData, IfStmtData, ThrowStmtData, StringLiteralData, VariableDeclData, CallExprData, TypeAssertionData, HiddenStdConvData, HiddenDerefData,
} from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { int32Type, charType, stringType, noneType, createArray, createSizedArray, isIterator, isMaybeType, getIteratorNextFnType } from "../../checker/types";
import { expandArrayRet, expandObjectRet } from "../desugar/destructuringLower";
import { walkNode } from "../walker";
import {
	makeIdentResolved, cloneIdent, makeNumber, makeBlock, makeVarDecl, makeWhile,
	makeBinary, makeUnary, makeAssign, makeExprStmt, makeMember, makeArrayAccess, makeCall,
	makeIf, makeBreak, makeBool, makeString, makeHiddenDeref, runtimeRef, extractBodyStmts, boolToDeclKind,
} from "../util";
import { stmtCountAfter, firstStmtKindAfter, parseInput, getStmts, makeCtx } from "../testUtil";

// ===== Main Entry Point =====

export function lowerForOf(program: Node, ctx: TransformContext): Node {
	return walkNode(program, forOfVisitor(ctx));
}

// Closure-returning visitor to capture ctx
function forOfVisitor(ctx: TransformContext): (node: Node) => Node {
	return (node: Node): Node => {
		if (node.kind != NodeKind.ForOfStmt) return node;
		const d = node.data as ForOfStmtData;
		const loc = node.location;
		const bindingSym = node.resolvedSym;
		// Detach symbol from ForOfStmt before it's orphaned — prevents DRC double-free
		// (the lowered VarDecl takes ownership of the symbol reference)
		node.resolvedSym = null;

		// Iterator<T>: while + next() pattern (for function* generators)
		const iterType = d.forOfIterable.nodeType;
		if (iterType != null && isIterator(iterType)) {
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
	if (resultType != null) call.nodeType = resultType;
	return call;
}

function lowerIteratorForOf(d: ForOfStmtData, ctx: TransformContext, loc: SourceLocation, bindingSym: Symbol | null): Node {
	const iterType = d.forOfIterable.nodeType;
	const iterSym = freshTempSym(ctx, "iter", iterType != null ? iterType : noneType());
	const nextFnType = getIteratorNextFnType(d.forOfIterable.nodeType);
	const resultType = nextFnType != null ? nextFnType.typeReturn : null;
	const rSym = freshTempSym(ctx, "r", resultType != null ? resultType : noneType());

	const stmts: Node[] = [];
	const iterDecl = makeVarDecl(iterSym.name, d.forOfIterable, DeclKind.Const, loc);
	iterDecl.resolvedSym = iterSym;
	stmts.push(iterDecl);
	const rDecl = makeVarDecl(rSym.name, makeNextCallSym(iterSym, resultType, loc), DeclKind.Let, loc);
	rDecl.resolvedSym = rSym;
	if (resultType != null) rDecl.nodeType = resultType;
	stmts.push(rDecl);

	const cond = makeUnary("!", makeMember(makeIdentResolved(rSym, loc), "done", loc), loc);
	const bodyStmts: Node[] = [];
	const itemDecl = makeVarDecl(d.forOfBinding, makeMember(makeIdentResolved(rSym, loc), "value", loc), boolToDeclKind(d.forOfIsConst), loc);
	if (bindingSym != null) itemDecl.resolvedSym = bindingSym;
	// Stamp the binding's resolved element type so downstream passes (generatorLower's
	// collectDeclTypes → env field types, lambdaLifting's typeToEnvStr) see the
	// monomorphized T. Without this, env fields fall back to `void*` and DRC hooks
	// reference `<Type>__unknown` instead of `<Type>__string` etc.
	if (resultType != null && resultType.typeChildren != null && resultType.typeChildren.length > 0) {
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
	const elemArrType = (iterType != null && iterType.kind == TypeKind.Ref
			&& iterType.typeReturn != null && iterType.typeReturn.kind == TypeKind.Array)
		? iterType.typeReturn : iterType;
	const isString = iterType != null && iterType.kind == TypeKind.String;
	const lengthCanChange = isString || (elemArrType != null && elemArrType.kind == TypeKind.Array);

	// Re-read a path of reads from a symbol every iteration, as Nim's items maps such an argument
	// (transf.nim putArgInto, paDirectMapping): a snapshot temp ends its live range inside the
	// loop and costs the element binding its cursor (+40-60% on a Box[] loop, 2026-09-26).
	const iterable = d.forOfIterable;
	const isStableLvalue = iterable.kind == NodeKind.Identifier
		|| (iterable.kind == NodeKind.MemberExpr && isSymbolPath(iterable));

	const preamble: Node[] = [];

	// For non-stable expressions, copy to a temp (evaluated once)
	let iterExpr: Node = d.forOfIterable;
	if (!isStableLvalue) {
		const iterSym = freshTempSym(ctx, "iter", iterType != null ? iterType : noneType());
		const iterDecl = makeVarDecl(iterSym.name, d.forOfIterable, DeclKind.Const, loc);
		iterDecl.resolvedSym = iterSym;
		preamble.push(iterDecl);
		iterExpr = makeIdentResolved(iterSym, loc);
	}

	// let $idx = 0;
	const idxDecl = makeVarDecl(idxSym.name, makeNumber(0, loc), DeclKind.Let, loc);
	idxDecl.resolvedSym = idxSym;
	preamble.push(idxDecl);

	const lenDecl = makeVarDecl(lenSym.name, lengthOf(iterExpr, isString, loc), DeclKind.Const, loc);
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

	const patKind = d.forOfPattern != null ? d.forOfPattern.kind : NodeKind.Identifier;
	if (patKind == NodeKind.ArrayPattern || patKind == NodeKind.ObjectPattern) {
		// Destructured: const $elem = <iter>[$idx]; const a = $elem[0]; const b = $elem[1]; ...
		const elemType = elemArrType != null && elemArrType.typeReturn != null ? elemArrType.typeReturn : noneType();
		const elemSym = freshTempSym(ctx, "elem", elemType);
		const elemAccess = makeArrayAccess(cloneExpr(iterExpr, loc), makeIdentResolved(idxSym, loc), loc);
		const elemDecl = makeVarDecl(elemSym.name, elemAccess, DeclKind.Const, loc);
		elemDecl.resolvedSym = elemSym;
		// Propagate element type for nativeLower (tuple → member access)
		if (elemArrType != null && elemArrType.typeReturn != null) {
			elemDecl.nodeType = elemArrType.typeReturn;
			// Untyped access + Maybe-carried element makes codegen re-wrap the already
			// wrapped element (lit.value = Maybe struct — clang error)
			elemAccess.nodeType = elemArrType.typeReturn;
		}
		whileStmts.push(elemDecl);
		const bindings = patKind == NodeKind.ArrayPattern
			? expandArrayRet(d.forOfPattern, makeIdentResolved(elemSym, loc), itemDk, loc, ctx)
			: expandObjectRet(d.forOfPattern, makeIdentResolved(elemSym, loc), itemDk, loc, ctx);
		let pi = 0;
		while (pi < bindings.length) {
			whileStmts.push(bindings[pi]);
			pi += 1;
		}
	} else {
		// Simple binding: const item = <iter>[$idx];
		const itemAccess = isString
			? makeCall(runtimeRef("msStringByteAt", loc), [cloneExpr(iterExpr, loc), makeIdentResolved(idxSym, loc)], loc)
			: makeArrayAccess(cloneExpr(iterExpr, loc), makeIdentResolved(idxSym, loc), loc);
		const itemDecl = makeVarDecl(d.forOfBinding, itemAccess, itemDk, loc);
		if (bindingSym != null) {
			itemDecl.resolvedSym = bindingSym;
		}
		// Stamp the element type (Array<T>.typeReturn = T after mono) so downstream
		// passes can see the monomorphized binding type. Same reason as the iterator
		// path above — without this, generic for..of bindings degrade to `void*` in
		// generated C and break DRC hook resolution.
		if (isString) {
			itemDecl.nodeType = charType();
			itemAccess.nodeType = charType();
		} else if (elemArrType != null && elemArrType.typeReturn != null) {
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

	const inRange = makeBinary(makeIdentResolved(idxSym, loc), "<", makeIdentResolved(lenSym, loc), loc);
	if (!lengthCanChange) {
		preamble.push(makeWhile(inRange, makeBlock(whileStmts, loc), loc));
		return makeBlock(preamble, loc);
	}

	const changed = makeBinary(lengthOf(iterExpr, isString, loc), "!=", makeIdentResolved(lenSym, loc), loc);
	const message = `the length of the ${isString ? "string" : "array"} changed while iterating over it`;
	const raise = createNodeAt(NodeKind.ThrowStmt, { throwArg: makeString(message, loc) }, loc);
	const guarded: Node[] = [
		makeIf(changed, makeBlock([raise], loc), makeBlock([], loc), loc),
		makeIf(makeUnary("!", inRange, loc), makeBlock([makeBreak(loc)], loc), makeBlock([], loc), loc),
	];
	for (const s of whileStmts) guarded.push(s);
	preamble.push(makeWhile(makeBool(true, loc), makeBlock(guarded, loc), loc));
	return makeBlock(preamble, loc);
}

function lengthOf(iterExpr: Node, isString: boolean, loc: SourceLocation): Node {
	if (!isString) return makeMember(cloneExpr(iterExpr, loc), "length", loc);
	const call = makeCall(runtimeRef("msStringByteLength", loc), [cloneExpr(iterExpr, loc)], loc);
	call.nodeType = int32Type();
	return call;
}

function isSymbolPath(node: Node): boolean {
	if (node.kind == NodeKind.Identifier) return true;
	if (node.kind == NodeKind.MemberExpr) return isSymbolPath((node.data as MemberExprData).object);
	if (node.kind == NodeKind.HiddenDeref) return isSymbolPath((node.data as HiddenDerefData).expr);
	if (node.kind == NodeKind.TypeAssertion) return isSymbolPath((node.data as TypeAssertionData).asExpr);
	if (isVariantRead(node)) return isSymbolPath((node.data as HiddenStdConvData).convExpr);
	return false;
}

function isVariantRead(node: Node): boolean {
	if (node.kind != NodeKind.HiddenSubConv || node.variantSlot <= 0) return false;
	const d = node.data as HiddenStdConvData;
	const from = d.convExpr.nodeType;
	return from != null && from.kind == TypeKind.Union
		&& d.convType.kind != TypeKind.Union && !isMaybeType(d.convType);
}

function cloneExpr(node: Node, loc: SourceLocation): Node {
	if (node.kind == NodeKind.Identifier) {
		return cloneIdent(node, loc);
	}
	if (node.kind == NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		const clone = makeMember(cloneExpr(d.object, loc), d.property, loc);
		clone.nodeType = node.nodeType;
		clone.resolvedSym = node.resolvedSym;
		return clone;
	}
	if (node.kind == NodeKind.HiddenDeref) {
		const clone = makeHiddenDeref(cloneExpr((node.data as HiddenDerefData).expr, loc), loc);
		clone.nodeType = node.nodeType;
		return clone;
	}
	if (node.kind == NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		const clone = createNodeAt(NodeKind.TypeAssertion, { asExpr: cloneExpr(d.asExpr, loc), asType: d.asType } as TypeAssertionData, loc);
		clone.nodeType = node.nodeType;
		clone.flags = node.flags;
		return clone;
	}
	if (isVariantRead(node)) {
		const d = node.data as HiddenStdConvData;
		const clone = createNodeAt(NodeKind.HiddenSubConv, { convExpr: cloneExpr(d.convExpr, loc), convType: d.convType } as NodeData, loc);
		clone.nodeType = node.nodeType;
		clone.flags = node.flags;
		clone.variantSlot = node.variantSlot;
		return clone;
	}
	throw new Error(`internal: for-of re-reads an iterable that is not a symbol path (node kind ${node.kind})`);
}

// ===== Pattern Expansion Helper =====


// ===== Tests =====
test "for-of becomes block" { assert firstStmtKindAfter("for (const x of arr) { use(x); }", lowerForOf) == NodeKind.BlockStmt; }

test "regular for unchanged" { assert firstStmtKindAfter("for (let i = 0; i < 10; i++) {}", lowerForOf) == NodeKind.ForStmt; }

test "for-of preserves surrounding stmts" { assert stmtCountAfter("x(); for (const i of arr) {} y();", lowerForOf) == 3; }

test "destructured for-of becomes block" { assert firstStmtKindAfter("for (const [a, b] of arr) { use(a); }", lowerForOf) == NodeKind.BlockStmt; }

test "destructured for-of preserves surrounding" { assert stmtCountAfter("x(); for (const [a, b] of arr) {} y();", lowerForOf) == 3; }

function loweredStmts(src: string, iterType: Type): Node[] {
	const parsed = parseInput(src);
	if (!parsed.ok) throw new Error(parsed.error);
	const stmt = getStmts(parsed.value)[0];
	(stmt.data as ForOfStmtData).forOfIterable.nodeType = iterType;
	const block = getStmts(lowerForOf(parsed.value, makeCtx()))[0];
	return (block.data as BlockStmtData).statements;
}

function loweredLoop(iterType: Type): Node {
	const stmts = loweredStmts("for (const x of arr) { use(x); }", iterType);
	return stmts[stmts.length - 1];
}

test "a call in the iterable path runs once, into a temp before the loop" {
	const stmts = loweredStmts("for (const x of mk().inner.items) { use(x); }", createArray(stringType()));
	assert stmts.length == 4;
	const iter = (stmts[0].data as VariableDeclData).initializer;
	assert iter.kind == NodeKind.MemberExpr;
	const len = (stmts[2].data as VariableDeclData).initializer;
	assert ((len.data as MemberExprData).object.kind == NodeKind.Identifier);
}

test "a field path from a symbol through a cast is read again at each element" {
	const stmts = loweredStmts("for (const x of (n.data as D).items) { use(x); }", createArray(stringType()));
	assert stmts.length == 3;
	assert stmts[0].kind == NodeKind.VariableDecl;
	assert stmts[2].kind == NodeKind.WhileStmt;
}

function loopBody(loop: Node): Node[] {
	return ((loop.data as WhileStmtData).whileBody.data as BlockStmtData).statements;
}

test "an array for-of raises when the length changed before the next element" {
	const loop = loweredLoop(createArray(int32Type()));
	assert (loop.data as WhileStmtData).whileCondition.kind == NodeKind.BooleanLiteral;
	const guard = loopBody(loop)[0];
	assert guard.kind == NodeKind.IfStmt;
	const raise = ((guard.data as IfStmtData).consequent.data as BlockStmtData).statements[0];
	assert raise.kind == NodeKind.ThrowStmt;
	assert ((raise.data as ThrowStmtData).throwArg.data as StringLiteralData).value.contains("array changed while iterating");
}

test "a string for-of binds each byte as a char" {
	const loop = loweredLoop(stringType());
	const item = loopBody(loop)[2];
	assert item.kind == NodeKind.VariableDecl;
	assert item.nodeType!.kind == TypeKind.Char;
	const read = (item.data as VariableDeclData).initializer;
	assert read.kind == NodeKind.CallExpr;
	assert ((read.data as CallExprData).callee.data as IdentifierData).name == "msStringByteAt";
}

test "a sized array for-of keeps the bounded loop" {
	const loop = loweredLoop(createSizedArray(int32Type(), 3));
	assert (loop.data as WhileStmtData).whileCondition.kind == NodeKind.BinaryExpr;
}
