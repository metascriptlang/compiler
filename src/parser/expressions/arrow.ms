// Arrow Function Parser
// Extracted from expression.ms with callback injection

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, Expression, createNode } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd, peek } from "../context";
import { skipTypeAnnotation } from "../typeAnnotation";
import { lex } from "../../lexer/lexer";
import { parseOk } from "./util";
import { test, check, testGroup } from "std/testing";

type ExprResult = Result<Expression, string>;
type ExprParser = (state: ParserState, minPrec: number) => ExprResult;
type BlockParser = (state: ParserState) => ExprResult;

// ===== Arrow Function Lookahead =====

export function isArrowFunction(state: ParserState): boolean {
	// Must start with (
	if (current(state).kind !== TokenKind.LParen) { return false; }

	const p1 = peek(state, 1);
	// () =>  (zero params)
	if (p1.kind === TokenKind.RParen && peek(state, 2).kind === TokenKind.Arrow) {
		return true;
	}

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
	blockParser: BlockParser
): ExprResult {
	const arrowToken = current(state);
	advance(state); // consume (

	const params: string[] = [];
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RParen) {
		const param = current(state);
		if (param.kind !== TokenKind.Ident) {
			return Result.err(`Expected parameter name at line ${param.line.toString()}`);
		}
		params.push(param.value);
		advance(state);

		// Optional type annotation: (a: string)
		if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
			advance(state);
			skipTypeAnnotation(state);
		}

		if (current(state).kind === TokenKind.Comma) {
			advance(state);
		} else {
			break;
		}
	}

	if (current(state).kind === TokenKind.RParen) { advance(state); }

	// Optional return type annotation: (): string => ...
	if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
		advance(state);
		skipTypeAnnotation(state);
	}

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
		}, arrowToken));
	}

	const body = try exprParser(state, 0);
	return Result.ok(createNode(NodeKind.ArrowFunction, {
		arrowParams: params,
		arrowBody: body,
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
	const result = parseArrowFunction(state, mockExpr, mockBlock);
	return result.ok;
}

function arrowParamCount(input: string): number {
	const lr = lex(input);
	if (!lr.ok) return -1;
	const state = createState(lr.value);
	const result = parseArrowFunction(state, mockExpr, mockBlock);
	if (!result.ok) return -1;
	const data = result.value.data as { arrowParams: string[], arrowBody: Node };
	return data.arrowParams.length;
}

testGroup("Arrow isArrowFunction", () => {
	test("zero params", () => { check(checkArrow("() => 42")); });
	test("single param", () => { check(checkArrow("(x) => x")); });
	test("multi params comma", () => { check(checkArrow("(a, b) => a")); });
	test("typed param", () => { check(checkArrow("(x: number) => x")); });
	test("not arrow - paren expr", () => { check(!checkArrow("(a + b)")); });
	test("not arrow - call", () => { check(!checkArrow("f(a)")); });
	test("not arrow - number", () => { check(!checkArrow("42")); });
});

testGroup("Arrow parseArrowFunction", () => {
	test("zero params ok", () => { check(arrowOk("() => 42")); });
	test("single param ok", () => { check(arrowOk("(x) => x")); });
	test("two params ok", () => { check(arrowOk("(a, b) => a")); });
	test("zero param count", () => { check(arrowParamCount("() => 42") === 0); });
	test("single param count", () => { check(arrowParamCount("(x) => x") === 1); });
	test("two param count", () => { check(arrowParamCount("(a, b) => a") === 2); });
	test("three param count", () => { check(arrowParamCount("(a, b, c) => a") === 3); });
	test("typed param ok", () => { check(arrowOk("(x: number) => x")); });
});

testGroup("Expr Arrow Functions", () => {
	test("zero params", () => { check(parseOk("() => 42")); });
	test("single param", () => { check(parseOk("(x) => x")); });
	test("two params", () => { check(parseOk("(a, b) => a + b")); });
	test("three params", () => { check(parseOk("(a, b, c) => a")); });
	test("nested call in body", () => { check(parseOk("(x) => f(x)")); });
	test("binary in body", () => { check(parseOk("(x) => x + 1")); });
	test("member in body", () => { check(parseOk("(x) => x.y")); });
	test("arrow as call arg", () => { check(parseOk("f((x) => x)")); });
	test("arrow in array", () => { check(parseOk("[(x) => x]")); });
	test("paren expr still works", () => { check(parseOk("(a + b)")); });
	test("paren expr complex", () => { check(parseOk("(a + b) * c")); });
});
