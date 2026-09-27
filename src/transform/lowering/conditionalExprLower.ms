// Conditional Expression Lowering — no ternary survives to a C `?:`.
//
// A MetaScript `?:` promises conditional evaluation. On C, any raise-checked
// call compiles to statements (trailing `if (msErr) goto`), so an arm holding
// one cannot sit inside a C `?:` — codegen flattens the statement out of the
// `?:` and the untaken arm runs. There is no complete "safe arm" predicate
// (three prior hazard-list patches each missed a shape), so EVERY ternary
// lowers to real branches (matchLower / reference genIf parity):
//
//   const x = t / return t / t;  — direct shapes (no temp for return/stmt)
//   any other statement          — mapChildren + hoistTernaries
//   while (t)                    — while(true){ <hoisted>; if(!c) break; body }
//     (a preceding hoist would evaluate once, not per iteration)
//
// Conditionally-evaluated positions never hoist OUT of their guard: ternary
// arms become assignments inside the generated if-blocks and re-lower there
// via the block re-walk (top-down — arms are NOT descended at hoist time),
// and `&&`/`||` rewrite to guarded statements the same way (no predicate on
// the RHS — a statement-emitting RHS inlined into a C `&&` runs
// unconditionally, corpus 215): LHS is descended, RHS re-lowers inside the
// branch that owns it.
//
//   do { B } while (t)           — B + <hoisted> + if(!c) break, cond=true
//     (per-iteration re-eval like while; a `continue` of B leaves a labelled
//     block around B, so it still reaches the test)
//
// Codegen checks msErr only after a statement's top-level call, so a call that
// can raise in a condition, a literal element or a return value inside a try
// becomes its own statement here.
//
// Runs AFTER optionalChain/nullishCoalesce (which produce ternaries) and
// lowerOperators (so overloaded struct-returning operators are CallExprs here).

import { Node, NodeKind, DeclKind, TypeKind, Symbol, createNode, SourceLocation, ExprStmtData, ConditionalExprData, VariableDeclData, ReturnStmtData, BinaryExprData, WhileStmtData, DoWhileStmtData, ArrayAccessData, MemberExprData, HiddenDerefData, UpdateExprData, OutExprData, IfStmtData, SwitchStmtData, SpreadExprData, CallExprData } from "../../ast/node";
import { TransformContext, freshTempSym, freshOwnedSym } from "../context";
import { forEachChild } from "../../ast/visitor";
import { cloneNodeKeepSem } from "../../monomorphize/clone";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { walkExpandBlocks, expandingInsideTry, mapExprChildren, mapChildren, hasEffect } from "../walker";
import { makeIf, makeBlock, makeExprStmt, makeVarDecl, makeAssign, makeIdent, makeIdentResolved, makeNull, makeReturn, makeBool, makeBreak, makeUnary, extractBodyStmts, syntheticToken } from "../util";
import { firstStmtKindAfter, stmtCountAfter, firstExprKindAfter } from "../testUtil";
import { nodeHasPositionalNew } from "./newExprLower";
import { moveDoWhileTestIntoBody } from "./jumpRetarget";
import { isLowerableSpreadLiteral, expandSpreadLiteral } from "../desugar/arraySpreadLower";
import { spreadStructOf, expandObjectSpread } from "../desugar/objectSpreadLower";

// ===== Hoist (top-down) =====

// A noreturn arm never yields a value (Nim endsInNoReturn): emit the bare call,
// not an assignment — its result type has no C carrier to assign from.
function branchValueStmt(target: Node, branch: Node, loc: SourceLocation): Node {
	if (branch.nodeType != null && branch.nodeType.kind == TypeKind.Never) {
		return makeExprStmt(branch, loc);
	}
	return makeExprStmt(makeAssign(target, branch, loc), loc);
}

