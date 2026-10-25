// Induction-pointer strength reduction for @computedGoto loops under --danger.
//
//   let pc: int64 = 0;  ... code[pc] ... pc += 1; ... pc = target;
//   → let p: Ptr<int64> = code.data + 0;  ... p[0] ... p += 1; ... p = code.data + target;
//
// A computed-goto dispatch is a CFG the C compiler's own strength reduction cannot follow, so
// `code[pc]` keeps reloading `code.data`. The integer is carried as the pointer instead; a read
// of the integer itself becomes `p - code.data`. A pairing (integer, span) is rewritten whole or
// not at all: any use the pass does not recognise leaves that integer as it is.

import { Node, NodeKind, DeclKind, Symbol, SymbolKind, Type, TypeKind, BlockStmtData, WhileStmtData, FunctionDeclData, ArrayAccessData, BinaryExprData, UnaryExprData, UpdateExprData, ExprStmtData, VariableDeclData, CallExprData, MemberExprData, NumberLiteralData, OutExprData } from "../../ast/node";
import { isRoutineNode } from "../../ast/shape";
import { peelTransparentInstance, peelToRepr, createPtr, getSysType, isIntegerType } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { isComputedGotoMark } from "../../checker/computedGoto";
import { forEachChild, anyChild, anyDescendant, Visit } from "../../ast/visitor";
import { TransformContext, SymSet, createSymSet, symSetAdd, symSetContains, newLoweredSym } from "../context";
import { walkNode, mapChildren } from "../walker";
import { isAssignOp } from "../../ast/operators";
import { makeBinary, makeIdentResolved, makeMember, makeNumber, makeVarDecl, makeHiddenStdConv, makeUnary } from "../util";

class Pairing {
	idx: Symbol;
	span: Symbol;
	elem: Type;
	ptrType: Type;
	ptr: Symbol;
	declAt: number;
	active: boolean;
}

class Induction {
	pairs: Pairing[];
	assigned: SymSet;
	ancestors: Node[];
	closureDepth: number;
	wet: boolean;
	ctx: TransformContext;
	body: Node;
}

export function lowerInductionPointers(program: Node, ctx: TransformContext): Node {
	if (ctx.boundChecks) return program;
	walkNode(program, (n: Node): Node => {
		if (n.kind == NodeKind.FunctionDecl) lowerFunction(n, ctx);
		return n;
	});
	return program;
}

function lowerFunction(fn: Node, ctx: TransformContext): void {
	const body = (fn.data as FunctionDeclData).fnBody;
	if (body == null || body.kind != NodeKind.BlockStmt || !hasComputedGotoLoop(body)) return;
	const st: Induction = { pairs: [], assigned: createSymSet(), ancestors: [], closureDepth: 0, wet: false, ctx, body };
	collectAssigned(body, st);
	collectPairs(body, st);
	let before: int32 = -1;
	while (before != activeCount(st)) {
		before = activeCount(st);
		runPass(body, st);
	}
	if (before == 0) return;
	st.wet = true;
	runPass(body, st);
	const params: Node[] = [];
	for (const p of st.pairs) {
		if (p.active && p.declAt < 0) params.push(pointerDecl(p, makeIdentResolved(p.idx, body.location)));
	}
	if (params.length > 0) {
		const bd = body.data as BlockStmtData;
		bd.statements = params.concat(bd.statements);
	}
}

function activeCount(st: Induction): int32 {
	let n: int32 = 0;
	for (const p of st.pairs) {
		if (p.active) n += 1;
	}
	return n;
}

function runPass(body: Node, st: Induction): void {
	st.ancestors = [];
	st.closureDepth = 0;
	visitChildren(body, st);
}

function hasComputedGotoLoop(n: Node): boolean {
	if (n.kind == NodeKind.WhileStmt) {
		const loopBody = (n.data as WhileStmtData).whileBody;
		if (loopBody.kind == NodeKind.BlockStmt) {
			for (const s of (loopBody.data as BlockStmtData).statements) {
				if (isComputedGotoMark(s)) return true;
			}
		}
	}
	return anyChild(n, hasComputedGotoLoop);
}

function collectAssigned(n: Node, st: Induction): void {
	if (n.kind == NodeKind.BinaryExpr) {
		const d = n.data as BinaryExprData;
		if (isAssignOp(d.operator) && d.left.kind == NodeKind.Identifier && d.left.resolvedSym != null) symSetAdd(st.assigned, d.left.resolvedSym);
	} else if (n.kind == NodeKind.UpdateExpr) {
		const arg = (n.data as UpdateExprData).updateArg;
		if (arg.kind == NodeKind.Identifier && arg.resolvedSym != null) symSetAdd(st.assigned, arg.resolvedSym);
	} else if (n.kind == NodeKind.OutExpr) {
		const arg = (n.data as OutExprData).outArg;
		if (arg != null && arg.kind == NodeKind.Identifier && arg.resolvedSym != null) symSetAdd(st.assigned, arg.resolvedSym);
	}
	forEachChild(n, (c: Node): void => collectAssigned(c, st));
}

