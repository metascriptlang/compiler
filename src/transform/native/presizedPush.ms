// A counted loop over an array that pushes exactly once per step onto a fresh empty array builds that array the
// way the reference's `map` does (NIM-REF TR-41): sized to the source length up front, written by index, cut to
// what was written when the source shrank, and continued by the unchanged push loop when the source grew.

import { Node, NodeKind, DeclKind, Symbol, SourceLocation, Type, SymbolKind, TypeKind, ProgramData, BlockStmtData, VariableDeclData, ArrayLiteralData, WhileStmtData, DoWhileStmtData, BinaryExprData, UpdateExprData, ExprStmtData, CallExprData, MemberExprData, HiddenDerefData, HiddenStdConvData, TypeAssertionData, BooleanLiteralData, NumberLiteralData } from "../../ast/node";
import { isRoutineNode } from "../../ast/shape";
import { isAssignOp } from "../../ast/operators";
import { forEachChild } from "../../ast/visitor";
import { peelTransparentInstance } from "../../checker/types";
import { cloneNodeKeepSem } from "../../monomorphize/clone";
import { TransformContext, freshTemp, newLoweredSym } from "../context";
import { makeVarDecl, makeIdentResolved, makeBinary, makeAssign, makeArrayAccess, makeMember, makeExprStmt, makeIf, makeWhile, makeBlock, makeHiddenDeref, makeNumber } from "../util";
import { cloneFresh } from "../lowering/iterInline";
import { lowerLengthAssign } from "./builtinLower";

const PUSH_NATIVES = ["msGenericArrayPush", "msNumberArrayPush", "msStringArrayPush", "msUint8ArrayPush"];

class Build {
	out: Symbol;
	list: Node[];
	at: int32;
	counter: Symbol;
	bound: Node;
	pushAfterStep: boolean;
}

export function lowerPresizedPushes(program: Node, ctx: TransformContext): Node {
	if (ctx.jsBackend || ctx.raiserBackend || ctx.boundChecks) return program;
	visit(program, ctx);
	return program;
}

function visit(n: Node, ctx: TransformContext): void {
	forEachChild(n, (c: Node): void => visit(c, ctx));
	if (n.kind == NodeKind.Program) rewriteList((n.data as ProgramData).programStmts, ctx);
	else if (n.kind == NodeKind.BlockStmt) rewriteList((n.data as BlockStmtData).statements, ctx);
}

function rewriteList(stmts: Node[], ctx: TransformContext): void {
	for (let k: int32 = 0; k < stmts.length; k++) {
		const out = freshEmptyArray(stmts[k]);
		if (out == null) continue;
		const b = findBuild(out, stmts, k + 1);
		if (b != null) presize(b, ctx);
	}
}

function freshEmptyArray(s: Node): Symbol | null {
	if (s.kind != NodeKind.VariableDecl || s.resolvedSym == null || s.resolvedSym.symbolType == null) return null;
	const d = s.data as VariableDeclData;
	if (d.declKind == DeclKind.Var || d.initializer == null || d.initializer.kind != NodeKind.ArrayLiteral) return null;
	if ((d.initializer.data as ArrayLiteralData).elements.length != 0) return null;
	return arrayType(s.resolvedSym.symbolType) != null ? s.resolvedSym : null;
}

// An array local is a counted cell read through a deref.
function arrayType(t: Type | null): Type | null {
	if (t == null) return null;
	let a = peelTransparentInstance(t);
	if (a.kind == TypeKind.Ref && a.typeReturn != null) a = peelTransparentInstance(a.typeReturn);
	return a.kind == TypeKind.Array ? a : null;
}

function arrayRead(b: Build, loc: SourceLocation): Node {
	const id = makeIdentResolved(b.out, loc);
	id.nodeType = b.out.symbolType;
	const t = arrayType(b.out.symbolType)!;
	if (peelTransparentInstance(b.out.symbolType).kind != TypeKind.Ref) return id;
	const d = makeHiddenDeref(id, loc);
	d.nodeType = t;
	return d;
}