// Replace every ternary at an unconditionally-evaluated position within `expr`
// by a temp, pushing `let $tern; if (cond) $tern = a; else $tern = b;` onto
// `hoisted`. The ternary CONDITION is unconditional → descended; the ARMS are
// not — they become assignments inside the if-blocks and the block re-walk
// lowers whatever they contain in the correct (guarded) scope. `&&`/`||` RHS
// is conditionally evaluated → never descended (LHS is).
function hoistTernaries(expr: Node, hoisted: Node[], ctx: TransformContext): Node {
	if (expr == null) return expr;
	if (expr.kind == NodeKind.BinaryExpr) {
		const bd = expr.data as BinaryExprData;
		if (bd.operator == "&&" || bd.operator == "||") {
			bd.left = hoistTernaries(bd.left, hoisted, ctx);
			return lowerShortCircuitExpr(expr, hoisted, ctx);
		}
	}
	if (expr.kind == NodeKind.ConditionalExpr) {
		const cd = expr.data as ConditionalExprData;
		cd.ternaryCondition = hoistRaisingCalls(cd.ternaryCondition, hoisted, ctx);
		const loc = expr.location;
		const t = freshTempSym(ctx, "tern", expr.nodeType);
		const letDecl = makeVarDecl(t.name, makeNull(loc), DeclKind.Let, loc);
		letDecl.resolvedSym = t;
		if (expr.nodeType != null) { letDecl.nodeType = expr.nodeType; }
		hoisted.push(letDecl);
		const thenStmt = branchValueStmt(makeIdentResolved(t, loc), cd.ternaryConsequent, loc);
		const elseStmt = branchValueStmt(makeIdentResolved(t, loc), cd.ternaryAlternate, loc);
		hoisted.push(makeIf(cd.ternaryCondition, makeBlock([thenStmt], loc), makeBlock([elseStmt], loc), loc));
		return makeIdentResolved(t, loc);
	}
	if (expr.kind == NodeKind.UpdateExpr) return hoistUpdate(expr, hoisted, ctx);
	if (!ctx.jsBackend) {
		if (expr.kind == NodeKind.ArrayLiteral || expr.kind == NodeKind.ObjectLiteral) return hoistLiteral(expr, hoisted, ctx);
		if (expr.kind == NodeKind.SpreadExpr) return hoistSpreadOperand(expr, hoisted, ctx);
	}
	hoistChildrenInOrder(expr, hoisted, ctx);
	if (callsToStatements > 0 && callCanRaise(expr)) return bindToStatement(expr, "call", hoisted, ctx);
	return expr;
}

let callsToStatements = 0;

function hoistRaisingCalls(expr: Node, hoisted: Node[], ctx: TransformContext): Node {
	callsToStatements += 1;
	const lowered = hoistTernaries(expr, hoisted, ctx);
	callsToStatements -= 1;
	return lowered;
}

function callCanRaise(n: Node): boolean {
	if (n.nodeType != null && (n.nodeType.kind == TypeKind.Void || n.nodeType.kind == TypeKind.Never)) return false;
	if (n.kind == NodeKind.NewExpr) return true;
	if (n.kind != NodeKind.CallExpr) return false;
	const sym = (n.data as CallExprData).callee.resolvedSym;
	if (sym == null) return true;
	return hasFlag(sym, SymbolFlag.Throws) || !hasFlag(sym, SymbolFlag.ImportC);
}

function bindToStatement(expr: Node, prefix: string, hoisted: Node[], ctx: TransformContext): Node {
	const loc = expr.location;
	const sym = freshOwnedSym(ctx, prefix, expr.nodeType);
	const value = createNode(expr.kind, expr.data, syntheticToken(loc));
	value.location = loc;
	value.nodeType = expr.nodeType;
	value.resolvedSym = expr.resolvedSym;
	value.flags = expr.flags;
	value.variantSlot = expr.variantSlot;
	value.typeArg = expr.typeArg;
	value.typeExpr = expr.typeExpr;
	const decl = makeVarDecl(sym.name, value, DeclKind.Const, loc);
	decl.resolvedSym = sym;
	if (expr.nodeType != null) { decl.nodeType = expr.nodeType; }
	hoisted.push(decl);
	const ref = makeIdentResolved(sym, loc);
	expr.kind = ref.kind;
	expr.data = ref.data;
	expr.flags = ref.flags;
	expr.resolvedSym = sym;
	expr.variantSlot = 0;
	expr.typeArg = "";
	expr.typeExpr = null;
	return expr;
}

