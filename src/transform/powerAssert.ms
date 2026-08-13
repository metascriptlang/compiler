// Power Assert Transform
//
// Instruments `assert expr;` inside test blocks to capture intermediate
// sub-expression values. On failure, prints each value with its position
// in the original source text, using vertical bar markers:
//
//   assert a.x === b + c
//          |   |    | | |
//          |   |    | | 3
//          |   |    | 5
//          |   |    2
//          |   false
//          42
//
// Only transforms AssertStmt nodes found inside TestDecl bodies.
// Outside test blocks, AssertStmt is left untouched (codegen emits simple abort).

import { Node, NodeKind, DeclKind, ProgramData, TestDeclData, BlockStmtData, AssertStmtData, BinaryExprData, UnaryExprData, CallExprData, MemberExprData, IdentifierData, NumberLiteralData, StringLiteralData, BooleanLiteralData, SourceLocation, makeLoc, Type, TypeKind } from "../ast/node";
import { isIntegerType } from "../checker/types";
import { TransformContext } from "./context";
import { makeIdent, makeString, makeNumber, makeBlock, makeVarDecl, makeExprStmt, makeIf, makeUnary, makeNull, syntheticToken } from "./util";
import { createNode } from "../ast/node";

// ===== Type-based __paValue dispatch =====

function paValueFnForType(t: Type): string {
	if (t === null) return "__paValueNum";
	if (t.kind === TypeKind.String) return "__paValueStr";
	if (t.kind === TypeKind.Boolean) return "__paValueBool";
	if (isIntegerType(t)) return "__paValueInt";
	return "__paValueNum";
}

// ===== Capture Entry =====

interface CaptureEntry {
	tempName: string;
	tempDecl: Node;
	label: string;
	column: number;
}

// ===== Main Entry Point =====

export function lowerPowerAssert(program: Node, ctx: TransformContext): Node {
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		walkForTests(pd.programStmts[i]);
	}
	return program;
}

function walkForTests(node: Node): void {
	if (node.kind === NodeKind.TestDecl) {
		instrumentTestBody(node);
		return;
	}
	// Recurse into blocks that might contain test decls (e.g., top-level blocks)
	if (node.kind === NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		for (let i = 0; i < bd.statements.length; i += 1) {
			walkForTests(bd.statements[i]);
		}
	}
}

function instrumentTestBody(testNode: Node): void {
	const d = testNode.data as TestDeclData;
	if (d.testBody === null) return;
	if (d.testBody.kind !== NodeKind.BlockStmt) return;
	const bd = d.testBody.data as BlockStmtData;
	const newStmts: Node[] = [];
	for (let i = 0; i < bd.statements.length; i += 1) {
		const stmt = bd.statements[i];
		if (stmt.kind === NodeKind.AssertStmt) {
			newStmts.push(instrumentAssert(stmt));
		} else {
			newStmts.push(stmt);
		}
	}
	d.testBody.data = { statements: newStmts };
}

// ===== Instrument a single AssertStmt =====

let paCounter = 0;

function instrumentAssert(assertNode: Node): Node {
	const d = assertNode.data as AssertStmtData;
	const expr = d.assertExpr;
	const source = d.assertSource;
	const loc = assertNode.location;

	// An explicit message states what to report — keep it, don't replace it with
	// the auto-decomposition diagram (the reporter shows the diagram over the message).
	if (d.assertMessage.length > 0 || d.assertMessageExpr !== null) return assertNode;

	// Only instrument "interesting" expressions (binary, member, call, unary)
	if (!isDecomposable(expr)) return assertNode;

	paCounter = 0;
	const captures: CaptureEntry[] = [];
	const baseCol = expr.location.column;
	const resultRef = decomposeExpr(expr, captures, baseCol, loc);

	// Need at least 2 captures to be useful (otherwise it's just the whole expression)
	if (captures.length < 2) return assertNode;

	// Build the replacement block
	const stmts: Node[] = [];

	// 1. Temp variable declarations
	for (let i = 0; i < captures.length; i += 1) {
		stmts.push(captures[i].tempDecl);
	}

	// 2. If the result is false, report and fail
	const failStmts: Node[] = [];

	// Call __paBegin(source)
	failStmts.push(makeCallStmt("__paBegin", [makeString(source, loc)], loc));

	// For each capture, call the type-appropriate capture function
	for (let i = 0; i < captures.length; i += 1) {
		const cap = captures[i];
		const ref = makeIdent(cap.tempName, loc);
		const fnName = paValueFnForType(cap.tempDecl.nodeType);
		failStmts.push(makeCallStmt(fnName, [
			makeNumber(cap.column, loc),
			makeString(cap.label, loc),
			ref,
		], loc));
	}

	// Call __paEnd()
	failStmts.push(makeCallStmt("__paEnd", [], loc));

	// Keep the original assert for the actual test failure (reached only for
	// message-less asserts, so no message to carry).
	const simpleAssert = createNode(NodeKind.AssertStmt, {
		assertExpr: resultRef,
		assertSource: source,
		assertMessage: "",
		assertMessageExpr: null,
	}, syntheticToken(loc));
	failStmts.push(simpleAssert);

	// Build: if (!result) { ...fail... }
	const notResult = makeUnary("!", resultRef, loc);
	const failBlock = makeBlock(failStmts, loc);
	const ifStmt = makeIf(notResult, failBlock, null, loc);
	stmts.push(ifStmt);

	return makeBlock(stmts, loc);
}

