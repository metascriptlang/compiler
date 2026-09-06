// Call Hoist — hoist a fresh RC-returning call out of a non-RC-consuming
// position into its own statement, so the analyzer's normal scope-exit cleanup
// destroys it.
//
// Problem: `const has = provide(path).ok` where provide returns a heap
// Result<string,string> but `has` is a bool. The analyzer's processVarDecl
// early-returns when the bound variable's type needs no cleanup, so the fresh
// Result is never walked, never registered for destroy, and leaks once per
// evaluation.
//
// Fix (statement-level hoist, the MetaScript equivalent of Nim's
// nkStmtListExpr in injectdestructors.nim — MetaScript has no such node):
//
//   const has = provide(path).ok;
//     →
//   const $hoist_N = provide(path);   // fresh RC value bound to a temp
//   const has = $hoist_N.ok;          // non-RC read off the temp
//
// The analyzer then sees an ordinary `const $hoist = call()` and cleans it via
// the well-trodden SINK-on-VariableDecl path at its canonical statement-walk
// position. This deliberately does NOT touch the analyzer (a prior fix that
// re-drove the analyzer's capture machinery from the binding-RHS expression
// position caused over-free) and does NOT wrap the pair in a BlockStmt (that
// would scope the binding away from following statements).
//
// Mirrors resultDesugar.ms: same walkExpandBlocks statement-list-level splice
// (NOT walkNode, NOT makeBlock) so the hoisted temp lands as a flat peer
// sibling in the parent scope.
//
// Positions covered (each evaluated once, unconditionally, when control
// reaches the statement → a preceding hoist is correct):
//   - VariableDecl initializer:  const has = f().ok        (b1)
//   - assignment RHS:            has = f().ok              (b1)
//   - if-condition:              if (f().ok) { ... }       (b2)
// Plus the LOOP condition, which re-evaluates every iteration so a *preceding*
// hoist is wrong — lowered to a top-of-body hoist + break instead (b3a):
//   while (f().ok) { BODY }
//     →  while (true) { const $t = f(); if (!($t.ok)) break; BODY }
//
// Short-circuit operands in an if / while condition (`if (a && f().ok)`) are
// handled too (b3b): f() there runs only sometimes, so instead of an eager hoist
// the condition is lowered to a flag + nested-if that preserves short-circuit
// (what Nim does for `and`/`or`) — see lowerShortCircuit. A fresh call inside a
// ternary branch is still left untouched (a flag rewrite can't express it), and
// short-circuit in a VariableDecl/assignment initializer is left to the analyzer.

import { Node, NodeKind, DeclKind, Symbol, SourceLocation, VariableDeclData, BinaryExprData, ExprStmtData, IfStmtData, WhileStmtData, ConditionalExprData, Type, TypeKind } from "../../ast/node";
import { isResult, isAwaitable, noneType, booleanType } from "../../checker/types";
import { TransformContext, freshTempSym } from "../context";
import { walkExpandBlocks, replaceInExpr } from "../walker";
import { makeVarDecl, makeIdentResolved, makeIf, makeBlock, makeBreak, makeUnary, makeBool, makeBinary, makeAssign, makeExprStmt, makeDefaultValue, extractBodyStmts } from "../util";

// A boolean condition lowered to: run `pre` statements (unconditionally, in order),
// then test `expr` (a pure boolean with no fresh RC call left in a conditional spot).
interface CondLower { pre: Node[]; expr: Node; }