function hoistLiteral(lit: Node, hoisted: Node[], ctx: TransformContext): Node {
	callsToStatements += 1;
	hoistChildrenInOrder(lit, hoisted, ctx);
	callsToStatements -= 1;
	if (isLowerableSpreadLiteral(lit)) {
		expandSpreadLiteral(lit, ctx, hoisted);
		return lit;
	}
	return lit.kind == NodeKind.ObjectLiteral ? expandObjectSpread(lit) : lit;
}

function hoistSpreadOperand(spread: Node, hoisted: Node[], ctx: TransformContext): Node {
	const sd = spread.data as SpreadExprData;
	sd.spreadArg = hoistTernaries(sd.spreadArg, hoisted, ctx);
	if (sd.spreadArg.kind != NodeKind.Identifier && spreadStructOf(sd.spreadArg.nodeType) != null) {
		sd.spreadArg = bindToStatement(sd.spreadArg, "sprd", hoisted, ctx);
	}
	return spread;
}

function hoistUpdate(expr: Node, hoisted: Node[], ctx: TransformContext): Node {
	const ud = expr.data as UpdateExprData;
	const loc = expr.location;
	ud.updateArg = hoistTernaries(ud.updateArg, hoisted, ctx);
	ud.updateArg = hoistAssignTargetEffects(ud.updateArg, hoisted, ctx, []);
	const t = freshTempSym(ctx, "upd", expr.nodeType);
	const decl = makeVarDecl(t.name, cloneNodeKeepSem(ud.updateArg), DeclKind.Const, loc);
	decl.resolvedSym = t;
	if (expr.nodeType != null) { decl.nodeType = expr.nodeType; }
	const step = makeExprStmt(expr, loc);
	if (ud.isPrefix) {
		hoisted.push(step);
		hoisted.push(decl);
	} else {
		hoisted.push(decl);
		hoisted.push(step);
	}
	return makeIdentResolved(t, loc);
}

// Nim keeps strict left-to-right order: each call is materialized at its own position
// (fixupCall) and a read aliased by a later write gets a temp (genParams, ccgcalls.nim).
function hoistChildrenInOrder(expr: Node, hoisted: Node[], ctx: TransformContext): void {
	const kids: Node[] = [];
	const ends: int32[] = [];
	mapExprChildren(expr, (child: Node): Node => {
		const lowered = hoistTernaries(child, hoisted, ctx);
		kids.push(lowered);
		ends.push(hoisted.length);
		return lowered;
	});
	let i = kids.length - 2;
	while (i >= 0) {
		if (ends[i] < hoisted.length && kids[i] != null) {
			const writes: Symbol[] = [];
			let w = ends[i];
			while (w < hoisted.length) { collectWrites(hoisted[w], writes); w += 1; }
			const pre: Node[] = [];
			kids[i] = captureSibling(expr, i, kids[i], pre, writes, ctx);
			let p = 0;
			while (p < pre.length) { hoisted.splice(ends[i] + p, 0, pre[p]); p += 1; }
		}
		i -= 1;
	}
	let k = 0;
	mapExprChildren(expr, (child: Node): Node => {
		const next = kids[k];
		k += 1;
		return next;
	});
}

function captureSibling(parent: Node, index: int32, child: Node, pre: Node[], writes: Symbol[], ctx: TransformContext): Node {
	const isCallee = index == 0 && (parent.kind == NodeKind.CallExpr || parent.kind == NodeKind.NewExpr);
	if (isCallee) return child;
	const isLocation = index == 0 && (parent.kind == NodeKind.MemberExpr || parent.kind == NodeKind.ArrayAccess
		|| parent.kind == NodeKind.HiddenDeref || parent.kind == NodeKind.HiddenAddr
		|| (parent.kind == NodeKind.BinaryExpr && isAssignOperator((parent.data as BinaryExprData).operator)));
	if (isLocation) return hoistAssignTargetEffects(child, pre, ctx, writes);
	if (isLiteral(child)) return child;
	if (!hasEffect(child) && !readsAnyOf(child, writes)) return child;
	const loc = child.location;
	const sym = freshOwnedSym(ctx, "ord", child.nodeType);
	const decl = makeVarDecl(sym.name, child, DeclKind.Const, loc);
	decl.resolvedSym = sym;
	if (child.nodeType != null) { decl.nodeType = child.nodeType; }
	pre.push(decl);
	return makeIdentResolved(sym, loc);
}

