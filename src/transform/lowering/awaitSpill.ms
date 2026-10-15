import {
	Node, NodeKind, DeclKind,
	BlockStmtData, VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	TryCatchStmtData, ExprStmtData, ReturnStmtData, ThrowStmtData, AssertStmtData, ExportDeclData,
	FunctionDeclData, BinaryExprData, UnaryExprData, UpdateExprData, MemberExprData,
	ConditionalExprData, TypeAssertionData,
	SpreadExprData, MoveExprData, OutExprData, HiddenStdConvData, HiddenDerefData,
	AwaitExprData,
} from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { booleanType } from "../../checker/types";
import { TransformContext } from "../context";
import {
	makeExprStmt, makeAssign,
	makeIf, makeBlock, makeWhile, makeBreak, makeBool, makeUnary, makeDefaultValue, extractBodyStmts,
} from "../util";
import { cloneIfPure } from "../coercion/intArithJS";
import { Spiller, bindTemp, tempRef, isVoidType, isAssignOp, lowerOperandList, lowerAssign } from "./operandOrder";
import { blockifyArrowsReading } from "../coercion/nullishCoalesce";
import { truthinessTest } from "../coercion/stringTruthiness";
import { shortCircuitLeftShare, shortCircuitRightRuns } from "../../checker/fit";
import { shortCircuitShareArm, fitShortCircuitArm } from "./conditionalExprLower";
import { foldedNullOperand, isNullExpr } from "./operatorLower";
import { walkExpandBlocks, isFuncBoundary } from "../walker";
import { stmtCountAfter, firstStmtKindAfter, parseInput, makeCtx, getStmts } from "../testUtil";

let _sp: Spiller = { ctx: null as unknown as TransformContext, has: needsSpill, lower: lowerAwaitExpr };

function useCtx(ctx: TransformContext): void {
	_sp = { ctx: ctx, has: needsSpill, lower: lowerAwaitExpr };
}

function isRoutine(node: Node): boolean {
	return isFuncBoundary(node) || node.kind == NodeKind.MethodDecl
		|| node.kind == NodeKind.ConstructorDecl || node.kind == NodeKind.ClassDecl;
}

// A null comparison that folds to a constant keeps its operand's evaluation only if the
// operand runs first, so an operand with effects is spilled like an await.
function dropsOperandEffects(node: Node): boolean {
	const operand = foldedNullOperand(_sp.ctx, node);
	return operand != null && cloneIfPure(operand) == null;
}

function isSpillPoint(node: Node): boolean {
	return node.kind == NodeKind.AwaitExpr || dropsOperandEffects(node);
}

function needsSpill(node: Node | null): boolean {
	if (node == null) return false;
	if (isSpillPoint(node)) return true;
	if (isRoutine(node)) return false;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && needsSpill(child)) found = true;
	});
	return found;
}

function isInert(e: Node): boolean {
	return e.kind == NodeKind.Identifier || e.kind == NodeKind.NumberLiteral
		|| e.kind == NodeKind.StringLiteral || e.kind == NodeKind.BooleanLiteral || e.kind == NodeKind.NullLiteral;
}

function lowerShortCircuit(e: Node, pre: Node[]): Node {
	const d = e.data as BinaryExprData;
	const loc = e.location;
	const t = e.nodeType != null ? e.nodeType : booleanType();
	const lhsType = d.left.nodeType != null ? d.left.nodeType : t;
	const lhs = bindTemp(_sp, lowerAwaitExpr(d.left, pre), DeclKind.Const, lhsType, pre, loc);
	const res = bindTemp(_sp, makeDefaultValue(t, loc), DeclKind.Let, t, pre, loc);
	const rightStmts: Node[] = [];
	if (shortCircuitRightRuns(d.operator, lhsType)) {
		const right = lowerAwaitExpr(d.right, rightStmts);
		rightStmts.push(makeExprStmt(makeAssign(tempRef(res, loc), fitShortCircuitArm(right, t, _sp.ctx), loc), loc));
	}
	const share = shortCircuitLeftShare(d.operator, lhsType);
	const leftStmts: Node[] = share == null ? []
		: [makeExprStmt(makeAssign(tempRef(res, loc), shortCircuitShareArm(tempRef(lhs, loc), share, t, _sp.ctx), loc), loc)];
	const isAnd = d.operator == "&&";
	pre.push(makeIf(truthinessTest(tempRef(lhs, loc), _sp.ctx), makeBlock(isAnd ? rightStmts : leftStmts, loc), makeBlock(isAnd ? leftStmts : rightStmts, loc), loc));
	return tempRef(res, loc);
}

