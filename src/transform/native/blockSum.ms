// Block versioning of any checked integer reduction on C:
//
//   while (i < E [&& i < F]) { DECLS; acc op= TERM; i += 1 }      op is += or -=, acc a signed local of 32 bits or less
//   → while (i < E [&& i < F]) {
//       const $end = msBlockEndOf(i, min(E, F), 1024);
//       DECLS and TERM over $j in [i, $end) with every raising operation sticky, the terms summed in $sum and
//       bounded by [-$hi - 1, $hi] from the OR of their x ^ (x >> sign) (constants when the term's range is known narrow);
//       if (!$bad && msBlockRangeFits(acc, $end - i, -$hi - 1, $hi)) { acc = acc + $sum, wrapped; i = $end; }
//       else while (i < $end) BODY
//     }
//
// DECLS and TERM are integer expressions of locals, element reads, conversions and checked add, subtract,
// multiply, negate and range checks, so the sticky block changes nothing but its own locals and the checked
// BODY re-runs a block it refuses and stops at the exact element.

import { Node, NodeKind, Symbol, Type, TypeKind, DeclKind, SourceLocation, BinaryExprData, UnaryExprData, CallExprData, BlockStmtData, ExprStmtData, VariableDeclData, MemberExprData, ArrayAccessData, WhileStmtData, HiddenStdConvData, HiddenDerefData, NumberLiteralData, TypeAssertionData, ConditionalExprData, NodeFlag } from "../../ast/node";
import { peelToRepr, peelTransparentInstance, getSysType, booleanType } from "../../checker/types";
import { TransformContext, freshTempSym } from "../context";
import { makeCall, runtimeRef, generatedRef, makeIdentResolved, cloneIdent, makeVarDecl, makeBlock, makeWhile, makeIf, makeBinary, makeUnary, makeAssign, makeExprStmt, makeHiddenDeref, makeHiddenStdConv, makeConditional, isRuntimeProcCall } from "../util";
import { makeIntNumber, makeBool } from "../../checker/literalNodes";
import { clonePlace } from "../place";
import { isSignedKind, bitsOfKind } from "../numKinds";
import { forEachChild } from "../../ast/visitor";
import { cloneFresh } from "../lowering/iterInline";

type SumLoop = { acc: Node, sub: boolean, index: Node, bounds: Node[], decls: Node[], term: Node };
type Fast = { bad: Symbol, counters: HashSet<Symbol>, guarded: Node[], ranges: HashMap<Symbol, Range>, counterChecks: Range[], loc: SourceLocation };
type Range = { lo: int64, hi: int64 };

export function versionSumLoop(loop: Node, ctx: TransformContext): Node | null {
	const s = matchSumLoop(loop);
	return s == null ? null : sumLoop(s, loop, ctx);
}

function matchSumLoop(loop: Node): SumLoop | null {
	const w = loop.data as WhileStmtData;
	if (w.whileLabel != "" || w.whileBody.kind != NodeKind.BlockStmt) return null;
	const bounds: Node[] = [];
	const index = boundedIndex(w.whileCondition, bounds);
	if (index == null) return null;
	const stmts = flatStatements(w.whileBody);
	if (stmts.length < 2 || !isStep(stmts[stmts.length - 1], index)) return null;
	const reduce = stmts[stmts.length - 2];
	if (reduce.kind != NodeKind.ExprStmt) return null;
	const e = (reduce.data as ExprStmtData).expr;
	const add = isRuntimeProcCall(e, "msAddAssign");
	if (!add && !isRuntimeProcCall(e, "msSubAssign")) return null;
	const args = (e.data as CallExprData).arguments;
	if (args.length != 2 || !isSmallSignedLocal(args[0]) || sameLocal(args[0], index)) return null;
	const acc = args[0];
	const decls = stmts.slice(0, stmts.length - 2);
	for (const d of decls) {
		if (d.kind != NodeKind.VariableDecl || d.resolvedSym == null || !isScalar(d.resolvedSym.symbolType)) return null;
		const init = (d.data as VariableDeclData).initializer;
		if (init == null || !isPure(init, acc)) return null;
	}
	if (!isPure(args[1], acc)) return null;
	for (const b of bounds) {
		if (reads(b, acc.resolvedSym!) || reads(b, index.resolvedSym!)) return null;
	}
	return { acc, sub: !add, index, bounds, decls, term: args[1] };
}

function boundedIndex(cond: Node, bounds: Node[]): Node | null {
	if (cond.kind != NodeKind.BinaryExpr) return null;
	const d = cond.data as BinaryExprData;
	if (d.operator == "&&") {
		const a = boundedIndex(d.left, bounds);
		const b = a != null ? boundedIndex(d.right, bounds) : null;
		return b != null && sameLocal(a!, b) ? a : null;
	}
	if (d.operator != "<" || !isSignedLocal(d.left) || !isIntegral(d.right.nodeType) || !isPure(d.right, null)) return null;
	bounds.push(d.right);
	return d.left;
}

