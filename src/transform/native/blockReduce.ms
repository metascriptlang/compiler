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

import { Node, NodeKind, Symbol, SymbolKind, Type, TypeKind, DeclKind, SourceLocation, BinaryExprData, FunctionDeclData, ReturnStmtData, CallExprData, BlockStmtData, ExprStmtData, VariableDeclData, MemberExprData, ArrayAccessData, IfStmtData, WhileStmtData, HiddenStdConvData, HiddenDerefData, NumberLiteralData, TypeAssertionData, UpdateExprData } from "../../ast/node";
import { peelStdConv } from "../../ast/shape";
import { isAssignOp } from "../../ast/operators";
import { peelToRepr, peelTransparentInstance, getSysType, booleanType } from "../../checker/types";
import { isRoutineNode } from "../../ast/shape";
import { forEachChild } from "../../ast/visitor";
import { cloneNodeKeepSem } from "../../monomorphize/clone";
import { closureFunction } from "./hcrIndirect";
import { TransformContext, freshTempSym } from "../context";
import { walkNode } from "../walker";
import { makeCall, runtimeRef, makeIdentResolved, cloneIdent, makeVarDecl, makeBlock, makeWhile, makeIf, makeBinary, makeAssign, makeExprStmt, makeHiddenDeref, makeHiddenStdConv, isRuntimeProcCall, generatedRef, extractBodyStmts } from "../util";
import { makeIntNumber } from "../../checker/literalNodes";
import { clonePlace } from "../place";
import { isSignedKind, bitsOfKind, isFloatKind } from "../numKinds";

type Reduce = { acc: Node, op: string, term: Node };
type Reduction = { acc: Node, op: string, arrays: Node[], index: Node, len: Node, widthTag: string, endLimit: int64, bounded: Bounded | null };
type Bounded = { term: Node, lo: int64, hi: int64, tmax: int64 };
type Shape = { consts: Symbol[], inits: Node[], hidden: Symbol[], elem: Symbol | null, array: Node | null, index: Node, acc: Node, limit: int64, reads: int32, loc: SourceLocation };
type Span = { lo: int64, hi: int64, elems: int32, tmax: int64, type: Type | null };
type MapStore = { index: Node, bound: Node, src: Node, dst: Node, param: Symbol, term: Node, step: Node | null, lo: int64, hi: int64, tag: string };
type Affine = { a: int64, b: int64 };
type Callees = { closures: HashMap<Symbol, Symbol>, routines: HashMap<Symbol, Node> };

const INT64_MAX: int64 = 9223372036854775807;

export function versionReductions(program: Node, ctx: TransformContext): Node {
	if (!ctx.rangeChecks || ctx.jsBackend || ctx.raiserBackend) return program;
	const callees: Callees = { closures: new HashMap<Symbol, Symbol>(), routines: new HashMap<Symbol, Node>() };
	const writes = new HashMap<Symbol, int32>();
	collectCallees(program, callees, writes);
	for (const sym of writes.keys()) {
		if (writes.get(sym) != 1) callees.closures.delete(sym);
	}
	return walkNode(program, (n: Node): Node => n.kind == NodeKind.WhileStmt ? versionLoop(n, ctx, callees) : n);
}

function collectCallees(n: Node, c: Callees, writes: HashMap<Symbol, int32>): void {
	if (isRoutineNode(n) && n.resolvedSym != null) c.routines.set(n.resolvedSym, n);
	if (n.kind == NodeKind.VariableDecl && n.resolvedSym != null) {
		const init = (n.data as VariableDeclData).initializer;
		if (init != null && init.kind != NodeKind.NullLiteral) noteWrite(n.resolvedSym!, init, c, writes);
	}
	if (n.kind == NodeKind.BinaryExpr && isAssignOp((n.data as BinaryExprData).operator)) {
		const d = n.data as BinaryExprData;
		if (d.left.kind == NodeKind.Identifier && d.left.resolvedSym != null) noteWrite(d.left.resolvedSym!, d.operator == "=" ? d.right : null, c, writes);
	}
	if (n.kind == NodeKind.UpdateExpr) {
		const arg = (n.data as UpdateExprData).updateArg;
		if (arg.kind == NodeKind.Identifier && arg.resolvedSym != null) noteWrite(arg.resolvedSym!, null, c, writes);
	}
	forEachChild(n, (child: Node): void => collectCallees(child, c, writes));
}

function noteWrite(sym: Symbol, value: Node | null, c: Callees, writes: HashMap<Symbol, int32>): void {
	writes.set(sym, (writes.has(sym) ? writes.get(sym)! : 0) + 1);
	const target = value != null ? closureFunction(value) : null;
	if (target != null && target.resolvedSym != null) c.closures.set(sym, target.resolvedSym!);
}

