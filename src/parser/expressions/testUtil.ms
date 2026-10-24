// Expression Test Utilities
// Provides parseOk() for integration tests across expression sub-modules.

import { TokenKind } from "../../lexer/token";
import { Node, NodeKind, Expression, createNode, createNodeAt, makeLoc, BinaryExprData, UnaryExprData, UpdateExprData } from "../../ast/node";
import { ParserState, current, advance } from "../context";
import { lex } from "../../lexer/lexer";
import { parseNumberLiteral, parseIntegerLiteral, integerLiteralFits, integerLiteralIsBitPattern, numericLiteralIsFloat } from "../../utils/string";
import { isIdentLike } from "../util";
import { parseExpression } from "./core";

type ExprResult = Result<Expression, string>;

export function parseOk(input: string): boolean {
	const lr = lex(input);
	if (!lr.ok) return false;
	const pr = parseExpression(lr.value);
	return pr.ok;
}

export function exprKind(input: string): NodeKind {
	const lr = lex(input);
	if (!lr.ok) return NodeKind.NumberLiteral;
	const pr = parseExpression(lr.value);
	if (!pr.ok) return NodeKind.NumberLiteral;
	return pr.value.kind;
}

export function exprNode(input: string): Node {
	const lr = lex(input);
	if (!lr.ok) return createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, makeLoc(0, 0));
	const pr = parseExpression(lr.value);
	if (!pr.ok) return createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, makeLoc(0, 0));
	return pr.value;
}

export function exprOp(input: string): string {
	const lr = lex(input);
	if (!lr.ok) return "";
	const pr = parseExpression(lr.value);
	if (!pr.ok) return "";
	if (pr.value.kind == NodeKind.BinaryExpr) {
		const d = pr.value.data as BinaryExprData;
		return d.operator;
	}
	if (pr.value.kind == NodeKind.UnaryExpr) {
		const d = pr.value.data as UnaryExprData;
		return d.unaryOp;
	}
	if (pr.value.kind == NodeKind.UpdateExpr) {
		const d = pr.value.data as UpdateExprData;
		return d.updateOp;
	}
	return "";
}

// ===== Mock Expression Parser for Unit Tests =====
// Shared by call.ms, object.ms, arrow.ms tests

export function mockExpr(state: ParserState, minPrec: int32): ExprResult {
	const tok = current(state);
	if (tok.kind == TokenKind.Number) {
		advance(state);
		const isFloat = numericLiteralIsFloat(tok.value);
		const intVal = isFloat ? 0 as int64 : parseIntegerLiteral(tok.value);
		const outOfRangeText = isFloat || integerLiteralFits(tok.value) ? "" : tok.value;
		const isBitPattern = !isFloat && integerLiteralIsBitPattern(tok.value);
		return Result.ok(createNode(NodeKind.NumberLiteral, { value: parseNumberLiteral(tok.value), isFloat, intVal, outOfRangeText, isBitPattern }, tok));
	}
	if (isIdentLike(tok)) {
		advance(state);
		return Result.ok(createNode(NodeKind.Identifier, { name: tok.value }, tok));
	}
	if (tok.kind == TokenKind.String) {
		advance(state);
		return Result.ok(createNode(NodeKind.StringLiteral, { value: tok.value }, tok));
	}
	return Result.err("mock: unexpected token");
}

export function binLeftKind(input: string): NodeKind {
	const lr = lex(input);
	if (!lr.ok) return NodeKind.NumberLiteral;
	const pr = parseExpression(lr.value);
	if (!pr.ok) return NodeKind.NumberLiteral;
	const d = pr.value.data as BinaryExprData;
	return d.left.kind;
}
