// Conditional Expression Lowering — rewrite ternary into if-else where a branch
// can't be a C expression.
//
// A MetaScript `?:` promises conditional evaluation: only the chosen branch runs.
// C's `?:` honours that for pure C expressions, but some MetaScript expressions
// compile to *statements* (NRVO struct/Span/Result/Tuple calls → `f(&tmp);`,
// object/new construction). Left inline, those statements escape the C `?:` and
// run UNCONDITIONALLY — over-execution, or a crash when the untaken branch was
// only valid under the condition.
//
// So when a branch emits statements, the ternary is lowered to `temp + if/else`
// (same shape matchLower gives match-expressions, same effect as Reference genIf):
//   const x = cond ? heavy() : other()
//   → let x; if (cond) { x = heavy(); } else { x = other(); }
// Pure-branch ternaries keep the inline C `?:`. Nested hazardous ternaries are
// re-walked into the generated blocks, so they hoist into the correct scope.
//
// Runs AFTER optionalChain/nullishCoalesce (which produce ternaries) and
// lowerOperators (so overloaded struct-returning operators are CallExprs here).

import { Node, NodeKind, DeclKind, ExprStmtData, ConditionalExprData, VariableDeclData, ReturnStmtData } from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { walkExpandBlocks, mapExprChildren } from "../walker";
import { makeIf, makeBlock, makeExprStmt, makeVarDecl, makeAssign, makeIdent, makeIdentResolved, makeNull, makeReturn } from "../util";
import { isNrvoReturnType } from "../../codegen/c/types";
import { firstStmtKindAfter, stmtCountAfter, firstExprKindAfter } from "../testUtil";

// ===== Hazard detection =====

// True if evaluating `node` emits C statements (so it can't sit inside a C `?:`).
// Mirrors codegen's own statement-emitting constructs: NRVO-returning calls,
// object literals (field-assign statements), allocation. Descends through all
// children — including nested ternary branches — so an outer ternary is lowered
// whenever anything inside it needs a guarded scope.
function branchEmitsStatements(node: Node): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.ObjectLiteral) return true;
	if (node.kind === NodeKind.NewExpr) return true;
	if (node.kind === NodeKind.CallExpr && isNrvoReturnType(node.nodeType, null)) return true;
	let found = false;
	mapExprChildren(node, (child: Node): Node => {
		if (!found && branchEmitsStatements(child)) { found = true; }
		return child;
	});
	return found;
}

function ternaryNeedsLowering(condExpr: Node): boolean {
	const cd = condExpr.data as ConditionalExprData;
	return branchEmitsStatements(cd.ternaryConsequent) || branchEmitsStatements(cd.ternaryAlternate);
}

// True if `node` contains (anywhere) a ternary that needs lowering.
function containsHazardousTernary(node: Node): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.ConditionalExpr && ternaryNeedsLowering(node)) return true;
	let found = false;
	mapExprChildren(node, (child: Node): Node => {
		if (!found && containsHazardousTernary(child)) { found = true; }
		return child;
	});
	return found;
}

// ===== Nested hoist (top-down) =====

