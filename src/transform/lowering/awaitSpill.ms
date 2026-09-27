import {
	Node, NodeKind, DeclKind, TypeKind, Type, SourceLocation,
	VariableDeclData, ExprStmtData, ReturnStmtData, ThrowStmtData, AssertStmtData, ExportDeclData,
	IfStmtData, WhileStmtData, DoWhileStmtData,
	AwaitExprData, BinaryExprData, ConditionalExprData, CallExprData, NewExprData, MemberExprData,
	ArrayAccessData, UnaryExprData, ArrayLiteralData, ObjectLiteralData, SpreadExprData,
	TypeAssertionData, HiddenDerefData, HiddenStdConvData,
} from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { TransformContext, freshOwnedSym } from "../context";
import { walkExpandBlocks, containsExprKind, mapExprChildren, isFuncBoundary } from "../walker";
import { makeVarDecl, makeIdentResolved, makeExprStmt, makeAssign, makeIf, makeBlock, makeUnary, makeBreak, makeBool, extractBodyStmts } from "../util";
import { hoistAssignTargetEffects, isAssignOperator, bodyHasLoopContinue } from "./conditionalExprLower";
import { blockifyAwaitingArrows } from "./awaitLower";
import { stmtCountAfter, firstStmtKindAfter, fnBodyStmtCount } from "../testUtil";

function hasAwait(node: Node | null): boolean {
	return node != null && containsExprKind(node, NodeKind.AwaitExpr);
}

function subtreeHasAwait(node: Node | null): boolean {
	if (node == null) return false;
	if (node.kind == NodeKind.AwaitExpr) return true;
	if (isFuncBoundary(node)) return false;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && subtreeHasAwait(child)) { found = true; }
	});
	return found;
}

function hasEffect(node: Node): boolean {
	if (node.kind == NodeKind.CallExpr || node.kind == NodeKind.NewExpr || node.kind == NodeKind.UpdateExpr) return true;
	if (node.kind == NodeKind.BinaryExpr && isAssignOperator((node.data as BinaryExprData).operator)) return true;
	let found = false;
	mapExprChildren(node, (child: Node): Node => {
		if (!found && hasEffect(child)) { found = true; }
		return child;
	});
	return found;
}

function bindTemp(ctx: TransformContext, prefix: string, t: Type | null, init: Node | null, declKind: DeclKind, pre: Node[], loc: SourceLocation): Node {
	const sym = freshOwnedSym(ctx, prefix, t);
	const decl = makeVarDecl(sym.name, init as Node, declKind, loc);
	decl.resolvedSym = sym;
	decl.nodeType = sym.symbolType;
	pre.push(decl);
	return makeIdentResolved(sym, loc);
}

function tempEffects(node: Node, pre: Node[], ctx: TransformContext): Node {
	match (node.kind) {
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			d.asExpr = tempEffects(d.asExpr, pre, ctx);
			return node;
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d = node.data as HiddenStdConvData;
			d.convExpr = tempEffects(d.convExpr, pre, ctx);
			return node;
		},
		_ => {},
	};
	return bindTemp(ctx, "sp", node.nodeType, node, DeclKind.Const, pre, node.location);
}

function spillOperands(ops: Node[], pre: Node[], ctx: TransformContext): void {
	let last = -1;
	for (let i = 0; i < ops.length; i += 1) {
		if (hasAwait(ops[i])) { last = i; }
	}
	for (let i = 0; i < ops.length; i += 1) {
		if (hasAwait(ops[i])) {
			ops[i] = spillExpr(ops[i], pre, ctx);
		} else if (i < last && hasEffect(ops[i])) {
			ops[i] = tempEffects(ops[i], pre, ctx);
		}
	}
}

function spillValue(expr: Node, pre: Node[], ctx: TransformContext): Node {
	return hasAwait(expr) ? spillExpr(expr, pre, ctx) : expr;
}

function spillDirect(expr: Node | null, pre: Node[], ctx: TransformContext): Node {
	if (expr == null || !hasAwait(expr)) return expr as Node;
	if (expr.kind == NodeKind.AwaitExpr) {
		const d = expr.data as AwaitExprData;
		d.awaitArg = spillValue(d.awaitArg, pre, ctx);
		return expr;
	}
	return spillExpr(expr, pre, ctx);
}

function armStmt(target: Node, arm: Node, loc: SourceLocation): Node {
	if (arm.nodeType != null && arm.nodeType.kind == TypeKind.Never) {
		return makeExprStmt(arm, loc);
	}
	return makeExprStmt(makeAssign(target, arm, loc), loc);
}

