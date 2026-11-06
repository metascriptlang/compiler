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

import { Node, NodeKind, Symbol, Type, TypeKind, DeclKind, SourceLocation, BinaryExprData, CallExprData, BlockStmtData, ExprStmtData, VariableDeclData, MemberExprData, ArrayAccessData, IfStmtData, WhileStmtData, HiddenStdConvData, HiddenDerefData, NumberLiteralData, TypeAssertionData } from "../../ast/node";
import { peelStdConv } from "../../ast/shape";
import { peelToRepr, getSysType, booleanType } from "../../checker/types";
import { TransformContext, freshTempSym } from "../context";
import { walkNode } from "../walker";
import { makeCall, runtimeRef, makeIdentResolved, cloneIdent, makeVarDecl, makeBlock, makeWhile, makeIf, makeBinary, makeAssign, makeExprStmt, makeHiddenDeref, makeHiddenStdConv, isRuntimeProcCall } from "../util";
import { makeIntNumber } from "../../checker/literalNodes";
import { clonePlace } from "../place";
import { isSignedKind, bitsOfKind } from "../numKinds";

type Reduce = { acc: Node, op: string, term: Node };
type Reduction = { acc: Node, op: string, arrays: Node[], index: Node, len: Node, widthTag: string, endLimit: int64, term: Node | null, mask: int64 };
type Consts = { syms: Symbol[], inits: Node[] };

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

	if (r.term != null) return boundedLoop(r, r.term, w, endDecl, endRef, loc);
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
	fits = indexInRange(r, fits, endRef, loc);
	const indexType = peelToRepr(r.index.nodeType)!;
	if (r.endLimit > 0) {
		const unmasked = makeBinary(endRef(), "<=", makeIntNumber(r.endLimit, loc), loc);
		unmasked.nodeType = booleanType();
		fits = makeBinary(unmasked, "&&", fits, loc);
		fits.nodeType = booleanType();
	}
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

// Each step moves acc by a value in [0, mask] (+=) or [-mask, 0] (-=), so a block whose two end points fit
// keeps every partial sum in range and the plain add cannot overflow.
function boundedLoop(r: Reduction, term: Node, w: WhileStmtData, endDecl: Node, endRef: () => Node, loc: SourceLocation): Node {
	const i64 = getSysType(TypeKind.Int64);
	const bound = (v: int64): Node => {
		const n = makeIntNumber(v, loc);
		n.nodeType = i64;
		return n;
	};
	const add = r.op == "+=";
	const fits = makeCall(runtimeRef(`msRangeFits${r.widthTag}`, loc), [ident(r.acc, loc), ident(r.index, loc), endRef(), bound(add ? 0 : -r.mask), bound(add ? r.mask : 0)], loc);
	fits.nodeType = booleanType();
	const next = makeBinary(ident(r.acc, loc), add ? "+" : "-", term, loc);
	next.nodeType = r.acc.nodeType;
	const one = makeIntNumber(1, loc);
	one.nodeType = r.index.nodeType;
	const stepped = makeBinary(ident(r.index, loc), "+", one, loc);
	stepped.nodeType = r.index.nodeType;
	const inBlock = makeBinary(ident(r.index, loc), "<", endRef(), loc);
	inBlock.nodeType = booleanType();
	const body = makeBlock([makeExprStmt(makeAssign(ident(r.acc, loc), next, loc), loc), makeExprStmt(makeAssign(ident(r.index, loc), stepped, loc), loc)], loc);
	const fast = makeBlock([makeWhile(inBlock, body, loc)], loc);
	return makeWhile(w.whileCondition, makeBlock([endDecl, makeIf(indexInRange(r, fits, endRef, loc), fast, checkedBlock(r, w, endRef, loc), loc)], loc), loc);
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
	return tag == "" ? null : { acc, op: reduce.op, arrays: [array], index, len: bareLen, widthTag: tag, endLimit: limit, term: null, mask: 0 };
}

// A generator's fused loop under a local limit: `{ const x = <pure term>; ...; { acc op= T & C } }` and the step of i.
// The mask bounds every step whatever its operands hold, so the operands only need to be pure.
function matchBoundedTerm(stmts: Node[], index: Node, len: Node): Reduction | null {
	if (!isIndexStep(stmts[1], index) || !isSignedLocal(len) || sameLocal(len, index)) return null;
	const inner = nestedStatements(stmts[0]);
	const reduce = inner.length > 0 ? reduceStmt(inner[inner.length - 1]) : null;
	if (reduce == null || !distinctFrom(reduce.acc, [index, len])) return null;
	const consts: Consts = { syms: [], inits: [] };
	const loc = reduce.acc.location;
	for (let k = 0; k < inner.length - 1; k++) {
		const s = inner[k];
		if (s.kind != NodeKind.VariableDecl || s.resolvedSym == null) return null;
		const init = (s.data as VariableDeclData).initializer;
		if (init == null || pureTerm(init, consts, reduce.acc, loc) == null) return null;
		consts.syms.push(s.resolvedSym!);
		consts.inits.push(init);
	}
	const masked = widened(reduce.term, reduce.acc);
	const mask = masked == null ? -1 : maskOf(masked);
	const term = mask < 0 ? null : pureTerm(reduce.term, consts, reduce.acc, loc);
	const k = signedKind(reduce.acc.nodeType);
	if (term == null || k == null) return null;
	return { acc: reduce.acc, op: reduce.op, arrays: [], index, len, widthTag: widthName(k), endLimit: 0, term, mask };
}

function maskOf(n: Node): int64 {
	const k = signedKind(n.nodeType);
	if (k == null || n.kind != NodeKind.BinaryExpr || (n.data as BinaryExprData).operator != "&") return -1;
	const d = n.data as BinaryExprData;
	for (const side of [peelStdConv(d.left), peelStdConv(d.right)]) {
		if (side.kind != NodeKind.NumberLiteral) continue;
		const m = side.data as NumberLiteralData;
		if (!m.isFloat && m.intVal >= 0 && (k == TypeKind.Int64 || m.intVal <= maxOf(k))) return m.intVal;
	}
	return -1;
}

function pureTerm(n: Node, consts: Consts, acc: Node, loc: SourceLocation): Node | null {
	if (n.kind == NodeKind.Identifier) {
		if (n.resolvedSym == null || n.resolvedSym == acc.resolvedSym || signedKind(n.nodeType) == null) return null;
		const at = consts.syms.indexOf(n.resolvedSym!);
		return at < 0 ? cloneIdent(n, loc) : pureTerm(consts.inits[at], consts, acc, loc);
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
		const inner = pureTerm(d.convExpr, consts, acc, loc);
		return inner == null ? null : makeHiddenStdConv(inner, d.convType, loc);
	}
	if (n.kind != NodeKind.BinaryExpr || signedKind(n.nodeType) == null) return null;
	const d = n.data as BinaryExprData;
	if (d.operator != "&" && d.operator != "|" && d.operator != "^") return null;
	const left = pureTerm(d.left, consts, acc, loc);
	const right = left == null ? null : pureTerm(d.right, consts, acc, loc);
	if (left == null || right == null) return null;
	const out = makeBinary(left, d.operator, right, loc);
	out.nodeType = n.nodeType;
	return out;
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
	return tag == "" ? null : { acc, op: reduce.op, arrays: [array], index, len, widthTag: tag, endLimit: 0 };
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
	return { acc, op: reduce.op, arrays, index, len, widthTag: tag, endLimit: 0 };
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
