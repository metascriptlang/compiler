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
//     (per-iteration re-eval like while; `continue` would skip the trailing
//     test, so that combination fails loud — zero users in the tree)
//
// Runs AFTER optionalChain/nullishCoalesce (which produce ternaries) and
// lowerOperators (so overloaded struct-returning operators are CallExprs here).

import { Node, NodeKind, DeclKind, TypeKind, SourceLocation, ExprStmtData, ConditionalExprData, VariableDeclData, ReturnStmtData, BinaryExprData, WhileStmtData, DoWhileStmtData, ArrayAccessData, MemberExprData, HiddenDerefData } from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { forEachChild } from "../../ast/visitor";
import { walkExpandBlocks, mapExprChildren, mapChildren } from "../walker";
import { makeIf, makeBlock, makeExprStmt, makeVarDecl, makeAssign, makeIdent, makeIdentResolved, makeNull, makeReturn, makeBool, makeBreak, makeUnary, extractBodyStmts } from "../util";
import { firstStmtKindAfter, stmtCountAfter, firstExprKindAfter } from "../testUtil";
import { nodeHasPositionalNew } from "./newExprLower";

// ===== Hoist (top-down) =====

// A noreturn arm never yields a value (Nim endsInNoReturn): emit the bare call,
// not an assignment — its result type has no C carrier to assign from.
function branchValueStmt(target: Node, branch: Node, loc: SourceLocation): Node {
	if (branch.nodeType !== null && branch.nodeType.kind === TypeKind.Never) {
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
	if (expr === null) return expr;
	if (expr.kind === NodeKind.BinaryExpr) {
		const bd = expr.data as BinaryExprData;
		if (bd.operator === "&&" || bd.operator === "||") {
			bd.left = hoistTernaries(bd.left, hoisted, ctx);
			return lowerShortCircuitExpr(expr, hoisted, ctx);
		}
	}
	if (expr.kind === NodeKind.ConditionalExpr) {
		const cd = expr.data as ConditionalExprData;
		cd.ternaryCondition = hoistTernaries(cd.ternaryCondition, hoisted, ctx);
		const loc = expr.location;
		const t = freshTempSym(ctx, "tern", expr.nodeType);
		const letDecl = makeVarDecl(t.name, makeNull(loc), DeclKind.Let, loc);
		letDecl.resolvedSym = t;
		if (expr.nodeType !== null) { letDecl.nodeType = expr.nodeType; }
		hoisted.push(letDecl);
		const thenStmt = branchValueStmt(makeIdentResolved(t, loc), cd.ternaryConsequent, loc);
		const elseStmt = branchValueStmt(makeIdentResolved(t, loc), cd.ternaryAlternate, loc);
		hoisted.push(makeIf(cd.ternaryCondition, makeBlock([thenStmt], loc), makeBlock([elseStmt], loc), loc));
		return makeIdentResolved(t, loc);
	}
	mapExprChildren(expr, (child: Node): Node => hoistTernaries(child, hoisted, ctx));
	return expr;
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
	if (expr.nodeType !== null) { resDecl.nodeType = expr.nodeType; }
	hoisted.push(resDecl);

	const rhsAssign = makeExprStmt(makeAssign(makeIdentResolved(resSym, loc), bd.right, loc), loc);
	const lhsAssign = makeExprStmt(makeAssign(makeIdentResolved(resSym, loc), makeIdentResolved(lhsSym, loc), loc), loc);
	const isAnd = bd.operator === "&&";
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
			if (d.initializer !== null && d.initializer.kind === NodeKind.ConditionalExpr) {
				return lowerTernaryInVar(stmt, ctx);
			}
		},
		NodeKind.ReturnStmt => {
			const d = stmt.data as ReturnStmtData;
			if (d.argument !== null && d.argument.kind === NodeKind.ConditionalExpr) {
				return lowerTernaryInReturn(stmt, ctx);
			}
		},
		NodeKind.ExprStmt => {
			const d = stmt.data as ExprStmtData;
			if (d.expr.kind === NodeKind.ConditionalExpr) {
				const cd = d.expr.data as ConditionalExprData;
				const pre: Node[] = [];
				cd.ternaryCondition = hoistTernaries(cd.ternaryCondition, pre, ctx);
				const thenStmt = makeExprStmt(cd.ternaryConsequent, loc);
				const elseStmt = makeExprStmt(cd.ternaryAlternate, loc);
				pre.push(makeIf(cd.ternaryCondition, makeBlock([thenStmt], loc), makeBlock([elseStmt], loc), loc));
				return pre;
			}
			if (d.expr.kind === NodeKind.BinaryExpr) {
				const bd = d.expr.data as BinaryExprData;
				if (isAssignOperator(bd.operator)) { return expandAssignStmt(stmt, ctx); }
			}
		},
		NodeKind.WhileStmt => { return expandWhileCond(stmt, ctx); },
		NodeKind.DoWhileStmt => { return expandDoWhileCond(stmt, ctx); },
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
	cd.ternaryCondition = hoistTernaries(cd.ternaryCondition, result, ctx);
	const letDecl = makeVarDecl(vd.declName, makeNull(loc), DeclKind.Let, loc);
	letDecl.resolvedSym = stmt.resolvedSym;
	if (stmt.nodeType !== null) { letDecl.nodeType = stmt.nodeType; }
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
	cd.ternaryCondition = hoistTernaries(cd.ternaryCondition, result, ctx);
	const thenStmt = (cd.ternaryConsequent.nodeType !== null && cd.ternaryConsequent.nodeType.kind === TypeKind.Never)
		? makeExprStmt(cd.ternaryConsequent, loc)
		: makeReturn(cd.ternaryConsequent, loc);
	const elseStmt = (cd.ternaryAlternate.nodeType !== null && cd.ternaryAlternate.nodeType.kind === TypeKind.Never)
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
	const cond = hoistTernaries(wd.whileCondition, pre, ctx);
	if (pre.length === 0) return [stmt];
	const loc = stmt.location;
	pre.push(makeIf(makeUnary("!", cond, loc), makeBlock([makeBreak(loc)], loc), null as unknown as Node, loc));
	for (const s of extractBodyStmts(wd.whileBody)) { pre.push(s); }
	wd.whileCondition = makeBool(true, loc);
	wd.whileBody = makeBlock(pre, loc);
	return [stmt];
}