function flatStatements(block: Node): Node[] {
	const out: Node[] = [];
	for (const s of (block.data as BlockStmtData).statements) {
		if (s.kind == NodeKind.BlockStmt) {
			for (const t of flatStatements(s)) out.push(t);
		} else out.push(s);
	}
	return out;
}

function isStep(stmt: Node, index: Node): boolean {
	if (stmt.kind != NodeKind.ExprStmt) return false;
	const e = (stmt.data as ExprStmtData).expr;
	if (e.kind != NodeKind.CallExpr) return false;
	const args = (e.data as CallExprData).arguments;
	if (isRuntimeProcCall(e, "msPostInc")) return args.length == 1 && sameLocal(args[0], index);
	if (!isRuntimeProcCall(e, "msAddAssign") || args.length != 2 || !sameLocal(args[0], index)) return false;
	const one = args[1].kind == NodeKind.HiddenStdConv ? (args[1].data as HiddenStdConvData).convExpr : args[1];
	return one.kind == NodeKind.NumberLiteral && !(one.data as NumberLiteralData).isFloat && (one.data as NumberLiteralData).intVal == 1;
}

// ===== What the sticky block may run =====

function isPure(n: Node, acc: Node | null): boolean {
	if (n.kind == NodeKind.NumberLiteral) return !(n.data as NumberLiteralData).isFloat;
	if (n.kind == NodeKind.BooleanLiteral) return true;
	if (n.kind == NodeKind.Identifier) {
		return n.resolvedSym != null && (acc == null || n.resolvedSym != acc.resolvedSym) && (isIntegral(n.nodeType) || isBoolean(n.nodeType));
	}
	if (n.kind == NodeKind.BinaryExpr) {
		const d = n.data as BinaryExprData;
		return PURE_BINARY.has(d.operator) && (isIntegral(n.nodeType) || isBoolean(n.nodeType)) && isPure(d.left, acc) && isPure(d.right, acc);
	}
	if (n.kind == NodeKind.UnaryExpr) {
		const op = (n.data as UnaryExprData).unaryOp;
		return (op == "-" || op == "~" || op == "!") && isPure((n.data as UnaryExprData).operand, acc);
	}
	if (n.kind == NodeKind.TypeAssertion || n.kind == NodeKind.HiddenStdConv) {
		const inner = n.kind == NodeKind.TypeAssertion ? (n.data as TypeAssertionData).asExpr : (n.data as HiddenStdConvData).convExpr;
		if (inner.kind == NodeKind.MemberExpr) return isIntegral(n.nodeType) && isPure(inner, acc);
		return isScalar(n.nodeType) && (isIntegral(inner.nodeType) || isBoolean(inner.nodeType)) && isPure(inner, acc);
	}
	if (n.kind == NodeKind.ConditionalExpr) {
		const d = n.data as ConditionalExprData;
		return isPure(d.ternaryCondition, acc) && isPure(d.ternaryConsequent, acc) && isPure(d.ternaryAlternate, acc);
	}
	if (n.kind == NodeKind.MemberExpr) {
		const d = n.data as MemberExprData;
		return d.property == "length" && !d.isOptional && arrayRoot(d.object) != null;
	}
	if (n.kind == NodeKind.ArrayAccess) {
		const d = n.data as ArrayAccessData;
		return arrayRoot(d.array) != null && isIntegral(elementType(d.array)) && isIntegral(d.index.nodeType) && isPure(d.index, acc);
	}
	if (n.kind == NodeKind.CallExpr) {
		if (stickyName(n) == "") return false;
		for (const a of (n.data as CallExprData).arguments) {
			if (!isPure(a, acc)) return false;
		}
		return true;
	}
	return false;
}

const PURE_BINARY: HashSet<string> = pureBinary();

function pureBinary(): HashSet<string> {
	const ops = new HashSet<string>();
	for (const op of ["+", "-", "*", "&", "|", "^", "<<", ">>", ">>>", "==", "!=", "<", "<=", ">", ">=", "&&", "||"]) ops.add(op);
	return ops;
}

function calleeName(n: Node): string {
	const d = n.data as CallExprData;
	if (d.callee.kind != NodeKind.Identifier || d.callee.resolvedSym == null) return "";
	const sym = d.callee.resolvedSym!;
	return sym.nativeName != "" ? sym.nativeName : sym.name;
}

