// A loop holding no call, no array-variable assignment and no `.length` write cannot change any array
// header, so its arrays are read through a local Span. Admitting any other node kind here breaks
// that rule: a header change inside the loop would go unseen.

import { Node, NodeKind, DeclKind, Symbol, SymbolKind, Type, TypeKind, ProgramData, BlockStmtData, HiddenDerefData, HiddenStdConvData, VariableDeclData, BinaryExprData, UnaryExprData, UpdateExprData, ArrayAccessData, MemberExprData } from "../../ast/node";
import { isRoutineNode } from "../../ast/shape";
import { peelTransparentInstance, peelToRepr, createSpan, isNumeric } from "../../checker/types";
import { forEachChild } from "../../ast/visitor";
import { isAssignOp } from "../../ast/operators";
import { TransformContext, SymSet, createSymSet, symSetAdd, symSetContains, freshTemp, newLoweredSym } from "../context";
import { makeBlock, makeVarDecl, makeIdentResolved, makeHiddenDeref } from "../util";
import { arraySpanLiteral } from "../lowering/spanLower";

class Cached {
	array: Symbol;
	viaDeref: boolean;
	elem: Type;
	span: Symbol;
}

class LoopCache {
	ctx: TransformContext;
	bound: SymSet;
	cached: Cached[];
}

export function lowerLoopSpans(program: Node, ctx: TransformContext): Node {
	if (ctx.jsBackend || ctx.raiserBackend || ctx.boundChecks) return program;
	const st: LoopCache = { ctx, bound: createSymSet(), cached: [] };
	scan(program, st);
	return program;
}

function scan(node: Node, st: LoopCache): void {
	if (node.kind == NodeKind.Program) {
		const d = node.data as ProgramData;
		d.programStmts = scanStatements(d.programStmts, st);
		return;
	}
	if (node.kind == NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		d.statements = scanStatements(d.statements, st);
		return;
	}
	if (isRoutineNode(node)) {
		const outer = st.bound;
		st.bound = createSymSet();
		forEachChild(node, (c: Node): void => scan(c, st));
		st.bound = outer;
		return;
	}
	forEachChild(node, (c: Node): void => scan(c, st));
}

function scanStatements(stmts: Node[], st: LoopCache): Node[] {
	const out: Node[] = [];
	for (const s of stmts) {
		if (s.kind == NodeKind.WhileStmt && cachesDeclaredArrays(s, st)) {
			const scope: Node[] = [];
			for (const c of st.cached) scope.push(spanDecl(c, s));
			rewrite(s, st);
			scope.push(s);
			out.push(makeBlock(scope, s.location));
		} else {
			scan(s, st);
			out.push(s);
		}
		if (s.kind == NodeKind.VariableDecl && s.resolvedSym != null && (s.data as VariableDeclData).initializer != null) symSetAdd(st.bound, s.resolvedSym);
	}
	return out;
}

function cachesDeclaredArrays(loop: Node, st: LoopCache): boolean {
	st.cached = [];
	if (!isHeaderStable(loop, st)) return false;
	return st.cached.length > 0;
}

function isScalar(t: Type | null): boolean {
	const r = peelToRepr(t);
	return r != null && (isNumeric(r) || r.kind == TypeKind.Boolean || r.kind == TypeKind.BooleanLiteral);
}

function plainElem(t: Type | null): boolean {
	const r = peelToRepr(t);
	return r != null && isNumeric(r) && r.kind != TypeKind.Char;
}

function arrayElemOf(sym: Symbol | null, viaDeref: boolean): Type | null {
	if (sym == null || sym.symbolType == null) return null;
	if (sym.symbolKind != SymbolKind.Variable && sym.symbolKind != SymbolKind.Parameter) return null;
	let t = peelTransparentInstance(sym.symbolType);
	if (viaDeref) {
		if ((t.kind != TypeKind.Ref && t.kind != TypeKind.Borrow) || t.typeReturn == null) return null;
		t = peelTransparentInstance(t.typeReturn);
	}
	if (t.kind != TypeKind.Array || !plainElem(t.typeReturn)) return null;
	return t.typeReturn;
}

function isSpanIdent(n: Node): boolean {
	if (n.kind != NodeKind.Identifier || n.nodeType == null) return false;
	const t = peelTransparentInstance(n.nodeType);
	return t.kind == TypeKind.Span && plainElem(t.typeReturn);
}

function arrayIdent(a: Node): Node | null {
	if (a.kind == NodeKind.HiddenDeref) {
		const inner = (a.data as HiddenDerefData).expr;
		return inner.kind == NodeKind.Identifier ? inner : null;
	}
	return a.kind == NodeKind.Identifier ? a : null;
}

function note(sym: Symbol, elem: Type, viaDeref: boolean, st: LoopCache): void {
	for (const c of st.cached) {
		if (c.array == sym) return;
	}
	const span = newLoweredSym(st.ctx, SymbolKind.Variable, freshTemp(st.ctx, "span"), createSpan(elem));
	st.cached.push({ array: sym, viaDeref, elem, span });
}