function lowerConditional(e: Node, pre: Node[]): Node {
	const d = e.data as ConditionalExprData;
	const loc = e.location;
	const cond = lowerAwaitExpr(d.ternaryCondition, pre);
	const tmp = bindTemp(_sp, makeDefaultValue(e.nodeType, loc), DeclKind.Let, e.nodeType, pre, loc);
	const thenStmts: Node[] = [];
	const thenVal = lowerAwaitExpr(d.ternaryConsequent, thenStmts);
	thenStmts.push(makeExprStmt(makeAssign(tempRef(tmp, loc), thenVal, loc), loc));
	const elseStmts: Node[] = [];
	const elseVal = lowerAwaitExpr(d.ternaryAlternate, elseStmts);
	elseStmts.push(makeExprStmt(makeAssign(tempRef(tmp, loc), elseVal, loc), loc));
	pre.push(makeIf(cond, makeBlock(thenStmts, loc), makeBlock(elseStmts, loc), loc));
	return tempRef(tmp, loc);
}

function lowerFoldedNullOperand(e: Node, pre: Node[]): Node {
	const d = e.data as BinaryExprData;
	const operandOnLeft = !isNullExpr(d.left);
	const operand = lowerAwaitExpr(operandOnLeft ? d.left : d.right, pre);
	const bound = tempRef(bindTemp(_sp, operand, DeclKind.Const, operand.nodeType, pre, operand.location), operand.location);
	if (operandOnLeft) d.left = bound;
	else d.right = bound;
	return e;
}

function lowerAwaitExpr(e: Node, pre: Node[]): Node {
	if (e == null || !needsSpill(e)) return e;
	const k = e.kind;
	if (k == NodeKind.AwaitExpr) {
		const d = e.data as AwaitExprData;
		d.awaitArg = lowerAwaitExpr(d.awaitArg, pre);
		if (isVoidType(e.nodeType)) return e;
		return tempRef(bindTemp(_sp, e, DeclKind.Const, e.nodeType, pre, e.location), e.location);
	}
	if (k == NodeKind.BinaryExpr) {
		const d = e.data as BinaryExprData;
		if (dropsOperandEffects(e)) return lowerFoldedNullOperand(e, pre);
		if (d.operator == "&&" || d.operator == "||") return lowerShortCircuit(e, pre);
		if (d.operator == "&&=" || d.operator == "||=" || d.operator == "??=") return e;
		if (isAssignOp(d.operator)) return lowerAssign(_sp, e, pre);
		lowerOperandList(_sp, e, pre);
	} else if (k == NodeKind.ConditionalExpr) {
		if (isVoidType(e.nodeType)) return e;
		return lowerConditional(e, pre);
	} else if (k == NodeKind.CallExpr || k == NodeKind.NewExpr || k == NodeKind.ArrayAccess
		|| k == NodeKind.ArrayLiteral || k == NodeKind.ObjectLiteral) {
		lowerOperandList(_sp, e, pre);
	} else if (k == NodeKind.UnaryExpr) {
		const d = e.data as UnaryExprData;
		d.operand = lowerAwaitExpr(d.operand, pre);
	} else if (k == NodeKind.UpdateExpr) {
		const d = e.data as UpdateExprData;
		d.updateArg = lowerAwaitExpr(d.updateArg, pre);
	} else if (k == NodeKind.MemberExpr) {
		const d = e.data as MemberExprData;
		d.object = lowerAwaitExpr(d.object, pre);
	} else if (k == NodeKind.TypeAssertion) {
		const d = e.data as TypeAssertionData;
		d.asExpr = lowerAwaitExpr(d.asExpr, pre);
	} else if (k == NodeKind.SpreadExpr) {
		const d = e.data as SpreadExprData;
		d.spreadArg = lowerAwaitExpr(d.spreadArg, pre);
	} else if (k == NodeKind.MoveExpr) {
		const d = e.data as MoveExprData;
		d.moveArg = lowerAwaitExpr(d.moveArg, pre);
	} else if (k == NodeKind.OutExpr) {
		const d = e.data as OutExprData;
		d.outArg = lowerAwaitExpr(d.outArg, pre);
	} else if (k == NodeKind.HiddenStdConv || k == NodeKind.HiddenSubConv) {
		const d = e.data as HiddenStdConvData;
		d.convExpr = lowerAwaitExpr(d.convExpr, pre);
	} else if (k == NodeKind.HiddenDeref || k == NodeKind.HiddenAddr) {
		const d = e.data as HiddenDerefData;
		d.expr = lowerAwaitExpr(d.expr, pre);
	} else {
		_sp.ctx.errors.push(`await inside a ${k.toString()} expression is not supported on the C backend yet`);
	}
	return e;
}