function isIndexVar(sym: Symbol | null, st: Induction): boolean {
	if (sym == null || sym.symbolType == null || !symSetContains(st.assigned, sym)) return false;
	if (sym.symbolKind != SymbolKind.Parameter && !(sym.symbolKind == SymbolKind.Variable && hasFlag(sym, SymbolFlag.Mutable))) return false;
	return sym.symbolType.kind == TypeKind.Int32 || sym.symbolType.kind == TypeKind.Int64;
}

function isPlainElem(t: Type | null): boolean {
	if (t == null) return false;
	return isIntegerType(t) || t.kind == TypeKind.Float32 || t.kind == TypeKind.Float64 || t.kind == TypeKind.Boolean;
}

function isOffsetOperand(n: Node): boolean {
	if (n.kind == NodeKind.NumberLiteral) {
		const d = n.data as NumberLiteralData;
		return !d.isFloat;
	}
	const t = peelToRepr(n.nodeType);
	if (t == null) return false;
	return t.kind == TypeKind.Int8 || t.kind == TypeKind.Int16 || t.kind == TypeKind.Int32 || t.kind == TypeKind.Int64 || t.kind == TypeKind.Uint8 || t.kind == TypeKind.Uint16;
}

function mentions(n: Node, sym: Symbol): boolean {
	return anyDescendant(n, (m: Node): Visit => m.kind == NodeKind.Identifier && m.resolvedSym == sym ? Visit.Hit : Visit.Descend);
}

// The index variable `n` is a sum of, with every other term free of that variable and an
// integer; null when `n` has any other shape.
function indexVarOf(n: Node, st: Induction): Symbol | null {
	if (n.kind == NodeKind.Identifier) return isIndexVar(n.resolvedSym, st) ? n.resolvedSym : null;
	if (n.kind != NodeKind.BinaryExpr) return null;
	const d = n.data as BinaryExprData;
	if (d.operator != "+" && d.operator != "-") return null;
	const l = indexVarOf(d.left, st);
	if (l != null && isOffsetOperand(d.right) && !mentions(d.right, l)) return l;
	if (d.operator == "+") {
		const r = indexVarOf(d.right, st);
		if (r != null && isOffsetOperand(d.left) && !mentions(d.left, r)) return r;
	}
	return null;
}

// The terms of `n` other than the index variable `sym`, as one expression; null when none remain.
function restOf(n: Node, sym: Symbol, st: Induction): Node | null {
	if (n.kind == NodeKind.Identifier) return null;
	const d = n.data as BinaryExprData;
	const l = indexVarOf(d.left, st);
	if (l == sym) {
		const rest = restOf(d.left, sym, st);
		if (rest == null) return d.operator == "+" ? d.right : negate(d.right);
		return sumNode(rest, d.operator, d.right, n);
	}
	const rest = restOf(d.right, sym, st);
	if (rest == null) return d.left;
	return sumNode(d.left, "+", rest, n);
}

function sumNode(l: Node, op: string, r: Node, like: Node): Node {
	const sum = makeBinary(l, op, r, like.location);
	sum.nodeType = like.nodeType;
	return sum;
}

function negate(n: Node): Node {
	if (n.kind == NodeKind.NumberLiteral) {
		const folded = makeNumber(-(n.data as NumberLiteralData).value, n.location);
		folded.nodeType = n.nodeType;
		return folded;
	}
	const neg = makeUnary("-", n, n.location);
	neg.nodeType = n.nodeType;
	return neg;
}

function spanElemOf(access: Node): Type | null {
	const d = access.data as ArrayAccessData;
	if (d.array.kind != NodeKind.Identifier || d.array.nodeType == null) return null;
	const t = peelTransparentInstance(d.array.nodeType);
	if (t.kind != TypeKind.Span || !isPlainElem(t.typeReturn)) return null;
	return t.typeReturn;
}

function topLevelDeclIndex(sym: Symbol, st: Induction): number {
	const stmts = (st.body.data as BlockStmtData).statements;
	for (let k = 0; k < stmts.length; k += 1) {
		if (stmts[k].kind == NodeKind.VariableDecl && stmts[k].resolvedSym == sym && (stmts[k].data as VariableDeclData).initializer != null) return k;
	}
	return -2;
}

function collectPairs(n: Node, st: Induction): void {
	if (n.kind == NodeKind.ArrayAccess) {
		const elem = spanElemOf(n);
		const idx = elem != null ? indexVarOf((n.data as ArrayAccessData).index, st) : null;
		if (elem != null && idx != null) addPairing(idx, (n.data as ArrayAccessData).array.resolvedSym, elem, st);
	}
	forEachChild(n, (c: Node): void => collectPairs(c, st));
}

