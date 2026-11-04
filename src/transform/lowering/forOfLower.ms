// For-Of Lowering — transforms for-of loops into index-based while loops
// Follows reference for_of_lower.zig
//
// Arrays/Strings (a string yields its bytes as char; arrays and strings check
// their length after each element, as Nim's items in lib/system/iterators.nim):
//   for (const item of arr) { body }
//   → { let $idx = 0; const $len = arr.length;
//       while ($idx < $len) { const item = arr[$idx]; $idx++; body;
//                             if (arr.length != $len) throw "..." } }

import {
	Node, NodeKind, NodeFlag, DeclKind, ForOfStmtData, SourceLocation, ArrayPatternData, IdentifierData, MemberExprData, Type, TypeKind, Symbol, SymbolKind, createNodeAt,
	BlockStmtData, WhileStmtData, IfStmtData, ThrowStmtData, StringLiteralData, VariableDeclData, CallExprData, TypeAssertionData, HiddenStdConvData, HiddenDerefData,
	ArrayAccessData, NumberLiteralData, TryCatchStmtData, BinaryExprData, UpdateExprData, OutExprData,
} from "../../ast/node";
import { TransformContext, SymSet, createSymSet, symSetAdd, symSetContains, freshTempSym } from "../context";
import { forEachChild } from "../../ast/visitor";
import { isAssignOp } from "../../ast/operators";
import { hasFlag, setFlag, makeSymbol, SymbolFlag } from "../../checker/symbol";
import { appendLoopTail } from "./forLoopLower";
import { calleeFormals } from "./jsVarParamLower";
import { receiverIsPlace } from "./operandOrder";
import { withoutOwned, int32Type, charType, stringType, noneType, booleanType, getIteratorReturnFnType, createArray, createSizedArray, createRef, isIterator, isMaybeType, getIteratorNextFnType, peelTransparentInstance } from "../../checker/types";
import { expandArrayRet, expandObjectRet } from "../desugar/destructuringLower";
import { walkNode } from "../walker";
import { clonePlace, isVariantRead } from "../place";
import { isRangeSlice } from "./spanLower";
import {
	makeIdentResolved, makeNumber, makeBlock, makeVarDecl, makeWhile,
	makeBinary, makeUnary, makeAssign, makeExprStmt, makeMember, makeArrayAccess, makeCall,
	makeIf, makeString, runtimeRef, extractBodyStmts, boolToDeclKind, counterType, makeCounterStep,
	makeBool, makeNull, makeBreak, makeTryCatch, makeTryFinally, makeCatchSym,
} from "../util";
import { stmtCountAfter, firstStmtKindAfter, parseInput, getStmts, makeCtx } from "../testUtil";

// ===== Main Entry Point =====

export function lowerForOf(program: Node, ctx: TransformContext): Node {
	return walkNode(program, forOfVisitor(ctx, program));
}

// Closure-returning visitor to capture ctx
function forOfVisitor(ctx: TransformContext, program: Node): (node: Node) => Node {
	const rebound = new Rebound(program);
	return (node: Node): Node => {
		if (node.kind != NodeKind.ForOfStmt) return node;
		const d = node.data as ForOfStmtData;
		const loc = node.location;
		const bindingSym = node.resolvedSym;
		// Detach symbol from ForOfStmt before it's orphaned — prevents DRC double-free
		// (the lowered VarDecl takes ownership of the symbol reference)
		node.resolvedSym = null;

		// Iterator<T>: while + next() pattern (for function* generators)
		const iterType = d.forOfIterable.nodeType != null ? peelTransparentInstance(d.forOfIterable.nodeType) : null;
		if (iterType != null && isIterator(iterType)) {
			return lowerIteratorForOf(d, ctx, loc, bindingSym);
		}

		// Array/String: index-based pattern
		return lowerArrayForOf(d, ctx, loc, bindingSym, rebound);
	};
}

// ===== Iterator For-Of (function* generators) =====
// for (const x of iter) { body }
// → { const $iter = iter;
//     while (true) { const $r = $iter.next(); if ($r.done) break; const x = $r.value; body } }
// The result is local to one step, so it is released before the next call, as the reference lowers
// a closure iterator's loop.