function versionLoop(loop: Node, ctx: TransformContext, callees: Callees): Node {
	const r = matchReduction(loop);
	if (r == null) {
		const m = matchMapStore(loop, callees);
		return m != null ? mapStoreLoop(m, loop, ctx) : loop;
	}
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

	if (r.bounded != null) return boundedLoop(r, r.bounded, w, endDecl, endRef, loc);
	const kind = r.arrays.length == 1 ? "Sum" : "Dot";
	const args = (): Node[] => {
		const out: Node[] = [ident(r.acc, loc)];
		for (const a of r.arrays) out.push(arrayValue(a, loc));
		out.push(ident(r.index, loc));
		out.push(endRef());
		return out;
	};
	const sumFits = makeCall(runtimeRef(`ms${kind}Fits${r.widthTag}`, loc), args(), loc);
	sumFits.nodeType = booleanType();
	const fits = endWithin(r, indexInRange(r, sumFits, endRef, loc), endRef, loc);
	const indexType = peelToRepr(r.index.nodeType)!;
	const sum = makeCall(runtimeRef(`ms${kind}${r.op == "+=" ? "Add" : "Sub"}${r.widthTag}`, loc), args(), loc);
	sum.nodeType = r.acc.nodeType;
	const step = indexType.kind == TypeKind.Int64 ? endRef() : makeHiddenStdConv(endRef(), r.index.nodeType!, loc);
	const fast = makeBlock([makeExprStmt(makeAssign(ident(r.acc, loc), sum, loc), loc), makeExprStmt(makeAssign(ident(r.index, loc), step, loc), loc)], loc);
	return makeWhile(w.whileCondition, makeBlock([endDecl, makeIf(fits, fast, checkedBlock(r, w, endRef, loc), loc)], loc), loc);
}

function checkedBlock(r: Reduction, w: WhileStmtData, endRef: () => Node, loc: SourceLocation): Node {
	const inBlock = makeBinary(ident(r.index, loc), "<", endRef(), loc);
	inBlock.nodeType = booleanType();
	return makeBlock([makeWhile(inBlock, w.whileBody, loc)], loc);
}

function indexInRange(r: Reduction, fits: Node, endRef: () => Node, loc: SourceLocation): Node {
	const indexType = peelToRepr(r.index.nodeType)!;
	if (indexType.kind == TypeKind.Int64) return fits;
	const inRange = makeBinary(endRef(), "<=", makeIntNumber(maxOf(indexType.kind), loc), loc);
	inRange.nodeType = booleanType();
	const both = makeBinary(inRange, "&&", fits, loc);
	both.nodeType = booleanType();
	return both;
}

function endWithin(r: Reduction, fits: Node, endRef: () => Node, loc: SourceLocation): Node {
	if (r.endLimit <= 0) return fits;
	const below = makeBinary(endRef(), "<=", makeIntNumber(r.endLimit, loc), loc);
	below.nodeType = booleanType();
	const both = makeBinary(below, "&&", fits, loc);
	both.nodeType = booleanType();
	return both;
}

// Each step moves acc by a value in [lo, hi] (+=) or [-hi, -lo] (-=), plus xs[i] when the term reads one, so a
// block whose two end points fit keeps every partial sum in range and the plain adds cannot overflow.
function boundedLoop(r: Reduction, b: Bounded, w: WhileStmtData, endDecl: Node, endRef: () => Node, loc: SourceLocation): Node {
	const i64 = getSysType(TypeKind.Int64);
	const bound = (v: int64): Node => {
		const n = makeIntNumber(v, loc);
		n.nodeType = i64;
		return n;
	};
	const add = r.op == "+=";
	const args = r.arrays.length == 1
		? [ident(r.acc, loc), arrayValue(r.arrays[0], loc), ident(r.index, loc), endRef(), bound(b.lo), bound(b.hi), bound(b.tmax), bound(add ? 0 : 1)]
		: [ident(r.acc, loc), ident(r.index, loc), endRef(), bound(add ? b.lo : -b.hi), bound(add ? b.hi : -b.lo)];
	let fits = makeCall(runtimeRef(r.arrays.length == 1 ? `msRangeSumFits${r.widthTag}` : `msRangeFits${r.widthTag}`, loc), args, loc);
	fits.nodeType = booleanType();
	if (r.endLimit > 0) {
		const zero = makeIntNumber(0, loc);
		zero.nodeType = r.index.nodeType;
		const above = makeBinary(ident(r.index, loc), ">=", zero, loc);
		above.nodeType = booleanType();
		fits = makeBinary(above, "&&", fits, loc);
		fits.nodeType = booleanType();
	}
	fits = endWithin(r, indexInRange(r, fits, endRef, loc), endRef, loc);
	const next = makeBinary(ident(r.acc, loc), add ? "+" : "-", b.term, loc);
	next.nodeType = r.acc.nodeType;
	const one = makeIntNumber(1, loc);
	one.nodeType = r.index.nodeType;
	const stepped = makeBinary(ident(r.index, loc), "+", one, loc);
	stepped.nodeType = r.index.nodeType;
	const inBlock = makeBinary(ident(r.index, loc), "<", endRef(), loc);
	inBlock.nodeType = booleanType();
	const body = makeBlock([makeExprStmt(makeAssign(ident(r.acc, loc), next, loc), loc), makeExprStmt(makeAssign(ident(r.index, loc), stepped, loc), loc)], loc);
	const fast = makeBlock([makeWhile(inBlock, body, loc)], loc);
	return makeWhile(w.whileCondition, makeBlock([endDecl, makeIf(fits, fast, checkedBlock(r, w, endRef, loc), loc)], loc), loc);
}