function lowerAwaitStmts(stmts: Node[]): Node[] {
	const out: Node[] = [];
	for (const s of stmts) {
		for (const r of lowerAwaitStmt(s)) out.push(r);
	}
	return out;
}

function lowerAwaitSlot(s: Node | null): Node | null {
	if (s == null) return s;
	const list = lowerAwaitStmt(s);
	if (list.length == 1) return list[0];
	return makeBlock(list, s.location);
}

function lowerLoopBody(body: Node): Node {
	return makeBlock(lowerAwaitStmts(extractBodyStmts(body)), body.location);
}

function lowerAwaitStmt(s: Node): Node[] {
	if (s == null || !needsSpill(s)) return [s];
	const loc = s.location;
	const pre: Node[] = [];
	const k = s.kind;
	if (k == NodeKind.BlockStmt) {
		const d = s.data as BlockStmtData;
		d.statements = lowerAwaitStmts(d.statements);
	} else if (k == NodeKind.ExprStmt) {
		const d = s.data as ExprStmtData;
		if (d.expr.kind == NodeKind.AwaitExpr) {
			const ad = d.expr.data as AwaitExprData;
			ad.awaitArg = lowerAwaitExpr(ad.awaitArg, pre);
		} else if (d.expr.kind == NodeKind.ConditionalExpr) {
			const cd = d.expr.data as ConditionalExprData;
			const cond = lowerAwaitExpr(cd.ternaryCondition, pre);
			const thenBranch = makeBlock(lowerAwaitStmt(makeExprStmt(cd.ternaryConsequent, loc)), loc);
			const elseBranch = makeBlock(lowerAwaitStmt(makeExprStmt(cd.ternaryAlternate, loc)), loc);
			pre.push(makeIf(cond, thenBranch, elseBranch, loc));
			return pre;
		} else {
			d.expr = lowerAwaitExpr(d.expr, pre);
			if (isInert(d.expr)) return pre;
		}
	} else if (k == NodeKind.VariableDecl) {
		const d = s.data as VariableDeclData;
		if (d.initializer.kind == NodeKind.AwaitExpr) {
			const ad = d.initializer.data as AwaitExprData;
			ad.awaitArg = lowerAwaitExpr(ad.awaitArg, pre);
		} else {
			d.initializer = lowerAwaitExpr(d.initializer, pre);
		}
	} else if (k == NodeKind.ReturnStmt) {
		const d = s.data as ReturnStmtData;
		const arg = d.argument!;
		if (arg.kind == NodeKind.AwaitExpr && isVoidType(arg.nodeType)) {
			const ad = arg.data as AwaitExprData;
			ad.awaitArg = lowerAwaitExpr(ad.awaitArg, pre);
			pre.push(makeExprStmt(arg, loc));
			d.argument = null;
		} else {
			d.argument = lowerAwaitExpr(arg, pre);
		}
	} else if (k == NodeKind.ThrowStmt) {
		const d = s.data as ThrowStmtData;
		d.throwArg = lowerAwaitExpr(d.throwArg, pre);
	} else if (k == NodeKind.AssertStmt) {
		const d = s.data as AssertStmtData;
		d.assertExpr = lowerAwaitExpr(d.assertExpr, pre);
	} else if (k == NodeKind.ExportDecl) {
		const ed = s.data as ExportDeclData;
		if (ed.exportedDecl != null && ed.exportedDecl.kind == NodeKind.VariableDecl) {
			const d = ed.exportedDecl.data as VariableDeclData;
			if (d.initializer != null && d.initializer.kind == NodeKind.AwaitExpr) {
				const ad = d.initializer.data as AwaitExprData;
				ad.awaitArg = lowerAwaitExpr(ad.awaitArg, pre);
			} else {
				d.initializer = lowerAwaitExpr(d.initializer, pre);
			}
		}
	} else if (k == NodeKind.IfStmt) {
		const d = s.data as IfStmtData;
		d.condition = lowerAwaitExpr(d.condition, pre);
		d.consequent = lowerAwaitSlot(d.consequent)!;
		d.alternate = lowerAwaitSlot(d.alternate)!;
	} else if (k == NodeKind.WhileStmt) {
		const d = s.data as WhileStmtData;
		const body = lowerLoopBody(d.whileBody);
		if (needsSpill(d.whileCondition)) {
			const head: Node[] = [];
			const cond = lowerAwaitExpr(d.whileCondition, head);
			head.push(makeIf(makeUnary("!", cond, loc), makeBlock([makeBreak(loc)], loc), null, loc));
			for (const b of (body.data as BlockStmtData).statements) head.push(b);
			d.whileCondition = makeBool(true, loc);
			d.whileBody = makeBlock(head, loc);
		} else {
			d.whileBody = body;
		}
	} else if (k == NodeKind.DoWhileStmt) {
		const d = s.data as DoWhileStmtData;
		const body = lowerLoopBody(d.doBody);
		if (!needsSpill(d.doCondition)) {
			d.doBody = body;
		} else {
			const entered = bindTemp(_sp, makeBool(false, loc), DeclKind.Let, booleanType(), pre, loc);
			const head: Node[] = [];
			const cond = lowerAwaitExpr(d.doCondition, head);
			head.push(makeIf(makeUnary("!", cond, loc), makeBlock([makeBreak(loc)], loc), null, loc));
			const loopStmts: Node[] = [
				makeIf(tempRef(entered, loc), makeBlock(head, loc), null, loc),
				makeExprStmt(makeAssign(tempRef(entered, loc), makeBool(true, loc), loc), loc),
			];
			for (const b of (body.data as BlockStmtData).statements) loopStmts.push(b);
			const loop = makeWhile(makeBool(true, loc), makeBlock(loopStmts, loc), loc);
			(loop.data as WhileStmtData).whileLabel = d.dwLabel;
			pre.push(loop);
			return pre;
		}
	} else if (k == NodeKind.SwitchStmt) {
		const d = s.data as SwitchStmtData;
		d.switchDisc = lowerAwaitExpr(d.switchDisc, pre);
		for (const c of d.switchCases) {
			const cd = c.data as SwitchCaseData;
			cd.caseStmts = lowerAwaitStmts(cd.caseStmts);
		}
	} else if (k == NodeKind.TryCatchStmt) {
		const d = s.data as TryCatchStmtData;
		d.tryBody = lowerAwaitSlot(d.tryBody)!;
		d.catchBody = lowerAwaitSlot(d.catchBody)!;
		d.finallyBody = lowerAwaitSlot(d.finallyBody)!;
	}
	pre.push(s);
	return pre;
}