function makeNextCallSym(iterSym: Symbol, resultType: Type | null, loc: SourceLocation): Node {
	const step = makeMember(makeIdentResolved(iterSym, loc), "next", loc);
	step.nodeType = getIteratorNextFnType(peelTransparentInstance(iterSym.symbolType));
	const call = makeCall(step, [], loc);
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
	const rDecl = makeVarDecl(rSym.name, makeNextCallSym(iterSym, resultType, loc), DeclKind.Const, loc);
	rDecl.resolvedSym = rSym;
	if (resultType != null) rDecl.nodeType = resultType;

	const liveSym = freshTempSym(ctx, "live", booleanType());
	const setLive = (on: boolean): Node => makeExprStmt(makeAssign(makeIdentResolved(liveSym, loc), makeBool(on, loc), loc), loc);
	const finished = makeIf(makeMember(makeIdentResolved(rSym, loc), "done", loc), makeBlock([makeBreak(loc)], loc), makeBlock([], loc), loc);
	const bodyStmts: Node[] = [setLive(false), rDecl, finished, setLive(true)];
	const itemType = resultType != null && resultType.typeChildren != null && resultType.typeChildren.length > 0 ? resultType.typeChildren[0] : null;
	const itemDk = boolToDeclKind(d.forOfIsConst);
	const patKind = d.forOfPattern != null ? d.forOfPattern.kind : NodeKind.Identifier;
	if (patKind == NodeKind.ArrayPattern || patKind == NodeKind.ObjectPattern) {
		const elemSym = freshTempSym(ctx, "elem", itemType != null ? itemType : noneType());
		const elemDecl = makeVarDecl(elemSym.name, makeMember(makeIdentResolved(rSym, loc), "value", loc), DeclKind.Const, loc);
		elemDecl.resolvedSym = elemSym;
		if (itemType != null) elemDecl.nodeType = itemType;
		bodyStmts.push(elemDecl);
		const bindings = patKind == NodeKind.ArrayPattern
			? expandArrayRet(d.forOfPattern, makeIdentResolved(elemSym, loc), itemDk, loc, ctx)
			: expandObjectRet(d.forOfPattern, makeIdentResolved(elemSym, loc), itemDk, loc, ctx);
		for (const b of bindings) { bodyStmts.push(b); }
	} else {
		const itemDecl = makeVarDecl(d.forOfBinding, makeMember(makeIdentResolved(rSym, loc), "value", loc), itemDk, loc);
		if (bindingSym != null) itemDecl.resolvedSym = bindingSym;
		// Stamp the binding's resolved element type so downstream passes (generatorLower's
		// collectDeclTypes → env field types, lambdaLifting's typeToEnvStr) see the
		// monomorphized T. Without this, env fields fall back to `void*` and DRC hooks
		// reference `<Type>__unknown` instead of `<Type>__string` etc.
		if (itemType != null) itemDecl.nodeType = itemType;
		bodyStmts.push(itemDecl);
	}
	for (const s of extractBodyStmts(d.forOfBody)) { bodyStmts.push(s); }

	const loop = makeWhile(makeBool(true, loc), makeBlock(bodyStmts, loc), loc);
	const liveDecl = makeVarDecl(liveSym.name, makeBool(false, loc), DeclKind.Let, loc);
	liveDecl.resolvedSym = liveSym;
	stmts.push(liveDecl);
	stmts.push(closeOnAbruptExit(makeBlock([loop], loc), iterSym, liveSym, ctx, loc));
	return makeBlock(stmts, loc);
}

export function closeIterator(iterSym: Symbol, loc: SourceLocation): Node {
	const retType = getIteratorReturnFnType(peelTransparentInstance(iterSym.symbolType));
	const field = (): Node => makeMember(makeIdentResolved(iterSym, loc), "return", loc);
	const present = field();
	present.nodeType = retType;
	const callee = field();
	callee.nodeType = retType != null && isMaybeType(retType) ? retType.typeReturn : retType;
	const call = makeCall(callee, [], loc);
	call.nodeType = callee.nodeType != null ? callee.nodeType.typeReturn : null;
	return makeIf(makeBinary(present, "!==", makeNull(loc), loc), makeBlock([makeExprStmt(call, loc)], loc), null as unknown as Node, loc);
}

function closeOnAbruptExit(loop: Node, iterSym: Symbol, liveSym: Symbol, ctx: TransformContext, loc: SourceLocation): Node {
	const closeIfLive = (swallow: boolean): Node => {
		let close: Node = closeIterator(iterSym, loc);
		if (swallow) close = makeBareCatch(makeBlock([close], loc), loc);
		const off = makeExprStmt(makeAssign(makeIdentResolved(liveSym, loc), makeBool(false, loc), loc), loc);
		return makeIf(makeIdentResolved(liveSym, loc), makeBlock([off, close], loc), null as unknown as Node, loc);
	};
	const caught = makeCatchSym(ctx, "$bodyExc");
	const rethrow = createNodeAt(NodeKind.ThrowStmt, { throwArg: makeIdentResolved(caught, loc) }, loc);
	return makeTryCatch(loop, caught, makeBlock([closeIfLive(true), rethrow], loc), makeBlock([closeIfLive(false)], loc), loc);
}