// The sticky twin of a call that raises, or "" for a call the sticky block may not run.
function stickyName(n: Node): string {
	const d = n.data as CallExprData;
	const name = calleeName(n);
	if (name == "") return "";
	if (n.flags.has(NodeFlag.IntCheck) && !n.flags.has(NodeFlag.WritesOperand)) {
		for (const op of ["Add", "Sub", "Mul", "Neg"]) {
			for (const w of ["I8", "I16", "I32", "I64"]) {
				if (name == `ms${op}${w}`) return `msSticky${op}${w}`;
			}
		}
		return "";
	}
	if (name == "msExactI64") return "msStickyExactI64";
	for (const w of ["I8", "U8", "I16", "U16", "I32", "U32"]) {
		if ((name == `msCheckRange${w}` && isIntegral(d.arguments[0].nodeType) && !isUint64(d.arguments[0].nodeType)) || name == `msCheckRangeExact${w}`) return `msStickyRange${w}`;
	}
	return "";
}

function sticky(n: Node, f: Fast): Node {
	const loc = f.loc;
	if (n.kind == NodeKind.CallExpr) {
		const name = stickyName(n);
		const safe = cannotRaise(n, f);
		const args: Node[] = [];
		for (const a of (n.data as CallExprData).arguments) args.push(sticky(a, f));
		if (safe) return unchecked(n, args, loc);
		args.push(makeIdentResolved(f.bad, loc));
		const call = makeCall(runtimeRef(name, loc), args, loc);
		call.nodeType = n.nodeType;
		return call;
	}
	if (n.kind == NodeKind.ArrayAccess) {
		const d = n.data as ArrayAccessData;
		const span = isSpan(d.array.nodeType);
		const array = span ? d.array : arrayValue(d.array, loc);
		const counter = counterOf(d.index, f.counters);
		if (counter != null) {
			f.guarded.push(array);
			const read = makeCall(generatedRef(span ? "msSpanAccessUnchecked" : "msArrayAccessUnchecked", loc), [clonePlace(array, loc), makeIdentResolved(counter, loc)], loc);
			read.nodeType = n.nodeType;
			return read;
		}
		const call = makeCall(runtimeRef(span ? "msStickySpanAt" : "msStickyAt", loc), [array, sticky(d.index, f), makeIdentResolved(f.bad, loc)], loc);
		call.nodeType = n.nodeType;
		return call;
	}
	const kids: Node[] = [];
	forEachChild(n, (c: Node): void => { kids.push(c); });
	for (const k of kids) replaceChild(n, k, sticky(k, f));
	return n;
}

function counterOf(n: Node, counters: HashSet<Symbol>): Symbol | null {
	let e = n;
	while (true) {
		if (e.kind == NodeKind.HiddenStdConv || e.kind == NodeKind.TypeAssertion) {
			const inner = e.kind == NodeKind.HiddenStdConv ? (e.data as HiddenStdConvData).convExpr : (e.data as TypeAssertionData).asExpr;
			if (!widens(inner.nodeType, e.nodeType)) return null;
			e = inner;
		} else if (e.kind == NodeKind.CallExpr && isRuntimeProcCall(e, "msExactI64")) {
			e = (e.data as CallExprData).arguments[0];
		} else break;
	}
	return e.kind == NodeKind.Identifier && e.resolvedSym != null && counters.has(e.resolvedSym!) ? e.resolvedSym : null;
}

// ===== Ranges =====

const MAX_SAFE: int64 = 9007199254740991;
export const REDUCE_BLOCK: int64 = 1024;

function cannotRaise(n: Node, f: Fast): boolean {
	const accepted = acceptedRange(n, f);
	if (accepted == null) return false;
	const args = (n.data as CallExprData).arguments;
	if (within(computedRange(n, f), accepted)) return true;
	if (n.flags.has(NodeFlag.IntCheck) || counterOf(args[0], f.counters) == null) return false;
	f.counterChecks.push(accepted);
	return true;
}

function unchecked(n: Node, args: Node[], loc: SourceLocation): Node {
	const name = calleeName(n);
	const op = arithOp(name);
	if (name.startsWith("msNeg")) return typed(makeUnary("-", args[0], loc), n.nodeType!);
	if (op != "") return typed(makeBinary(args[0], op, args[1], loc), n.nodeType!);
	return makeHiddenStdConv(args[0], n.nodeType!, loc);
}

function arithOp(name: string): string {
	if (name.startsWith("msAdd")) return "+";
	if (name.startsWith("msSub")) return "-";
	return name.startsWith("msMul") ? "*" : "";
}