function matchMapStore(loop: Node, callees: Callees): MapStore | null {
	const w = loop.data as WhileStmtData;
	if (w.whileLabel != "" || w.whileBody.kind != NodeKind.BlockStmt) return null;
	const stmts = (w.whileBody.data as BlockStmtData).statements;
	if (stmts.length != 2 || stmts[0].kind != NodeKind.BlockStmt) return null;
	const bounds: Node[] = [];
	if (!conjunctBounds(w.whileCondition, bounds) || bounds.length == 0) return null;
	const index = (bounds[0].data as BinaryExprData).left;
	const indexType = peelToRepr(index.nodeType);
	if (indexType == null || indexType.kind != TypeKind.Int64 || !isIndexStep(stmts[1], index)) return null;
	const inner = nestedStatements(stmts[0]);
	if (inner.length != 3 && inner.length != 4) return null;
	const xDecl = inner[0];
	const yDecl = inner[1];
	if (xDecl.kind != NodeKind.VariableDecl || yDecl.kind != NodeKind.VariableDecl || xDecl.resolvedSym == null || yDecl.resolvedSym == null) return null;
	const xInit = (xDecl.data as VariableDeclData).initializer;
	const src = xInit != null ? spanRead(xInit, index) : null;
	const call = (yDecl.data as VariableDeclData).initializer;
	if (src == null || call == null || call.kind != NodeKind.CallExpr) return null;
	const cd = call.data as CallExprData;
	const fn = cd.callee.kind == NodeKind.Identifier && cd.callee.resolvedSym != null ? callees.closures.get(cd.callee.resolvedSym) : null;
	const decl = fn != null ? callees.routines.get(fn) : null;
	if (decl == null || decl.paramSyms == null || decl.paramSyms.length != cd.arguments.length || cd.arguments.length == 0) return null;
	if (!sameSym(cd.arguments[0], xDecl.resolvedSym!)) return null;
	for (let k = 1; k < cd.arguments.length; k++) {
		const a = cd.arguments[k];
		if (a.kind != NodeKind.Identifier || a.resolvedSym == null || (a.resolvedSym!.symbolKind != SymbolKind.Variable && a.resolvedSym!.symbolKind != SymbolKind.Temp)) return null;
	}
	const body = extractBodyStmts((decl.data as FunctionDeclData).fnBody);
	if (body.length != 1 || body[0].kind != NodeKind.ReturnStmt) return null;
	const term = (body[0].data as ReturnStmtData).argument;
	const param = decl.paramSyms![0];
	const store = inner[2];
	if (term == null || store.kind != NodeKind.ExprStmt) return null;
	const se = (store.data as ExprStmtData).expr;
	if (se.kind != NodeKind.BinaryExpr || (se.data as BinaryExprData).operator != "=" || !sameSym((se.data as BinaryExprData).right, yDecl.resolvedSym!)) return null;
	const dst = spanRead((se.data as BinaryExprData).left, index);
	if (dst == null) return null;
	let step: Node | null = null;
	if (inner.length == 4) {
		step = floatUnitStep(inner[3]);
		if (step == null || cd.arguments.length < 2 || !sameSym(cd.arguments[1], step.resolvedSym!)) return null;
	}
	const e = signedKind(spanElem(src));
	const dk = signedKind(spanElem(dst));
	if (e == null || dk == null || bitsOfKind(e) > 32 || bitsOfKind(dk) > 32 || signedKind(param.symbolType) != e || signedKind(term.nodeType) != dk || signedKind((se.data as BinaryExprData).right.nodeType) != dk) return null;
	const range: int64[] = [minOfKind(e), kindMax(e)];
	const form = affineOf(term, param, range);
	if (form == null || form.a == 0 || !constrain(form, dk, range) || range[0] > range[1]) return null;
	const bound = boundFor(bounds, src);
	if (bound == null) return null;
	return { index, bound, src, dst, param, term, step, lo: range[0], hi: range[1], tag: widthName(e) };
}

function conjunctBounds(cond: Node, out: Node[]): boolean {
	if (cond.kind != NodeKind.BinaryExpr) return false;
	const d = cond.data as BinaryExprData;
	if (d.operator == "&&") return conjunctBounds(d.left, out) && conjunctBounds(d.right, out);
	if (d.operator != "<" || !isSignedLocal(d.left)) return false;
	if (out.length > 0 && !sameLocal(d.left, (out[0].data as BinaryExprData).left)) return false;
	out.push(cond);
	return true;
}