export function spillAwaitStmt(stmt: Node, ctx: TransformContext): Node[] {
	useCtx(ctx);
	return lowerAwaitStmt(stmt);
}

export function blockifyAwaitingArrows(program: Node): void {
	blockifyArrowsReading(program, isSpillPoint);
}

export function lowerAwaitSpill(program: Node, ctx: TransformContext): Node {
	useCtx(ctx);
	blockifyAwaitingArrows(program);
	walkExpandBlocks(program, spillAwaitStmt, ctx);
	return program;
}

function bodyAfter(src: string): Node[] {
	const parsed = parseInput(src);
	if (!parsed.ok) return [];
	const fn = getStmts(lowerAwaitSpill(parsed.value, makeCtx()))[0];
	return ((fn.data as FunctionDeclData).fnBody.data as BlockStmtData).statements;
}

function bodyKinds(src: string): string {
	let out = "";
	for (const s of bodyAfter(src)) out = out + s.kind.toString() + ";";
	return out;
}

test "an await in an operand moves into a declaration ahead of its statement" {
	assert bodyKinds("async function f() { const v = (await p) + 1; }") == "VariableDecl;VariableDecl;";
}

test "a call before the await is bound first, so it still runs first" {
	assert bodyKinds("async function f() { g(h(), await p); }") == "VariableDecl;VariableDecl;ExprStmt;";
}