// Owned-heap types whose fresh-call result needs scope-exit cleanup. Mirrors the
// owned set in analyzer/classify.ms classifyType WITHOUT importing it — transform
// (Phase 3) must not depend on the analyzer (Phase 4). Conservative: only the
// unambiguous owned-heap kinds. Ptr (borrow) and Struct (value type) are excluded.
function isRcReturning(t: Type | null): boolean {
	if (t == null) return false;
	// Awaitables (Promise<T> from async / spawn / actor CALL) are managed by the
	// await / spawn / actor lowering, NOT by plain scope-exit destroy. Hoisting an
	// awaited call out of its `await` breaks that machinery (PARALOCK). Never hoist.
	if (isAwaitable(t)) return false;
	// Owned-heap return types. A call's RC return is made owned for the caller at
	// the return site (Ref returns are increfed, String/Array deep-copied via
	// needsReturnIncref / passCopyToSink), so capturing the result in a temp and
	// destroying it at scope exit is balanced even for "borrow accessor" returns
	// like `current(state)` — verified safe natively (no over-free, container
	// intact). Result is the always-fresh subset. Awaitables excluded above. The
	// ONE hazard is NOT the type but the POSITION: a call inside a short-circuit
	// operand or ternary branch must not be hoisted eagerly — handled by the
	// conditional-eval skip in expandStmt, not here.
	if (isResult(t)) return true;
	return match (t.kind) {
		TypeKind.String | TypeKind.Array | TypeKind.SizedArray | TypeKind.Ref | TypeKind.Function => true,
		_ => false,
	};
}

// True if the expression contains a CONDITIONALLY-evaluated sub-position: the RHS
// of a short-circuit `&&`/`||`, or a ternary branch. A fresh call there runs only
// sometimes — hoisting it to a preceding statement would evaluate it eagerly and
// break the guard (proven: `if (xs.length>0 && xs[0].slice(...))` hoisted the slice
// before the length guard → crash). Such inits are skipped until the nested-if
// lowering (which preserves short-circuit) is in place.
export function containsConditionalEval(expr: Node): boolean {
	let found = false;
	replaceInExpr(expr, (node: Node): Node => {
		if (node.kind == NodeKind.ConditionalExpr) { found = true; }
		if (node.kind == NodeKind.BinaryExpr) {
			const op = (node.data as BinaryExprData).operator;
			if (op == "&&" || op == "||") { found = true; }
		}
		return node;
	});
	return found;
}

// Hoist every fresh RC-returning Call/New out of an expression tree into preceding
// statements (bottom-up: innermost calls declared first), replacing each with a
// reference to its temp. Returns the rewritten expression.
function hoistFreshRcCalls(expr: Node, hoisted: Node[], ctx: TransformContext): Node {
	return replaceInExpr(expr, (node: Node): Node => {
		if (node.kind != NodeKind.CallExpr && node.kind != NodeKind.NewExpr) return node;
		if (!isRcReturning(node.nodeType)) return node;
		const ty = node.nodeType != null ? node.nodeType : noneType();
		const loc = node.location;
		const sym = freshTempSym(ctx, "hoist", ty);
		const decl = makeVarDecl(sym.name, node, DeclKind.Const, loc);
		decl.resolvedSym = sym;
		decl.nodeType = ty;
		hoisted.push(decl);
		const ref = makeIdentResolved(sym, loc);
		ref.nodeType = ty;
		return ref;
	});
}

// Hoist a once-evaluated expression's fresh RC calls into preceding statements.
function plainHoist(expr: Node, ctx: TransformContext): CondLower {
	const pre: Node[] = [];
	const rewritten = hoistFreshRcCalls(expr, pre, ctx);
	return { pre, expr: rewritten };
}

// True if the expression tree contains a fresh RC-returning Call/New anywhere.
function containsFreshRcCall(expr: Node): boolean {
	let found = false;
	replaceInExpr(expr, (node: Node): Node => {
		if ((node.kind == NodeKind.CallExpr || node.kind == NodeKind.NewExpr) && isRcReturning(node.nodeType)) {
			found = true;
		}
		return node;
	});
	return found;
}

// True if an `else if` chain (the alternate of an IfStmt) holds a fresh RC call in
// any of its conditions. An `else if` is the `.alternate` of its parent IfStmt, not
// a statement-list entry, so expandStmt never reaches it directly — this drives the
// block-wrap in the IfStmt branch that brings it under the walker.
function altChainHasFreshCond(node: Node): boolean {
	if (node == null || node.kind != NodeKind.IfStmt) return false;
	const d = node.data as IfStmtData;
	if (containsFreshRcCall(d.condition)) return true;
	return altChainHasFreshCond(d.alternate);
}