function isLiteral(n: Node): boolean {
	return n.kind == NodeKind.NumberLiteral || n.kind == NodeKind.StringLiteral
		|| n.kind == NodeKind.BooleanLiteral || n.kind == NodeKind.NullLiteral;
}

function isFunctionNode(n: Node): boolean {
	return n.kind == NodeKind.FunctionDecl || n.kind == NodeKind.FunctionExpr || n.kind == NodeKind.ArrowFunction;
}

function writtenRoot(target: Node): Symbol | null {
	let cur = target;
	while (cur != null) {
		if (cur.kind == NodeKind.Identifier) return cur.resolvedSym;
		if (cur.kind == NodeKind.MemberExpr) {
			cur = (cur.data as MemberExprData).object;
		} else if (cur.kind == NodeKind.ArrayAccess) {
			cur = (cur.data as ArrayAccessData).array;
		} else if (cur.kind == NodeKind.HiddenDeref || cur.kind == NodeKind.HiddenAddr) {
			cur = (cur.data as HiddenDerefData).expr;
		} else {
			return null;
		}
	}
	return null;
}

function collectWrites(n: Node, writes: Symbol[]): void {
	if (n == null || isFunctionNode(n)) return;
	let target: Node | null = null;
	if (n.kind == NodeKind.BinaryExpr && isAssignOperator((n.data as BinaryExprData).operator)) {
		target = (n.data as BinaryExprData).left;
	} else if (n.kind == NodeKind.UpdateExpr) {
		target = (n.data as UpdateExprData).updateArg;
	} else if (n.kind == NodeKind.OutExpr) {
		target = (n.data as OutExprData).outArg;
	} else if (n.kind == NodeKind.HiddenAddr) {
		target = (n.data as HiddenDerefData).expr;
	}
	if (target != null) {
		const root = writtenRoot(target);
		if (root != null) { writes.push(root); }
	}
	forEachChild(n, (c: Node): void => collectWrites(c, writes));
}

function readsAnyOf(n: Node, writes: Symbol[]): boolean {
	if (n == null || writes.length == 0 || isFunctionNode(n)) return false;
	if (n.kind == NodeKind.Identifier && n.resolvedSym != null) {
		for (const w of writes) {
			if (w == n.resolvedSym) return true;
		}
		return false;
	}
	let found = false;
	forEachChild(n, (c: Node): void => {
		if (!found && readsAnyOf(c, writes)) { found = true; }
	});
	return found;
}

// a && rhs → const $sclhs = a; let $scres; if ($sclhs) { $scres = rhs; } else { $scres = $sclhs; }
// a || rhs → const $sclhs = a; let $scres; if ($sclhs) { $scres = $sclhs; } else { $scres = rhs; }
function lowerShortCircuitExpr(expr: Node, hoisted: Node[], ctx: TransformContext): Node {
	const bd = expr.data as BinaryExprData;
	const loc = expr.location;
	const lhsSym = freshTempSym(ctx, "sclhs", bd.left.nodeType);
	const lhsDecl = makeVarDecl(lhsSym.name, bd.left, DeclKind.Const, loc);
	lhsDecl.resolvedSym = lhsSym;
	hoisted.push(lhsDecl);

	const resSym = freshTempSym(ctx, "scres", expr.nodeType);
	const resDecl = makeVarDecl(resSym.name, makeNull(loc), DeclKind.Let, loc);
	resDecl.resolvedSym = resSym;
	if (expr.nodeType != null) { resDecl.nodeType = expr.nodeType; }
	hoisted.push(resDecl);

	const rhsAssign = makeExprStmt(makeAssign(makeIdentResolved(resSym, loc), bd.right, loc), loc);
	const lhsAssign = makeExprStmt(makeAssign(makeIdentResolved(resSym, loc), makeIdentResolved(lhsSym, loc), loc), loc);
	const isAnd = bd.operator == "&&";
	const thenBlk = makeBlock([isAnd ? rhsAssign : lhsAssign], loc);
	const elseBlk = makeBlock([isAnd ? lhsAssign : rhsAssign], loc);
	hoisted.push(makeIf(makeIdentResolved(lhsSym, loc), thenBlk, elseBlk, loc));
	return makeIdentResolved(resSym, loc);
}

