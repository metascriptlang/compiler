// Guarded block versioning of a checked integer reduction on C:
//
//   while (i < LEN) BODY        BODY: `acc op= xs[i]` or `acc op= a[i] * b[i]` (op is += or -=) and the step of i
//   → while (i < LEN) {
//       const $end = msBlockEnd(i, LEN);
//       if (msSumFits<A><E>(acc, xs, i, $end)) { acc = msSumAdd<A><E>(acc, xs, i, $end); i = $end; }
//       else while (i < $end) BODY
//     }
//
// BODY moves unchanged into the fallback, so a block the guard refuses keeps every check and stops
// at the exact element. Any other loop is left alone.

import { Node, NodeKind, Symbol, Type, TypeKind, DeclKind, SourceLocation, BinaryExprData, CallExprData, BlockStmtData, ExprStmtData, VariableDeclData, MemberExprData, ArrayAccessData, IfStmtData, WhileStmtData, HiddenStdConvData, HiddenDerefData, NumberLiteralData } from "../../ast/node";
import { peelToRepr, getSysType, booleanType } from "../../checker/types";
import { TransformContext, freshTempSym } from "../context";
import { walkNode } from "../walker";
import { makeCall, runtimeRef, makeIdentResolved, cloneIdent, makeVarDecl, makeBlock, makeWhile, makeIf, makeBinary, makeAssign, makeExprStmt, makeHiddenDeref, makeHiddenStdConv, isRuntimeProcCall } from "../util";
import { makeIntNumber } from "../../checker/literalNodes";
import { clonePlace } from "../place";

type Reduce = { acc: Node, op: string, term: Node };
type Reduction = { acc: Node, op: string, arrays: Node[], index: Node, len: Node, widthTag: string };

export function versionReductions(program: Node, ctx: TransformContext): Node {
	if (!ctx.rangeChecks || ctx.jsBackend || ctx.raiserBackend) return program;
	return walkNode(program, (n: Node): Node => n.kind == NodeKind.WhileStmt ? versionLoop(n, ctx) : n);
}

function versionLoop(loop: Node, ctx: TransformContext): Node {
	const r = matchReduction(loop);
	if (r == null) return loop;
	const w = loop.data as WhileStmtData;
	const loc = loop.location;
	const i64 = getSysType(TypeKind.Int64);
	const endSym = freshTempSym(ctx, "end", i64);
	const endCall = makeCall(runtimeRef("msBlockEnd", loc), [ident(r.index, loc), clonePlace(r.len, loc)], loc);
	endCall.nodeType = i64;
	const endDecl = makeVarDecl(endSym.name, endCall, DeclKind.Const, loc);
	endDecl.resolvedSym = endSym;
	endDecl.nodeType = i64;
	const endRef = (): Node => makeIdentResolved(endSym, loc);

	const kind = r.arrays.length == 1 ? "Sum" : "Dot";
	const args = (): Node[] => {
		const out: Node[] = [ident(r.acc, loc)];
		for (const a of r.arrays) out.push(arrayValue(a, loc));
		out.push(ident(r.index, loc));
		out.push(endRef());
		return out;
	};
	let fits = makeCall(runtimeRef(`ms${kind}Fits${r.widthTag}`, loc), args(), loc);
	fits.nodeType = booleanType();
	const indexType = peelToRepr(r.index.nodeType)!;
	if (indexType.kind != TypeKind.Int64) {
		const inRange = makeBinary(endRef(), "<=", makeIntNumber(maxOf(indexType.kind), loc), loc);
		inRange.nodeType = booleanType();
		fits = makeBinary(inRange, "&&", fits, loc);
		fits.nodeType = booleanType();
	}
	const sum = makeCall(runtimeRef(`ms${kind}${r.op == "+=" ? "Add" : "Sub"}${r.widthTag}`, loc), args(), loc);
	sum.nodeType = r.acc.nodeType;
	const step = indexType.kind == TypeKind.Int64 ? endRef() : makeHiddenStdConv(endRef(), r.index.nodeType!, loc);
	const fast = makeBlock([makeExprStmt(makeAssign(ident(r.acc, loc), sum, loc), loc), makeExprStmt(makeAssign(ident(r.index, loc), step, loc), loc)], loc);
	const inBlock = makeBinary(ident(r.index, loc), "<", endRef(), loc);
	inBlock.nodeType = booleanType();
	const checked = makeBlock([makeWhile(inBlock, w.whileBody, loc)], loc);
	return makeWhile(w.whileCondition, makeBlock([endDecl, makeIf(fits, fast, checked, loc)], loc), loc);
}

// ===== Recognizer =====

function matchReduction(loop: Node): Reduction | null {
	const w = loop.data as WhileStmtData;
	if (w.whileLabel != "" || w.whileBody.kind != NodeKind.BlockStmt) return null;
	const cond = w.whileCondition;
	if (cond.kind != NodeKind.BinaryExpr) return null;
	const cd = cond.data as BinaryExprData;
	if (cd.operator != "<" || !isSignedLocal(cd.left)) return null;
	const index = cd.left;
	const stmts = (w.whileBody.data as BlockStmtData).statements;
	return stmts.length == 4 ? matchForOf(stmts, index, cd.right) : stmts.length == 2 ? matchIndexed(stmts, index, cd.right) : null;
}