function spillShortCircuit(expr: Node, pre: Node[], ctx: TransformContext): Node {
	const d = expr.data as BinaryExprData;
	d.left = spillValue(d.left, pre, ctx);
	if (!hasAwait(d.right)) return expr;
	const loc = expr.location;
	const lhs = bindTemp(ctx, "sclhs", d.left.nodeType, d.left, DeclKind.Const, pre, loc);
	const res = bindTemp(ctx, "scres", expr.nodeType, null, DeclKind.Let, pre, loc);
	const rhsStmts: Node[] = [];
	const rhs = spillExpr(d.right, rhsStmts, ctx);
	rhsStmts.push(makeExprStmt(makeAssign(makeIdentResolved(res.resolvedSym!, loc), rhs, loc), loc));
	const keepLhs = makeBlock([makeExprStmt(makeAssign(makeIdentResolved(res.resolvedSym!, loc), makeIdentResolved(lhs.resolvedSym!, loc), loc), loc)], loc);
	const isAnd = d.operator == "&&";
	pre.push(makeIf(lhs, isAnd ? makeBlock(rhsStmts, loc) : keepLhs, isAnd ? keepLhs : makeBlock(rhsStmts, loc), loc));
	return res;
}

function spillConditional(expr: Node, pre: Node[], ctx: TransformContext): Node {
	const d = expr.data as ConditionalExprData;
	d.ternaryCondition = spillValue(d.ternaryCondition, pre, ctx);
	if (!hasAwait(d.ternaryConsequent) && !hasAwait(d.ternaryAlternate)) return expr;
	const loc = expr.location;
	const res = bindTemp(ctx, "tern", expr.nodeType, null, DeclKind.Let, pre, loc);
	const thenStmts: Node[] = [];
	const thenValue = spillValue(d.ternaryConsequent, thenStmts, ctx);
	thenStmts.push(armStmt(makeIdentResolved(res.resolvedSym!, loc), thenValue, loc));
	const elseStmts: Node[] = [];
	const elseValue = spillValue(d.ternaryAlternate, elseStmts, ctx);
	elseStmts.push(armStmt(makeIdentResolved(res.resolvedSym!, loc), elseValue, loc));
	pre.push(makeIf(d.ternaryCondition, makeBlock(thenStmts, loc), makeBlock(elseStmts, loc), loc));
	return res;
}

function spillTarget(target: Node, pre: Node[], ctx: TransformContext): Node {
	match (target.kind) {
		NodeKind.MemberExpr => {
			const d = target.data as MemberExprData;
			d.object = spillTarget(d.object, pre, ctx);
			return target;
		},
		NodeKind.ArrayAccess => {
			const d = target.data as ArrayAccessData;
			if (hasAwait(d.index)) {
				d.array = hasAwait(d.array) ? spillTarget(d.array, pre, ctx) : hoistAssignTargetEffects(d.array, pre, ctx, []);
				d.index = spillExpr(d.index, pre, ctx);
			} else {
				d.array = spillTarget(d.array, pre, ctx);
			}
			return target;
		},
		_ => {},
	};
	return spillValue(target, pre, ctx);
}

function spillAssign(expr: Node, pre: Node[], ctx: TransformContext): Node {
	const d = expr.data as BinaryExprData;
	if (hasAwait(d.left)) { d.left = spillTarget(d.left, pre, ctx); }
	if (hasAwait(d.right)) {
		d.left = hoistAssignTargetEffects(d.left, pre, ctx, []);
		d.right = spillExpr(d.right, pre, ctx);
	}
	return expr;
}

function spillCall(expr: Node, pre: Node[], ctx: TransformContext): Node {
	const d = expr.data as CallExprData;
	let argAwaits = false;
	for (const a of d.arguments) {
		if (hasAwait(a)) { argAwaits = true; }
	}
	if (d.callee.kind == NodeKind.MemberExpr) {
		const md = d.callee.data as MemberExprData;
		if (hasAwait(md.object)) { md.object = spillTarget(md.object, pre, ctx); }
		if (argAwaits) { md.object = hoistAssignTargetEffects(md.object, pre, ctx, []); }
	} else {
		d.callee = spillValue(d.callee, pre, ctx);
		if (argAwaits && hasEffect(d.callee)) { d.callee = tempEffects(d.callee, pre, ctx); }
	}
	spillOperands(d.arguments, pre, ctx);
	return expr;
}

