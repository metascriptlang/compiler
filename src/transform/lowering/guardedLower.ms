// Guarded hoisting — lowers an expression kind that needs statements (a `match`, a `try`)
// out of an expression without evaluating it where the expression would not.
//
// A position evaluated conditionally (`&&`/`||` right operand, ternary arm) rewrites its OWNER
// to statement form, so the block re-walk lowers the kind inside the branch that guards it.
// A loop condition becomes `while (true) { <hoisted>; if (!cond) break; body }`.

import { Node, NodeKind, DeclKind, TypeKind, WhileStmtData, DoWhileStmtData, ForStmtData, SwitchStmtData, AssertStmtData, IfStmtData, VariableDeclData, ExprStmtData, BinaryExprData, ConditionalExprData } from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { containsExprKind, mapExprChildren } from "../walker";
import { lowerForStmt } from "./forLoopLower";
import { moveDoWhileTestIntoBody } from "./jumpRetarget";
import { makeIdentResolved, makeBlock, makeVarDecl, makeExprStmt, makeNull, makeIf, makeAssign, makeBool, makeUnary, makeBreak, extractBodyStmts } from "../util";

export type KindHoister = (node: Node, hoisted: Node[], ctx: TransformContext) => Node;

export function hoistGuarded(expr: Node, kind: NodeKind, hoistKind: KindHoister, hoisted: Node[], ctx: TransformContext): Node {
	if (expr.kind == NodeKind.BinaryExpr) {
		const bd = expr.data as BinaryExprData;
		if (bd.operator == "&&" || bd.operator == "||") {
			bd.left = hoistGuarded(bd.left, kind, hoistKind, hoisted, ctx);
			if (containsExprKind(bd.right, kind)) {
				return lowerGuardedShortCircuit(expr, hoisted, ctx);
			}
			return expr;
		}
	}
	if (expr.kind == NodeKind.ConditionalExpr) {
		const cd = expr.data as ConditionalExprData;
		cd.ternaryCondition = hoistGuarded(cd.ternaryCondition, kind, hoistKind, hoisted, ctx);
		if (containsExprKind(cd.ternaryConsequent, kind) || containsExprKind(cd.ternaryAlternate, kind)) {
			return lowerGuardedTernary(expr, hoisted, ctx);
		}
		return expr;
	}
	if (expr.kind == kind) {
		return hoistKind(expr, hoisted, ctx);
	}
	mapExprChildren(expr, (child: Node): Node => hoistGuarded(child, kind, hoistKind, hoisted, ctx));
	return expr;
}

// a && rhs → const $sclhs = a; let $scres; if ($sclhs) { $scres = rhs; } else { $scres = $sclhs; }
// a || rhs → const $sclhs = a; let $scres; if ($sclhs) { $scres = $sclhs; } else { $scres = rhs; }
export function lowerGuardedShortCircuit(expr: Node, hoisted: Node[], ctx: TransformContext): Node {
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

// c ? a : b → let $gtern; if (c) { $gtern = a; } else { $gtern = b; }
export function lowerGuardedTernary(expr: Node, hoisted: Node[], ctx: TransformContext): Node {
	const cd = expr.data as ConditionalExprData;
	const loc = expr.location;
	const t = freshTempSym(ctx, "gtern", expr.nodeType);
	const letDecl = makeVarDecl(t.name, makeNull(loc), DeclKind.Let, loc);
	letDecl.resolvedSym = t;
	if (expr.nodeType != null) { letDecl.nodeType = expr.nodeType; }
	hoisted.push(letDecl);
	const thenStmt = (cd.ternaryConsequent.nodeType != null && cd.ternaryConsequent.nodeType.kind == TypeKind.Never)
		? makeExprStmt(cd.ternaryConsequent, loc)
		: makeExprStmt(makeAssign(makeIdentResolved(t, loc), cd.ternaryConsequent, loc), loc);
	const elseStmt = (cd.ternaryAlternate.nodeType != null && cd.ternaryAlternate.nodeType.kind == TypeKind.Never)
		? makeExprStmt(cd.ternaryAlternate, loc)
		: makeExprStmt(makeAssign(makeIdentResolved(t, loc), cd.ternaryAlternate, loc), loc);
	hoisted.push(makeIf(cd.ternaryCondition, makeBlock([thenStmt], loc), makeBlock([elseStmt], loc), loc));
	return makeIdentResolved(t, loc);
}

// The condition-carrying statements (`if`, loops, `switch`, `assert`): what the condition
// hoists runs where the condition ran, once per iteration for a loop.
export function expandConditionStmt(stmt: Node, kind: NodeKind, hoistKind: KindHoister, ctx: TransformContext): Node[] {
	match (stmt.kind) {
		NodeKind.IfStmt => {
			const d = stmt.data as IfStmtData;
			if (!containsExprKind(d.condition, kind)) return [stmt];
			const pre: Node[] = [];
			d.condition = hoistGuarded(d.condition, kind, hoistKind, pre, ctx);
			if (pre.length > 0) { pre.push(stmt); return pre; }
		},
		NodeKind.WhileStmt => {
			const d = stmt.data as WhileStmtData;
			if (!containsExprKind(d.whileCondition, kind)) return [stmt];
			const pre: Node[] = [];
			const cond = hoistGuarded(d.whileCondition, kind, hoistKind, pre, ctx);
			if (pre.length > 0) {
				const loc = stmt.location;
				pre.push(makeIf(makeUnary("!", cond, loc), makeBlock([makeBreak(loc)], loc), null, loc));
				for (const s of extractBodyStmts(d.whileBody)) { pre.push(s); }
				d.whileCondition = makeBool(true, loc);
				d.whileBody = makeBlock(pre, loc);
			}
		},
		NodeKind.DoWhileStmt => {
			const d = stmt.data as DoWhileStmtData;
			if (!containsExprKind(d.doCondition, kind)) return [stmt];
			const pre: Node[] = [];
			const cond = hoistGuarded(d.doCondition, kind, hoistKind, pre, ctx);
			if (pre.length > 0) { moveDoWhileTestIntoBody(stmt, pre, cond, ctx); }
		},
		NodeKind.ForStmt => {
			// Native for headers are already normalized; JS keeps them until a
			// header needs statements. Reuse the same continue-safe loop tail.
			const d = stmt.data as ForStmtData;
			let init: Node | null = d.forInit;
			if (init != null && init.kind == NodeKind.VariableDecl) {
				init = (init.data as VariableDeclData).initializer;
			} else if (init != null && init.kind == NodeKind.ExprStmt) {
				init = (init.data as ExprStmtData).expr;
			}
			if (containsExprKind(init, kind)
				|| containsExprKind(d.forCondition, kind)
				|| containsExprKind(d.forUpdate, kind)) {
				return [lowerForStmt(stmt, ctx)];
			}
		},
		NodeKind.SwitchStmt => {
			const d = stmt.data as SwitchStmtData;
			if (!containsExprKind(d.switchDisc, kind)) return [stmt];
			const pre: Node[] = [];
			d.switchDisc = hoistGuarded(d.switchDisc, kind, hoistKind, pre, ctx);
			if (pre.length > 0) { pre.push(stmt); return pre; }
		},
		NodeKind.AssertStmt => {
			const d = stmt.data as AssertStmtData;
			if (!containsExprKind(d.assertExpr, kind)) return [stmt];
			const pre: Node[] = [];
			d.assertExpr = hoistGuarded(d.assertExpr, kind, hoistKind, pre, ctx);
			if (pre.length > 0) { pre.push(stmt); return pre; }
		},
		_ => {},
	};
	return [stmt];
}