function matchForOf(stmts: Node[], index: Node, len: Node): Reduction | null {
	if (len.kind != NodeKind.Identifier || len.resolvedSym == null || len.resolvedSym == index.resolvedSym) return null;
	const decl = stmts[0];
	if (decl.kind != NodeKind.VariableDecl || decl.resolvedSym == null) return null;
	const array = elementRead((decl.data as VariableDeclData).initializer, index);
	if (array == null || !isCounterStep(stmts[1], index) || !isLengthCheck(stmts[3], array, len)) return null;
	const reduce = reduceStmt(stmts[2]);
	if (reduce == null) return null;
	const acc = reduce.acc;
	const term = widened(reduce.term, acc);
	if (term == null || term.kind != NodeKind.Identifier || term.resolvedSym != decl.resolvedSym) return null;
	if (!distinctFrom(acc, [index, len, decl])) return null;
	const tag = sumTag(acc, array);
	return tag == "" ? null : { acc, op: reduce.op, arrays: [array], index, len, widthTag: tag };
}

function matchIndexed(stmts: Node[], index: Node, len: Node): Reduction | null {
	if (!isIndexStep(stmts[1], index)) return null;
	const reduce = reduceStmt(stmts[0]);
	if (reduce == null) return null;
	const acc = reduce.acc;
	if (!distinctFrom(acc, [index])) return null;
	const bound = lengthOf(len);
	if (bound == null) return null;
	const term = widened(reduce.term, acc);
	if (term == null) return null;
	let arrays: Node[] = [];
	let tag = "";
	const single = elementRead(term, index);
	if (single != null) {
		arrays = [single];
		tag = sumTag(acc, single);
	} else if (term == reduce.term && isProduct(term)) {
		const factors = (term.data as CallExprData).arguments;
		const a = elementRead(factors[0], index);
		const b = elementRead(factors[1], index);
		if (a == null || b == null) return null;
		arrays = [a, b];
		tag = dotTag(acc, term, a, b);
	}
	if (tag == "" || !readsAnyOf(bound, arrays)) return null;
	for (const a of arrays) if (!distinctFrom(acc, [a]) || rootSym(a) == index.resolvedSym) return null;
	return { acc, op: reduce.op, arrays, index, len, widthTag: tag };
}

function reduceStmt(stmt: Node): Reduce | null {
	if (stmt.kind != NodeKind.ExprStmt) return null;
	const e = (stmt.data as ExprStmtData).expr;
	const add = isRuntimeProcCall(e, "msAddAssign");
	if (!add && !isRuntimeProcCall(e, "msSubAssign")) return null;
	const args = (e.data as CallExprData).arguments;
	if (args.length != 2 || !isSignedLocal(args[0])) return null;
	return { acc: args[0], op: add ? "+=" : "-=", term: args[1] };
}

function widened(term: Node, acc: Node): Node | null {
	if (term.kind != NodeKind.HiddenStdConv) return term;
	const d = term.data as HiddenStdConvData;
	const to = peelToRepr(d.convType);
	const from = signedKind(d.convExpr.nodeType);
	const accKind = signedKind(acc.nodeType);
	if (to == null || from == null || accKind == null || to.kind != accKind || width(from) > width(accKind)) return null;
	return d.convExpr;
}

function elementRead(n: Node, index: Node): Node | null {
	if (n.kind != NodeKind.ArrayAccess) return null;
	const d = n.data as ArrayAccessData;
	if (d.index.kind != NodeKind.Identifier || d.index.resolvedSym != index.resolvedSym) return null;
	if (rootSym(d.array) == null || signedKind(elementType(d.array)) == null) return null;
	return d.array;
}

function rootSym(a: Node): Symbol | null {
	if (a.kind == NodeKind.Identifier) return a.resolvedSym;
	if (a.kind == NodeKind.HiddenDeref) {
		const inner = (a.data as HiddenDerefData).expr;
		return inner.kind == NodeKind.Identifier ? inner.resolvedSym : null;
	}
	return null;
}

function elementType(a: Node): Type | null {
	let t = a.nodeType;
	if (t != null && t.kind == TypeKind.Ref) t = t.typeReturn;
	return t != null && t.kind == TypeKind.Array ? t.typeReturn : null;
}

function lengthOf(n: Node): Node | null {
	if (n.kind != NodeKind.MemberExpr) return null;
	const d = n.data as MemberExprData;
	return d.property == "length" && rootSym(d.object) != null && elementType(d.object) != null ? d.object : null;
}

function readsAnyOf(bound: Node, arrays: Node[]): boolean {
	for (const a of arrays) if (rootSym(a) == rootSym(bound)) return true;
	return false;
}

