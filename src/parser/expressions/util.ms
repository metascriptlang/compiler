// Expression Test Utilities
// Provides parseOk() for integration tests across expression sub-modules.
// core.ms registers the real parseExpression at module load time.
// Test callbacks are lazy (registered during load, executed after), so
// parseFn is always set by the time tests actually run.

import { Token, TokenKind, isIdentOrKeyword } from "../../lexer/token";
import { Node, NodeKind, Expression, createNode, createNodeAt, makeLoc, BinaryExprData, UnaryExprData, UpdateExprData } from "../../ast/node";
import { ParserState, current, advance, isAtEnd } from "../context";
import { lex } from "../../lexer/lexer";
import { parseNumberLiteral, parseIntegerLiteral, integerLiteralFits, integerLiteralIsBitPattern, numericLiteralIsFloat } from "../../utils/string";
import { isIdentLike } from "../util";

type ExprResult = Result<Expression, string>;
type ParseExprFn = (tokens: Token[]) => ExprResult;

let parseFn: ParseExprFn = (tokens: Token[]): ExprResult => {
	return Result.err("parseOk not registered");
};

export function registerParseExpr(fn: ParseExprFn): void {
	parseFn = fn;
}

export function parseOk(input: string): boolean {
	const lr = lex(input);
	if (!lr.ok) return false;
	const pr = parseFn(lr.value);
	return pr.ok;
}

export function exprKind(input: string): NodeKind {
	const lr = lex(input);
	if (!lr.ok) return NodeKind.NumberLiteral;
	const pr = parseFn(lr.value);
	if (!pr.ok) return NodeKind.NumberLiteral;
	return pr.value.kind;
}

export function exprNode(input: string): Node {
	const lr = lex(input);
	if (!lr.ok) return createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, makeLoc(0, 0));
	const pr = parseFn(lr.value);
	if (!pr.ok) return createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, makeLoc(0, 0));
	return pr.value;
}

export function exprOp(input: string): string {
	const lr = lex(input);
	if (!lr.ok) return "";
	const pr = parseFn(lr.value);
	if (!pr.ok) return "";
	if (pr.value.kind === NodeKind.BinaryExpr) {
		const d = pr.value.data as BinaryExprData;
		return d.operator;
	}
	if (pr.value.kind === NodeKind.UnaryExpr) {
		const d = pr.value.data as UnaryExprData;
		return d.unaryOp;
	}
	if (pr.value.kind === NodeKind.UpdateExpr) {
		const d = pr.value.data as UpdateExprData;
		return d.updateOp;
	}
	return "";
}

// ===== Mock Expression Parser for Unit Tests =====
// Shared by call.ms, object.ms, arrow.ms tests

export function mockExpr(state: ParserState, minPrec: number): ExprResult {
	const tok = current(state);
	if (tok.kind === TokenKind.Number) {
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
	if (tok.kind === TokenKind.String) {
		advance(state);
		return Result.ok(createNode(NodeKind.StringLiteral, { value: tok.value }, tok));
	}
	return Result.err("mock: unexpected token");
}

// ===== Member Access Chain Parser =====
// Shared by new-expression (core.ms) and match-pattern (match.ms)
// Parses: base.prop1.prop2.prop3...

export function parseMemberChain(state: ParserState, base: Node): Node {
	let node = base;
	while (!isAtEnd(state) && current(state).kind === TokenKind.Dot) {
		const dotToken = current(state);
		advance(state);
		const prop = current(state);
		if (isIdentOrKeyword(prop.kind)) {
			advance(state);
			node = createNode(NodeKind.MemberExpr, { object: node, property: prop.value, isOptional: false }, dotToken);
		} else {
			break;
		}
	}
	return node;
}

// Try-parse a literal-keyword token (true/false/null) into the corresponding
// literal Node. Returns null if current token is not a literal keyword.
// Shared by expression parser (core.ms) and match-pattern parser (match.ms)
// — both must produce literal nodes (not Identifier-with-name) so downstream
// passes treat them as literals rather than binding names. See bug025.
export function tryParseLiteralKeyword(state: ParserState): Node {
	const token = current(state);
	if (token.kind === TokenKind.True || token.kind === TokenKind.False) {
		advance(state);
		return createNode(NodeKind.BooleanLiteral, { boolValue: token.kind === TokenKind.True }, token);
	}
	if (token.kind === TokenKind.Null) {
		advance(state);
		return createNode(NodeKind.NullLiteral, { nullPlaceholder: true }, token);
	}
	return null as unknown as Node;
}

export function binLeftKind(input: string): NodeKind {
	const lr = lex(input);
	if (!lr.ok) return NodeKind.NumberLiteral;
	const pr = parseFn(lr.value);
	if (!pr.ok) return NodeKind.NumberLiteral;
	const d = pr.value.data as BinaryExprData;
	return d.left.kind;
}