function isAssignOperator(op: string): boolean {
	return op === "=" || op === "+=" || op === "-=" || op === "*=" || op === "/=" || op === "%=";
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
		bd.left = hoistAssignTargetEffects(bd.left, pre, ctx);
		for (const s of rhsPre) { pre.push(s); }
	}
	if (pre.length === 0) return [stmt];
	pre.push(stmt);
	return pre;
}

// Hoist the effectful parts of an assignment TARGET into preceding temps.
// Lvalue paths (ident, member/index chains over them) must stay paths — a
// temp would copy a struct and the store would hit the copy — so only
// rvalue-producing parts are hoisted: index expressions, and Call/New in
// object position (their result is a reference; temping preserves identity).
function hoistAssignTargetEffects(target: Node, pre: Node[], ctx: TransformContext): Node {
	if (target === null) return target;
	if (target.kind === NodeKind.ArrayAccess) {
		const ad = target.data as ArrayAccessData;
		ad.array = hoistAssignTargetEffects(ad.array, pre, ctx);
		ad.index = hoistRvalueToTemp(ad.index, pre, ctx);
		return target;
	}
	if (target.kind === NodeKind.MemberExpr) {
		const md = target.data as MemberExprData;
		md.object = hoistAssignTargetEffects(md.object, pre, ctx);
		return target;
	}
	if (target.kind === NodeKind.HiddenDeref || target.kind === NodeKind.HiddenAddr) {
		const hd = target.data as HiddenDerefData;
		hd.expr = hoistAssignTargetEffects(hd.expr, pre, ctx);
		return target;
	}
	if (target.kind === NodeKind.CallExpr || target.kind === NodeKind.NewExpr) {
		return hoistRvalueToTemp(target, pre, ctx);
	}
	return target;
}