function isCounterStep(stmt: Node, index: Node): boolean {
	if (stmt.kind != NodeKind.ExprStmt) return false;
	const e = (stmt.data as ExprStmtData).expr;
	if (e.kind != NodeKind.BinaryExpr || (e.data as BinaryExprData).operator != "=") return false;
	const d = e.data as BinaryExprData;
	if (!sameLocal(d.left, index) || d.right.kind != NodeKind.BinaryExpr) return false;
	const add = d.right.data as BinaryExprData;
	return add.operator == "+" && sameLocal(add.left, index) && isOne(add.right);
}

function isIndexStep(stmt: Node, index: Node): boolean {
	if (stmt.kind != NodeKind.ExprStmt) return false;
	const e = (stmt.data as ExprStmtData).expr;
	if (e.kind != NodeKind.CallExpr) return false;
	const args = (e.data as CallExprData).arguments;
	if (isRuntimeProcCall(e, "msPostInc")) return args.length == 1 && sameLocal(args[0], index);
	return isRuntimeProcCall(e, "msAddAssign") && args.length == 2 && sameLocal(args[0], index) && isOne(args[1]);
}

function isProduct(n: Node): boolean {
	if (n.kind != NodeKind.CallExpr || (n.data as CallExprData).arguments.length != 2) return false;
	return isRuntimeProcCall(n, "msMulI8") || isRuntimeProcCall(n, "msMulI16") || isRuntimeProcCall(n, "msMulI32") || isRuntimeProcCall(n, "msMulI64");
}

function isLengthCheck(stmt: Node, array: Node, len: Node): boolean {
	if (stmt.kind != NodeKind.IfStmt) return false;
	const d = stmt.data as IfStmtData;
	if (d.condition.kind != NodeKind.BinaryExpr) return false;
	const c = d.condition.data as BinaryExprData;
	const checked = lengthOf(c.left);
	if (c.operator != "!=" || checked == null || rootSym(checked) != rootSym(array) || !sameLocal(c.right, len)) return false;
	if (d.consequent.kind != NodeKind.BlockStmt) return false;
	const thrown = (d.consequent.data as BlockStmtData).statements;
	if (thrown.length != 1 || thrown[0].kind != NodeKind.ThrowStmt) return false;
	return d.alternate == null || (d.alternate.kind == NodeKind.BlockStmt && (d.alternate.data as BlockStmtData).statements.length == 0);
}

function isOne(n: Node): boolean {
	let e = n;
	while (e.kind == NodeKind.HiddenStdConv) e = (e.data as HiddenStdConvData).convExpr;
	if (e.kind != NodeKind.NumberLiteral) return false;
	const d = e.data as NumberLiteralData;
	return !d.isFloat && d.intVal == 1;
}

function isSignedLocal(n: Node): boolean {
	return n.kind == NodeKind.Identifier && n.resolvedSym != null && signedKind(n.nodeType) != null;
}

function sameLocal(n: Node, local: Node): boolean {
	return n.kind == NodeKind.Identifier && n.resolvedSym != null && n.resolvedSym == local.resolvedSym;
}

function distinctFrom(acc: Node, others: Node[]): boolean {
	for (const o of others) {
		const sym = o.kind == NodeKind.Identifier || o.kind == NodeKind.VariableDecl ? o.resolvedSym : rootSym(o);
		if (sym == acc.resolvedSym) return false;
	}
	return true;
}

// ===== Width tags =====

function sumTag(acc: Node, array: Node): string {
	const a = signedKind(acc.nodeType);
	const e = signedKind(elementType(array));
	if (a == null || e == null || width(e) > width(a)) return "";
	return widthName(a) + widthName(e);
}

function dotTag(acc: Node, product: Node, a: Node, b: Node): string {
	const k = signedKind(acc.nodeType);
	if (k == null || signedKind(product.nodeType) != k || signedKind(elementType(a)) != k || signedKind(elementType(b)) != k) return "";
	return widthName(k);
}

function signedKind(t: Type | null): TypeKind | null {
	const r = peelToRepr(t);
	if (r == null) return null;
	return r.kind == TypeKind.Int8 || r.kind == TypeKind.Int16 || r.kind == TypeKind.Int32 || r.kind == TypeKind.Int64 ? r.kind : null;
}

function width(k: TypeKind): number {
	return match (k) {
		TypeKind.Int8 => 8,
		TypeKind.Int16 => 16,
		TypeKind.Int32 => 32,
		_ => 64,
	};
}

function widthName(k: TypeKind): string {
	return `I${width(k)}`;
}

function maxOf(k: TypeKind): int64 {
	return match (k) {
		TypeKind.Int8 => 127 as int64,
		TypeKind.Int16 => 32767 as int64,
		_ => 2147483647 as int64,
	};
}

// ===== Node builders =====

function ident(n: Node, loc: SourceLocation): Node {
	return cloneIdent(n, loc);
}

function arrayValue(a: Node, loc: SourceLocation): Node {
	const c = clonePlace(a, loc);
	if (c.nodeType != null && c.nodeType.kind == TypeKind.Ref) return makeHiddenDeref(c, loc);
	return c;
}