// A block that runs `lowered.pre` then assigns `lowered.expr` to `sym` (typed `ty`).
// Shared by the short-circuit flag branch and the ternary result branches: the fresh
// temps in `lowered.pre` live in this block, so the analyzer destroys them at its scope
// exit only when the branch runs.
function assignBlock(sym: Symbol, ty: Type, lowered: CondLower, loc: SourceLocation): Node {
	const stmts: Node[] = [];
	for (const s of lowered.pre) { stmts.push(s); }
	if (lowered.expr.nodeType != null && lowered.expr.nodeType.kind == TypeKind.Never) {
		stmts.push(makeExprStmt(lowered.expr, loc));
		return makeBlock(stmts, loc);
	}
	const lhs = makeIdentResolved(sym, loc);
	lhs.nodeType = ty;
	stmts.push(makeExprStmt(makeAssign(lhs, lowered.expr, loc), loc));
	return makeBlock(stmts, loc);
}

// Lower a boolean condition that contains a fresh RC call in a SHORT-CIRCUIT
// operand (`a && f().ok`, `a || f().ok`) into preceding statements + a pure flag,
// preserving short-circuit evaluation. This is what Nim does (it lowers `and`/`or`
// to nested-if so injectdestructors sees the conditional fresh value); MetaScript
// has no nkStmtListExpr, so the flag + if is emitted as real statements.
//
//   a && f().ok   →   let $flag = false; if (a) { const $t = f(); $flag = $t.ok; }   test $flag
//   a || f().ok   →   let $flag = true;  if (!(a)) { const $t = f(); $flag = $t.ok; } test $flag
//
// The fresh `$t` lives in the inner if-block, so the analyzer destroys it at that
// block's scope exit only when the call actually ran — leak-free AND short-circuit
// correct. Ternary operands are handled by lowerTernary; a fresh call buried inside a
// non-short-circuit/non-ternary leaf (e.g. `(c ? f() : g()).ok`) returns null (caller
// leaves the statement untouched).
function lowerShortCircuit(cond: Node, ctx: TransformContext): CondLower | null {
	if (cond.kind == NodeKind.BinaryExpr) {
		const bd = cond.data as BinaryExprData;
		if (bd.operator == "&&" || bd.operator == "||") {
			const left = lowerShortCircuit(bd.left, ctx);
			if (left == null) return null;
			const loc = cond.location;
			// RHS has no fresh call → keep it inline; C's `&&`/`||` short-circuits it.
			if (!containsFreshRcCall(bd.right)) {
				return { pre: left.pre, expr: makeBinary(left.expr, bd.operator, bd.right, loc) };
			}
			// RHS has a fresh call → evaluate it only on the branch that reaches it.
			const right = lowerShortCircuit(bd.right, ctx);
			if (right == null) return null;
			const isAnd = bd.operator == "&&";
			const flagSym = freshTempSym(ctx, "sc", booleanType());
			const pre: Node[] = [];
			for (const s of left.pre) { pre.push(s); }
			const flagDecl = makeVarDecl(flagSym.name, makeBool(!isAnd, loc), DeclKind.Let, loc);
			flagDecl.resolvedSym = flagSym;
			flagDecl.nodeType = booleanType();
			pre.push(flagDecl);
			const guard = isAnd ? left.expr : makeUnary("!", left.expr, loc);
			pre.push(makeIf(guard, assignBlock(flagSym, booleanType(), right, loc), null as unknown as Node, loc));
			const flagRef = makeIdentResolved(flagSym, loc);
			flagRef.nodeType = booleanType();
			return { pre, expr: flagRef };
		}
	}
	if (cond.kind == NodeKind.ConditionalExpr) return lowerTernary(cond, ctx);
	// Leaf (no top-level short-circuit or ternary). A nested ternary with a fresh call
	// (e.g. `(c ? f() : g()).ok`) can't be plain-hoisted without eager-evaluating both
	// branches — bail.
	if (containsConditionalEval(cond)) return null;
	return plainHoist(cond, ctx);
}

