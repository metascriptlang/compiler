// Array Spread Lower — [...a, x, ...b] → accumulator + push loops (C backend).
//
// The JS backend keeps native spread. C codegen had no lowering at all: the
// SpreadExpr passthrough emitted the source array into an element slot. The
// rewrite stays inside the literal's own type — elements are read one by one
// and pushed into an accumulator of the literal's type — so it never crosses
// the Vec<T> / T[] boundary (that coercion is a separate open hole).
//
//   const b: Vec<int32> = [...a, 3];
//     → const $sps0 = a; let $spa1 = []; let $spi2 = 0;
//       while ($spi2 < $sps0.length) { $spa1.push($sps0[$spi2]); $spi2 = $spi2 + 1; }
//       $spa1.push(3);
//       const b: Vec<int32> = $spa1;

import {
	Node, NodeKind, DeclKind, SourceLocation, createNode,
	ArrayLiteralData, SpreadExprData, IdentifierData, Type, TypeKind,
} from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { int32Type } from "../../checker/types";
import { Symbol } from "../../ast/node";
import { walkExpandBlocks } from "../walker";
import { forEachChild } from "../../ast/visitor";
import {
	makeVarDecl, makeIdentResolved, makeIdent, makeCall, makeMember, makeExprStmt, makeBlock,
	makeWhile, makeBinary, makeNumber, makeAssign, makeArrayAccess, makeHiddenAddr, makeHiddenDeref, syntheticToken,
} from "../util";

function isLowerableSpreadLiteral(node: Node): boolean {
	if (node.kind != NodeKind.ArrayLiteral) return false;
	const t = node.nodeType;
	if (t == null) return false;
	let bare = t;
	if (bare.kind == TypeKind.Ref && bare.typeReturn != null) bare = bare.typeReturn;
	if (bare.kind != TypeKind.Array) return false;
	const d = node.data as ArrayLiteralData;
	for (const e of d.elements) {
		if (e != null && e.kind == NodeKind.SpreadExpr) return true;
	}
	return false;
}

function collectSpreadLiterals(node: Node, out: Node[]): void {
	if (node == null) return;
	forEachChild(node, (c: Node): void => {
		if (c == null) return;
		const k = c.kind;
		if (k == NodeKind.ArrowFunction || k == NodeKind.FunctionExpr
			|| k == NodeKind.FunctionDecl || k == NodeKind.MethodDecl
			|| k == NodeKind.BlockStmt) return;
		collectSpreadLiterals(c, out);
	});
	if (isLowerableSpreadLiteral(node)) out.push(node);
}

function typedRef(sym: Symbol, t: Type | null, loc: SourceLocation): Node {
	const ref = makeIdentResolved(sym, loc);
	ref.nodeType = t;
	return ref;
}

function isRefArray(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.Ref && t.typeReturn != null && t.typeReturn.kind == TypeKind.Array;
}

function bareArrayType(t: Type | null): Type | null {
	if (t == null) return null;
	return t.kind == TypeKind.Ref && t.typeReturn != null ? t.typeReturn : t;
}

function viewRef(sym: Symbol, t: Type | null, loc: SourceLocation): Node {
	if (!isRefArray(t)) return typedRef(sym, t, loc);
	const deref = makeHiddenDeref(typedRef(sym, t, loc), loc);
	deref.nodeType = bareArrayType(t);
	return deref;
}

function pushStmt(accSym: Symbol, accT: Type | null, arg: Node, loc: SourceLocation): Node {
	const args: Node[] = [];
	if (isRefArray(accT)) {
		args.push(typedRef(accSym, accT, loc));
	} else {
		args.push(makeHiddenAddr(typedRef(accSym, accT, loc), loc));
	}
	args.push(arg);
	return makeExprStmt(makeCall(makeIdent("msGenericArrayPush", loc), args, loc), loc);
}

function buildExpansion(lit: Node, ctx: TransformContext, out: Node[]): void {
	const litT = lit.nodeType;
	const loc = lit.location;
	const d = lit.data as ArrayLiteralData;
	const accSym = freshTempSym(ctx, "spra", litT);
	const emptyLit = createNode(NodeKind.ArrayLiteral, { elements: [] }, syntheticToken(loc));
	emptyLit.nodeType = litT;
	const accDecl = makeVarDecl(accSym.name, emptyLit, DeclKind.Let, loc);
	accDecl.resolvedSym = accSym;
	accDecl.nodeType = litT;
	out.push(accDecl);
	for (const e of d.elements) {
		if (e == null) continue;
		if (e.kind != NodeKind.SpreadExpr) {
			out.push(pushStmt(accSym, litT, e, loc));
			continue;
		}
		const sd = e.data as SpreadExprData;
		const srcT = sd.spreadArg.nodeType;
		const srcSym = freshTempSym(ctx, "sprs", srcT);
		const srcDecl = makeVarDecl(srcSym.name, sd.spreadArg, DeclKind.Const, loc);
		srcDecl.resolvedSym = srcSym;
		srcDecl.nodeType = srcT;
		out.push(srcDecl);
		const iSym = freshTempSym(ctx, "spri", int32Type());
		const iDecl = makeVarDecl(iSym.name, makeNumber(0, loc), DeclKind.Let, loc);
		iDecl.resolvedSym = iSym;
		iDecl.nodeType = int32Type();
		out.push(iDecl);
		const elemAccess = makeArrayAccess(viewRef(srcSym, srcT, loc), typedRef(iSym, int32Type(), loc), loc);
		const bareSrc = bareArrayType(srcT);
		elemAccess.nodeType = bareSrc != null ? bareSrc.typeReturn : null;
		const bodyStmts: Node[] = [];
		bodyStmts.push(pushStmt(accSym, litT, elemAccess, loc));
		bodyStmts.push(makeExprStmt(makeAssign(
			typedRef(iSym, int32Type(), loc),
			makeBinary(typedRef(iSym, int32Type(), loc), "+", makeNumber(1, loc), loc),
		loc), loc));
		const lenMember = makeMember(viewRef(srcSym, srcT, loc), "length", loc);
		lenMember.nodeType = int32Type();
		const cond = makeBinary(typedRef(iSym, int32Type(), loc), "<", lenMember, loc);
		out.push(makeWhile(cond, makeBlock(bodyStmts, loc), loc));
	}
	const litData: IdentifierData = { name: accSym.name };
	lit.kind = NodeKind.Identifier;
	lit.data = litData;
	lit.resolvedSym = accSym;
}

function expandStmt(stmt: Node, ctx: TransformContext): Node[] {
	const lits: Node[] = [];
	collectSpreadLiterals(stmt, lits);
	if (lits.length == 0) return [stmt];
	const out: Node[] = [];
	for (const lit of lits) buildExpansion(lit, ctx, out);
	out.push(stmt);
	return out;
}

export function lowerArraySpread(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandStmt, ctx);
	return program;
}
