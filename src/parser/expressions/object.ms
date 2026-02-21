// Object Literal Parser
// Extracted from expression.ms with callback injection

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, Expression, createNode } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd } from "../context";
import { lex } from "../../lexer/lexer";
import { parseOk } from "./util";
import { test, check, testGroup } from "std/testing";

type ExprResult = Result<Expression, string>;
type ExprParser = (state: ParserState, minPrec: number) => ExprResult;

// ===== Object Literal =====
// { key: value, ... } or { key, ... } (shorthand)

export function parseObjectLiteral(state: ParserState, exprParser: ExprParser): ExprResult {
	const lbrace = current(state);
	const keys: string[] = [];
	const values: Expression[] = [];

	advance(state);
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		const keyToken = current(state);
		if (keyToken.kind !== TokenKind.Ident) {
			return Result.err(`Expected property name at line ${keyToken.line.toString()}`);
		}
		advance(state);

		if (current(state).kind === TokenKind.Colon) {
			// Full property: { key: value }
			advance(state);
			keys.push(keyToken.value);
			const val = try exprParser(state, 0);
			values.push(val);
		} else {
			// Shorthand property: { key } means { key: key }
			keys.push(keyToken.value);
			values.push(createNode(NodeKind.Identifier, { name: keyToken.value }, keyToken));
		}

		if (current(state).kind === TokenKind.Comma) {
			advance(state);
		} else {
			break;
		}
	}

	if (current(state).kind === TokenKind.RBrace) { advance(state); }

	return Result.ok(createNode(NodeKind.ObjectLiteral, {
		properties: values,
		keys,
	}, lbrace));
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
	if (tok.kind === TokenKind.String) {
		advance(state);
		return Result.ok(createNode(NodeKind.StringLiteral, { value: tok.value }, tok));
	}
	return Result.err("mock: unexpected token");
}

function objKeyCount(input: string): number {
	const lr = lex(input);
	if (!lr.ok) return -1;
	const state = createState(lr.value);
	const result = parseObjectLiteral(state, mockExpr);
	if (!result.ok) return -1;
	const data = result.value.data as { properties: Node[], keys: string[] };
	return data.keys.length;
}

function objOk(input: string): boolean {
	const lr = lex(input);
	if (!lr.ok) return false;
	const state = createState(lr.value);
	const result = parseObjectLiteral(state, mockExpr);
	return result.ok;
}

testGroup("Object parseObjectLiteral", () => {
	test("empty object", () => { check(objKeyCount("{}") === 0); });
	test("single property", () => { check(objKeyCount("{ x: 1 }") === 1); });
	test("two properties", () => { check(objKeyCount("{ x: 1, y: 2 }") === 2); });
	test("shorthand property", () => { check(objKeyCount("{ x }") === 1); });
	test("mixed shorthand and full", () => { check(objKeyCount("{ x, y: 2 }") === 2); });
	test("trailing comma", () => { check(objKeyCount("{ x: 1, y: 2, }") === 2); });
	test("string value", () => { check(objOk("{ x: \"hello\" }")); });
	test("non-ident key fails", () => { check(!objOk("{ 42: x }")); });
});

testGroup("Expr Object Literals", () => {
	test("empty object", () => { check(parseOk("f({})")); });
	test("single property", () => { check(parseOk("f({ x: 1 })")); });
	test("two properties", () => { check(parseOk("f({ x: 1, y: 2 })")); });
	test("shorthand property", () => { check(parseOk("f({ x })")); });
	test("mixed shorthand and full", () => { check(parseOk("f({ x, y: 2 })")); });
	test("nested object", () => { check(parseOk("f({ a: { b: 1 } })")); });
	test("expr value", () => { check(parseOk("f({ x: a + b })")); });
	test("call value", () => { check(parseOk("f({ x: g(y) })")); });
	test("trailing comma", () => { check(parseOk("f({ x: 1, y: 2, })")); });
	test("createNode pattern", () => { check(parseOk("f({ kind, value, line: 1 })")); });
	test("array value in object", () => { check(parseOk("f({ items: [1, 2] })")); });
	test("member access value", () => { check(parseOk("f({ x: a.b.c })")); });
	test("non-ident key fails", () => { check(!parseOk("f({ 42: x })")); });
});