function makeBareCatch(tryBody: Node, loc: SourceLocation): Node {
	const n = makeTryFinally(tryBody, null as unknown as Node, loc);
	const d = n.data as TryCatchStmtData;
	d.hasCatchClause = true;
	return n;
}

// ===== Array/String For-Of =====

function lowerArrayForOf(d: ForOfStmtData, ctx: TransformContext, loc: SourceLocation, bindingSym: Symbol | null, rebound: Rebound): Node {
	const indexType = counterType(ctx);
	const idxSym = freshTempSym(ctx, "idx", indexType);
	const lenSym = freshTempSym(ctx, "len", indexType);
	const iterType = d.forOfIterable.nodeType != null ? peelTransparentInstance(d.forOfIterable.nodeType) : null;
	// reference array: the iter expr keeps its Ref<Array> type (nativeLower derefs the
	// synthesized .length/[idx] access), but element-type stamping must read through the
	// Ref to the value array so `.typeReturn` yields the element type, not the inner array.
	const isRefArray = iterType != null && iterType.kind == TypeKind.Ref
		&& iterType.typeReturn != null && iterType.typeReturn.kind == TypeKind.Array;
	const elemArrType = isRefArray ? iterType.typeReturn : iterType;
	const isString = iterType != null && iterType.kind == TypeKind.String;
	const lengthCanChange = (isString && !ctx.jsBackend) || (elemArrType != null && elemArrType.kind == TypeKind.Array);

	// A value iterable reached from a symbol is read at its location each element: a snapshot of a
	// value is a heap copy whenever the body writes through the same root, and an address taken once
	// dangles when the body grows an outer array (NIM-REF TR-26). A T[] or a string is read once.
	const iterable = d.forOfIterable;
	const readsLocation = !isRefArray && !isString && (iterable.kind == NodeKind.Identifier
		|| ((iterable.kind == NodeKind.MemberExpr || iterable.kind == NodeKind.ArrayAccess) && isSymbolPath(iterable)));
	const heldByConst = (isRefArray || isString) && iterable.kind == NodeKind.Identifier && cannotRebind(iterable.resolvedSym, rebound);

	const preamble: Node[] = [];
	if (readsLocation) hoistIndices(iterable, ctx, preamble, loc);

	let iterExpr: Node = d.forOfIterable;
	if (!readsLocation && !heldByConst) {
		const iterSym = freshTempSym(ctx, "iter", iterType != null ? iterType : noneType());
		const iterDecl = makeVarDecl(iterSym.name, d.forOfIterable, DeclKind.Const, loc);
		iterDecl.resolvedSym = iterSym;
		preamble.push(iterDecl);
		iterExpr = makeIdentResolved(iterSym, loc);
	}

	// let $idx = 0;
	const idxDecl = makeVarDecl(idxSym.name, makeNumber(0, loc), DeclKind.Let, loc);
	idxDecl.resolvedSym = idxSym;
	idxDecl.nodeType = indexType;
	preamble.push(idxDecl);

	const lenDecl = makeVarDecl(lenSym.name, lengthOf(iterExpr, isString, loc), DeclKind.Const, loc);
	lenDecl.resolvedSym = lenSym;
	lenDecl.nodeType = indexType;
	preamble.push(lenDecl);

	const incStmt = makeCounterStep(idxSym, indexType, loc);

	// Build while body — bindings scoped inside the loop iteration
	const whileStmts: Node[] = [];
	const itemDk = boolToDeclKind(d.forOfIsConst);

	const patKind = d.forOfPattern != null ? d.forOfPattern.kind : NodeKind.Identifier;
	if (patKind == NodeKind.ArrayPattern || patKind == NodeKind.ObjectPattern) {
		// Destructured: const $elem = <iter>[$idx]; const a = $elem[0]; const b = $elem[1]; ...
		const elemType = elemArrType != null && elemArrType.typeReturn != null ? elemArrType.typeReturn : noneType();
		const elemSym = freshTempSym(ctx, "elem", elemType);
		const elemAccess = makeArrayAccess(clonePlace(iterExpr, loc), makeIdentResolved(idxSym, loc), loc);
		elemAccess.flags = elemAccess.flags.incl(NodeFlag.InBounds);
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
			? makeCall(runtimeRef("msStringByteAt", loc), [clonePlace(iterExpr, loc), makeIdentResolved(idxSym, loc)], loc)
			: makeArrayAccess(clonePlace(iterExpr, loc), makeIdentResolved(idxSym, loc), loc);
		itemAccess.flags = itemAccess.flags.incl(NodeFlag.InBounds);
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
			itemDecl.nodeType = withoutOwned(elemArrType.typeReturn);
			itemAccess.nodeType = withoutOwned(elemArrType.typeReturn);
		}
		whileStmts.push(itemDecl);
	}

	// Increment BEFORE body: continue in user code must not skip $idx++
	// (while-loop continue jumps to condition, skipping trailing statements)
	whileStmts.push(incStmt);

	let bodyStmts = extractBodyStmts(d.forOfBody);
	let whileLabel = "";
	if (lengthCanChange) {
		const tail = appendLoopTail(bodyStmts, lengthCheck(iterExpr, lenSym, isString, loc), ctx, loc);
		bodyStmts = tail.tailStmts;
		whileLabel = tail.tailLabel;
	}
	for (const s of bodyStmts) whileStmts.push(s);

	const inRange = makeBinary(makeIdentResolved(idxSym, loc), "<", makeIdentResolved(lenSym, loc), loc);
	const loop = makeWhile(inRange, makeBlock(whileStmts, loc), loc);
	(loop.data as WhileStmtData).whileLabel = whileLabel;
	preamble.push(loop);
	return makeBlock(preamble, loc);
}

