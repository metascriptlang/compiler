// Arrow Function Parser
// Extracted from expression.ms with callback injection

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, Expression, createNode } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd, peek } from "../context";
import { parseParamList, skipOptionalType } from "../util";
import { lex } from "../../lexer/lexer";
import { parseOk } from "./util";
import { test, check, testGroup } from "std/testing";

type ExprResult = Result<Expression, string>;
type ExprParser = (state: ParserState, minPrec: number) => ExprResult;
type BlockParser = (state: ParserState) => ExprResult;

// syntax: arrow = ('async')? ('(' params ')' | ID) (':' type)? '=>' (expr | block)

// ===== Arrow Function Lookahead =====

export function isArrowFunction(state: ParserState): boolean {
	// Must start with (
	if (current(state).kind !== TokenKind.LParen) { return false; }

	const p1 = peek(state, 1);
	// () =>  (zero params)
	if (p1.kind === TokenKind.RParen && peek(state, 2).kind === TokenKind.Arrow) {
		return true;
	}

	// Rest params: (...args) =>
	if (p1.kind === TokenKind.DotDotDot) { return true; }

	// Destructured params: ({ ... }) => or ([ ... ]) =>
	if (p1.kind === TokenKind.LBrace || p1.kind === TokenKind.LBracket) { return true; }

	// Must have identifier as first param
	if (p1.kind !== TokenKind.Ident) { return false; }

	const p2 = peek(state, 2);
	// (ident) =>  (single untyped param)
	if (p2.kind === TokenKind.RParen && peek(state, 3).kind === TokenKind.Arrow) {
		return true;
	}

	// (ident,  (multiple params — comma is never valid start of paren subexpr)
	if (p2.kind === TokenKind.Comma) { return true; }

	// (ident:  (typed param — colon never valid after bare ident in expression)
	if (p2.kind === TokenKind.Colon) { return true; }

	return false;
}

// ===== Arrow Function Parser =====

export function parseArrowFunction(
	state: ParserState,
	exprParser: ExprParser,
	blockParser: BlockParser,
	flags: string
): ExprResult {
	const arrowToken = current(state);
	const params = parseParamList(state);

	// Optional return type annotation: (): string => ...
	skipOptionalType(state);

	if (isAtEnd(state) || current(state).kind !== TokenKind.Arrow) {
		return Result.err(`Expected '=>' in arrow function at line ${current(state).line.toString()}`);
	}

	advance(state); // consume =>
	// Body: block { ... } or expression
	if (!isAtEnd(state) && current(state).kind === TokenKind.LBrace) {
		const body = try blockParser(state);
		return Result.ok(createNode(NodeKind.ArrowFunction, {
			arrowParams: params,
			arrowBody: body,
			arrowFlags: flags,
		}, arrowToken));
	}

	const body = try exprParser(state, 0);
	return Result.ok(createNode(NodeKind.ArrowFunction, {
		arrowParams: params,
		arrowBody: body,
		arrowFlags: flags,
	}, arrowToken));
}

// ===== Tests =====

function mockExpr(state: ParserState, minPrec: number): ExprResult {
	const tok = current(state);
	if (tok.kind === TokenKind.Number) {
		advance(state);
		return Result.ok(createNode(NodeKind.NumberLiteral, { value: parseFloat(tok.value) }, tok));
	}
	if (tok.kind === TokenKind.Ident) {
		advance(state);
		return Result.ok(createNode(NodeKind.Identifier, { name: tok.value }, tok));
	}
	return Result.err("mock: unexpected token");
}

function mockBlock(state: ParserState): ExprResult {
	return Result.err("mock: block not supported");
}

function checkArrow(input: string): boolean {
	const lr = lex(input);
	if (!lr.ok) return false;
	const state = createState(lr.value);
	return isArrowFunction(state);
}

function arrowOk(input: string): boolean {
	const lr = lex(input);
	if (!lr.ok) return false;
	const state = createState(lr.value);
	const result = parseArrowFunction(state, mockExpr, mockBlock, "");
	return result.ok;
}

function arrowParamCount(input: string): number {
	const lr = lex(input);
	if (!lr.ok) return -1;
	const state = createState(lr.value);
	const result = parseArrowFunction(state, mockExpr, mockBlock, "");
	if (!result.ok) return -1;
	const data = result.value.data as { arrowParams: string[], arrowBody: Node, arrowFlags: string };
	return data.arrowParams.length;
}

testGroup("Arrow Structure", () => {
	// Detection
	test("detect arrow", () => { check(checkArrow("() => 42")); });
	test("detect typed", () => { check(checkArrow("(x: number) => x")); });
	test("reject paren expr", () => { check(!checkArrow("(a + b)")); });
	test("reject call", () => { check(!checkArrow("f(a)")); });
	// Param counts
	test("zero params", () => { check(arrowParamCount("() => 42") === 0); });
	test("two params", () => { check(arrowParamCount("(a, b) => a") === 2); });
	// Integration
	test("arrow as arg", () => { check(parseOk("f((x) => x)")); });
	test("paren expr still works", () => { check(parseOk("(a + b) * c")); });
});