function boundFor(bounds: Node[], src: Node): Node | null {
	for (const b of bounds) {
		const right = (b.data as BinaryExprData).right;
		if (right.kind == NodeKind.Identifier && signedKind(right.nodeType) == TypeKind.Int64) return right;
	}
	for (const b of bounds) {
		const right = (b.data as BinaryExprData).right;
		const bare = right.kind == NodeKind.TypeAssertion ? (right.data as TypeAssertionData).asExpr : right;
		if (bare.kind == NodeKind.MemberExpr && (bare.data as MemberExprData).property == "length" && sameSym((bare.data as MemberExprData).object, src.resolvedSym!)) return right;
	}
	return null;
}

function spanRead(n: Node, index: Node): Node | null {
	if (n.kind != NodeKind.ArrayAccess) return null;
	const d = n.data as ArrayAccessData;
	if (!sameLocal(d.index, index) || d.array.kind != NodeKind.Identifier || d.array.resolvedSym == null) return null;
	return spanElem(d.array) != null ? d.array : null;
}

function spanElem(n: Node): Type | null {
	if (n.nodeType == null) return null;
	const t = peelTransparentInstance(n.nodeType);
	return t.kind == TypeKind.Span ? t.typeReturn : null;
}

function floatUnitStep(stmt: Node): Node | null {
	if (stmt.kind != NodeKind.ExprStmt) return null;
	const e = (stmt.data as ExprStmtData).expr;
	if (e.kind != NodeKind.BinaryExpr || (e.data as BinaryExprData).operator != "+=") return null;
	const d = e.data as BinaryExprData;
	const t = peelToRepr(d.left.nodeType);
	if (d.left.kind != NodeKind.Identifier || d.left.resolvedSym == null || t == null || !isFloatKind(t.kind)) return null;
	const one = peelStdConv(d.right);
	if (one.kind != NodeKind.NumberLiteral || (one.data as NumberLiteralData).value != 1) return null;
	return d.left;
}

function affineOf(n: Node, p: Symbol, range: int64[]): Affine | null {
	if (n.kind == NodeKind.Identifier) return n.resolvedSym == p ? { a: 1, b: 0 } : null;
	if (n.kind == NodeKind.NumberLiteral) {
		const d = n.data as NumberLiteralData;
		return d.isFloat ? null : { a: 0, b: d.intVal };
	}
	if (n.kind == NodeKind.HiddenStdConv) {
		const d = n.data as HiddenStdConvData;
		const to = signedKind(d.convType);
		const from = signedKind(d.convExpr.nodeType);
		if (to == null || from == null || bitsOfKind(from) > bitsOfKind(to)) return null;
		return affineOf(d.convExpr, p, range);
	}
	const op = checkedOp(n);
	if (op == "") return null;
	const k = signedKind(n.nodeType);
	const args = (n.data as CallExprData).arguments;
	const l = affineOf(args[0], p, range);
	const r = l == null ? null : affineOf(args[1], p, range);
	if (k == null || bitsOfKind(k) > 32 || l == null || r == null) return null;
	let out: Affine;
	if (op == "+") out = { a: l.a + r.a, b: l.b + r.b };
	else if (op == "-") out = { a: l.a - r.a, b: l.b - r.b };
	else if (l.a == 0) out = { a: l.b * r.a, b: l.b * r.b };
	else if (r.a == 0) out = { a: l.a * r.b, b: l.b * r.b };
	else return null;
	const limit: int64 = 2147483648;
	if (out.a > limit || out.a < -limit || out.b > limit * 512 || out.b < -limit * 512) return null;
	return constrain(out, k, range) ? out : null;
}

function checkedOp(n: Node): string {
	if (n.kind != NodeKind.CallExpr || (n.data as CallExprData).arguments.length != 2) return "";
	for (const w of ["I8", "I16", "I32"]) {
		if (isRuntimeProcCall(n, "msAdd" + w)) return "+";
		if (isRuntimeProcCall(n, "msSub" + w)) return "-";
		if (isRuntimeProcCall(n, "msMul" + w)) return "*";
	}
	return "";
}

function constrain(f: Affine, k: TypeKind, range: int64[]): boolean {
	const min = minOfKind(k);
	const max = kindMax(k);
	if (f.a == 0) return f.b >= min && f.b <= max;
	const lo = f.a > 0 ? ceilDiv(min - f.b, f.a) : ceilDiv(max - f.b, f.a);
	const hi = f.a > 0 ? floorDiv(max - f.b, f.a) : floorDiv(min - f.b, f.a);
	if (lo > range[0]) range[0] = lo;
	if (hi < range[1]) range[1] = hi;
	return true;
}

function floorDiv(n: int64, d: int64): int64 {
	const q = n / d;
	return n % d != 0 && (n < 0) != (d < 0) ? q - 1 : q;
}

function ceilDiv(n: int64, d: int64): int64 {
	const q = n / d;
	return n % d != 0 && (n < 0) == (d < 0) ? q + 1 : q;
}

function minOfKind(k: TypeKind): int64 {
	return -maxOf(k) - 1;
}