// ===== Expression Decomposition =====

function decomposeExpr(
	expr: Node,
	captures: CaptureEntry[],
	baseCol: number,
	loc: SourceLocation,
): Node {
	// Literals: no capture needed, return as-is
	if (expr.kind === NodeKind.NumberLiteral ||
		expr.kind === NodeKind.StringLiteral ||
		expr.kind === NodeKind.BooleanLiteral ||
		expr.kind === NodeKind.NullLiteral) {
		return expr;
	}

	// Identifier: capture the value
	if (expr.kind === NodeKind.Identifier) {
		const d = expr.data as IdentifierData;
		return captureValue(expr, d.name, expr.location.column - baseCol, captures, loc);
	}

	// Member access: decompose object, then capture the full member access
	if (expr.kind === NodeKind.MemberExpr) {
		const d = expr.data as MemberExprData;
		const objRef = decomposeExpr(d.object, captures, baseCol, loc);
		// Build new member expr using the temp reference
		const newMember = createNode(NodeKind.MemberExpr, {
			object: objRef, property: d.property, isOptional: d.isOptional,
		}, syntheticToken(loc));
		if (expr.nodeType !== null) newMember.nodeType = expr.nodeType;
		newMember.flags = expr.flags;
		if (expr.resolvedSym !== null) newMember.resolvedSym = expr.resolvedSym;
		return captureValue(newMember, exprLabel(expr), expr.location.column - baseCol, captures, loc);
	}

	// Binary expression: decompose left and right, then capture the result
	if (expr.kind === NodeKind.BinaryExpr) {
		const d = expr.data as BinaryExprData;
		const leftRef = decomposeExpr(d.left, captures, baseCol, loc);
		const rightRef = decomposeExpr(d.right, captures, baseCol, loc);
		const newBinary = createNode(NodeKind.BinaryExpr, {
			operator: d.operator, left: leftRef, right: rightRef,
		}, syntheticToken(loc));
		if (expr.nodeType !== null) newBinary.nodeType = expr.nodeType;
		newBinary.flags = expr.flags;
		if (expr.resolvedSym !== null) newBinary.resolvedSym = expr.resolvedSym;
		return captureValue(newBinary, exprLabel(expr), expr.location.column - baseCol, captures, loc);
	}

	// Unary expression: decompose operand, then capture the result
	if (expr.kind === NodeKind.UnaryExpr) {
		const d = expr.data as UnaryExprData;
		const operandRef = decomposeExpr(d.operand, captures, baseCol, loc);
		const newUnary = createNode(NodeKind.UnaryExpr, {
			unaryOp: d.unaryOp, operand: operandRef,
		}, syntheticToken(loc));
		if (expr.nodeType !== null) newUnary.nodeType = expr.nodeType;
		newUnary.flags = expr.flags;
		if (expr.resolvedSym !== null) newUnary.resolvedSym = expr.resolvedSym;
		return captureValue(newUnary, exprLabel(expr), expr.location.column - baseCol, captures, loc);
	}

	// Call expression: decompose arguments, then capture the call result
	if (expr.kind === NodeKind.CallExpr) {
		const d = expr.data as CallExprData;
		const newArgs: Node[] = [];
		for (let i = 0; i < d.arguments.length; i += 1) {
			newArgs.push(decomposeExpr(d.arguments[i], captures, baseCol, loc));
		}
		// A method callee is left intact — later passes lower it by matching on
		// the original node (protocol methods have no property to read at all),
		// and a temp holding `obj.method` would be detached from its receiver.
		// Arguments and the call result still get captured.
		const newCallee = d.callee;
		const newCall = createNode(NodeKind.CallExpr, {
			callee: newCallee, arguments: newArgs,
			isDirectCall: d.isDirectCall, resolvedOverloadIdx: d.resolvedOverloadIdx,
		}, syntheticToken(loc));
		if (expr.nodeType !== null) newCall.nodeType = expr.nodeType;
		newCall.flags = expr.flags;
		if (expr.resolvedSym !== null) newCall.resolvedSym = expr.resolvedSym;
		return captureValue(newCall, exprLabel(expr), expr.location.column - baseCol, captures, loc);
	}

	// Anything else: return as-is (no decomposition)
	return expr;
}

// ===== Helpers =====

function captureValue(
	expr: Node,
	label: string,
	column: number,
	captures: CaptureEntry[],
	loc: SourceLocation,
): Node {
	const name = "__pa_" + paCounter.toString();
	paCounter = paCounter + 1;
	const varDecl = makeVarDecl(name, expr, DeclKind.Const, loc);
	const ref = makeIdent(name, loc);
	if (expr.nodeType !== null) ref.nodeType = expr.nodeType;
	captures.push({ tempName: name, tempDecl: varDecl, label, column });
	return ref;
}