// The local variables and parameters some statement of the module assigns, whole or by address.
class Rebound {
	program: Node;
	syms: SymSet | null = null;
	constructor(program: Node) { this.program = program; }
}

function reboundSyms(r: Rebound): SymSet {
	if (r.syms == null) {
		const out = createSymSet();
		collectRebound(r.program, out);
		r.syms = out;
	}
	return r.syms!;
}

// A symbol no statement assigns holds one array for the whole routine, so reading it at each
// element is the once-evaluated read of the iterable: a closure that assigns it counts, as the
// assignment is found wherever it sits in the module.
function cannotRebind(sym: Symbol | null, rebound: Rebound): boolean {
	if (sym == null || (sym.symbolKind != SymbolKind.Variable && sym.symbolKind != SymbolKind.Parameter)) return false;
	if (hasFlag(sym, SymbolFlag.Global) && hasFlag(sym, SymbolFlag.Mutable)) return false;
	if (sym.symbolType != null && sym.symbolType.kind == TypeKind.Var) return false;
	return !symSetContains(reboundSyms(rebound), sym);
}

function collectRebound(node: Node, out: SymSet): void {
	if (node.kind == NodeKind.BinaryExpr) {
		const b = node.data as BinaryExprData;
		if (isAssignOp(b.operator)) addTarget(b.left, out);
	} else if (node.kind == NodeKind.UpdateExpr) {
		addTarget((node.data as UpdateExprData).updateArg, out);
	} else if (node.kind == NodeKind.HiddenAddr) {
		addTarget((node.data as HiddenDerefData).expr, out);
	} else if (node.kind == NodeKind.OutExpr) {
		addTarget((node.data as OutExprData).outArg, out);
	} else if (node.kind == NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		const formals = calleeFormals(d);
		for (let i = 0; i < d.arguments.length; i += 1) {
			if (formals != null && i < formals.length && formals[i] != null && formals[i].kind == TypeKind.Var) addTarget(d.arguments[i], out);
		}
		if (d.callee.kind == NodeKind.MemberExpr && receiverIsPlace(node)) addTarget((d.callee.data as MemberExprData).object, out);
	}
	forEachChild(node, (c: Node): void => collectRebound(c, out));
}

function addTarget(target: Node, out: SymSet): void {
	if (target.kind == NodeKind.ArrayAccess || target.kind == NodeKind.MemberExpr) return;
	if (target.kind == NodeKind.Identifier && target.resolvedSym != null) symSetAdd(out, target.resolvedSym);
	forEachChild(target, (c: Node): void => addTarget(c, out));
}