function addPairing(idx: Symbol, spanSym: Symbol | null, elem: Type, st: Induction): void {
	if (spanSym == null) return;
	const span: Symbol = spanSym;
	for (const p of st.pairs) {
		if (p.idx != idx) continue;
		if (p.span != span) p.active = false;
		return;
	}
	const declAt = idx.symbolKind == SymbolKind.Parameter ? -1 : topLevelDeclIndex(idx, st);
	let ok = declAt >= -1;
	if (span.symbolKind == SymbolKind.Variable) {
		const spanAt = topLevelDeclIndex(span, st);
		ok = ok && !hasFlag(span, SymbolFlag.Mutable) && spanAt >= 0 && declAt > spanAt;
	} else if (span.symbolKind != SymbolKind.Parameter) {
		ok = false;
	}
	const ptrType = createPtr(elem);
	const ptr = newLoweredSym(st.ctx, SymbolKind.Variable, "$ptr_" + idx.name, ptrType, true);
	st.pairs.push({ idx, span, elem, ptrType, ptr, declAt, active: ok });
}

function activePairOfIdx(sym: Symbol | null, st: Induction): Pairing | null {
	if (sym == null) return null;
	for (const p of st.pairs) {
		if (p.active && p.idx == sym) return p;
	}
	return null;
}

function spanIsPaired(sym: Symbol | null, st: Induction): boolean {
	if (sym == null) return false;
	for (const p of st.pairs) {
		if (p.active && p.span == sym) return true;
	}
	return false;
}

function reject(p: Pairing, st: Induction): void {
	if (st.wet && p.active) throw new Error("internal: induction pairing for '" + p.idx.name + "' rejected after the survey accepted it");
	p.active = false;
}

function rejectSpan(sym: Symbol, st: Induction): void {
	for (const p of st.pairs) {
		if (p.span == sym) reject(p, st);
	}
}

function visit(node: Node, st: Induction): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.ArrayAccess) return visitAccess(node, st);
	if (node.kind == NodeKind.ExprStmt) return visitStatement(node, st);
	if (node.kind == NodeKind.VariableDecl) return visitDecl(node, st);
	if (node.kind == NodeKind.Identifier) return visitIdentifier(node, st);
	visitChildren(node, st);
	return node;
}

function visitChildren(node: Node, st: Induction): void {
	const fn = isRoutineNode(node);
	if (fn) st.closureDepth += 1;
	st.ancestors.push(node);
	mapChildren(node, (child: Node): Node => visit(child, st));
	st.ancestors.pop();
	if (fn) st.closureDepth -= 1;
}

function parentOf(st: Induction): Node {
	return st.ancestors[st.ancestors.length - 1];
}

function isVarFormal(call: CallExprData, at: number): boolean {
	const t = call.callee.nodeType;
	if (t == null || t.kind != TypeKind.Function || at >= t.typeChildren.length) return true;
	const f = t.typeChildren[at];
	return f == null || f.kind == TypeKind.Var;
}

function callArgIndex(call: CallExprData, n: Node): number {
	for (let k = 0; k < call.arguments.length; k += 1) {
		if (call.arguments[k] == n) return k;
	}
	return -1;
}

function readsAllowed(parent: Node, n: Node): boolean {
	if (parent.kind == NodeKind.BinaryExpr) {
		const d = parent.data as BinaryExprData;
		return !isAssignOp(d.operator) || d.right == n;
	}
	if (parent.kind == NodeKind.ArrayAccess) return (parent.data as ArrayAccessData).array != n;
	if (parent.kind == NodeKind.VariableDecl) return (parent.data as VariableDeclData).initializer == n;
	if (parent.kind == NodeKind.UnaryExpr) {
		const op = (parent.data as UnaryExprData).unaryOp;
		return op == "-" || op == "+" || op == "~";
	}
	if (parent.kind == NodeKind.CallExpr) {
		const d = parent.data as CallExprData;
		const at = callArgIndex(d, n);
		return at >= 0 && !isVarFormal(d, at);
	}
	return parent.kind == NodeKind.ReturnStmt || parent.kind == NodeKind.ConditionalExpr || parent.kind == NodeKind.HiddenStdConv;
}

function spanUseAllowed(parent: Node, n: Node): boolean {
	if (parent.kind == NodeKind.ArrayAccess) return (parent.data as ArrayAccessData).array == n;
	if (parent.kind == NodeKind.MemberExpr) return (parent.data as MemberExprData).object == n;
	if (parent.kind == NodeKind.VariableDecl) return (parent.data as VariableDeclData).initializer == n;
	if (parent.kind == NodeKind.CallExpr) {
		const d = parent.data as CallExprData;
		const at = callArgIndex(d, n);
		return at >= 0 && !isVarFormal(d, at);
	}
	return parent.kind == NodeKind.HiddenStdConv;
}