function isDecomposable(expr: Node): boolean {
	return expr.kind === NodeKind.BinaryExpr ||
		expr.kind === NodeKind.MemberExpr ||
		expr.kind === NodeKind.CallExpr ||
		expr.kind === NodeKind.UnaryExpr;
}

// Reconstruct a human-readable label from an expression AST node
function exprLabel(node: Node): string {
	if (node.kind === NodeKind.Identifier) {
		return (node.data as IdentifierData).name;
	}
	if (node.kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		return exprLabel(d.object) + "." + d.property;
	}
	if (node.kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		return exprLabel(d.left) + " " + d.operator + " " + exprLabel(d.right);
	}
	if (node.kind === NodeKind.UnaryExpr) {
		const d = node.data as UnaryExprData;
		if (d.unaryOp === "!" || d.unaryOp === "-" || d.unaryOp === "~") {
			return d.unaryOp + exprLabel(d.operand);
		}
		return d.unaryOp + " " + exprLabel(d.operand);
	}
	if (node.kind === NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		let args = "";
		for (let i = 0; i < d.arguments.length; i += 1) {
			if (i > 0) args = args + ", ";
			args = args + exprLabel(d.arguments[i]);
		}
		return exprLabel(d.callee) + "(" + args + ")";
	}
	if (node.kind === NodeKind.NumberLiteral) {
		return (node.data as NumberLiteralData).value.toString();
	}
	if (node.kind === NodeKind.StringLiteral) {
		return "\"" + (node.data as StringLiteralData).value + "\"";
	}
	if (node.kind === NodeKind.BooleanLiteral) {
		const d = node.data as BooleanLiteralData;
		if (d.boolValue) return "true";
		return "false";
	}
	return "?";
}

function makeCallStmt(fnName: string, args: Node[], loc: SourceLocation): Node {
	const callee = makeIdent(fnName, loc);
	const callNode = createNode(NodeKind.CallExpr, {
		callee, arguments: args, isDirectCall: true, resolvedOverloadIdx: -1,
	}, syntheticToken(loc));
	return makeExprStmt(callNode, loc);
}

// ===== Tests =====

test "exprLabel identifier" {
	assert exprLabel(makeIdent("foo", makeLoc(1, 0))) === "foo";
}

test "exprLabel binary" {
	const left = makeIdent("a", makeLoc(1, 0));
	const right = makeIdent("b", makeLoc(1, 5));
	const bin = createNode(NodeKind.BinaryExpr, {
		operator: "===", left, right,
	}, syntheticToken(makeLoc(1, 2)));
	assert exprLabel(bin) === "a === b";
}

test "exprLabel member" {
	const obj = makeIdent("obj", makeLoc(1, 0));
	const mem = createNode(NodeKind.MemberExpr, {
		object: obj, property: "x", isOptional: false,
	}, syntheticToken(makeLoc(1, 0)));
	assert exprLabel(mem) === "obj.x";
}

test "isDecomposable binary" {
	const left = makeIdent("a", makeLoc(1, 0));
	const right = makeIdent("b", makeLoc(1, 5));
	const bin = createNode(NodeKind.BinaryExpr, {
		operator: "===", left, right,
	}, syntheticToken(makeLoc(1, 2)));
	assert isDecomposable(bin);
}

test "isDecomposable literal" {
	const lit = createNode(NodeKind.NumberLiteral, { value: 42, isFloat: false, intVal: 42 as int64 }, syntheticToken(makeLoc(1, 0)));
	assert !isDecomposable(lit);
}

test "decompose simple binary" {
	const loc = makeLoc(1, 0);
	const left = makeIdent("a", loc);
	const right = makeIdent("b", makeLoc(1, 6));
	const bin = createNode(NodeKind.BinaryExpr, {
		operator: "===", left, right,
	}, syntheticToken(makeLoc(1, 2)));
	paCounter = 0;
	const captures: CaptureEntry[] = [];
	const result = decomposeExpr(bin, captures, 0, loc);
	// Should have 3 captures: a, b, a === b
	assert captures.length === 3;
	assert captures[0].label === "a";
	assert captures[1].label === "b";
	assert captures[2].label === "a === b";
}

test "decompose member access" {
	const loc = makeLoc(1, 0);
	const obj = makeIdent("obj", loc);
	const mem = createNode(NodeKind.MemberExpr, {
		object: obj, property: "x", isOptional: false,
	}, syntheticToken(loc));
	const right = makeIdent("y", makeLoc(1, 10));
	const bin = createNode(NodeKind.BinaryExpr, {
		operator: "===", left: mem, right,
	}, syntheticToken(makeLoc(1, 6)));
	paCounter = 0;
	const captures: CaptureEntry[] = [];
	decomposeExpr(bin, captures, 0, loc);
	// Should have 4 captures: obj, obj.x, y, obj.x === y
	assert captures.length === 4;
	assert captures[0].label === "obj";
	assert captures[1].label === "obj.x";
	assert captures[2].label === "y";
	assert captures[3].label === "obj.x === y";
}