function lengthCheck(iterExpr: Node, lenSym: Symbol, isString: boolean, loc: SourceLocation): Node {
	const changed = makeBinary(lengthOf(iterExpr, isString, loc), "!=", makeIdentResolved(lenSym, loc), loc);
	const raise = createNodeAt(NodeKind.ThrowStmt, { throwArg: makeString(lengthChangedMessage(isString), loc) }, loc);
	return makeIf(changed, makeBlock([raise], loc), makeBlock([], loc), loc);
}

function lengthChangedMessage(isString: boolean): string {
	return `the length of the ${isString ? "string" : "array"} changed while iterating over it`;
}

export function isArrayLengthGuard(n: Node): boolean {
	if (n.kind != NodeKind.IfStmt) return false;
	const then = (n.data as IfStmtData).consequent;
	if (then.kind != NodeKind.BlockStmt) return false;
	const stmts = (then.data as BlockStmtData).statements;
	if (stmts.length != 1 || stmts[0].kind != NodeKind.ThrowStmt) return false;
	const arg = (stmts[0].data as ThrowStmtData).throwArg;
	if (arg.kind != NodeKind.StringLiteral || (arg.data as StringLiteralData).value != lengthChangedMessage(false)) return false;
	const cond = (n.data as IfStmtData).condition;
	if (cond.kind != NodeKind.BinaryExpr) return false;
	const snapshot = (cond.data as BinaryExprData).right;
	return snapshot.kind == NodeKind.Identifier && snapshot.resolvedSym != null && snapshot.resolvedSym.symbolKind == SymbolKind.Temp;
}

function lengthOf(iterExpr: Node, isString: boolean, loc: SourceLocation): Node {
	if (!isString) return makeMember(clonePlace(iterExpr, loc), "length", loc);
	const call = makeCall(runtimeRef("msStringByteLength", loc), [clonePlace(iterExpr, loc)], loc);
	call.nodeType = int32Type();
	return call;
}

function pathInner(node: Node): Node | null {
	if (node.kind == NodeKind.MemberExpr) return (node.data as MemberExprData).object;
	if (node.kind == NodeKind.HiddenDeref) return (node.data as HiddenDerefData).expr;
	if (node.kind == NodeKind.TypeAssertion) return (node.data as TypeAssertionData).asExpr;
	if (isVariantRead(node)) return (node.data as HiddenStdConvData).convExpr;
	if (node.kind == NodeKind.ArrayAccess && !isRangeSlice(node)) {
		const array = (node.data as ArrayAccessData).array;
		const t = array.nodeType;
		if (t != null && (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray)) return array;
	}
	return null;
}

function isSymbolPath(node: Node): boolean {
	if (node.kind == NodeKind.Identifier) return true;
	const inner = pathInner(node);
	return inner != null && isSymbolPath(inner);
}

