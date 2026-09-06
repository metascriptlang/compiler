// New Expression Lowering — materialize positional `new C(a, b)` on a class
// WITHOUT a user constructor into a hoisted temp + field assignments:
//
//   const p = new Pt(1, 2);
//     →
//   const $new_0 = new Pt();   // alloc + Pt_init (field defaults, super chain)
//   $new_0.x = 1;
//   $new_0.y = 2;
//   const p = $new_0;
//
// Positional new without a constructor is a MetaScript extension (TS rejects
// the args). Before this pass the C backend carried an inline positional
// branch in codegen and JS had nothing — `new Pt(1, 2)` silently dropped both
// args on JS. One statement-splice lowering here serves both backends: the
// materialize-once shape Nim uses at sem (defaultFieldsForTheUninitialized).
// The 0-arg `new` runs <Class>_init (super chain + field defaults, ctorLower),
// then the positional assignments override — same order the C branch had.
//
// Classes WITH a user constructor (SymbolFlag.HasConstructor) are untouched:
// their `new` routes to <Class>_new / the JS constructor with real parameters.
//
// A statement whose expression still holds a conditionally-evaluated spot
// (`&&`/`||` RHS, ternary arm) is skipped here — an eager hoist would evaluate
// the args unconditionally. The pass runs a SECOND time after
// conditionalExprLower, by which point those spots are real branches and the
// news inside them sit at ordinary statement positions; lowering empties
// `newArguments`, so the second run only sees what the first refused.
//
// A while-condition re-evaluates per iteration, so it is not hoisted before the
// loop but rewritten to `while (true) { <hoist>; if (!cond) break; body }` —
// the same shape conditionalExprLower uses for a ternary in that position.

import {
	Node, NodeKind, NewExprData, VariableDeclData, ExprStmtData, IfStmtData,
	ReturnStmtData, WhileStmtData, DeclKind, Type, TypeKind,
} from "../../ast/node";
import { SymbolFlag, hasFlag } from "../../checker/symbol";
import { TransformContext, createTransformContext, freshTempSym } from "../context";
import { walkExpandBlocks, replaceInExpr } from "../walker";
import { forEachChild } from "../../ast/visitor";
import { containsConditionalEval } from "./callHoist";
import { makeVarDecl, makeIdentResolved, makeMember, makeAssign, makeExprStmt, makeBlock, makeIf, makeUnary, makeBreak, makeBool, extractBodyStmts } from "../util";
import { firstExprKindAfter, stmtCountAfter, parseInput, getStmts } from "../testUtil";

// ===== Gate =====

// The unwrapped Struct type of a lowerable NewExpr, or null. Lowerable means:
// resolved callee without a user constructor, at least one argument, and a
// class type carrying field names to map the positional args onto.
function positionalStruct(node: Node): Type | null {
	if (node.kind != NodeKind.NewExpr) return null;
	const d = node.data as NewExprData;
	if (d.newArguments.length == 0) return null;
	const sym = d.newCallee.resolvedSym;
	if (sym == null || hasFlag(sym, SymbolFlag.HasConstructor)) return null;
	const classType = node.nodeType;
	if (classType == null) return null;
	const inner = (classType.kind == TypeKind.Ref || classType.kind == TypeKind.Ptr) ? classType.typeReturn : classType;
	if (inner == null) return null;
	if (inner.typeNames == null || d.newArguments.length > inner.typeNames.length) return null;
	return inner;
}

function hasPositionalNew(expr: Node): boolean {
	let found = false;
	replaceInExpr(expr, (node: Node): Node => {
		if (positionalStruct(node) != null) { found = true; }
		return node;
	});
	return found;
}

// Statement-subtree variant — used by conditionalExprLower to skip JS statements
// whose conditional constructs hold no positional new (those keep native ternary
// / short-circuit on JS). Walks expr AND stmt nodes via the child visitor.
export function nodeHasPositionalNew(node: Node): boolean {
	let found = false;
	function visit(n: Node): void {
		if (found || n == null) return;
		if (positionalStruct(n) != null) { found = true; return; }
		forEachChild(n, visit);
	}
	visit(node);
	return found;
}

// ===== Hoist =====

// Bottom-up: an inner positional new inside another's args is materialized
// first, so its temp ref is already in place when the outer one captures args.
function hoistPositionalNews(expr: Node, hoisted: Node[], ctx: TransformContext): Node {
	return replaceInExpr(expr, (node: Node): Node => {
		const inner = positionalStruct(node);
		if (inner == null) return node;
		const d = node.data as NewExprData;
		const args = d.newArguments;
		d.newArguments = [];
		const ty = node.nodeType;
		const loc = node.location;
		const sym = freshTempSym(ctx, "new", ty);
		const decl = makeVarDecl(sym.name, node, DeclKind.Const, loc);
		decl.resolvedSym = sym;
		decl.nodeType = ty;
		hoisted.push(decl);
		let i = 0;
		while (i < args.length) {
			const recv = makeIdentResolved(sym, loc);
			recv.nodeType = ty;
			const target = makeMember(recv, inner.typeNames[i], loc);
			if (inner.typeChildren != null && i < inner.typeChildren.length) {
				target.nodeType = inner.typeChildren[i];
			}
			hoisted.push(makeExprStmt(makeAssign(target, args[i], loc), loc));
			i += 1;
		}
		const ref = makeIdentResolved(sym, loc);
		ref.nodeType = ty;
		return ref;
	});
}

// ===== Statement expanders =====

