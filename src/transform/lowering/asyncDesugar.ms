// Async/Await Desugaring — converts await to yield, lets generator handle state machine
//
// async function f() { const x = await p; return x; }
// → function* f() { const x = yield p; return x; }
// → (generatorLower then builds the state machine)
//
// Proven architectural insight: "await is just yield." This pass rewrites, generator does heavy lifting.
// V1: No Promise wrapper (runtime/codegen concern, not AST transform).

import {
	Node, NodeKind, NodeFlag, DeclKind, createNode, SourceLocation, Symbol, SymbolKind, Type, TypeKind,
	BlockStmtData, FunctionDeclData, FunctionExprData,
	ArrowFunctionData, MethodDeclData,
	VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	TryCatchStmtData, ExprStmtData, ReturnStmtData, ThrowStmtData,
	CallExprData, BinaryExprData, UnaryExprData, UpdateExprData, MemberExprData, ArrayAccessData,
	ArrayLiteralData, ObjectLiteralData, ConditionalExprData, NewExprData, TypeAssertionData,
	SpreadExprData, MoveExprData, OutExprData, HiddenStdConvData, HiddenDerefData,
	AwaitExprData,
} from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { makeSymbol } from "../../checker/symbol";
import { booleanType } from "../../checker/types";
import { TransformContext } from "../context";
import {
	syntheticToken, makeVarDecl, makeReturn, makeTypedIdentResolved, makeExprStmt, makeAssign,
	makeIf, makeBlock, makeWhile, makeBreak, makeBool, makeUnary, makeDefaultValue, extractBodyStmts,
} from "../util";
import { mapChildren, isFuncBoundary } from "../walker";
import { stmtCountAfter, firstStmtKindAfter, parseInput, makeCtx, getStmts } from "../testUtil";

// ===== Await in expression position =====
let _retAwaitCounter: number = 0;

function isRoutine(node: Node): boolean {
	return isFuncBoundary(node) || node.kind == NodeKind.MethodDecl
		|| node.kind == NodeKind.ConstructorDecl || node.kind == NodeKind.ClassDecl;
}

function hasAwait(node: Node | null): boolean {
	if (node == null) return false;
	if (node.kind == NodeKind.AwaitExpr) return true;
	if (isRoutine(node)) return false;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && hasAwait(child)) found = true;
	});
	return found;
}

function isVoidType(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.Void;
}

function isAssignOp(op: string): boolean {
	if (op == "==" || op == "!=" || op == "===" || op == "!==" || op == "<=" || op == ">=") return false;
	return op.endsWith("=");
}

function isCallKind(e: Node): boolean {
	if (e.kind == NodeKind.CallExpr || e.kind == NodeKind.NewExpr
		|| e.kind == NodeKind.UnaryExpr || e.kind == NodeKind.UpdateExpr) return true;
	return e.kind == NodeKind.BinaryExpr && !isAssignOp((e.data as BinaryExprData).operator);
}

function isInert(e: Node): boolean {
	return e.kind == NodeKind.Identifier || e.kind == NodeKind.NumberLiteral
		|| e.kind == NodeKind.StringLiteral || e.kind == NodeKind.BooleanLiteral || e.kind == NodeKind.NullLiteral;
}

function bindTemp(init: Node, declKind: DeclKind, t: Type | null, pre: Node[], loc: SourceLocation): Symbol {
	const name = "$aw" + _retAwaitCounter.toString();
	_retAwaitCounter = _retAwaitCounter + 1;
	const sym = makeSymbol(name, SymbolKind.Variable, t, declKind != DeclKind.Const);
	const decl = makeVarDecl(name, init, declKind, loc);
	decl.nodeType = t;
	decl.resolvedSym = sym;
	pre.push(decl);
	return sym;
}

function tempRef(sym: Symbol, loc: SourceLocation): Node {
	return makeTypedIdentResolved(sym, sym.symbolType, loc);
}

function lowerOperands(ops: Node[], pre: Node[]): void {
	let any = false;
	for (const op of ops) {
		if (hasAwait(op)) any = true;
	}
	if (!any) return;
	for (let i = 0; i < ops.length; i += 1) {
		if (ops[i] == null) continue;
		ops[i] = lowerAwaitExpr(ops[i], pre);
		if (isCallKind(ops[i]) && !isVoidType(ops[i].nodeType)) {
			ops[i] = tempRef(bindTemp(ops[i], DeclKind.Const, ops[i].nodeType, pre, ops[i].location), ops[i].location);
		}
	}
}