function acceptedRange(n: Node, f: Fast): Range | null {
	const name = calleeName(n);
	const args = (n.data as CallExprData).arguments;
	if (name == "msExactI64") return { lo: -MAX_SAFE, hi: MAX_SAFE };
	if (n.flags.has(NodeFlag.IntCheck)) return typeRange(n.nodeType);
	const lo = rangeOf(args[1], f);
	const hi = rangeOf(args[2], f);
	return lo != null && hi != null ? { lo: lo.hi, hi: hi.lo } : null;
}

function computedRange(n: Node, f: Fast): Range | null {
	const name = calleeName(n);
	const args = (n.data as CallExprData).arguments;
	if (name.startsWith("msNeg")) return negate(rangeOf(args[0], f));
	const op = arithOp(name);
	return op != "" ? arith(op, rangeOf(args[0], f), rangeOf(args[1], f)) : rangeOf(args[0], f);
}

// A refused block still runs every operation proven unchecked, so a range holds in every block, never only in
// an accepted one: a sticky check lets a value its type holds through, not one its check accepts.
function rangeOf(n: Node, f: Fast): Range | null {
	if (n.kind == NodeKind.NumberLiteral) {
		const d = n.data as NumberLiteralData;
		return d.isFloat ? null : { lo: d.intVal, hi: d.intVal };
	}
	if (isBoolean(n.nodeType)) return { lo: 0, hi: 1 };
	if (n.kind == NodeKind.Identifier) {
		return n.resolvedSym != null && f.ranges.has(n.resolvedSym!) ? f.ranges.get(n.resolvedSym!)! : typeRange(n.nodeType);
	}
	if (n.kind == NodeKind.BinaryExpr) {
		const d = n.data as BinaryExprData;
		return wrap(binaryRange(d.operator, rangeOf(d.left, f), rangeOf(d.right, f)), n.nodeType);
	}
	if (n.kind == NodeKind.UnaryExpr) {
		const d = n.data as UnaryExprData;
		const a = rangeOf(d.operand, f);
		if (a == null) return typeRange(n.nodeType);
		return wrap(d.unaryOp == "-" ? negate(a) : { lo: ~a.hi, hi: ~a.lo }, n.nodeType);
	}
	if (n.kind == NodeKind.TypeAssertion) return wrap(rangeOf((n.data as TypeAssertionData).asExpr, f), n.nodeType);
	if (n.kind == NodeKind.HiddenStdConv) return wrap(rangeOf((n.data as HiddenStdConvData).convExpr, f), n.nodeType);
	if (n.kind == NodeKind.ConditionalExpr) {
		const d = n.data as ConditionalExprData;
		const a = rangeOf(d.ternaryConsequent, f);
		const b = rangeOf(d.ternaryAlternate, f);
		return wrap(a != null && b != null ? { lo: a.lo < b.lo ? a.lo : b.lo, hi: a.hi > b.hi ? a.hi : b.hi } : null, n.nodeType);
	}
	if (n.kind == NodeKind.CallExpr) return meet(computedRange(n, f), typeRange(n.nodeType));
	return typeRange(n.nodeType);
}

function binaryRange(op: string, a: Range | null, b: Range | null): Range | null {
	if (op == "&") {
		if (a != null && a.lo >= 0 && b != null && b.lo >= 0) return { lo: 0, hi: a.hi < b.hi ? a.hi : b.hi };
		if (a != null && a.lo >= 0) return { lo: 0, hi: a.hi };
		return b != null && b.lo >= 0 ? { lo: 0, hi: b.hi } : null;
	}
	if (a == null || b == null) return null;
	if (op == "|" || op == "^") return a.lo >= 0 && b.lo >= 0 ? { lo: 0, hi: ones(a.hi > b.hi ? a.hi : b.hi) } : null;
	const shift = b.lo == b.hi && b.lo >= 0 && b.lo < 31;
	if (shift && (op == ">>" || (op == ">>>" && a.lo >= 0))) return { lo: a.lo >> b.lo, hi: a.hi >> b.lo };
	return arith(op, a, b);
}

function arith(op: string, a: Range | null, b: Range | null): Range | null {
	if (a == null || b == null) return null;
	if (op == "+" || op == "-") {
		if (!small(a, MAX_SAFE) || !small(b, MAX_SAFE)) return null;
		return op == "+" ? { lo: a.lo + b.lo, hi: a.hi + b.hi } : { lo: a.lo - b.hi, hi: a.hi - b.lo };
	}
	if (op != "*" || !small(a, 2147483648) || !small(b, 2147483648)) return null;
	let lo = a.lo * b.lo;
	let hi = lo;
	for (const p of [a.lo * b.hi, a.hi * b.lo, a.hi * b.hi]) {
		if (p < lo) lo = p;
		if (p > hi) hi = p;
	}
	return { lo, hi };
}

