// Call Expression + Expression List Parsing
// Extracted from expression.ms with callback injection

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, Expression, createNode } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd } from "../context";
import { lex } from "../../lexer/lexer";
import { parseOk } from "./util";
import { test, check, testGroup } from "std/testing";

type ExprResult = Result<Expression, string>;
type ExprParser = (state: ParserState, minPrec: number) => ExprResult;
type Nodes = Node[];
type NodesResult = Result<Nodes, string>;

// ===== Comma-Separated Expression List =====
// Shared by call args and array literals

export function parseExprList(state: ParserState, endKind: TokenKind, exprParser: ExprParser): NodesResult {
	const items: Node[] = [];
	while (!isAtEnd(state) && current(state).kind !== endKind) {
		const item = try exprParser(state, 0);
		items.push(item);
		if (current(state).kind === TokenKind.Comma) {
			advance(state);
		} else {
			break;
		}
	}
	if (current(state).kind === endKind) { advance(state); }
	return Result.ok(items);
}

// ===== Call Expression =====

export function parseCallExpr(state: ParserState, callee: Expression, exprParser: ExprParser): ExprResult {
	const lparen = current(state);
	advance(state);
	const args = try parseExprList(state, TokenKind.RParen, exprParser);
	return Result.ok(createNode(NodeKind.CallExpr, { callee, arguments: args }, lparen));
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

function callArgCount(input: string): number {
	const lr = lex(`f${input}`);
	if (!lr.ok) return -1;
	const state = createState(lr.value);
	const calleeToken = current(state);
	const callee = createNode(NodeKind.Identifier, { name: "f" }, calleeToken);
	advance(state);
	const result = parseCallExpr(state, callee, mockExpr);
	if (!result.ok) return -1;
	const data = result.value.data as { callee: Node, arguments: Node[] };
	return data.arguments.length;
}

function listCount(input: string): number {
	const lr = lex(`[${input}]`);
	if (!lr.ok) return -1;
	const state = createState(lr.value);
	advance(state); // skip [
	const result = parseExprList(state, TokenKind.RBracket, mockExpr);
	if (!result.ok) return -1;
	return result.value.length;
}

testGroup("Call parseCallExpr", () => {
	test("no args", () => { check(callArgCount("()") === 0); });
	test("single arg", () => { check(callArgCount("(a)") === 1); });
	test("two args", () => { check(callArgCount("(a, b)") === 2); });
	test("three args", () => { check(callArgCount("(1, 2, 3)") === 3); });
	test("string arg", () => { check(callArgCount("(\"hello\")") === 1); });
	test("trailing comma", () => { check(callArgCount("(a, b,)") === 2); });
});

testGroup("Call parseExprList", () => {
	test("empty list", () => { check(listCount("") === 0); });
	test("single item", () => { check(listCount("1") === 1); });
	test("two items", () => { check(listCount("1, 2") === 2); });
	test("three items", () => { check(listCount("a, b, c") === 3); });
	test("mixed types", () => { check(listCount("1, \"two\", x") === 3); });
});

testGroup("Expr Call", () => {
	test("empty call", () => { check(parseOk("f()")); });
	test("single arg call", () => { check(parseOk("f(a)")); });
	test("multi arg call", () => { check(parseOk("f(a, b)")); });
	test("three arg call", () => { check(parseOk("f(a, b, c)")); });
	test("expression arg", () => { check(parseOk("f(1 + 2)")); });
	test("nested call", () => { check(parseOk("f(g(x))")); });
	test("mixed args with nested call", () => { check(parseOk("f(a, g(b), c)")); });
});
