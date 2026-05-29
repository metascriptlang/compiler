// Call Hoist — Stage 1: hoist a fresh RC-returning call out of a non-RC binding
// initializer into its own preceding statement, so the analyzer's normal
// scope-exit cleanup destroys it.
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
// Stage-1 scope is intentionally narrow — only VariableDecl initializers.
// Conditions (`if (f().ok)`, `while (f().ok)`) and short-circuit operands are
// deferred: they need per-iteration / per-branch control-flow rewrites, not a
// plain hoist.

import { Node, NodeKind, DeclKind, VariableDeclData, BinaryExprData, ExprStmtData, IfStmtData, Type, TypeKind } from "../../ast/node";
import { isResult, isAwaitable, unknownType } from "../../checker/types";
import { TransformContext, freshTempSym } from "../context";
import { walkExpandBlocks, replaceInExpr } from "../walker";
import { makeVarDecl, makeIdentResolved } from "../util";

// Owned-heap types whose fresh-call result needs scope-exit cleanup. Mirrors the
// owned set in analyzer/classify.ms classifyType WITHOUT importing it — transform
// (Phase 3) must not depend on the analyzer (Phase 4). Conservative: only the
// unambiguous owned-heap kinds. Ptr (borrow) and Struct (value type) are excluded.
function isRcReturning(t: Type | null): boolean {
	if (t === null) return false;
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
function containsConditionalEval(expr: Node): boolean {
	let found = false;
	replaceInExpr(expr, (node: Node): Node => {
		if (node.kind === NodeKind.ConditionalExpr) { found = true; }
		if (node.kind === NodeKind.BinaryExpr) {
			const op = (node.data as BinaryExprData).operator;
			if (op === "&&" || op === "||") { found = true; }
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
		if (node.kind !== NodeKind.CallExpr && node.kind !== NodeKind.NewExpr) return node;
		if (!isRcReturning(node.nodeType)) return node;
		const ty = node.nodeType !== null ? node.nodeType : unknownType();
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

function expandStmt(stmt: Node, ctx: TransformContext): Node[] {
	// VariableDecl init: `const x = f().field` (x non-RC) → hoist f() before the decl.
	if (stmt.kind === NodeKind.VariableDecl) {
		const d = stmt.data as VariableDeclData;
		if (d.initializer === null) return [stmt];
		// If the binding's OWN type needs cleanup, the analyzer already SINKs it
		// correctly — hoisting would only add a redundant move. Skip.
		if (isRcReturning(stmt.nodeType)) return [stmt];
		// A fresh call inside a short-circuit operand / ternary branch is only sometimes
		// evaluated; hoisting it to a preceding statement runs it eagerly and breaks the
		// guard. Skip such inits (deferred to nested-if lowering).
		if (containsConditionalEval(d.initializer)) return [stmt];
		const hoisted: Node[] = [];
		d.initializer = hoistFreshRcCalls(d.initializer, hoisted, ctx);
		if (hoisted.length === 0) return [stmt];
		hoisted.push(stmt);
		return hoisted;
	}
	// Assignment RHS: `x = f().field` (x a plain non-RC variable) → hoist f() before the
	// assignment. Same shape as the vardecl case; the analyzer then SINKs the temp.
	// RC-typed LHS, member/index LHS (obj.field=/arr[i]=) are left to the analyzer's
	// own reassignment path — only the plain non-RC identifier LHS is hoisted here.
	if (stmt.kind === NodeKind.ExprStmt) {
		const ed = stmt.data as ExprStmtData;
		if (ed.expr === null || ed.expr.kind !== NodeKind.BinaryExpr) return [stmt];
		const bd = ed.expr.data as BinaryExprData;
		if (bd.operator !== "=") return [stmt];
		if (bd.left.kind !== NodeKind.Identifier) return [stmt];
		if (isRcReturning(bd.left.nodeType)) return [stmt];
		if (containsConditionalEval(bd.right)) return [stmt];
		const hoisted: Node[] = [];
		bd.right = hoistFreshRcCalls(bd.right, hoisted, ctx);
		if (hoisted.length === 0) return [stmt];
		hoisted.push(stmt);
		return hoisted;
	}
	// if-condition: `if (f().field)` → hoist f() before the if. The condition is
	// evaluated once, unconditionally, when control reaches the statement, so a
	// preceding hoist is correct and the temp is destroyed at scope exit. A
	// short-circuit/ternary condition is skipped (deferred to nested-if lowering).
	// `else if` chains aren't statement-list entries, so they pass through here
	// un-hoisted (no eager-eval hazard) — handled later.
	if (stmt.kind === NodeKind.IfStmt) {
		const ifd = stmt.data as IfStmtData;
		if (containsConditionalEval(ifd.condition)) return [stmt];
		const hoisted: Node[] = [];
		ifd.condition = hoistFreshRcCalls(ifd.condition, hoisted, ctx);
		if (hoisted.length === 0) return [stmt];
		hoisted.push(stmt);
		return hoisted;
	}
	return [stmt];
}

export function lowerCallHoist(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandStmt, ctx);
	return program;
}