// Hoist hazardous ternaries sitting at unconditionally-evaluated positions within
// `expr` to preceding statements in `hoisted`, replacing each with a temp. Must be
// top-down: a hazardous ternary's own branches are NOT descended into here — they
// become assignments inside the generated if-blocks, hoisted by the re-walk in the
// correct (guarded) scope. Descending bottom-up would lift a branch's inner ternary
// above its guard → the very unconditional-execution bug we are fixing.
function hoistTernaries(expr: Node, hoisted: Node[], ctx: TransformContext): Node {
	if (expr === null) return expr;
	if (expr.kind === NodeKind.ConditionalExpr) {
		if (!ternaryNeedsLowering(expr)) return expr;
		const cd = expr.data as ConditionalExprData;
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

function expandConditionalStmt(stmt: Node, ctx: TransformContext): Node[] {
	const loc = stmt.location;
	match (stmt.kind) {
		NodeKind.VariableDecl => {
			const d = stmt.data as VariableDeclData;
			if (d.initializer !== null && d.initializer.kind === NodeKind.ConditionalExpr && ternaryNeedsLowering(d.initializer)) {
				return lowerTernaryInVar(stmt, ctx);
			}
			if (d.initializer !== null && containsHazardousTernary(d.initializer)) {
				const hoisted: Node[] = [];
				d.initializer = hoistTernaries(d.initializer, hoisted, ctx);
				hoisted.push(stmt);
				return hoisted;
			}
		},
		NodeKind.ReturnStmt => {
			const d = stmt.data as ReturnStmtData;
			if (d.argument !== null && d.argument.kind === NodeKind.ConditionalExpr && ternaryNeedsLowering(d.argument)) {
				return lowerTernaryInReturn(stmt, ctx);
			}
			if (d.argument !== null && containsHazardousTernary(d.argument)) {
				const hoisted: Node[] = [];
				d.argument = hoistTernaries(d.argument, hoisted, ctx);
				hoisted.push(stmt);
				return hoisted;
			}
		},
		NodeKind.ExprStmt => {
			const d = stmt.data as ExprStmtData;
			if (d.expr.kind === NodeKind.ConditionalExpr) {
				const cd = d.expr.data as ConditionalExprData;
				const thenStmt = makeExprStmt(cd.ternaryConsequent, loc);
				const elseStmt = makeExprStmt(cd.ternaryAlternate, loc);
				return [makeIf(cd.ternaryCondition, makeBlock([thenStmt], loc), makeBlock([elseStmt], loc), loc)];
			}
			if (containsHazardousTernary(d.expr)) {
				const hoisted: Node[] = [];
				d.expr = hoistTernaries(d.expr, hoisted, ctx);
				hoisted.push(stmt);
				return hoisted;
			}
		},
		_ => {},
	};
	return [stmt];
}

// const x = cond ? a : b  →  let x; if (cond) { x = a; } else { x = b; }
function lowerTernaryInVar(stmt: Node, ctx: TransformContext): Node[] {
	const vd = stmt.data as VariableDeclData;
	const cd = vd.initializer.data as ConditionalExprData;
	const loc = stmt.location;
	const result: Node[] = [];
	const letDecl = makeVarDecl(vd.declName, makeNull(loc), DeclKind.Let, loc);
	if (stmt.nodeType !== null) { letDecl.nodeType = stmt.nodeType; }
	result.push(letDecl);
	const thenStmt = makeExprStmt(makeAssign(makeIdent(vd.declName, loc), cd.ternaryConsequent, loc), loc);
	const elseStmt = makeExprStmt(makeAssign(makeIdent(vd.declName, loc), cd.ternaryAlternate, loc), loc);
	result.push(makeIf(cd.ternaryCondition, makeBlock([thenStmt], loc), makeBlock([elseStmt], loc), loc));
	return result;
}

// return cond ? a : b  →  if (cond) { return a; } else { return b; }
function lowerTernaryInReturn(stmt: Node, ctx: TransformContext): Node[] {
	const rd = stmt.data as ReturnStmtData;
	const cd = rd.argument.data as ConditionalExprData;
	const loc = stmt.location;
	const thenStmt = makeReturn(cd.ternaryConsequent, loc);
	const elseStmt = makeReturn(cd.ternaryAlternate, loc);
	return [makeIf(cd.ternaryCondition, makeBlock([thenStmt], loc), makeBlock([elseStmt], loc), loc)];
}

// ===== Entry Point =====

export function lowerConditionalExpr(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandConditionalStmt, ctx);
	return program;
}

// ===== Tests =====
test "ternary in stmt becomes if" { assert firstStmtKindAfter("a ? b : c;", lowerConditionalExpr) === NodeKind.IfStmt; }

test "non-ternary ExprStmt unchanged" { assert firstStmtKindAfter("f();", lowerConditionalExpr) === NodeKind.ExprStmt; }

test "pure variable decl ternary stays inline" { assert firstStmtKindAfter("const x = a ? b : c;", lowerConditionalExpr) === NodeKind.VariableDecl; }

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", lowerConditionalExpr) === NodeKind.WhileStmt; }

test "stmt count preserved" { assert stmtCountAfter("let a = 1; let b = 2;", lowerConditionalExpr) === 2; }

test "binary expr unchanged" { assert firstExprKindAfter("x + y;", lowerConditionalExpr) === NodeKind.BinaryExpr; }