function spillExpr(expr: Node, pre: Node[], ctx: TransformContext): Node {
	match (expr.kind) {
		NodeKind.AwaitExpr => {
			const d = expr.data as AwaitExprData;
			d.awaitArg = spillValue(d.awaitArg, pre, ctx);
			return bindTemp(ctx, "aw", expr.nodeType, expr, DeclKind.Const, pre, expr.location);
		},
		NodeKind.BinaryExpr => {
			const d = expr.data as BinaryExprData;
			if (d.operator == "&&" || d.operator == "||") return spillShortCircuit(expr, pre, ctx);
			if (isAssignOperator(d.operator)) return spillAssign(expr, pre, ctx);
			const ops = [d.left, d.right];
			spillOperands(ops, pre, ctx);
			d.left = ops[0];
			d.right = ops[1];
			return expr;
		},
		NodeKind.ConditionalExpr => { return spillConditional(expr, pre, ctx); },
		NodeKind.CallExpr => { return spillCall(expr, pre, ctx); },
		NodeKind.NewExpr => {
			spillOperands((expr.data as NewExprData).newArguments, pre, ctx);
			return expr;
		},
		NodeKind.ArrayLiteral => {
			spillOperands((expr.data as ArrayLiteralData).elements, pre, ctx);
			return expr;
		},
		NodeKind.ObjectLiteral => {
			spillOperands((expr.data as ObjectLiteralData).properties, pre, ctx);
			return expr;
		},
		NodeKind.ArrayAccess => {
			const d = expr.data as ArrayAccessData;
			const ops = [d.array, d.index];
			spillOperands(ops, pre, ctx);
			d.array = ops[0];
			d.index = ops[1];
			return expr;
		},
		NodeKind.MemberExpr => {
			const d = expr.data as MemberExprData;
			d.object = spillExpr(d.object, pre, ctx);
			return expr;
		},
		NodeKind.UnaryExpr => {
			const d = expr.data as UnaryExprData;
			d.operand = spillExpr(d.operand, pre, ctx);
			return expr;
		},
		NodeKind.SpreadExpr => {
			const d = expr.data as SpreadExprData;
			d.spreadArg = spillExpr(d.spreadArg, pre, ctx);
			return expr;
		},
		NodeKind.TypeAssertion => {
			const d = expr.data as TypeAssertionData;
			d.asExpr = spillExpr(d.asExpr, pre, ctx);
			return expr;
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			const d = expr.data as HiddenDerefData;
			d.expr = spillExpr(d.expr, pre, ctx);
			return expr;
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d = expr.data as HiddenStdConvData;
			d.convExpr = spillExpr(d.convExpr, pre, ctx);
			return expr;
		},
		_ => {},
	};
	ctx.errors.push(`await inside a ${expr.kind.toString()} expression is not supported on the C backend yet`);
	return expr;
}

function blockifyAwaiting(stmt: Node | null): Node {
	if (stmt == null || stmt.kind == NodeKind.BlockStmt || !subtreeHasAwait(stmt)) return stmt as Node;
	return makeBlock([stmt], stmt.location);
}

function spillWhileCond(stmt: Node, ctx: TransformContext): Node[] {
	const wd = stmt.data as WhileStmtData;
	wd.whileBody = blockifyAwaiting(wd.whileBody);
	if (!hasAwait(wd.whileCondition)) return [stmt];
	const loc = stmt.location;
	const body: Node[] = [];
	const cond = spillExpr(wd.whileCondition, body, ctx);
	body.push(makeIf(makeUnary("!", cond, loc), makeBlock([makeBreak(loc)], loc), makeBlock([], loc), loc));
	for (const s of extractBodyStmts(wd.whileBody)) { body.push(s); }
	wd.whileCondition = makeBool(true, loc);
	wd.whileBody = makeBlock(body, loc);
	return [stmt];
}

function spillDoWhileCond(stmt: Node, ctx: TransformContext): Node[] {
	const wd = stmt.data as DoWhileStmtData;
	wd.doBody = blockifyAwaiting(wd.doBody);
	if (!hasAwait(wd.doCondition)) return [stmt];
	if (bodyHasLoopContinue(wd.doBody)) {
		ctx.errors.push("do-while: an await in the condition combined with 'continue' in the loop body is not supported on the C backend yet");
		return [stmt];
	}
	const loc = stmt.location;
	const body: Node[] = extractBodyStmts(wd.doBody);
	const cond = spillExpr(wd.doCondition, body, ctx);
	body.push(makeIf(makeUnary("!", cond, loc), makeBlock([makeBreak(loc)], loc), makeBlock([], loc), loc));
	wd.doCondition = makeBool(true, loc);
	wd.doBody = makeBlock(body, loc);
	return [stmt];
}