// The loop is the first statement after the declaration that mentions `out`, reached through blocks and
// once-loops only, so nothing that can catch a raise or read `out` runs between them.
function findBuild(out: Symbol, stmts: Node[], from: int32): Build | null {
	for (let j: int32 = from; j < stmts.length; j++) {
		const s = stmts[j];
		if (!mentions(s, out)) continue;
		if (s.kind == NodeKind.BlockStmt) return findBuild(out, (s.data as BlockStmtData).statements, 0);
		if (isOnceLoop(s)) {
			const body = (s.data as DoWhileStmtData).doBody;
			return body.kind == NodeKind.BlockStmt ? findBuild(out, (body.data as BlockStmtData).statements, 0) : null;
		}
		return s.kind == NodeKind.WhileStmt && j > 0 ? countedBuild(out, stmts, j) : null;
	}
	return null;
}

function isOnceLoop(s: Node): boolean {
	if (s.kind != NodeKind.DoWhileStmt) return false;
	const c = (s.data as DoWhileStmtData).doCondition;
	return c.kind == NodeKind.BooleanLiteral && !(c.data as BooleanLiteralData).boolValue;
}

// `let i = 0; while (i < A.length) { body }`, where `body` holds one top-level `i += 1`, runs `out.push(e)` once
// on every path that finishes the step, reads `out` nowhere else, and nothing in it leaves the step early or
// writes `i` again. A push after the step stores at `i - 1`.
function countedBuild(out: Symbol, stmts: Node[], at: int32): Build | null {
	const loop = stmts[at].data as WhileStmtData;
	const counter = zeroCounterBefore(loop.whileCondition, stmts, at);
	if (counter == null) return null;
	const bound = lengthBound(loop.whileCondition, counter);
	if (bound == null || loop.whileLabel != "" || loop.whileBody.kind != NodeKind.BlockStmt) return null;
	const body = (loop.whileBody.data as BlockStmtData).statements;
	let step: int32 = -1;
	let pushAt: int32 = -1;
	const owners = [out];
	for (let i: int32 = 0; i < body.length; i++) {
		if (isUnitStep(body[i], counter)) {
			if (step >= 0) return null;
			step = i;
			continue;
		}
		if (noteAlias(body[i], owners)) continue;
		if (!stepSafe(body[i], counter) || (bound.kind == NodeKind.Identifier && !stepSafe(body[i], bound.resolvedSym!))) return null;
		const n = straightPushes(body[i], owners);
		if (n < 0 || (n > 0 && pushAt >= 0) || n > 1) return null;
		if (n == 1) pushAt = i;
	}
	if (step < 0 || pushAt < 0) return null;
	return { out, list: stmts, at, counter, bound, pushAfterStep: pushAt > step };
}

// The counter the condition tests, declared at 0 before the loop with only other declarations in between.
function zeroCounterBefore(cond: Node, stmts: Node[], at: int32): Symbol | null {
	if (cond.kind != NodeKind.BinaryExpr) return null;
	const left = (cond.data as BinaryExprData).left;
	const counter = left.kind == NodeKind.Identifier ? left.resolvedSym : null;
	if (counter == null || counter.symbolType == null || peelTransparentInstance(counter.symbolType).kind != TypeKind.Int64) return null;
	for (let j: int32 = at - 1; j >= 0; j--) {
		const s = stmts[j];
		if (s.kind != NodeKind.VariableDecl) return null;
		if (s.resolvedSym != counter) {
			if (mentions(s, counter)) return null;
			continue;
		}
		const init = (s.data as VariableDeclData).initializer;
		return init != null && init.kind == NodeKind.NumberLiteral && (init.data as NumberLiteralData).intVal == 0 ? counter : null;
	}
	return null;
}

function lengthBound(cond: Node, counter: Symbol): Node | null {
	if (cond.kind != NodeKind.BinaryExpr) return null;
	const d = cond.data as BinaryExprData;
	if (d.operator != "<" || !names(d.left, counter)) return null;
	let r = d.right;
	while (r.kind == NodeKind.HiddenStdConv || r.kind == NodeKind.TypeAssertion) {
		r = r.kind == NodeKind.HiddenStdConv ? (r.data as HiddenStdConvData).convExpr : (r.data as TypeAssertionData).asExpr;
	}
	if (r.kind == NodeKind.Identifier && r.resolvedSym != null && r.resolvedSym != counter) return d.right;
	if (r.kind != NodeKind.MemberExpr) return null;
	const m = r.data as MemberExprData;
	if (m.property != "length" || m.isOptional) return null;
	let a = m.object;
	if (a.kind == NodeKind.HiddenDeref) a = (a.data as HiddenDerefData).expr;
	if (a.kind != NodeKind.Identifier || a.resolvedSym == null || a.nodeType == null) return null;
	return d.right;
}