function lowerShortCircuit(e: Node, pre: Node[]): Node {
	const d = e.data as BinaryExprData;
	const loc = e.location;
	const t = e.nodeType != null ? e.nodeType : booleanType();
	const tmp = bindTemp(lowerAwaitExpr(d.left, pre), DeclKind.Let, t, pre, loc);
	const inner: Node[] = [];
	const right = lowerAwaitExpr(d.right, inner);
	inner.push(makeExprStmt(makeAssign(tempRef(tmp, loc), right, loc), loc));
	const test = d.operator == "&&" ? tempRef(tmp, loc) : makeUnary("!", tempRef(tmp, loc), loc);
	pre.push(makeIf(test, makeBlock(inner, loc), null, loc));
	return tempRef(tmp, loc);
}

function lowerConditional(e: Node, pre: Node[]): Node {
	const d = e.data as ConditionalExprData;
	const loc = e.location;
	const cond = lowerAwaitExpr(d.ternaryCondition, pre);
	const tmp = bindTemp(makeDefaultValue(e.nodeType, loc), DeclKind.Let, e.nodeType, pre, loc);
	const thenStmts: Node[] = [];
	const thenVal = lowerAwaitExpr(d.ternaryConsequent, thenStmts);
	thenStmts.push(makeExprStmt(makeAssign(tempRef(tmp, loc), thenVal, loc), loc));
	const elseStmts: Node[] = [];
	const elseVal = lowerAwaitExpr(d.ternaryAlternate, elseStmts);
	elseStmts.push(makeExprStmt(makeAssign(tempRef(tmp, loc), elseVal, loc), loc));
	pre.push(makeIf(cond, makeBlock(thenStmts, loc), makeBlock(elseStmts, loc), loc));
	return tempRef(tmp, loc);
}