// Lower a ternary whose branches may hold conditionally-evaluated fresh calls into a
// result temp + if/else, so each branch's fresh value gets its own scope (destroyed only
// when that branch runs). The condition is always evaluated; its own fresh calls hoist
// ahead. `$r` is non-RC here — the only callers are non-RC bindings and boolean
// conditions, so a default-init temp + branch assignment is sound. Returns null if a
// sub-part can't be lowered (deeper ternary) or the result type is RC (defensive).
function lowerTernary(cond: Node, ctx: TransformContext): CondLower | null {
	const cd = cond.data as ConditionalExprData;
	const loc = cond.location;
	const ty = cond.nodeType != null ? cond.nodeType : booleanType();
	if (isRcReturning(ty)) return null;
	const condL = lowerShortCircuit(cd.ternaryCondition, ctx);
	if (condL == null) return null;
	const thenL = lowerShortCircuit(cd.ternaryConsequent, ctx);
	if (thenL == null) return null;
	const elseL = lowerShortCircuit(cd.ternaryAlternate, ctx);
	if (elseL == null) return null;
	const resSym = freshTempSym(ctx, "tern", ty);
	const decl = makeVarDecl(resSym.name, makeDefaultValue(ty, loc), DeclKind.Let, loc);
	decl.resolvedSym = resSym;
	decl.nodeType = ty;
	const pre: Node[] = [];
	for (const s of condL.pre) { pre.push(s); }
	pre.push(decl);
	pre.push(makeIf(condL.expr, assignBlock(resSym, ty, thenL, loc), assignBlock(resSym, ty, elseL, loc), loc));
	const resRef = makeIdentResolved(resSym, loc);
	resRef.nodeType = ty;
	return { pre, expr: resRef };
}

// Lower a boolean condition for a once-or-per-iteration test position (if / while).
// Returns null when there is nothing to do (no fresh RC call) or the condition can't
// be safely lowered (fresh call inside a ternary branch).
function lowerBoolCond(cond: Node, ctx: TransformContext): CondLower | null {
	if (!containsFreshRcCall(cond)) return null;
	// No conditional-eval → every fresh call runs unconditionally → plain preceding hoist.
	if (!containsConditionalEval(cond)) return plainHoist(cond, ctx);
	// Short-circuit operand carries the fresh call → flag/nested-if lowering.
	return lowerShortCircuit(cond, ctx);
}

// `const x = f().ok` — once-evaluated initializer of a non-RC binding. Routed through
// lowerBoolCond: plain hoist for `f().ok`, flag for short-circuit `a && f().ok`, ternary
// →if/else for `c ? f().ok : g().ok`. The analyzer then SINKs the hoisted temps. Skipped
// when the binding's own type is RC (the analyzer already SINKs it).
function expandVarDecl(stmt: Node, ctx: TransformContext): Node[] {
	const d = stmt.data as VariableDeclData;
	if (d.initializer == null || isRcReturning(stmt.nodeType)) return [stmt];
	// Plain once-eval fresh calls are captured by the analyzer (processVarDecl Normal-walk +
	// processNode wrapper recursion). callHoist only keeps the conditional-eval cases.
	if (!containsConditionalEval(d.initializer)) return [stmt];
	const lowered = lowerBoolCond(d.initializer, ctx);
	if (lowered == null) return [stmt];
	d.initializer = lowered.expr;
	lowered.pre.push(stmt);
	return lowered.pre;
}