function isUnitStep(s: Node, counter: Symbol): boolean {
	if (s.kind != NodeKind.ExprStmt) return false;
	const e = (s.data as ExprStmtData).expr;
	if (e.kind == NodeKind.UpdateExpr) {
		const u = e.data as UpdateExprData;
		return u.updateOp == "++" && names(u.updateArg, counter);
	}
	if (e.kind != NodeKind.BinaryExpr) return false;
	const d = e.data as BinaryExprData;
	if (!names(d.left, counter)) return false;
	if (d.operator == "+=") return isOne(d.right);
	if (d.operator != "=" || d.right.kind != NodeKind.BinaryExpr) return false;
	const sum = d.right.data as BinaryExprData;
	return sum.operator == "+" && names(sum.left, counter) && isOne(sum.right);
}

function stepSafe(n: Node, counter: Symbol): boolean {
	if (isRoutineNode(n)) return false;
	if (n.kind == NodeKind.BreakStmt || n.kind == NodeKind.ContinueStmt || n.kind == NodeKind.ReturnStmt
			|| n.kind == NodeKind.YieldExpr || n.kind == NodeKind.AwaitExpr || n.kind == NodeKind.DeferStmt) return false;
	if (n.kind == NodeKind.BinaryExpr && isAssignOp((n.data as BinaryExprData).operator) && names((n.data as BinaryExprData).left, counter)) return false;
	if (n.kind == NodeKind.UpdateExpr && names((n.data as UpdateExprData).updateArg, counter)) return false;
	let ok = true;
	forEachChild(n, (c: Node): void => {
		if (ok && !stepSafe(c, counter)) ok = false;
	});
	return ok;
}

// Pushes onto `out` that run every time `s` finishes, or -1 when `out` is read anywhere else in `s`. A const
// copied from `out` before the push (an operand the call order hoists) names the same array.
function straightPushes(s: Node, owners: Symbol[]): int32 {
	if (s.kind == NodeKind.BlockStmt) {
		let n: int32 = 0;
		for (const c of (s.data as BlockStmtData).statements) {
			if (noteAlias(c, owners)) continue;
			const k = straightPushes(c, owners);
			if (k < 0) return -1;
			n += k;
		}
		return n;
	}
	const v = pushedValue(s, owners);
	if (v != null) return mentionsAny(v, owners) ? -1 : 1;
	return mentionsAny(s, owners) ? -1 : 0;
}

function noteAlias(s: Node, owners: Symbol[]): boolean {
	if (s.kind != NodeKind.VariableDecl || s.resolvedSym == null) return false;
	const d = s.data as VariableDeclData;
	if (d.declKind != DeclKind.Const || d.initializer == null) return false;
	for (const o of owners) {
		if (names(d.initializer, o)) {
			owners.push(s.resolvedSym);
			return true;
		}
	}
	return false;
}

function mentionsAny(n: Node, owners: Symbol[]): boolean {
	for (const o of owners) {
		if (mentions(n, o)) return true;
	}
	return false;
}

function pushedValue(s: Node, owners: Symbol[]): Node | null {
	if (s.kind != NodeKind.ExprStmt) return null;
	const call = (s.data as ExprStmtData).expr;
	if (call.kind != NodeKind.CallExpr) return null;
	const d = call.data as CallExprData;
	const sym = call.resolvedSym != null ? call.resolvedSym : d.callee.resolvedSym;
	if (sym == null || sym.nativeName == null || !PUSH_NATIVES.includes(sym.nativeName.startsWith("&") ? sym.nativeName.slice(1) : sym.nativeName)) return null;
	let receiver: Node;
	let value: Node;
	if (d.callee.kind == NodeKind.MemberExpr) {
		if (d.arguments.length != 1) return null;
		receiver = (d.callee.data as MemberExprData).object;
		value = d.arguments[0];
	} else {
		if (d.arguments.length != 2) return null;
		receiver = d.arguments[0];
		value = d.arguments[1];
	}
	if (receiver.kind == NodeKind.HiddenAddr || receiver.kind == NodeKind.HiddenDeref) receiver = (receiver.data as HiddenDerefData).expr;
	for (const o of owners) {
		if (names(receiver, o)) return value;
	}
	return null;
}