function negate(a: Range | null): Range | null {
	return a != null && small(a, MAX_SAFE) ? { lo: -a.hi, hi: -a.lo } : null;
}

function ones(x: int64): int64 {
	let m: int64 = 0;
	while (m < x) m = m * 2 + 1;
	return m;
}

function small(r: Range, limit: int64): boolean {
	return r.lo >= -limit && r.hi <= limit;
}

function within(r: Range | null, bounds: Range): boolean {
	return r != null && r.lo >= bounds.lo && r.hi <= bounds.hi;
}

function meet(a: Range | null, b: Range | null): Range | null {
	if (a == null || b == null) return a == null ? b : a;
	const lo = a.lo > b.lo ? a.lo : b.lo;
	const hi = a.hi < b.hi ? a.hi : b.hi;
	return lo <= hi ? { lo, hi } : b;
}

function wrap(r: Range | null, t: Type | null): Range | null {
	const own = typeRange(t);
	if (r == null) return own;
	if (own != null) return within(r, own) ? r : own;
	const k = peelToRepr(t);
	return k != null && k.kind == TypeKind.Int64 ? r : null;
}

function typeRange(t: Type | null): Range | null {
	if (isBoolean(t)) return { lo: 0, hi: 1 };
	const r = peelToRepr(t);
	const bits = r != null ? bitsOfKind(r.kind) : 0;
	if (bits == 0 || bits == 64) return null;
	const signed = isSignedKind(r!.kind);
	if (bits == 8) return signed ? { lo: -128, hi: 127 } : { lo: 0, hi: 255 };
	if (bits == 16) return signed ? { lo: -32768, hi: 32767 } : { lo: 0, hi: 65535 };
	return signed ? { lo: -2147483648, hi: 2147483647 } : { lo: 0, hi: 4294967295 };
}

function widens(from: Type | null, to: Type | null): boolean {
	const a = peelToRepr(from);
	const b = peelToRepr(to);
	if (a == null || b == null || !isIntegral(from) || !isIntegral(to)) return false;
	return isSignedKind(a.kind) == isSignedKind(b.kind) && bitsOfKind(a.kind) <= bitsOfKind(b.kind);
}

function replaceChild(n: Node, from: Node, to: Node): void {
	if (from == to) return;
	match (n.kind) {
		NodeKind.BinaryExpr => {
			const d = n.data as BinaryExprData;
			if (d.left == from) d.left = to; else d.right = to;
		},
		NodeKind.UnaryExpr => { (n.data as UnaryExprData).operand = to; },
		NodeKind.TypeAssertion => { (n.data as TypeAssertionData).asExpr = to; },
		NodeKind.HiddenStdConv => { (n.data as HiddenStdConvData).convExpr = to; },
		NodeKind.ConditionalExpr => {
			const d = n.data as ConditionalExprData;
			if (d.ternaryCondition == from) d.ternaryCondition = to;
			else if (d.ternaryConsequent == from) d.ternaryConsequent = to;
			else d.ternaryAlternate = to;
		},
		NodeKind.VariableDecl => { (n.data as VariableDeclData).initializer = to; },
		NodeKind.ArrayAccess => {
			const d = n.data as ArrayAccessData;
			if (d.index == from) d.index = to; else d.array = to;
		},
		NodeKind.MemberExpr => { (n.data as MemberExprData).object = to; },
		_ => { throw new Error(`internal: a sticky block cannot rewrite a child of node kind ${n.kind}`); },
	};
}

// ===== The versioned loop =====