// ===== Statement expansion =====

// The expander runs ONCE per statement and its output is only re-walked into
// BLOCKS — so the direct shapes must hoist from their ternary's CONDITION
// themselves (the generated IfStmt is never re-expanded).
function expandConditionalStmt(stmt: Node, ctx: TransformContext): Node[] {
	// On JS, ternaries and short-circuits are native and need no statement
	// rewrite — UNLESS one holds a positional `new`, which cannot stay in a JS
	// expression after newExprLower refused it. Gate the whole statement on
	// that, so `const x = true ? 1 : 2` stays `(true ? 1 : 2)` on JS.
	if (ctx.jsBackend && !nodeHasPositionalNew(stmt)) return [stmt];
	const loc = stmt.location;
	match (stmt.kind) {
		NodeKind.VariableDecl => {
			const d = stmt.data as VariableDeclData;
			if (d.initializer != null && d.initializer.kind == NodeKind.ConditionalExpr) {
				return lowerTernaryInVar(stmt, ctx);
			}
		},
		NodeKind.ReturnStmt => {
			const d = stmt.data as ReturnStmtData;
			if (d.argument != null && d.argument.kind == NodeKind.ConditionalExpr) {
				return lowerTernaryInReturn(stmt, ctx);
			}
			if (d.argument != null && expandingInsideTry()) {
				const pre: Node[] = [];
				d.argument = hoistRaisingCalls(d.argument, pre, ctx);
				pre.push(stmt);
				return pre;
			}
		},
		NodeKind.ExprStmt => {
			const d = stmt.data as ExprStmtData;
			if (d.expr.kind == NodeKind.ConditionalExpr) {
				const cd = d.expr.data as ConditionalExprData;
				const pre: Node[] = [];
				cd.ternaryCondition = hoistRaisingCalls(cd.ternaryCondition, pre, ctx);
				const thenStmt = makeExprStmt(cd.ternaryConsequent, loc);
				const elseStmt = makeExprStmt(cd.ternaryAlternate, loc);
				pre.push(makeIf(cd.ternaryCondition, makeBlock([thenStmt], loc), makeBlock([elseStmt], loc), loc));
				return pre;
			}
			if (d.expr.kind == NodeKind.BinaryExpr) {
				const bd = d.expr.data as BinaryExprData;
				if (isAssignOperator(bd.operator)) { return expandAssignStmt(stmt, ctx); }
			}
			if (d.expr.kind == NodeKind.UpdateExpr) {
				const ud = d.expr.data as UpdateExprData;
				const pre: Node[] = [];
				ud.updateArg = hoistTernaries(ud.updateArg, pre, ctx);
				if (pre.length == 0) return [stmt];
				pre.push(stmt);
				return pre;
			}
		},
		NodeKind.WhileStmt => { return expandWhileCond(stmt, ctx); },
		NodeKind.DoWhileStmt => { return expandDoWhileCond(stmt, ctx); },
		NodeKind.IfStmt => { return expandIfCond(stmt, ctx); },
		NodeKind.SwitchStmt => { return expandSwitchDisc(stmt, ctx); },
		_ => {},
	};
	const hoisted: Node[] = [];
	mapChildren(stmt, (child: Node): Node => hoistTernaries(child, hoisted, ctx));
	if (hoisted.length > 0) {
		hoisted.push(stmt);
		return hoisted;
	}
	return [stmt];
}