function lowerAwaitExpr(e: Node, pre: Node[]): Node {
	if (e == null || !hasAwait(e)) return e;
	const k = e.kind;
	if (k == NodeKind.AwaitExpr) {
		const d = e.data as AwaitExprData;
		d.awaitArg = lowerAwaitExpr(d.awaitArg, pre);
		if (isVoidType(e.nodeType)) return e;
		return tempRef(bindTemp(e, DeclKind.Const, e.nodeType, pre, e.location), e.location);
	}
	if (k == NodeKind.BinaryExpr) {
		const d = e.data as BinaryExprData;
		if (d.operator == "&&" || d.operator == "||") return lowerShortCircuit(e, pre);
		if (d.operator == "&&=" || d.operator == "||=" || d.operator == "??=") return e;
		const ops = [d.left, d.right];
		lowerOperands(ops, pre);
		d.left = ops[0];
		d.right = ops[1];
	} else if (k == NodeKind.ConditionalExpr) {
		if (isVoidType(e.nodeType)) return e;
		return lowerConditional(e, pre);
	} else if (k == NodeKind.CallExpr) {
		const d = e.data as CallExprData;
		const viaMember = d.callee.kind == NodeKind.MemberExpr;
		const ops: Node[] = [viaMember ? (d.callee.data as MemberExprData).object : d.callee];
		for (const a of d.arguments) ops.push(a);
		lowerOperands(ops, pre);
		if (viaMember) (d.callee.data as MemberExprData).object = ops[0];
		else d.callee = ops[0];
		for (let i = 0; i < d.arguments.length; i += 1) d.arguments[i] = ops[i + 1];
	} else if (k == NodeKind.NewExpr) {
		lowerOperands((e.data as NewExprData).newArguments, pre);
	} else if (k == NodeKind.ArrayAccess) {
		const d = e.data as ArrayAccessData;
		const ops = [d.array, d.index];
		lowerOperands(ops, pre);
		d.array = ops[0];
		d.index = ops[1];
	} else if (k == NodeKind.ArrayLiteral) {
		lowerOperands((e.data as ArrayLiteralData).elements, pre);
	} else if (k == NodeKind.ObjectLiteral) {
		lowerOperands((e.data as ObjectLiteralData).properties, pre);
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
	if (s == null || !hasAwait(s)) return [s];
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
	} else if (k == NodeKind.IfStmt) {
		const d = s.data as IfStmtData;
		d.condition = lowerAwaitExpr(d.condition, pre);
		d.consequent = lowerAwaitSlot(d.consequent)!;
		d.alternate = lowerAwaitSlot(d.alternate)!;
	} else if (k == NodeKind.WhileStmt) {
		const d = s.data as WhileStmtData;
		const body = lowerLoopBody(d.whileBody);
		if (hasAwait(d.whileCondition)) {
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
		if (!hasAwait(d.doCondition)) {
			d.doBody = body;
		} else {
			const entered = bindTemp(makeBool(false, loc), DeclKind.Let, booleanType(), pre, loc);
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

// ===== Await → Yield Rewriting =====
// Walk a function body, replacing AwaitExpr nodes with YieldExpr nodes.
// Stops at nested function boundaries (each async function is independent).

function rewriteAwaits(node: Node): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.AwaitExpr) {
		const d = node.data as AwaitExprData;
		return createNode(NodeKind.YieldExpr, { yieldArg: d.awaitArg, isDelegate: false }, syntheticToken(node.location));
	}
	if (isFuncBoundary(node)) return node;
	mapChildren(node, rewriteAwaits);
	return node;
}

// ===== Main Walk =====

function isAsyncFlags(flags: string): boolean {
	return flags == "async" || flags == "async_generator";
}

function desugarAsyncBody(fn: Node, body: Node): void {
	fn.flags = fn.flags.incl(NodeFlag.WasAsync);
	lowerAwaitStmt(body);
	rewriteAwaits(body);
}

function walkAsync(node: Node | null): void {
	if (node == null) return;
	const k = node.kind;
	if (k == NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		walkAsync(d.fnBody);
		if (isAsyncFlags(d.fnFlags)) {
			desugarAsyncBody(node, d.fnBody);
			d.fnFlags = "generator";
		}
	} else if (k == NodeKind.MethodDecl) {
		const d = node.data as MethodDeclData;
		walkAsync(d.methodBody);
		if (isAsyncFlags(d.methodFlags)) {
			desugarAsyncBody(node, d.methodBody);
			d.methodFlags = "generator";
		}
	} else if (k == NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		walkAsync(d.funcExprBody);
		if (isAsyncFlags(d.funcExprFlags)) {
			desugarAsyncBody(node, d.funcExprBody);
			d.funcExprFlags = "generator";
		}
	} else if (k == NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		if (isAsyncFlags(d.arrowFlags) && d.arrowBody != null && d.arrowBody.kind != NodeKind.BlockStmt) {
			const ret = makeReturn(d.arrowBody, node.location);
			d.arrowBody = createNode(NodeKind.BlockStmt, { statements: [ret] }, syntheticToken(node.location));
		}
		walkAsync(d.arrowBody);
		if (isAsyncFlags(d.arrowFlags)) {
			desugarAsyncBody(node, d.arrowBody);
			d.arrowFlags = "generator";
		}
	} else {
		forEachChild(node, (child: Node): void => { walkAsync(child); });
	}
}

// ===== Main Entry Point =====

export function lowerAsync(program: Node, ctx: TransformContext): Node {
	_retAwaitCounter = 0;
	walkAsync(program);
	return program;
}

// ===== Tests =====
test "non-async passthrough" { assert firstStmtKindAfter("function f() { return 1; }", lowerAsync) == NodeKind.FunctionDecl; }

test "stmt count passthrough" { assert stmtCountAfter("const x = 1;", lowerAsync) == 1; }

test "async function still one stmt" { assert stmtCountAfter("async function f() { await x; }", lowerAsync) == 1; }

test "async flag cleared" { assert firstStmtKindAfter("async function f() { await x; }", lowerAsync) == NodeKind.FunctionDecl; }

test "async arrow unchanged count" { assert stmtCountAfter("const f = async () => await x;", lowerAsync) == 1; }

test "non-async function preserved" { assert stmtCountAfter("function f() { return 1; }", lowerAsync) == 1; }

function bodyAfter(src: string): Node[] {
	const parsed = parseInput(src);
	if (!parsed.ok) return [];
	const fn = getStmts(lowerAsync(parsed.value, makeCtx()))[0];
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