function hoistRvalueToTemp(expr: Node, pre: Node[], ctx: TransformContext): Node {
	if (expr.kind === NodeKind.Identifier || expr.kind === NodeKind.NumberLiteral
		|| expr.kind === NodeKind.StringLiteral || expr.kind === NodeKind.BooleanLiteral) return expr;
	const loc = expr.location;
	const sym = freshTempSym(ctx, "lhs", expr.nodeType);
	const decl = makeVarDecl(sym.name, expr, DeclKind.Const, loc);
	decl.resolvedSym = sym;
	if (expr.nodeType !== null) { decl.nodeType = expr.nodeType; }
	pre.push(decl);
	return makeIdentResolved(sym, loc);
}

// do { BODY } while (COND) re-evaluates COND after each iteration, so the
// hoisted statements must run at the END of the body:
//   do { BODY } while (t ? a : b) → do { BODY; <hoisted>; if (!c) break; } while (true)
// `continue` targets the condition and would skip the trailing test — that
// combination fails loud instead of silently looping forever.
function expandDoWhileCond(stmt: Node, ctx: TransformContext): Node[] {
	const wd = stmt.data as DoWhileStmtData;
	const pre: Node[] = [];
	const cond = hoistTernaries(wd.doCondition, pre, ctx);
	if (pre.length === 0) return [stmt];
	if (bodyHasLoopContinue(wd.doBody)) {
		ctx.errors.push("do-while: a condition that lowers to statements (ternary / '&&' / '||') combined with 'continue' in the loop body is not supported on the C backend yet");
		return [stmt];
	}
	const loc = stmt.location;
	const stmts: Node[] = extractBodyStmts(wd.doBody);
	for (const s of pre) { stmts.push(s); }
	stmts.push(makeIf(makeUnary("!", cond, loc), makeBlock([makeBreak(loc)], loc), null as unknown as Node, loc));
	wd.doCondition = makeBool(true, loc);
	wd.doBody = makeBlock(stmts, loc);
	return [stmt];
}

function bodyHasLoopContinue(node: Node): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.ContinueStmt) return true;
	if (node.kind === NodeKind.WhileStmt || node.kind === NodeKind.DoWhileStmt
		|| node.kind === NodeKind.ForStmt || node.kind === NodeKind.ForOfStmt
		|| node.kind === NodeKind.ForInStmt || node.kind === NodeKind.FunctionDecl
		|| node.kind === NodeKind.FunctionExpr || node.kind === NodeKind.ArrowFunction) return false;
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
test "ternary in stmt becomes if" { assert firstStmtKindAfter("a ? b : c;", lowerConditionalExpr) === NodeKind.IfStmt; }

test "non-ternary ExprStmt unchanged" { assert firstStmtKindAfter("f();", lowerConditionalExpr) === NodeKind.ExprStmt; }

test "pure var-init ternary lowers to let + if" { assert stmtCountAfter("const x = a ? b : c;", lowerConditionalExpr) === 2; }

test "call-arg ternary hoisted" { assert stmtCountAfter("f(a ? b : c);", lowerConditionalExpr) === 3; }

test "concat-operand ternary hoisted" { assert stmtCountAfter("g(s + (a ? b : c));", lowerConditionalExpr) === 3; }

test "if-condition ternary hoisted" { assert stmtCountAfter("if (a ? b : c) {}", lowerConditionalExpr) === 3; }

test "short-circuit lowers to guarded branches" { assert stmtCountAfter("const x = a && b;", lowerConditionalExpr) === 4; }

test "short-circuit RHS ternary re-lowers inside its branch" { assert stmtCountAfter("const x = a && (b ? c : d);", lowerConditionalExpr) === 4; }

test "short-circuit LHS ternary hoisted before the guard" { assert stmtCountAfter("const x = (a ? b : c) && d;", lowerConditionalExpr) === 6; }

test "do-while condition ternary lowers into body end" { assert firstStmtKindAfter("do { f(); } while (a ? b : c);", lowerConditionalExpr) === NodeKind.DoWhileStmt; }

test "while-condition ternary lowers into body" { assert firstStmtKindAfter("while (a ? b : c) { f(); }", lowerConditionalExpr) === NodeKind.WhileStmt; }

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", lowerConditionalExpr) === NodeKind.WhileStmt; }

test "stmt count preserved" { assert stmtCountAfter("let a = 1; let b = 2;", lowerConditionalExpr) === 2; }

test "binary expr unchanged" { assert firstExprKindAfter("x + y;", lowerConditionalExpr) === NodeKind.BinaryExpr; }