// const x = cond ? a : b  →  <cond pre>; let x; if (cond) { x = a; } else { x = b; }
function lowerTernaryInVar(stmt: Node, ctx: TransformContext): Node[] {
	const vd = stmt.data as VariableDeclData;
	const cd = vd.initializer.data as ConditionalExprData;
	const loc = stmt.location;
	const result: Node[] = [];
	cd.ternaryCondition = hoistRaisingCalls(cd.ternaryCondition, result, ctx);
	const letDecl = makeVarDecl(vd.declName, makeNull(loc), DeclKind.Let, loc);
	letDecl.resolvedSym = stmt.resolvedSym;
	if (stmt.nodeType != null) { letDecl.nodeType = stmt.nodeType; }
	result.push(letDecl);
	const thenTarget = makeIdent(vd.declName, loc);
	thenTarget.resolvedSym = stmt.resolvedSym;
	const elseTarget = makeIdent(vd.declName, loc);
	elseTarget.resolvedSym = stmt.resolvedSym;
	const thenStmt = branchValueStmt(thenTarget, cd.ternaryConsequent, loc);
	const elseStmt = branchValueStmt(elseTarget, cd.ternaryAlternate, loc);
	result.push(makeIf(cd.ternaryCondition, makeBlock([thenStmt], loc), makeBlock([elseStmt], loc), loc));
	return result;
}

// return cond ? a : b  →  <cond pre>; if (cond) { return a; } else { return b; }
export function lowerTernaryInReturn(stmt: Node, ctx: TransformContext): Node[] {
	const rd = stmt.data as ReturnStmtData;
	const cd = rd.argument.data as ConditionalExprData;
	const loc = stmt.location;
	const result: Node[] = [];
	cd.ternaryCondition = hoistRaisingCalls(cd.ternaryCondition, result, ctx);
	const thenStmt = (cd.ternaryConsequent.nodeType != null && cd.ternaryConsequent.nodeType.kind == TypeKind.Never)
		? makeExprStmt(cd.ternaryConsequent, loc)
		: makeReturn(cd.ternaryConsequent, loc);
	const elseStmt = (cd.ternaryAlternate.nodeType != null && cd.ternaryAlternate.nodeType.kind == TypeKind.Never)
		? makeExprStmt(cd.ternaryAlternate, loc)
		: makeReturn(cd.ternaryAlternate, loc);
	result.push(makeIf(cd.ternaryCondition, makeBlock([thenStmt], loc), makeBlock([elseStmt], loc), loc));
	return result;
}

// while (COND) re-evaluates COND every iteration, so a preceding hoist is
// wrong. Same lowering as callHoist expandWhile (b3a):
//   while (t ? a : b) { BODY } → while (true) { <hoisted>; if (!c) break; BODY }
function expandWhileCond(stmt: Node, ctx: TransformContext): Node[] {
	const wd = stmt.data as WhileStmtData;
	const pre: Node[] = [];
	const cond = hoistRaisingCalls(wd.whileCondition, pre, ctx);
	if (pre.length == 0) return [stmt];
	const loc = stmt.location;
	pre.push(makeIf(makeUnary("!", cond, loc), makeBlock([makeBreak(loc)], loc), null as unknown as Node, loc));
	for (const s of extractBodyStmts(wd.whileBody)) { pre.push(s); }
	wd.whileCondition = makeBool(true, loc);
	wd.whileBody = makeBlock(pre, loc);
	return [stmt];
}

export function isAssignOperator(op: string): boolean {
	return op == "=" || op == "+=" || op == "-=" || op == "*=" || op == "/=" || op == "%=";
}

// Assignment statement: TS evaluates the target reference BEFORE the RHS.
// When the RHS lowers to statements, the target's effectful parts must hoist
// FIRST or they would run after the RHS machinery (corpus 217).
function expandAssignStmt(stmt: Node, ctx: TransformContext): Node[] {
	const d = stmt.data as ExprStmtData;
	const bd = d.expr.data as BinaryExprData;
	const pre: Node[] = [];
	bd.left = hoistTernaries(bd.left, pre, ctx);
	const rhsPre: Node[] = [];
	bd.right = hoistTernaries(bd.right, rhsPre, ctx);
	if (rhsPre.length > 0) {
		const writes: Symbol[] = [];
		for (const s of rhsPre) { collectWrites(s, writes); }
		collectWrites(bd.right, writes);
		bd.left = hoistAssignTargetEffects(bd.left, pre, ctx, writes);
		for (const s of rhsPre) { pre.push(s); }
	}
	if (pre.length == 0) return [stmt];
	pre.push(stmt);
	return pre;
}