function sumLoop(s: SumLoop, loop: Node, ctx: TransformContext): Node {
	const w = loop.data as WhileStmtData;
	const loc = loop.location;
	const i64 = getSysType(TypeKind.Int64);
	const indexType = s.index.nodeType!;
	const head: Node[] = [];
	let bound = wide(clonePlace(s.bounds[0], loc), loc);
	for (let k = 1; k < s.bounds.length; k++) {
		const next = wide(clonePlace(s.bounds[k], loc), loc);
		const less = typed(makeBinary(bound, "<", next, loc), booleanType());
		bound = typed(makeConditional(less, clonePlace(bound, loc), clonePlace(next, loc), loc), i64);
	}
	const endCall = typed(makeCall(runtimeRef("msBlockEndOf", loc), [wide(cloneIdent(s.index, loc), loc), bound, int64(REDUCE_BLOCK, loc)], loc), i64);
	const end = declareLocal(head, ctx, "end", i64, endCall, DeclKind.Const, loc);
	const bad = declareLocal(head, ctx, "bad", booleanType(), makeBool(false, loc), DeclKind.Let, loc);
	const j = declareLocal(head, ctx, "j", indexType, cloneIdent(s.index, loc), DeclKind.Let, loc);

	const renames = new HashMap<Symbol, Symbol>();
	renames.set(s.index.resolvedSym!, j);
	const f: Fast = { bad, counters: new HashSet<Symbol>(), guarded: [], ranges: new HashMap<Symbol, Range>(), counterChecks: [], loc };
	f.counters.add(j);
	const fast: Node[] = [];
	for (const d of s.decls) {
		const copy = cloneFresh(d, renames, ctx, true);
		const init = (copy.data as VariableDeclData).initializer;
		if (copy.resolvedSym != null && init != null && isIntegral(copy.resolvedSym!.symbolType) && counterOf(init, f.counters) != null) f.counters.add(copy.resolvedSym!);
		const r = copy.resolvedSym != null && init != null ? wrap(rangeOf(init, f), copy.resolvedSym!.symbolType) : null;
		fast.push(sticky(copy, f));
		if (r != null) f.ranges.set(copy.resolvedSym!, r);
	}
	const termCopy = cloneFresh(s.term, renames, ctx, true);
	const termRange = rangeOf(termCopy, f);
	const narrowTerm = termRange != null && small(termRange, 2147483648) && termRange.lo * REDUCE_BLOCK > -2147483648 && termRange.hi * REDUCE_BLOCK < 2147483647;
	const folded = narrowTerm ? null : foldedCheck(termCopy, f);
	const valueRange = folded != null ? computedRange(termCopy, f) : termRange;
	const nonNegative = valueRange != null && valueRange.lo >= 0;
	const i32 = getSysType(TypeKind.Int32);
	const value = narrowTerm ? convert(sticky(termCopy, f), i32, loc) : folded != null ? wideValue(termCopy, f, loc) : sticky(termCopy, f);
	const termType = value.nodeType!;
	const sumType = narrowTerm ? i32 : wrappingSumType(termType);
	const sum = declareLocal(head, ctx, "sum", sumType, zero(sumType, loc), DeclKind.Let, loc);
	const termSym = freshTempSym(ctx, "t", termType);
	const termDecl = makeVarDecl(termSym.name, value, DeclKind.Const, loc);
	termDecl.resolvedSym = termSym;
	termDecl.nodeType = termType;
	fast.push(termDecl);
	fast.push(assignTo(sum, typed(makeBinary(makeIdentResolved(sum, loc), "+", convert(makeIdentResolved(termSym, loc), sumType, loc), loc), sumType), loc));
	const magnitude = narrowTerm ? null : declareLocal(head, ctx, "mag", termType, zero(termType, loc), DeclKind.Let, loc);
	if (magnitude != null) fast.push(assignTo(magnitude, typed(makeBinary(makeIdentResolved(magnitude, loc), "|", magnitudeBits(termSym, nonNegative, loc), loc), termType), loc));
	const one = makeIntNumber(1, loc);
	one.nodeType = indexType;
	fast.push(makeExprStmt(makeAssign(makeIdentResolved(j, loc), typed(makeBinary(makeIdentResolved(j, loc), "+", one, loc), indexType), loc), loc));
	for (const a of f.guarded) {
		const within = typed(makeCall(runtimeRef(isSpan(a.nodeType) ? "msBlockWithinSpan" : "msBlockWithin", loc), [a, wide(cloneIdent(s.index, loc), loc), makeIdentResolved(end, loc)], loc), booleanType());
		head.push(markBad(bad, typed(makeUnaryNot(within, loc), booleanType()), loc));
	}
	for (const r of f.counterChecks) {
		const below = typed(makeBinary(wide(cloneIdent(s.index, loc), loc), "<", int64(r.lo, loc), loc), booleanType());
		const above = typed(makeBinary(makeIdentResolved(end, loc), ">", int64(r.hi + 1, loc), loc), booleanType());
		head.push(markBad(bad, typed(makeBinary(below, "||", above, loc), booleanType()), loc));
	}
	head.push(makeWhile(typed(makeBinary(wide(makeIdentResolved(j, loc), loc), "<", makeIdentResolved(end, loc), loc), booleanType()), makeBlock(fast, loc), loc));
	const hi = magnitude == null ? null : declareLocal(head, ctx, "hi", i64, typed(makeCall(runtimeRef("msBlockMagnitude", loc), [makeIdentResolved(magnitude, loc)], loc), i64), DeclKind.Const, loc);
	if (folded != null) {
		const below = typed(makeBinary(blockLow(hi, nonNegative, termRange, loc), "<", int64(folded.lo, loc), loc), booleanType());
		const above = typed(makeBinary(blockHigh(hi, termRange, loc), ">", int64(folded.hi, loc), loc), booleanType());
		head.push(markBad(bad, typed(makeBinary(below, "||", above, loc), booleanType()), loc));
	}

	const accType = s.acc.nodeType!;
	const accRange = typeRange(accType)!;
	const count = typed(makeBinary(makeIdentResolved(end, loc), "-", wide(cloneIdent(s.index, loc), loc), loc), i64);
	const fitsCall = typed(makeCall(runtimeRef("msBlockRangeFits", loc), [cloneIdent(s.acc, loc), count, blockLow(hi, nonNegative, termRange, loc), blockHigh(hi, termRange, loc), makeBool(s.sub, loc), int64(accRange.lo, loc), int64(accRange.hi, loc)], loc), booleanType());
	const clean = typed(makeUnaryNot(makeIdentResolved(bad, loc), loc), booleanType());
	const fits = typed(makeBinary(clean, "&&", fitsCall, loc), booleanType());
	const total = narrowTerm
		? typed(makeCall(runtimeRef("msBlockSumOf", loc), [cloneIdent(s.acc, loc), makeIdentResolved(sum, loc), makeBool(s.sub, loc)], loc), i64)
		: typed(makeBinary(makeHiddenStdConv(cloneIdent(s.acc, loc), sumType, loc), s.sub ? "-" : "+", makeIdentResolved(sum, loc), loc), sumType);
	const take = makeBlock([
		makeExprStmt(makeAssign(cloneIdent(s.acc, loc), makeHiddenStdConv(total, accType, loc), loc), loc),
		makeExprStmt(makeAssign(cloneIdent(s.index, loc), narrow(makeIdentResolved(end, loc), indexType, loc), loc), loc),
	], loc);
	const inBlock = typed(makeBinary(wide(cloneIdent(s.index, loc), loc), "<", makeIdentResolved(end, loc), loc), booleanType());
	const checked = makeBlock([makeWhile(inBlock, w.whileBody, loc)], loc);
	head.push(makeIf(fits, take, checked, loc));
	return makeWhile(w.whileCondition, makeBlock(head, loc), loc);
}

