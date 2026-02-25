// Transform Utilities — node-building helpers for AST transforms
// Each helper wraps createNode with the correct NodeKind and data shape.

import { Token, TokenKind, createToken } from "../lexer/token";
import { Node, NodeKind, SourceLocation, createNode, BlockStmtData } from "../ast/node";

// Create a synthetic token from a source location (for transform-generated nodes)
export function syntheticToken(loc: SourceLocation): Token {
	return createToken(TokenKind.Ident, "", loc.line);
}

// ===== Literal Builders =====

export function makeIdent(identName: string, loc: SourceLocation): Node {
	return createNode(NodeKind.Identifier, { name: identName }, syntheticToken(loc));
}

export function makeNull(loc: SourceLocation): Node {
	return createNode(NodeKind.NullLiteral, { nullPlaceholder: true }, syntheticToken(loc));
}

export function makeNumber(val: number, loc: SourceLocation): Node {
	return createNode(NodeKind.NumberLiteral, { value: val }, syntheticToken(loc));
}

export function makeString(val: string, loc: SourceLocation): Node {
	return createNode(NodeKind.StringLiteral, { value: val }, syntheticToken(loc));
}

export function makeBool(val: boolean, loc: SourceLocation): Node {
	return createNode(NodeKind.BooleanLiteral, { boolValue: val }, syntheticToken(loc));
}

// ===== Statement Builders =====

export function makeBlock(stmts: Node[], loc: SourceLocation): Node {
	return createNode(NodeKind.BlockStmt, { statements: stmts }, syntheticToken(loc));
}

export function makeVarDecl(varName: string, init: Node, isConst: boolean, loc: SourceLocation): Node {
	return createNode(NodeKind.VariableDecl, { declName: varName, initializer: init, isConst }, syntheticToken(loc));
}

export function makeExprStmt(exprNode: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.ExprStmt, { expr: exprNode }, syntheticToken(loc));
}

export function makeReturn(arg: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.ReturnStmt, { argument: arg }, syntheticToken(loc));
}

export function makeIf(cond: Node, thenBranch: Node, elseBranch: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.IfStmt, { condition: cond, consequent: thenBranch, alternate: elseBranch }, syntheticToken(loc));
}

export function makeWhile(cond: Node, body: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.WhileStmt, { whileCondition: cond, whileBody: body }, syntheticToken(loc));
}

export function makeTryCatch(tryBody: Node, catchName: string, catchBody: Node, finallyBody: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.TryCatchStmt, { tryBody, catchName, catchBody, finallyBody }, syntheticToken(loc));
}

// ===== Expression Builders =====

export function makeBinary(leftNode: Node, op: string, rightNode: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.BinaryExpr, { operator: op, left: leftNode, right: rightNode }, syntheticToken(loc));
}

export function makeUnary(op: string, arg: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.UnaryExpr, { unaryOp: op, operand: arg }, syntheticToken(loc));
}

export function makeCall(calleeNode: Node, args: Node[], loc: SourceLocation): Node {
	return createNode(NodeKind.CallExpr, { callee: calleeNode, arguments: args }, syntheticToken(loc));
}

export function makeMember(obj: Node, prop: string, loc: SourceLocation): Node {
	return createNode(NodeKind.MemberExpr, { object: obj, property: prop, isOptional: false }, syntheticToken(loc));
}

export function makeConditional(cond: Node, cons: Node, alt: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.ConditionalExpr, { ternaryCondition: cond, ternaryConsequent: cons, ternaryAlternate: alt }, syntheticToken(loc));
}

export function makeAssign(leftNode: Node, rightNode: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.BinaryExpr, { operator: "=", left: leftNode, right: rightNode }, syntheticToken(loc));
}

export function makeArrayAccess(obj: Node, idx: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.ArrayAccess, { array: obj, index: idx }, syntheticToken(loc));
}

export function makeSwitch(disc: Node, cases: Node[], loc: SourceLocation): Node {
	return createNode(NodeKind.SwitchStmt, { switchDisc: disc, switchCases: cases }, syntheticToken(loc));
}

export function makeSwitchCase(tests: Node[], stmts: Node[], isDefault: boolean, loc: SourceLocation): Node {
	return createNode(NodeKind.SwitchCase, { caseTests: tests, caseStmts: stmts, isDefault }, syntheticToken(loc));
}

// ===== Helpers =====

// Extract statements from a body node (block → its stmts, single stmt → [stmt])
export function extractBodyStmts(body: Node): Node[] {
	const result: Node[] = [];
	if (body.kind === NodeKind.BlockStmt) {
		const bd = body.data as BlockStmtData;
		for (const stmt of bd.statements) {
			result.push(stmt);
		}
	} else {
		result.push(body);
	}
	return result;
}