function visitIdentifier(node: Node, st: Induction): Node {
	const sym = node.resolvedSym;
	const p = activePairOfIdx(sym, st);
	if (p != null) {
		if (st.closureDepth > 0 || !readsAllowed(parentOf(st), node)) {
			reject(p, st);
			return node;
		}
		return st.wet ? currentOffset(p, node) : node;
	}
	if (sym != null && spanIsPaired(sym, st) && (st.closureDepth > 0 || !spanUseAllowed(parentOf(st), node))) rejectSpan(sym, st);
	return node;
}

function spanData(p: Pairing, at: Node): Node {
	const data = makeMember(makeIdentResolved(p.span, at.location), "data", at.location);
	data.nodeType = p.ptrType;
	return data;
}

function currentOffset(p: Pairing, at: Node): Node {
	const diff = makeBinary(makeIdentResolved(p.ptr, at.location), "-", spanData(p, at), at.location);
	diff.nodeType = getSysType(TypeKind.Int64);
	if (p.idx.symbolType.kind == TypeKind.Int64) return diff;
	return makeHiddenStdConv(diff, p.idx.symbolType, at.location);
}

function pointerAt(p: Pairing, offset: Node, at: Node): Node {
	const sum = makeBinary(spanData(p, at), "+", offset, at.location);
	sum.nodeType = p.ptrType;
	return sum;
}

function pointerDecl(p: Pairing, init: Node): Node {
	const decl = makeVarDecl(p.ptr.name, pointerAt(p, init, init), DeclKind.Let, init.location);
	decl.nodeType = p.ptrType;
	decl.resolvedSym = p.ptr;
	return decl;
}

function visitAccess(node: Node, st: Induction): Node {
	const d = node.data as ArrayAccessData;
	const elem = spanElemOf(node);
	const idx = elem != null ? indexVarOf(d.index, st) : null;
	const p = idx != null ? activePairOfIdx(idx, st) : null;
	if (p == null || p.span != d.array.resolvedSym) {
		visitChildren(node, st);
		return node;
	}
	if (st.closureDepth > 0) {
		reject(p, st);
		return node;
	}
	st.ancestors.push(node);
	const rest = restOf(d.index, p.idx, st);
	const offset = rest != null ? visit(rest, st) : makeNumber(0, node.location);
	st.ancestors.pop();
	if (st.wet) {
		d.array = makeIdentResolved(p.ptr, d.array.location);
		d.index = offset;
	}
	return node;
}

function visitDecl(node: Node, st: Induction): Node {
	const d = node.data as VariableDeclData;
	const p = activePairOfIdx(node.resolvedSym, st);
	if (p == null || p.declAt < 0) {
		visitChildren(node, st);
		return node;
	}
	if (st.closureDepth > 0 || mentions(d.initializer, p.idx) || !isOffsetOperand(d.initializer)) {
		reject(p, st);
		return node;
	}
	visitChildren(node, st);
	if (!st.wet) return node;
	return pointerDecl(p, d.initializer);
}

// `i += e`, `i -= e`, `i = i + e`, `i = i - e` step the pointer; `i = e` re-seats it.
function visitStatement(node: Node, st: Induction): Node {
	const sd = node.data as ExprStmtData;
	const e = sd.expr;
	if (e.kind != NodeKind.BinaryExpr) {
		visitChildren(node, st);
		return node;
	}
	const d = e.data as BinaryExprData;
	const p = d.left.kind == NodeKind.Identifier ? activePairOfIdx(d.left.resolvedSym, st) : null;
	if (p == null) {
		visitChildren(node, st);
		return node;
	}
	let op = "";
	let amount = d.right;
	if (d.operator == "+=" || d.operator == "-=") {
		op = d.operator;
	} else if (d.operator == "=") {
		if (indexVarOf(d.right, st) == p.idx) {
			op = "+=";
			const rest = restOf(d.right, p.idx, st);
			amount = rest != null ? rest : makeNumber(0, e.location);
		} else {
			op = "=";
		}
	}
	if (op == "" || st.closureDepth > 0 || mentions(amount, p.idx) || !isOffsetOperand(amount)) {
		reject(p, st);
		return node;
	}
	st.ancestors.push(node);
	const next = visit(amount, st);
	st.ancestors.pop();
	if (!st.wet) return node;
	const target = makeIdentResolved(p.ptr, d.left.location);
	const step = op == "=" ? makeBinary(target, "=", pointerAt(p, next, e), e.location) : makeBinary(target, op, next, e.location);
	step.nodeType = p.ptrType;
	sd.expr = step;
	return node;
}
