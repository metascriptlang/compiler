// Call Expression + Expression List Parsing
// Extracted from expression.ms with callback injection

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, Expression, createNode, CallExprData } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd } from "../context";
import { lex } from "../../lexer/lexer";
import { parseOk, mockExpr } from "./util";


type ExprResult = Result<Expression, string>;
type ExprParser = (state: ParserState, minPrec: number) => ExprResult;
type NodesResult = Result<Node[], string>;

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
	const callNode = createNode(NodeKind.CallExpr, { callee, arguments: args, isDirectCall: true, resolvedOverloadIdx: -1 }, lparen);
	// Consume pending type arg (set by generic call parsing: foo<T>(...))
	if (state.pendingTypeArg !== "") {
		callNode.typeArg = state.pendingTypeArg;
		state.pendingTypeArg = "";
	}
	return Result.ok(callNode);
}

// ===== Tests =====

function callArgCount(input: string): number {
	const lr = lex(`f${input}`);
	if (!lr.ok) return -1;
	const state = createState(lr.value);
	const calleeToken = current(state);
	const callee = createNode(NodeKind.Identifier, { name: "f" }, calleeToken);
	advance(state);
	const result = parseCallExpr(state, callee, mockExpr);
	if (!result.ok) return -1;
	const data = result.value.data as CallExprData;
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

test "no args" { assert callArgCount("()") === 0; }

test "two args" { assert callArgCount("(a, b)") === 2; }

test "trailing comma" { assert callArgCount("(a, b,)") === 2; }

test "empty list" { assert listCount("") === 0; }

test "three items" { assert listCount("a, b, c") === 3; }

test "nested call" { assert parseOk("f(g(x))"); }

test "expr arg" { assert parseOk("f(1 + 2)"); }