function expandAwaitStmt(stmt: Node, ctx: TransformContext): Node[] {
	const pre: Node[] = [];
	match (stmt.kind) {
		NodeKind.VariableDecl => {
			const d = stmt.data as VariableDeclData;
			d.initializer = spillDirect(d.initializer, pre, ctx);
		},
		NodeKind.ExportDecl => {
			const ed = stmt.data as ExportDeclData;
			if (ed.exportedDecl != null && ed.exportedDecl.kind == NodeKind.VariableDecl) {
				const d = ed.exportedDecl.data as VariableDeclData;
				d.initializer = spillDirect(d.initializer, pre, ctx);
			}
		},
		NodeKind.ExprStmt => {
			const d = stmt.data as ExprStmtData;
			d.expr = spillDirect(d.expr, pre, ctx);
			if (pre.length > 0 && d.expr.kind == NodeKind.Identifier) return pre;
		},
		NodeKind.ReturnStmt => {
			const d = stmt.data as ReturnStmtData;
			d.argument = spillDirect(d.argument, pre, ctx);
		},
		NodeKind.ThrowStmt => {
			const d = stmt.data as ThrowStmtData;
			d.throwArg = spillValue(d.throwArg, pre, ctx);
		},
		NodeKind.AssertStmt => {
			const d = stmt.data as AssertStmtData;
			d.assertExpr = spillValue(d.assertExpr, pre, ctx);
		},
		NodeKind.IfStmt => {
			const d = stmt.data as IfStmtData;
			d.condition = spillValue(d.condition, pre, ctx);
			d.consequent = blockifyAwaiting(d.consequent);
			d.alternate = blockifyAwaiting(d.alternate);
		},
		NodeKind.WhileStmt => { return spillWhileCond(stmt, ctx); },
		NodeKind.DoWhileStmt => { return spillDoWhileCond(stmt, ctx); },
		_ => {},
	};
	if (pre.length == 0) return [stmt];
	pre.push(stmt);
	return pre;
}

export function lowerAwaitSpill(program: Node, ctx: TransformContext): Node {
	blockifyAwaitingArrows(program);
	walkExpandBlocks(program, expandAwaitStmt, ctx);
	return program;
}

test "a whole-initializer await stays one statement" { assert stmtCountAfter("const x = await g();", lowerAwaitSpill) == 1; }

test "a bare await statement stays one statement" { assert stmtCountAfter("await g();", lowerAwaitSpill) == 1; }

test "a direct return await stays one statement" { assert fnBodyStmtCount("async function f() { return await g(); }", lowerAwaitSpill) == 1; }

test "a return operand await spills inside the function" { assert fnBodyStmtCount("async function f() { return await g() + 1; }", lowerAwaitSpill) == 2; }

test "an await operand spills to its own declaration" { assert stmtCountAfter("const v = await g() + 1;", lowerAwaitSpill) == 2; }

test "a call operand ahead of an await spills first" { assert stmtCountAfter("const v = side() + await g();", lowerAwaitSpill) == 3; }

test "a plain operand ahead of an await stays in place" { assert stmtCountAfter("const v = x + await g();", lowerAwaitSpill) == 2; }

test "an await argument spills out of the call" { assert stmtCountAfter("f(await g());", lowerAwaitSpill) == 2; }

test "an await on the right of && runs under a guard" { assert stmtCountAfter("const v = a && await g();", lowerAwaitSpill) == 4; }

test "an await on the left of && needs no guard" { assert stmtCountAfter("const v = await g() && a;", lowerAwaitSpill) == 2; }

test "an await in a ternary arm runs under a guard" { assert stmtCountAfter("const v = c ? await g() : 7;", lowerAwaitSpill) == 3; }

test "an await in a ternary condition needs no guard" { assert stmtCountAfter("const v = (await g()) ? 1 : 2;", lowerAwaitSpill) == 2; }

test "an if condition await spills before the if" { assert firstStmtKindAfter("if (await g()) { f(); }", lowerAwaitSpill) == NodeKind.VariableDecl; }

test "a while condition await moves into the loop body" { assert firstStmtKindAfter("while (await g()) { f(); }", lowerAwaitSpill) == NodeKind.WhileStmt; }

test "an assignment from an await keeps its target" { assert stmtCountAfter("x = await g() + 1;", lowerAwaitSpill) == 2; }

test "a statement without await is unchanged" { assert stmtCountAfter("const v = a() + b();", lowerAwaitSpill) == 1; }