// `x = f().ok` — only a plain non-RC identifier LHS is hoisted; RC-typed and member/index
// LHS (`obj.f =`, `arr[i] =`) are left to the analyzer's own reassignment path.
function expandAssign(stmt: Node, ctx: TransformContext): Node[] {
	const ed = stmt.data as ExprStmtData;
	if (ed.expr == null || ed.expr.kind != NodeKind.BinaryExpr) return [stmt];
	const bd = ed.expr.data as BinaryExprData;
	if (bd.operator != "=" || bd.left.kind != NodeKind.Identifier || isRcReturning(bd.left.nodeType)) return [stmt];
	// Plain once-eval fresh calls in the RHS are captured by the analyzer. callHoist only keeps
	// the conditional-eval cases.
	if (!containsConditionalEval(bd.right)) return [stmt];
	const lowered = lowerBoolCond(bd.right, ctx);
	if (lowered == null) return [stmt];
	bd.right = lowered.expr;
	lowered.pre.push(stmt);
	return lowered.pre;
}

// `if (COND)` is evaluated once when control reaches it → fresh RC calls hoist before it
// (plain hoist for `if (f().ok)`, flag/nested-if for short-circuit `if (a && f().ok)`).
function expandIf(stmt: Node, ctx: TransformContext): Node[] {
	const ifd = stmt.data as IfStmtData;
	// `else if (f().ok)` is the `.alternate`, never a statement-list entry, so expandStmt
	// can't reach its condition. Wrap a fresh-cond else-if in a block so the walker
	// descends and lowers the now-listed inner if; deeper else-ifs cascade the same way.
	if (ifd.alternate != null && ifd.alternate.kind == NodeKind.IfStmt && altChainHasFreshCond(ifd.alternate)) {
		ifd.alternate = makeBlock([ifd.alternate], ifd.alternate.location);
	}
	// Plain once-eval conditions are captured by the analyzer (processIf walks the condition).
	// callHoist only keeps the conditional-eval (short-circuit) main condition; the wrap above
	// still routes a short-circuit else-if through the walker while a plain one falls to the analyzer.
	if (!containsConditionalEval(ifd.condition)) return [stmt];
	const lowered = lowerBoolCond(ifd.condition, ctx);
	if (lowered == null) return [stmt];
	ifd.condition = lowered.expr;
	lowered.pre.push(stmt);
	return lowered.pre;
}

// `while (COND)` re-evaluates COND every iteration, so a *preceding* hoist is wrong.
// Lower the condition into the top of a `while (true)` body + a break:
//   while (f().ok) { BODY }      → while (true) { const $t = f(); if (!($t.ok)) break; BODY }
//   while (a && f().ok) { BODY } → while (true) { <flag eval>; if (!$flag) break; BODY }
// `continue` in BODY jumps to the while(true) top and re-runs the condition eval, so
// per-iteration semantics hold and the fresh temp is destroyed at each iteration's exit.
function expandWhile(stmt: Node, ctx: TransformContext): Node[] {
	const wd = stmt.data as WhileStmtData;
	const lowered = lowerBoolCond(wd.whileCondition, ctx);
	if (lowered == null) return [stmt];
	const loc = stmt.location;
	const body = lowered.pre;
	body.push(makeIf(makeUnary("!", lowered.expr, loc), makeBlock([makeBreak(loc)], loc), null as unknown as Node, loc));
	for (const s of extractBodyStmts(wd.whileBody)) { body.push(s); }
	wd.whileCondition = makeBool(true, loc);
	wd.whileBody = makeBlock(body, loc);
	return [stmt];
}

function expandStmt(stmt: Node, ctx: TransformContext): Node[] {
	return match (stmt.kind) {
		NodeKind.VariableDecl => expandVarDecl(stmt, ctx),
		NodeKind.ExprStmt => expandAssign(stmt, ctx),
		NodeKind.IfStmt => expandIf(stmt, ctx),
		NodeKind.WhileStmt => expandWhile(stmt, ctx),
		_ => [stmt],
	};
}

export function lowerCallHoist(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandStmt, ctx);
	return program;
}