function allHeaderStable(n: Node, st: LoopCache): boolean {
	let ok = true;
	forEachChild(n, (c: Node): void => {
		if (ok && !isHeaderStable(c, st)) ok = false;
	});
	return ok;
}

function arrayUse(a: Node, st: LoopCache): boolean {
	const id = arrayIdent(a);
	if (id == null) return false;
	if (a == id && isSpanIdent(id)) return true;
	const sym = id.resolvedSym;
	const viaDeref = a != id;
	const elem = arrayElemOf(sym, viaDeref);
	if (sym == null || elem == null) return false;
	if (sym.symbolKind == SymbolKind.Parameter || symSetContains(st.bound, sym)) note(sym, elem, viaDeref, st);
	return true;
}

function isHeaderStable(n: Node, st: LoopCache): boolean {
	if (n.kind == NodeKind.NumberLiteral || n.kind == NodeKind.BooleanLiteral) return true;
	if (n.kind == NodeKind.NullLiteral) return isScalar(n.nodeType);
	if (n.kind == NodeKind.BlockStmt || n.kind == NodeKind.BreakStmt || n.kind == NodeKind.ContinueStmt || n.kind == NodeKind.ExprStmt
			|| n.kind == NodeKind.IfStmt || n.kind == NodeKind.WhileStmt) return allHeaderStable(n, st);
	if (n.kind == NodeKind.VariableDecl) {
		const sym = n.resolvedSym;
		const declared = sym != null && sym.symbolType != null ? sym.symbolType : n.nodeType;
		return (declared == null || isScalar(declared)) && allHeaderStable(n, st);
	}
	if (n.kind == NodeKind.Identifier) {
		const sym = n.resolvedSym;
		return sym != null && isScalar(n.nodeType != null ? n.nodeType : sym.symbolType);
	}
	if (n.kind == NodeKind.ArrayAccess) {
		const d = n.data as ArrayAccessData;
		return isScalar(n.nodeType) && arrayUse(d.array, st) && isHeaderStable(d.index, st);
	}
	if (n.kind == NodeKind.MemberExpr) {
		const d = n.data as MemberExprData;
		return d.property == "length" && !d.isOptional && isScalar(n.nodeType) && arrayUse(d.object, st);
	}
	if (n.kind == NodeKind.BinaryExpr) {
		const d = n.data as BinaryExprData;
		if (isAssignOp(d.operator) && d.left.kind != NodeKind.Identifier && d.left.kind != NodeKind.ArrayAccess) return false;
		return isHeaderStable(d.left, st) && isHeaderStable(d.right, st);
	}
	if (n.kind == NodeKind.UnaryExpr) {
		const op = (n.data as UnaryExprData).unaryOp;
		return (op == "-" || op == "+" || op == "!" || op == "~") && allHeaderStable(n, st);
	}
	if (n.kind == NodeKind.UpdateExpr) {
		const arg = (n.data as UpdateExprData).updateArg;
		return (arg.kind == NodeKind.Identifier || arg.kind == NodeKind.ArrayAccess) && isHeaderStable(arg, st);
	}
	if (n.kind == NodeKind.ConditionalExpr) return allHeaderStable(n, st);
	if (n.kind == NodeKind.TypeAssertion) return isScalar(n.nodeType) && allHeaderStable(n, st);
	if (n.kind == NodeKind.HiddenStdConv || n.kind == NodeKind.HiddenSubConv) {
		return isScalar((n.data as HiddenStdConvData).convType) && allHeaderStable(n, st);
	}
	return false;
}

function spanDecl(c: Cached, at: Node): Node {
	const spanType = c.span.symbolType;
	let source = makeIdentResolved(c.array, at.location);
	if (c.viaDeref) source = makeHiddenDeref(source, at.location);
	const init = arraySpanLiteral(source, c.elem, spanType, at.location);
	const decl = makeVarDecl(c.span.name, init, DeclKind.Const, at.location);
	decl.nodeType = spanType;
	decl.resolvedSym = c.span;
	return decl;
}

function cachedSpan(n: Node, st: LoopCache): Symbol | null {
	const id = arrayIdent(n);
	if (id == null || id.resolvedSym == null) return null;
	for (const c of st.cached) {
		if (c.array == id.resolvedSym) return c.span;
	}
	return null;
}

function rewrite(n: Node, st: LoopCache): void {
	if (n.kind == NodeKind.ArrayAccess) {
		const d = n.data as ArrayAccessData;
		const span = cachedSpan(d.array, st);
		if (span != null) d.array = makeIdentResolved(span, d.array.location);
	} else if (n.kind == NodeKind.MemberExpr) {
		const d = n.data as MemberExprData;
		const span = cachedSpan(d.object, st);
		if (span != null) d.object = makeIdentResolved(span, d.object.location);
	}
	forEachChild(n, (c: Node): void => rewrite(c, st));
}