function expandVarDecl(stmt: Node, ctx: TransformContext): Node[] {
	const d = stmt.data as VariableDeclData;
	if (d.initializer == null || containsConditionalEval(d.initializer)) return [stmt];
	const hoisted: Node[] = [];
	d.initializer = hoistPositionalNews(d.initializer, hoisted, ctx);
	if (hoisted.length == 0) return [stmt];
	hoisted.push(stmt);
	return hoisted;
}

function expandExprStmt(stmt: Node, ctx: TransformContext): Node[] {
	const ed = stmt.data as ExprStmtData;
	if (ed.expr == null || containsConditionalEval(ed.expr)) return [stmt];
	const hoisted: Node[] = [];
	ed.expr = hoistPositionalNews(ed.expr, hoisted, ctx);
	if (hoisted.length == 0) return [stmt];
	hoisted.push(stmt);
	return hoisted;
}

function expandReturn(stmt: Node, ctx: TransformContext): Node[] {
	const rd = stmt.data as ReturnStmtData;
	if (rd.argument == null || containsConditionalEval(rd.argument)) return [stmt];
	const hoisted: Node[] = [];
	rd.argument = hoistPositionalNews(rd.argument, hoisted, ctx);
	if (hoisted.length == 0) return [stmt];
	hoisted.push(stmt);
	return hoisted;
}

function altChainHasPositionalNew(alt: Node): boolean {
	if (alt.kind != NodeKind.IfStmt) return false;
	const d = alt.data as IfStmtData;
	if (hasPositionalNew(d.condition)) return true;
	if (d.alternate != null) return altChainHasPositionalNew(d.alternate);
	return false;
}

// `if (COND)` evaluates once when control reaches it → hoisting before the if
// is correct. An `else if` condition is the `.alternate`, never a statement-
// list entry — wrap it in a block so the walker descends and lowers the
// now-listed inner if (same trick as callHoist expandIf).
function expandIf(stmt: Node, ctx: TransformContext): Node[] {
	const ifd = stmt.data as IfStmtData;
	if (ifd.alternate != null && ifd.alternate.kind == NodeKind.IfStmt && altChainHasPositionalNew(ifd.alternate)) {
		ifd.alternate = makeBlock([ifd.alternate], ifd.alternate.location);
	}
	if (containsConditionalEval(ifd.condition)) return [stmt];
	const hoisted: Node[] = [];
	ifd.condition = hoistPositionalNews(ifd.condition, hoisted, ctx);
	if (hoisted.length == 0) return [stmt];
	hoisted.push(stmt);
	return hoisted;
}

// `while (COND)` re-evaluates COND per iteration, so hoisting before the loop
// would construct once and reuse the same object. Same shape conditionalExprLower
// uses: run on `true` and re-test at the top of the body, where the hoist belongs.
function expandWhile(stmt: Node, ctx: TransformContext): Node[] {
	const wd = stmt.data as WhileStmtData;
	if (containsConditionalEval(wd.whileCondition)) return [stmt];
	const pre: Node[] = [];
	const cond = hoistPositionalNews(wd.whileCondition, pre, ctx);
	if (pre.length == 0) return [stmt];
	const loc = stmt.location;
	pre.push(makeIf(makeUnary("!", cond, loc), makeBlock([makeBreak(loc)], loc), null as unknown as Node, loc));
	for (const s of extractBodyStmts(wd.whileBody)) { pre.push(s); }
	wd.whileCondition = makeBool(true, loc);
	wd.whileBody = makeBlock(pre, loc);
	return [stmt];
}

function expandStmt(stmt: Node, ctx: TransformContext): Node[] {
	return match (stmt.kind) {
		NodeKind.VariableDecl => expandVarDecl(stmt, ctx),
		NodeKind.ExprStmt => expandExprStmt(stmt, ctx),
		NodeKind.ReturnStmt => expandReturn(stmt, ctx),
		NodeKind.IfStmt => expandIf(stmt, ctx),
		NodeKind.WhileStmt => expandWhile(stmt, ctx),
		_ => [stmt],
	};
}

// ===== Entry Point =====

export function lowerNewExpr(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandStmt, ctx);
	return program;
}

// ===== Tests =====
// Parse-only input carries no resolvedSym/nodeType, so the gate skips it —
// these pin the pass to leaving unresolved and 0-arg news untouched. The
// end-to-end lowering is proven by the positional-new guard programs.

test "new Foo() stays NewExpr (no args, nothing to lower)" { assert firstExprKindAfter("new Foo();", lowerNewExpr) == NodeKind.NewExpr; }

test "unresolved new Bar(x, y) is left untouched" {
	assert firstExprKindAfter("new Bar(x, y);", lowerNewExpr) == NodeKind.NewExpr;
}

test "non-new unchanged" { assert firstExprKindAfter("foo();", lowerNewExpr) == NodeKind.CallExpr; }

test "stmt count preserved on unresolved input" { assert stmtCountAfter("new A(); new B();", lowerNewExpr) == 2; }

test "unresolved args preserved in NewExpr" {
	const result = parseInput("new Foo(1, 2);");
	if (!result.ok) { assert false; return; }
	const ctx = createTransformContext();
	const prog = lowerNewExpr(result.value, ctx);
	const stmts = getStmts(prog);
	const sd = stmts[0].data as ExprStmtData;
	assert sd.expr.kind == NodeKind.NewExpr;
	const nd = (sd.expr.data as NewExprData);
	assert nd.newArguments.length == 2;
}