function sameSym(n: Node, sym: Symbol): boolean {
	return n.kind == NodeKind.Identifier && n.resolvedSym == sym;
}

function mapStoreLoop(m: MapStore, loop: Node, ctx: TransformContext): Node {
	const w = loop.data as WhileStmtData;
	const loc = loop.location;
	const i64 = getSysType(TypeKind.Int64);
	const endSym = freshTempSym(ctx, "end", i64);
	const endCall = makeCall(runtimeRef("msBlockEnd", loc), [ident(m.index, loc), cloneNodeKeepSem(m.bound)], loc);
	endCall.nodeType = i64;
	const endDecl = makeVarDecl(endSym.name, endCall, DeclKind.Const, loc);
	endDecl.resolvedSym = endSym;
	endDecl.nodeType = i64;
	const endRef = (): Node => makeIdentResolved(endSym, loc);
	const int = (v: int64): Node => {
		const n = makeIntNumber(v, loc);
		n.nodeType = i64;
		return n;
	};
	const fits = makeCall(runtimeRef(`msSpanMapFits${m.tag}`, loc), [ident(m.src, loc), ident(m.dst, loc), ident(m.index, loc), endRef(), int(m.lo), int(m.hi)], loc);
	fits.nodeType = booleanType();
	const read = makeCall(generatedRef("msSpanAccessUnchecked", loc), [ident(m.src, loc), ident(m.index, loc)], loc);
	read.nodeType = m.param.symbolType;
	const slot = makeCall(generatedRef("msSpanAccessUnchecked", loc), [ident(m.dst, loc), ident(m.index, loc)], loc);
	slot.nodeType = m.term.nodeType;
	const stepped = makeBinary(ident(m.index, loc), "+", int(1), loc);
	stepped.nodeType = m.index.nodeType;
	const inBlock = (): Node => {
		const c = makeBinary(ident(m.index, loc), "<", endRef(), loc);
		c.nodeType = booleanType();
		return c;
	};
	const store = makeExprStmt(makeAssign(slot, plainTerm(m.term, read, loc), loc), loc);
	const fast: Node[] = [];
	if (m.step != null) {
		const count = makeBinary(endRef(), "-", ident(m.index, loc), loc);
		count.nodeType = i64;
		const advanced = makeBinary(ident(m.step!, loc), "+", makeHiddenStdConv(count, m.step!.nodeType!, loc), loc);
		advanced.nodeType = m.step!.nodeType;
		fast.push(makeExprStmt(makeAssign(ident(m.step!, loc), advanced, loc), loc));
	}
	fast.push(makeWhile(inBlock(), makeBlock([store, makeExprStmt(makeAssign(ident(m.index, loc), stepped, loc), loc)], loc), loc));
	const slowCond = makeBinary(inBlock(), "&&", cloneNodeKeepSem(w.whileCondition), loc);
	slowCond.nodeType = booleanType();
	const slow = makeBlock([makeWhile(slowCond, w.whileBody, loc)], loc);
	return makeWhile(w.whileCondition, makeBlock([endDecl, makeIf(fits, makeBlock(fast, loc), slow, loc)], loc), loc);
}

function plainTerm(n: Node, read: Node, loc: SourceLocation): Node {
	if (n.kind == NodeKind.Identifier) return cloneNodeKeepSem(read);
	if (n.kind == NodeKind.NumberLiteral) {
		const c = makeIntNumber((n.data as NumberLiteralData).intVal, loc);
		c.nodeType = n.nodeType;
		return c;
	}
	if (n.kind == NodeKind.HiddenStdConv) {
		const d = n.data as HiddenStdConvData;
		return makeHiddenStdConv(plainTerm(d.convExpr, read, loc), d.convType, loc);
	}
	const args = (n.data as CallExprData).arguments;
	const out = makeBinary(plainTerm(args[0], read, loc), checkedOp(n), plainTerm(args[1], read, loc), loc);
	out.nodeType = n.nodeType;
	return out;
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
	if (stmts.length == 4) return matchForOf(stmts, index, cd.right);
	if (stmts.length != 2) return null;
	if (stmts[0].kind != NodeKind.BlockStmt) return matchIndexed(stmts, index, cd.right);
	const element = matchElementLocal(stmts, index, cd.right);
	return element != null ? element : matchBoundedTerm(stmts, index, cd.right);
}