// The block's magnitude bound always holds -1 and 0, so only a check that lets both through can be tested on it.
function foldedCheck(term: Node, f: Fast): Range | null {
	if (term.kind != NodeKind.CallExpr || stickyName(term) == "") return null;
	if (term.flags.has(NodeFlag.IntCheck) && typeRange(term.nodeType) == null) return null;
	const r = acceptedRange(term, f);
	return r != null && r.lo < 0 && r.hi >= 0 ? r : null;
}

function wideValue(n: Node, f: Fast, loc: SourceLocation): Node {
	const i64 = getSysType(TypeKind.Int64);
	const name = calleeName(n);
	const args: Node[] = [];
	for (const a of (n.data as CallExprData).arguments) args.push(sticky(a, f));
	if (!n.flags.has(NodeFlag.IntCheck)) return wide(args[0], loc);
	if (name.startsWith("msNeg")) return typed(makeBinary(int64(0, loc), "-", wide(args[0], loc), loc), i64);
	return typed(makeBinary(wide(args[0], loc), arithOp(name), wide(args[1], loc), loc), i64);
}

function wrappingSumType(t: Type): Type {
	const r = peelToRepr(t);
	return getSysType(r != null && bitsOfKind(r.kind) == 64 ? TypeKind.Uint64 : TypeKind.Uint32);
}

function magnitudeBits(term: Symbol, nonNegative: boolean, loc: SourceLocation): Node {
	const t = term.symbolType!;
	const k = peelToRepr(t)!.kind;
	if (nonNegative || !isSignedKind(k)) return makeIdentResolved(term, loc);
	const sign = makeIntNumber(bitsOfKind(k) - 1, loc);
	sign.nodeType = t;
	const fill = typed(makeBinary(makeIdentResolved(term, loc), ">>", sign, loc), t);
	return typed(makeBinary(makeIdentResolved(term, loc), "^", fill, loc), t);
}

function blockLow(hi: Symbol | null, nonNegative: boolean, r: Range | null, loc: SourceLocation): Node {
	if (hi == null) return int64(r!.lo, loc);
	return nonNegative ? int64(0, loc) : typed(makeBinary(int64(-1, loc), "-", makeIdentResolved(hi, loc), loc), getSysType(TypeKind.Int64));
}

function blockHigh(hi: Symbol | null, r: Range | null, loc: SourceLocation): Node {
	return hi == null ? int64(r!.hi, loc) : makeIdentResolved(hi, loc);
}

function assignTo(sym: Symbol, value: Node, loc: SourceLocation): Node {
	return makeExprStmt(makeAssign(makeIdentResolved(sym, loc), value, loc), loc);
}

// ===== Helpers =====