// Hoist the effectful parts of an assignment TARGET into preceding temps.
// Lvalue paths (ident, member/index chains over them) must stay paths — a
// temp would copy a struct and the store would hit the copy — so only
// rvalue-producing parts are hoisted: index expressions, and Call/New in
// object position (their result is a reference; temping preserves identity).
export function hoistAssignTargetEffects(target: Node, pre: Node[], ctx: TransformContext, writes: Symbol[]): Node {
	if (target == null) return target;
	if (target.kind == NodeKind.ArrayAccess) {
		const ad = target.data as ArrayAccessData;
		ad.array = hoistAssignTargetEffects(ad.array, pre, ctx, writes);
		ad.index = hoistRvalueToTemp(ad.index, pre, ctx, writes);
		return target;
	}
	if (target.kind == NodeKind.MemberExpr) {
		const md = target.data as MemberExprData;
		md.object = hoistAssignTargetEffects(md.object, pre, ctx, writes);
		return target;
	}
	if (target.kind == NodeKind.HiddenDeref || target.kind == NodeKind.HiddenAddr) {
		const hd = target.data as HiddenDerefData;
		hd.expr = hoistAssignTargetEffects(hd.expr, pre, ctx, writes);
		return target;
	}
	if (target.kind == NodeKind.CallExpr || target.kind == NodeKind.NewExpr) {
		return hoistRvalueToTemp(target, pre, ctx, writes);
	}
	return target;
}

function hoistRvalueToTemp(expr: Node, pre: Node[], ctx: TransformContext, writes: Symbol[]): Node {
	if (isLiteral(expr)) return expr;
	const aliased = expr.kind == NodeKind.Identifier && readsAnyOf(expr, writes);
	if (expr.kind == NodeKind.Identifier && !aliased) return expr;
	const loc = expr.location;
	const sym = aliased ? freshOwnedSym(ctx, "lhs", expr.nodeType) : freshTempSym(ctx, "lhs", expr.nodeType);
	const decl = makeVarDecl(sym.name, expr, DeclKind.Const, loc);
	decl.resolvedSym = sym;
	if (expr.nodeType != null) { decl.nodeType = expr.nodeType; }
	pre.push(decl);
	return makeIdentResolved(sym, loc);
}

// do { BODY } while (COND) re-evaluates COND after each iteration, so the
// hoisted statements must run at the END of the body:
//   do { BODY } while (t ? a : b) → do { BODY; <hoisted>; if (!c) break; } while (true)
function expandDoWhileCond(stmt: Node, ctx: TransformContext): Node[] {
	const wd = stmt.data as DoWhileStmtData;
	if (wd.dwSwitchWrapper) return [stmt];
	const pre: Node[] = [];
	const cond = hoistRaisingCalls(wd.doCondition, pre, ctx);
	if (pre.length == 0) return [stmt];
	moveDoWhileTestIntoBody(stmt, pre, cond, ctx);
	return [stmt];
}

function expandIfCond(stmt: Node, ctx: TransformContext): Node[] {
	const d = stmt.data as IfStmtData;
	if (d.alternate != null && d.alternate.kind == NodeKind.IfStmt && condLowersToStatements((d.alternate.data as IfStmtData).condition)) {
		d.alternate = makeBlock([d.alternate], d.alternate.location);
	}
	const pre: Node[] = [];
	d.condition = hoistRaisingCalls(d.condition, pre, ctx);
	if (pre.length == 0) return [stmt];
	pre.push(stmt);
	return pre;
}

function expandSwitchDisc(stmt: Node, ctx: TransformContext): Node[] {
	const d = stmt.data as SwitchStmtData;
	const pre: Node[] = [];
	d.switchDisc = hoistRaisingCalls(d.switchDisc, pre, ctx);
	if (pre.length == 0) return [stmt];
	pre.push(stmt);
	return pre;
}