// The fused loop of an array iterator, then the step of i, bounded by `xs.length` read each step (through
// `as int64`): values() reads `{ const x = xs[i]; { acc op= x } }`; keys() reads `{ const k = i & M; const key =
// k as number; { acc op= xs[k] } }`, where k is i for every block that ends at or below M + 1.
function matchElementLocal(stmts: Node[], index: Node, len: Node): Reduction | null {
	if (!isIndexStep(stmts[1], index)) return null;
	const inner = nestedStatements(stmts[0]);
	if (inner.length < 2 || inner[0].kind != NodeKind.VariableDecl || inner[0].resolvedSym == null) return null;
	const decl = inner[0];
	const init = (decl.data as VariableDeclData).initializer;
	const limit = maskedIndexLimit(init, index);
	for (let k = 1; k < inner.length - 1; k++) {
		if (limit == 0 || !castOf(inner[k], decl)) return null;
	}
	const reduce = reduceStmt(inner[inner.length - 1]);
	if (reduce == null || (limit == 0 && inner.length != 2)) return null;
	const acc = reduce.acc;
	const term = widened(reduce.term, acc);
	if (term == null) return null;
	const array = limit > 0 ? keyedRead(term, decl) : elementRead(init, index);
	if (array == null || (limit == 0 && (term.kind != NodeKind.Identifier || term.resolvedSym != decl.resolvedSym))) return null;
	const bareLen = len.kind == NodeKind.TypeAssertion ? (len.data as TypeAssertionData).asExpr : len;
	const bound = lengthOf(bareLen);
	if (bound == null || !readsAnyOf(bound, [array]) || !distinctFrom(acc, [index, decl, array])) return null;
	const tag = sumTag(acc, array);
	return tag == "" ? null : { acc, op: reduce.op, arrays: [array], index, len: bareLen, widthTag: tag, endLimit: limit, bounded: null };
}

// A fused loop whose term adds nonnegative parts of a static range (`e & C`, a literal) and at most one `xs[i]`:
// a generator's `{ const x = i; { acc op= (x ^ s) & C } }` under a local limit, or entries()' `{ const k = i & M;
// const key = k as number; const x = xs[i]; { acc op= x + ((k as int32) & 1) } }`. A mask bounds a step whatever
// its operands hold, so they need only be pure; a narrowing check of a value read from i holds for every block
// that starts at or above 0 and ends at or below its maximum + 1.
function matchBoundedTerm(stmts: Node[], index: Node, len: Node): Reduction | null {
	if (!isIndexStep(stmts[1], index)) return null;
	const inner = nestedStatements(stmts[0]);
	const reduce = inner.length > 0 ? reduceStmt(inner[inner.length - 1]) : null;
	if (reduce == null) return null;
	const acc = reduce.acc;
	const bareLen = len.kind == NodeKind.TypeAssertion ? (len.data as TypeAssertionData).asExpr : len;
	const local = isSignedLocal(bareLen) && !sameLocal(bareLen, index);
	if ((!local && lengthOf(bareLen) == null) || !distinctFrom(acc, local ? [index, bareLen] : [index])) return null;
	const s: Shape = { consts: [], inits: [], hidden: [], elem: null, array: null, index, acc, limit: 0, reads: 0, loc: acc.location };
	for (let k = 0; k < inner.length - 1; k++) {
		const decl = inner[k];
		if (decl.kind != NodeKind.VariableDecl || decl.resolvedSym == null) return null;
		const init = (decl.data as VariableDeclData).initializer;
		if (init == null) return null;
		const read = elementRead(init, index);
		if (read != null && s.elem == null) {
			s.elem = decl.resolvedSym;
			s.array = read;
		} else if (cloneTerm(init, s, false) != null) {
			s.consts.push(decl.resolvedSym!);
			s.inits.push(init);
		} else if (init.kind == NodeKind.TypeAssertion || init.kind == NodeKind.HiddenStdConv) {
			s.hidden.push(decl.resolvedSym!);
		} else return null;
	}
	const top = widened(reduce.term, acc);
	const span = top == null ? null : spanOf(top, s);
	s.reads = 0;
	const term = span == null ? null : cloneTerm(reduce.term, s, true);
	if (span == null || term == null || span.elems > 1 || s.reads > span.elems) return null;
	const array = span.elems == 1 ? s.array : null;
	if (array != null && !distinctFrom(acc, [array])) return null;
	if (array == null && span.hi > span.tmax) return null;
	const k = signedKind(acc.nodeType);
	const tag = array != null ? sumTag(acc, array) : k != null ? widthName(k) : "";
	if (tag == "") return null;
	return { acc, op: reduce.op, arrays: array != null ? [array] : [], index, len: bareLen, widthTag: tag, endLimit: s.limit, bounded: { term, lo: span.lo, hi: span.hi, tmax: span.tmax } };
}