function markBad(bad: Symbol, outside: Node, loc: SourceLocation): Node {
	return makeExprStmt(makeAssign(makeIdentResolved(bad, loc), typed(makeBinary(makeIdentResolved(bad, loc), "||", outside, loc), booleanType()), loc), loc);
}

function declareLocal(out: Node[], ctx: TransformContext, name: string, t: Type, init: Node, kind: DeclKind, loc: SourceLocation): Symbol {
	const sym = freshTempSym(ctx, name, t);
	const decl = makeVarDecl(sym.name, init, kind, loc);
	decl.resolvedSym = sym;
	decl.nodeType = t;
	out.push(decl);
	return sym;
}

function typed(n: Node, t: Type): Node {
	n.nodeType = t;
	return n;
}

function int64(v: int64, loc: SourceLocation): Node {
	const n = makeIntNumber(v, loc);
	n.nodeType = getSysType(TypeKind.Int64);
	return n;
}

function makeUnaryNot(operand: Node, loc: SourceLocation): Node {
	return makeBinary(operand, "==", makeBool(false, loc), loc);
}

function wide(n: Node, loc: SourceLocation): Node {
	return convert(n, getSysType(TypeKind.Int64), loc);
}

function convert(n: Node, t: Type, loc: SourceLocation): Node {
	const r = peelToRepr(n.nodeType);
	return r != null && r.kind == peelToRepr(t)!.kind ? n : makeHiddenStdConv(n, t, loc);
}

function zero(t: Type, loc: SourceLocation): Node {
	const n = makeIntNumber(0, loc);
	n.nodeType = t;
	return n;
}

function narrow(n: Node, t: Type, loc: SourceLocation): Node {
	const r = peelToRepr(t);
	return r != null && r.kind == TypeKind.Int64 ? n : makeHiddenStdConv(n, t, loc);
}

function reads(n: Node, sym: Symbol): boolean {
	if (n.kind == NodeKind.Identifier && n.resolvedSym == sym) return true;
	let found = false;
	forEachChild(n, (c: Node): void => {
		if (!found && reads(c, sym)) found = true;
	});
	return found;
}

function isIntegral(t: Type | null): boolean {
	const r = peelToRepr(t);
	if (r == null) return false;
	return match (r.kind) {
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 => true,
		TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 | TypeKind.Char => true,
		_ => false,
	};
}

function isScalar(t: Type | null): boolean {
	const r = peelToRepr(t);
	return r != null && (isIntegral(t) || isBoolean(t) || r.kind == TypeKind.Number || r.kind == TypeKind.Float64 || r.kind == TypeKind.Float32);
}

function isUint64(t: Type | null): boolean {
	const r = peelToRepr(t);
	return r != null && r.kind == TypeKind.Uint64;
}

function isBoolean(t: Type | null): boolean {
	const r = peelToRepr(t);
	return r != null && (r.kind == TypeKind.Boolean || r.kind == TypeKind.BooleanLiteral);
}

function signedKindOf(t: Type | null): TypeKind | null {
	const r = peelToRepr(t);
	return r != null && isSignedKind(r.kind) ? r.kind : null;
}

function isSignedLocal(n: Node): boolean {
	return n.kind == NodeKind.Identifier && n.resolvedSym != null && signedKindOf(n.nodeType) != null;
}

function isSmallSignedLocal(n: Node): boolean {
	const k = isSignedLocal(n) ? signedKindOf(n.nodeType) : null;
	return k != null && bitsOfKind(k) <= 32;
}

function sameLocal(n: Node, local: Node): boolean {
	return n.kind == NodeKind.Identifier && n.resolvedSym != null && n.resolvedSym == local.resolvedSym;
}

function arrayRoot(a: Node): Symbol | null {
	const id = a.kind == NodeKind.HiddenDeref ? (a.data as HiddenDerefData).expr : a;
	if (id.kind != NodeKind.Identifier || id.resolvedSym == null) return null;
	return elementType(a) != null ? id.resolvedSym : null;
}

function elementType(a: Node): Type | null {
	let t = a.nodeType != null ? peelTransparentInstance(a.nodeType) : null;
	if (t != null && t.kind == TypeKind.Ref && t.typeReturn != null) t = peelTransparentInstance(t.typeReturn);
	return t != null && (t.kind == TypeKind.Array || t.kind == TypeKind.Span) ? t.typeReturn : null;
}

function isSpan(t: Type | null): boolean {
	return t != null && peelTransparentInstance(t).kind == TypeKind.Span;
}

function arrayValue(a: Node, loc: SourceLocation): Node {
	const c = clonePlace(a, loc);
	if (c.nodeType != null && c.nodeType.kind == TypeKind.Ref) return makeHiddenDeref(c, loc);
	return c;
}