function condLowersToStatements(n: Node): boolean {
	if (n == null || isFunctionNode(n)) return false;
	if (n.kind == NodeKind.ConditionalExpr || n.kind == NodeKind.UpdateExpr || callCanRaise(n)
		|| n.kind == NodeKind.ArrayLiteral || n.kind == NodeKind.ObjectLiteral) return true;
	if (n.kind == NodeKind.BinaryExpr) {
		const op = (n.data as BinaryExprData).operator;
		if (op == "&&" || op == "||") return true;
	}
	let found = false;
	forEachChild(n, (c: Node): void => {
		if (!found && condLowersToStatements(c)) { found = true; }
	});
	return found;
}

export function bodyHasLoopContinue(node: Node): boolean {
	if (node == null) return false;
	if (node.kind == NodeKind.ContinueStmt) return true;
	if (node.kind == NodeKind.WhileStmt || node.kind == NodeKind.DoWhileStmt
		|| node.kind == NodeKind.ForStmt || node.kind == NodeKind.ForOfStmt
		|| node.kind == NodeKind.ForInStmt || node.kind == NodeKind.FunctionDecl
		|| node.kind == NodeKind.FunctionExpr || node.kind == NodeKind.ArrowFunction) return false;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && bodyHasLoopContinue(child)) { found = true; }
	});
	return found;
}

// ===== Entry Point =====

export function lowerConditionalExpr(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandConditionalStmt, ctx);
	return program;
}

// ===== Tests =====
test "ternary in stmt becomes if" { assert firstStmtKindAfter("a ? b : c;", lowerConditionalExpr) == NodeKind.IfStmt; }

test "non-ternary ExprStmt unchanged" { assert firstStmtKindAfter("f();", lowerConditionalExpr) == NodeKind.ExprStmt; }

test "pure var-init ternary lowers to let + if" { assert stmtCountAfter("const x = a ? b : c;", lowerConditionalExpr) == 2; }

test "call-arg ternary hoisted" { assert stmtCountAfter("f(a ? b : c);", lowerConditionalExpr) == 3; }

test "concat-operand ternary hoisted" { assert stmtCountAfter("g(s + (a ? b : c));", lowerConditionalExpr) == 3; }

test "if-condition ternary hoisted" { assert stmtCountAfter("if (a ? b : c) {}", lowerConditionalExpr) == 3; }

test "short-circuit lowers to guarded branches" { assert stmtCountAfter("const x = a && b;", lowerConditionalExpr) == 4; }

test "short-circuit RHS ternary re-lowers inside its branch" { assert stmtCountAfter("const x = a && (b ? c : d);", lowerConditionalExpr) == 4; }

test "short-circuit LHS ternary hoisted before the guard" { assert stmtCountAfter("const x = (a ? b : c) && d;", lowerConditionalExpr) == 6; }

test "do-while condition ternary lowers into body end" { assert firstStmtKindAfter("do { f(); } while (a ? b : c);", lowerConditionalExpr) == NodeKind.DoWhileStmt; }

test "while-condition ternary lowers into body" { assert firstStmtKindAfter("while (a ? b : c) { f(); }", lowerConditionalExpr) == NodeKind.WhileStmt; }

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", lowerConditionalExpr) == NodeKind.WhileStmt; }

test "stmt count preserved" { assert stmtCountAfter("let a = 1; let b = 2;", lowerConditionalExpr) == 2; }

test "binary expr unchanged" { assert firstExprKindAfter("x + y;", lowerConditionalExpr) == NodeKind.BinaryExpr; }

test "left call sibling of a hoisted ternary is captured first" { assert stmtCountAfter("f(a(), b ? c : d);", lowerConditionalExpr) == 4; }

test "pure left sibling of a hoisted ternary stays inline" { assert stmtCountAfter("f(x, b ? c : d);", lowerConditionalExpr) == 3; }

test "value-position update lowers to a temp and a step" { assert stmtCountAfter("f(i++);", lowerConditionalExpr) == 3; }

test "statement update stays a statement" { assert stmtCountAfter("i++;", lowerConditionalExpr) == 1; }