function spanOf(n: Node, s: Shape): Span | null {
	const k = signedKind(n.nodeType);
	if (k == null) return null;
	if (n.kind == NodeKind.HiddenStdConv) {
		const inner = spanOf((n.data as HiddenStdConvData).convExpr, s);
		return inner != null && bitsOfKind(signedKind(inner.type)!) <= bitsOfKind(k) ? { lo: inner.lo, hi: inner.hi, elems: inner.elems, tmax: inner.tmax, type: n.nodeType } : null;
	}
	const mask = maskOf(n);
	if (mask >= 0) return { lo: 0, hi: mask, elems: 0, tmax: kindMax(k), type: n.nodeType };
	if (n.kind == NodeKind.NumberLiteral) {
		const d = n.data as NumberLiteralData;
		return !d.isFloat && d.intVal >= 0 ? { lo: d.intVal, hi: d.intVal, elems: 0, tmax: kindMax(k), type: n.nodeType } : null;
	}
	if (n.kind == NodeKind.Identifier && n.resolvedSym != null) {
		if (n.resolvedSym == s.elem) return { lo: 0, hi: 0, elems: 1, tmax: kindMax(k), type: n.nodeType };
		const at = s.consts.indexOf(n.resolvedSym!);
		return at < 0 ? null : spanOf(s.inits[at], s);
	}
	if (!isCheckedAdd(n)) return null;
	const args = (n.data as CallExprData).arguments;
	const a = spanOf(args[0], s);
	const b = a == null ? null : spanOf(args[1], s);
	if (a == null || b == null) return null;
	const tmax = minOf(minOf(a.tmax, b.tmax), kindMax(k));
	return { lo: a.lo + b.lo, hi: a.hi + b.hi, elems: a.elems + b.elems, tmax, type: n.nodeType };
}

function maskOf(n: Node): int64 {
	const k = signedKind(n.nodeType);
	if (k == null || n.kind != NodeKind.BinaryExpr || (n.data as BinaryExprData).operator != "&") return -1;
	const d = n.data as BinaryExprData;
	for (const side of [peelStdConv(d.left), peelStdConv(d.right)]) {
		if (side.kind != NodeKind.NumberLiteral) continue;
		const m = side.data as NumberLiteralData;
		if (!m.isFloat && m.intVal >= 0 && m.intVal < 9007199254740992 && m.intVal <= kindMax(k)) return m.intVal;
	}
	return -1;
}

// The term as the fast block runs it: each const replaced by its own term, `xs[i]` read without its bound check
// (the guard holds 0 <= i and end <= xs.length), a checked add as a plain one only where spanOf bounded it
// (`proven`: not under a mask, whose operands may hold anything), a narrowing check of a value read from i as a
// cast (the guard holds 0 <= i and end <= maximum + 1).
function cloneTerm(n: Node, s: Shape, proven: boolean): Node | null {
	const loc = s.loc;
	if (n.kind == NodeKind.Identifier) {
		const sym = n.resolvedSym;
		if (sym == null || sym == s.acc.resolvedSym || s.hidden.indexOf(sym!) >= 0 || signedKind(n.nodeType) == null) return null;
		if (sym == s.elem) {
			s.reads++;
			const read = makeCall(generatedRef("msArrayAccessUnchecked", loc), [arrayValue(s.array!, loc), ident(s.index, loc)], loc);
			read.nodeType = n.nodeType;
			return read;
		}
		const at = s.consts.indexOf(sym!);
		return at < 0 ? cloneIdent(n, loc) : cloneTerm(s.inits[at], s, proven);
	}
	if (n.kind == NodeKind.NumberLiteral) {
		const d = n.data as NumberLiteralData;
		if (d.isFloat || signedKind(n.nodeType) == null) return null;
		const c = makeIntNumber(d.intVal, loc);
		c.nodeType = n.nodeType;
		return c;
	}
	if (n.kind == NodeKind.HiddenStdConv) {
		const d = n.data as HiddenStdConvData;
		const to = signedKind(d.convType);
		const from = signedKind(d.convExpr.nodeType);
		if (to == null || from == null || bitsOfKind(from) > bitsOfKind(to)) return null;
		const inner = cloneTerm(d.convExpr, s, proven);
		return inner == null ? null : makeHiddenStdConv(inner, d.convType, loc);
	}
	if (isCheckedAdd(n)) {
		if (!proven) return null;
		const args = (n.data as CallExprData).arguments;
		const left = cloneTerm(args[0], s, true);
		const right = left == null ? null : cloneTerm(args[1], s, true);
		if (left == null || right == null) return null;
		const sum = makeBinary(left, "+", right, loc);
		sum.nodeType = n.nodeType;
		return sum;
	}
	const narrowed = narrowedIndex(n, s);
	if (narrowed != null) return narrowed;
	if (n.kind != NodeKind.BinaryExpr || signedKind(n.nodeType) == null) return null;
	const d = n.data as BinaryExprData;
	if (d.operator != "&" && d.operator != "|" && d.operator != "^") return null;
	const left = cloneTerm(d.left, s, false);
	const right = left == null ? null : cloneTerm(d.right, s, false);
	if (left == null || right == null) return null;
	const out = makeBinary(left, d.operator, right, loc);
	out.nodeType = n.nodeType;
	return out;
}

function narrowedIndex(n: Node, s: Shape): Node | null {
	if (!isRuntimeProcCall(n, "msCheckRangeI8") && !isRuntimeProcCall(n, "msCheckRangeI16") && !isRuntimeProcCall(n, "msCheckRangeI32")) return null;
	const args = (n.data as CallExprData).arguments;
	if (args.length != 3 || !readsIndex(args[0], s) || n.nodeType == null) return null;
	const value = cloneTerm(args[0], s, false);
	if (value == null) return null;
	const k = signedKind(n.nodeType);
	if (k == null) return null;
	const limit = maxOf(k) + 1;
	s.limit = s.limit == 0 || limit < s.limit ? limit : s.limit;
	return makeHiddenStdConv(value, n.nodeType!, s.loc);
}