test "a short-circuit right operand awaits only inside its branch" {
	assert bodyKinds("async function f() { const v = a && await p; }") == "VariableDecl;IfStmt;VariableDecl;";
}

test "an await in a while condition moves into the loop body" {
	const body = bodyAfter("async function f() { while (await p) { g(); } }");
	assert body.length == 1;
	const inner = ((body[0].data as WhileStmtData).whileBody.data as BlockStmtData).statements;
	assert inner.length == 3;
	assert inner[0].kind == NodeKind.VariableDecl;
}

test "an await in a do-while condition runs after the body on every pass" {
	assert bodyKinds("async function f() { do { g(); } while (await p); }") == "VariableDecl;WhileStmt;";
}

test "a statement-level await stays where it is" {
	assert bodyKinds("async function f() { await p; const v = await q; return await r; }") == "ExprStmt;VariableDecl;VariableDecl;ReturnStmt;";
}

test "a sync body spills the same way" {
	assert bodyKinds("function f() { const v = (await p) + 1; }") == "VariableDecl;VariableDecl;";
}

test "a top-level await operand spills before its statement" { assert stmtCountAfter("const v = (await g()) + 1;", lowerAwaitSpill) == 2; }

test "an assert operand await spills before the assert" { assert stmtCountAfter("assert (await g()) == 1;", lowerAwaitSpill) == 2; }

test "an exported initializer await spills before the export" { assert stmtCountAfter("export const v = (await g()) + 1;", lowerAwaitSpill) == 2; }

test "a statement without await is unchanged" { assert stmtCountAfter("const v = a() + b();", lowerAwaitSpill) == 1; }

test "an await argument spills out of the call" { assert stmtCountAfter("f(await g());", lowerAwaitSpill) == 2; }

test "an await on the left of && is awaited before the guard" { assert firstStmtKindAfter("const v = await g() && a;", lowerAwaitSpill) == NodeKind.VariableDecl; }

test "an await in a ternary arm runs under a guard" { assert stmtCountAfter("const v = c ? await g() : 7;", lowerAwaitSpill) == 3; }

test "an await in a ternary condition spills before the branches" { assert firstStmtKindAfter("const v = (await g()) ? 1 : 2;", lowerAwaitSpill) == NodeKind.VariableDecl; }

test "an if condition await spills before the if" { assert firstStmtKindAfter("if (await g()) { f(); }", lowerAwaitSpill) == NodeKind.VariableDecl; }

test "an assignment from an await keeps its target" { assert firstStmtKindAfter("x = await g() + 1;", lowerAwaitSpill) == NodeKind.VariableDecl; }