function storeInstead(s: Node, b: Build, owners: Symbol[]): boolean {
	if (s.kind == NodeKind.BlockStmt) {
		for (const c of (s.data as BlockStmtData).statements) {
			if (noteAlias(c, owners)) continue;
			if (storeInstead(c, b, owners)) return true;
		}
		return false;
	}
	const v = pushedValue(s, owners);
	if (v == null) return false;
	let index = counterRead(b, s);
	if (b.pushAfterStep) {
		index = makeBinary(index, "-", makeNumber(1, s.location), s.location);
		index.nodeType = b.counter.symbolType;
	}
	const slot = makeArrayAccess(arrayRead(b, s.location), index, s.location);
	slot.nodeType = arrayType(b.out.symbolType)!.typeReturn;
	const store = makeAssign(slot, v, s.location);
	store.nodeType = slot.nodeType;
	(s.data as ExprStmtData).expr = store;
	return true;
}

// let n = A.length; out.length = n;
// while (i < n && i < A.length) { body with out[i] = e; i += 1 }
// if (i < n) out.length = i;
// while (i < A.length) { body with out.push(e); i += 1 }
function presize(b: Build, ctx: TransformContext): void {
	const loop = b.list[b.at];
	const loc = loop.location;
	const lenType = b.bound.nodeType;
	const n = newLoweredSym(ctx, SymbolKind.Variable, freshTemp(ctx, "n"), lenType);
	const nDecl = makeVarDecl(n.name, cloneNodeKeepSem(b.bound), DeclKind.Const, loc);
	nDecl.nodeType = lenType;
	nDecl.resolvedSym = n;
	const cond = (loop.data as WhileStmtData).whileCondition;
	const fastCond = makeBinary(below(b, n, cond, loc), "&&", cloneNodeKeepSem(cond), loc);
	fastCond.nodeType = cond.nodeType;
	const body = cloneFresh((loop.data as WhileStmtData).whileBody, new HashMap<Symbol, Symbol>(), ctx, true);
	if (!storeInstead(body, b, [b.out])) throw new Error("internal: a presized push loop lost its push when its body was copied");
	const cut = makeIf(below(b, n, cond, loc), makeBlock([setLength(b, counterRead(b, loop), ctx, loc)], loc), null, loc);
	const before = [nDecl, setLength(b, makeIdentResolved(n, loc), ctx, loc), makeWhile(fastCond, body, loc), cut];
	for (let k: int32 = 0; k < before.length; k++) b.list.splice(b.at + k, 0, before[k]);
}

function below(b: Build, n: Symbol, cond: Node, loc: SourceLocation): Node {
	const bound = makeIdentResolved(n, loc);
	bound.nodeType = n.symbolType;
	const e = makeBinary(counterRead(b, cond), "<", bound, loc);
	e.nodeType = cond.nodeType;
	return e;
}

function counterRead(b: Build, at: Node): Node {
	const r = makeIdentResolved(b.counter, at.location);
	r.nodeType = b.counter.symbolType;
	return r;
}

function setLength(b: Build, len: Node, ctx: TransformContext, loc: SourceLocation): Node {
	const member = makeMember(arrayRead(b, loc), "length", loc);
	member.nodeType = b.bound.nodeType;
	const assign = makeAssign(member, len, loc);
	assign.nodeType = len.nodeType;
	return makeExprStmt(lowerLengthAssign(assign, ctx), loc);
}

function names(n: Node, sym: Symbol): boolean {
	return n.kind == NodeKind.Identifier && n.resolvedSym == sym;
}

function isOne(n: Node): boolean {
	return n.kind == NodeKind.NumberLiteral && (n.data as NumberLiteralData).intVal == 1;
}

function mentions(n: Node, sym: Symbol): boolean {
	if (n.resolvedSym == sym && (n.kind == NodeKind.Identifier || n.kind == NodeKind.VariableDecl)) return true;
	let hit = false;
	forEachChild(n, (c: Node): void => {
		if (!hit && mentions(c, sym)) hit = true;
	});
	return hit;
}