function hoistIndices(node: Node, ctx: TransformContext, out: Node[], loc: SourceLocation): void {
	const inner = pathInner(node);
	if (inner == null) return;
	hoistIndices(inner, ctx, out, loc);
	if (node.kind != NodeKind.ArrayAccess) return;
	const d = node.data as ArrayAccessData;
	if (d.index.kind == NodeKind.NumberLiteral) return;
	const atSym = freshTempSym(ctx, "at", d.index.nodeType);
	const atDecl = makeVarDecl(atSym.name, d.index, DeclKind.Const, loc);
	atDecl.resolvedSym = atSym;
	out.push(atDecl);
	d.index = makeIdentResolved(atSym, loc);
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

function lastIsLengthCheck(stmts: Node[]): boolean {
	const guard = stmts[stmts.length - 1];
	if (guard.kind != NodeKind.IfStmt) return false;
	const raise = ((guard.data as IfStmtData).consequent.data as BlockStmtData).statements[0];
	return raise.kind == NodeKind.ThrowStmt
		&& ((raise.data as ThrowStmtData).throwArg.data as StringLiteralData).value.contains("array changed while iterating");
}

test "an array for-of checks the length after the body, under a bounded condition" {
	const loop = loweredLoop(createArray(int32Type()));
	assert (loop.data as WhileStmtData).whileCondition.kind == NodeKind.BinaryExpr;
	assert lastIsLengthCheck(loopBody(loop));
}

test "a continue in the body still reaches the length check" {
	const stmts = loweredStmts("for (const x of arr) { if (x) continue; use(x); }", createArray(int32Type()));
	const body = loopBody(stmts[stmts.length - 1]);
	assert body[2].kind == NodeKind.DoWhileStmt;
	assert lastIsLengthCheck(body);
}

test "a reference array is read once into a temp" {
	const stmts = loweredStmts("for (const x of arr) { use(x); }", createRef(createArray(int32Type())));
	assert stmts.length == 4;
	assert (stmts[0].data as VariableDeclData).initializer.kind == NodeKind.Identifier;
	const len = (stmts[2].data as VariableDeclData).initializer;
	assert ((len.data as MemberExprData).object.data as IdentifierData).name != "arr";
}

function refArrayHeldBy(sym: Symbol, source: string = "for (const x of arr) { use(x); }"): Node[] {
	const parsed = parseInput(source);
	if (!parsed.ok) throw new Error(parsed.error);
	const stmts = getStmts(parsed.value);
	walkNode(parsed.value, (n: Node): Node => {
		if (n.kind == NodeKind.Identifier && (n.data as IdentifierData).name == "arr") n.resolvedSym = sym;
		return n;
	});
	const iter = (stmts[0].data as ForOfStmtData).forOfIterable;
	iter.nodeType = createRef(createArray(int32Type()));
	return (getStmts(lowerForOf(parsed.value, makeCtx()))[0].data as BlockStmtData).statements;
}

function readsThroughArr(stmts: Node[]): boolean {
	if (stmts.length != 3) return false;
	const len = (stmts[1].data as VariableDeclData).initializer;
	return ((len.data as MemberExprData).object.data as IdentifierData).name == "arr";
}

const REASSIGNED = "for (const x of arr) { arr = other; }";

test "a reference array held by a const is read through the const, with no temp" {
	assert readsThroughArr(refArrayHeldBy(makeSymbol("arr", SymbolKind.Variable, null, false)));
}

test "a reference array held by a let nothing assigns is read through the let, with no temp" {
	assert readsThroughArr(refArrayHeldBy(makeSymbol("arr", SymbolKind.Variable, null, true)));
}

test "a reference array held by a parameter nothing assigns is read through the parameter, with no temp" {
	assert readsThroughArr(refArrayHeldBy(makeSymbol("arr", SymbolKind.Parameter, null, false)));
}

test "a reference array held by an outer loop binding nothing assigns is read through the binding, with no temp" {
	const sym = makeSymbol("arr", SymbolKind.Variable, null, false);
	setFlag(sym, SymbolFlag.ForVar);
	assert readsThroughArr(refArrayHeldBy(sym));
}

test "a reference array held by a let the body assigns is read once into a temp" {
	assert refArrayHeldBy(makeSymbol("arr", SymbolKind.Variable, null, true), REASSIGNED).length == 4;
}

test "a reference array held by a parameter the body assigns is read once into a temp" {
	assert refArrayHeldBy(makeSymbol("arr", SymbolKind.Parameter, null, false), REASSIGNED).length == 4;
}

test "a reference array held by an outer loop binding the body assigns is read once into a temp" {
	const sym = makeSymbol("arr", SymbolKind.Variable, null, true);
	setFlag(sym, SymbolFlag.ForVar);
	assert refArrayHeldBy(sym, REASSIGNED).length == 4;
}

test "a reference array held by a parameter that a later statement assigns is read once into a temp" {
	assert refArrayHeldBy(makeSymbol("arr", SymbolKind.Parameter, null, false), "for (const x of arr) { use(x); } arr = other;").length == 4;
}

test "a reference array held by a mutable module variable is read once into a temp" {
	const sym = makeSymbol("arr", SymbolKind.Variable, null, true);
	setFlag(sym, SymbolFlag.Global);
	assert refArrayHeldBy(sym).length == 4;
}

test "an index in a value path is evaluated once, before the loop" {
	const parsed = parseInput("for (const x of g[pick()]) { use(x); }");
	if (!parsed.ok) throw new Error(parsed.error);
	const iter = (getStmts(parsed.value)[0].data as ForOfStmtData).forOfIterable;
	iter.nodeType = createArray(int32Type());
	(iter.data as ArrayAccessData).array.nodeType = createArray(createArray(int32Type()));
	const stmts = (getStmts(lowerForOf(parsed.value, makeCtx()))[0].data as BlockStmtData).statements;
	assert stmts.length == 4;
	assert (stmts[0].data as VariableDeclData).initializer.kind == NodeKind.CallExpr;
	assert ((iter.data as ArrayAccessData).index.kind == NodeKind.Identifier);
}

test "a string for-of binds each byte as a char" {
	const loop = loweredLoop(stringType());
	const item = loopBody(loop)[0];
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