// A value no larger than i and no smaller than 0 while i >= 0: i, `v & C` with C >= 0, or a const holding one.
function readsIndex(n: Node, s: Shape): boolean {
	if (n.kind == NodeKind.HiddenStdConv) return readsIndex((n.data as HiddenStdConvData).convExpr, s);
	if (n.kind == NodeKind.Identifier) {
		if (sameLocal(n, s.index)) return true;
		const at = n.resolvedSym != null ? s.consts.indexOf(n.resolvedSym!) : -1;
		return at >= 0 && readsIndex(s.inits[at], s);
	}
	if (n.kind != NodeKind.BinaryExpr || (n.data as BinaryExprData).operator != "&") return false;
	const d = n.data as BinaryExprData;
	const l = peelStdConv(d.left);
	const r = peelStdConv(d.right);
	if (r.kind == NodeKind.NumberLiteral) return !(r.data as NumberLiteralData).isFloat && (r.data as NumberLiteralData).intVal >= 0 && readsIndex(d.left, s);
	if (l.kind == NodeKind.NumberLiteral) return !(l.data as NumberLiteralData).isFloat && (l.data as NumberLiteralData).intVal >= 0 && readsIndex(d.right, s);
	return false;
}

function isCheckedAdd(n: Node): boolean {
	if (n.kind != NodeKind.CallExpr || (n.data as CallExprData).arguments.length != 2) return false;
	return isRuntimeProcCall(n, "msAddI8") || isRuntimeProcCall(n, "msAddI16") || isRuntimeProcCall(n, "msAddI32") || isRuntimeProcCall(n, "msAddI64");
}

function kindMax(k: TypeKind): int64 {
	return k == TypeKind.Int64 ? INT64_MAX : maxOf(k);
}

function minOf(a: int64, b: int64): int64 {
	return a < b ? a : b;
}

// `xs[k]` for the key const k, read through the standard conversion an index gets.
function keyedRead(n: Node, key: Node): Node | null {
	if (n.kind != NodeKind.ArrayAccess) return null;
	const d = n.data as ArrayAccessData;
	const at = peelStdConv(d.index);
	if (at.kind != NodeKind.Identifier || at.resolvedSym != key.resolvedSym) return null;
	return rootSym(d.array) != null && signedKind(elementType(d.array)) != null ? d.array : null;
}

// M + 1 when `n` is `index & M` with 0 <= M < 2^53, else 0.
function maskedIndexLimit(n: Node | null, index: Node): int64 {
	if (n == null || n.kind != NodeKind.BinaryExpr) return 0;
	const d = n.data as BinaryExprData;
	if (d.operator != "&") return 0;
	const mask = sameLocal(d.left, index) ? peelStdConv(d.right) : sameLocal(d.right, index) ? peelStdConv(d.left) : null;
	if (mask == null || mask.kind != NodeKind.NumberLiteral) return 0;
	const m = mask.data as NumberLiteralData;
	return !m.isFloat && m.intVal >= 0 && m.intVal < 9007199254740992 ? m.intVal + 1 : 0;
}

// `const v = <cast of decl's local>`: a declaration with no effect the fast path may skip.
function castOf(s: Node, decl: Node): boolean {
	if (s.kind != NodeKind.VariableDecl) return false;
	const init = (s.data as VariableDeclData).initializer;
	if (init == null) return false;
	const operand = init.kind == NodeKind.TypeAssertion ? (init.data as TypeAssertionData).asExpr : init.kind == NodeKind.HiddenStdConv ? (init.data as HiddenStdConvData).convExpr : null;
	return operand != null && operand.kind == NodeKind.Identifier && operand.resolvedSym == decl.resolvedSym;
}

function nestedStatements(block: Node): Node[] {
	const out: Node[] = [];
	for (const s of (block.data as BlockStmtData).statements) {
		if (s.kind == NodeKind.BlockStmt) {
			for (const t of nestedStatements(s)) out.push(t);
		} else out.push(s);
	}
	return out;
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
	return tag == "" ? null : { acc, op: reduce.op, arrays: [array], index, len, widthTag: tag, endLimit: 0, bounded: null };
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
	return { acc, op: reduce.op, arrays, index, len, widthTag: tag, endLimit: 0, bounded: null };
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
	if (to == null || from == null || accKind == null || to.kind != accKind || bitsOfKind(from) > bitsOfKind(accKind)) return null;
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
	const e = peelStdConv(n);
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
	if (a == null || e == null || bitsOfKind(e) > bitsOfKind(a)) return "";
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
	return isSignedKind(r.kind) ? r.kind : null;
}

function widthName(k: TypeKind): string {
	return `I${bitsOfKind(k)}`;
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
