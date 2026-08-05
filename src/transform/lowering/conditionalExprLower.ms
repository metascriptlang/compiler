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
// and `&&`/`||` RHS is left inline: C `&&` short-circuits what remains there
// correctly; a statement-emitting RHS is a known open seam (210-condNrvo
// note), unchanged by this pass.
//
// Runs AFTER optionalChain/nullishCoalesce (which produce ternaries) and
// lowerOperators (so overloaded struct-returning operators are CallExprs here).

import { Node, NodeKind, DeclKind, ExprStmtData, ConditionalExprData, VariableDeclData, ReturnStmtData, BinaryExprData, WhileStmtData } from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { walkExpandBlocks, mapExprChildren, mapChildren } from "../walker";
import { makeIf, makeBlock, makeExprStmt, makeVarDecl, makeAssign, makeIdent, makeIdentResolved, makeNull, makeReturn, makeBool, makeBreak, makeUnary, extractBodyStmts } from "../util";
import { firstStmtKindAfter, stmtCountAfter, firstExprKindAfter } from "../testUtil";

// ===== Hoist (top-down) =====

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
			return expr;
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
		const thenStmt = makeExprStmt(makeAssign(makeIdentResolved(t, loc), cd.ternaryConsequent, loc), loc);
		const elseStmt = makeExprStmt(makeAssign(makeIdentResolved(t, loc), cd.ternaryAlternate, loc), loc);
		hoisted.push(makeIf(cd.ternaryCondition, makeBlock([thenStmt], loc), makeBlock([elseStmt], loc), loc));
		return makeIdentResolved(t, loc);
	}
	mapExprChildren(expr, (child: Node): Node => hoistTernaries(child, hoisted, ctx));
	return expr;
}

// ===== Statement expansion =====

// The expander runs ONCE per statement and its output is only re-walked into
// BLOCKS — so the direct shapes must hoist from their ternary's CONDITION
// themselves (the generated IfStmt is never re-expanded).
function expandConditionalStmt(stmt: Node, ctx: TransformContext): Node[] {
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
		},
		NodeKind.WhileStmt => { return expandWhileCond(stmt, ctx); },
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
	const thenStmt = makeExprStmt(makeAssign(thenTarget, cd.ternaryConsequent, loc), loc);
	const elseStmt = makeExprStmt(makeAssign(elseTarget, cd.ternaryAlternate, loc), loc);
	result.push(makeIf(cd.ternaryCondition, makeBlock([thenStmt], loc), makeBlock([elseStmt], loc), loc));
	return result;
}

// return cond ? a : b  →  <cond pre>; if (cond) { return a; } else { return b; }
function lowerTernaryInReturn(stmt: Node, ctx: TransformContext): Node[] {
	const rd = stmt.data as ReturnStmtData;
	const cd = rd.argument.data as ConditionalExprData;
	const loc = stmt.location;
	const result: Node[] = [];
	cd.ternaryCondition = hoistTernaries(cd.ternaryCondition, result, ctx);
	const thenStmt = makeReturn(cd.ternaryConsequent, loc);
	const elseStmt = makeReturn(cd.ternaryAlternate, loc);
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

test "short-circuit RHS ternary stays inline" { assert stmtCountAfter("const x = a && (b ? c : d);", lowerConditionalExpr) === 1; }

test "short-circuit LHS ternary hoisted" { assert stmtCountAfter("const x = (a ? b : c) && d;", lowerConditionalExpr) === 3; }

test "while-condition ternary lowers into body" { assert firstStmtKindAfter("while (a ? b : c) { f(); }", lowerConditionalExpr) === NodeKind.WhileStmt; }

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", lowerConditionalExpr) === NodeKind.WhileStmt; }

test "stmt count preserved" { assert stmtCountAfter("let a = 1; let b = 2;", lowerConditionalExpr) === 2; }

test "binary expr unchanged" { assert firstExprKindAfter("x + y;", lowerConditionalExpr) === NodeKind.BinaryExpr; }
