// Match Expression Parser
// Pattern: ~/projects/metascript/src/parser/parser.zig parseMatchStatement()
// Uses callback injection to avoid circular imports with expression.ms

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, Expression, createNode } from "../../ast/node";
import { ParserState, current, advance, isAtEnd, expect, peek } from "../context";
import { parseOk } from "./util";
import { test, check, testGroup } from "std/testing";

type ExprResult = Result<Expression, string>;
type ExprParser = (state: ParserState, minPrec: number) => ExprResult;
type BlockParser = (state: ParserState) => ExprResult;

// ===== Match Expression =====
// match (discriminant) { pattern => body, pattern1 | pattern2 => body, _ => body }

export function parseMatchExpr(
	state: ParserState,
	exprParser: ExprParser,
	blockParser: BlockParser
): ExprResult {
	const matchToken = current(state);
	advance(state); // consume 'match'

	// Expect ( discriminant )
	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after 'match' at line ${current(state).line.toString()}`);
	}
	advance(state);
	let disc = try exprParser(state, 0);
	if (current(state).kind !== TokenKind.RParen) {
		return Result.err(`Expected ')' after match discriminant at line ${current(state).line.toString()}`);
	}
	advance(state);

	// Expect { cases }
	if (current(state).kind !== TokenKind.LBrace) {
		return Result.err(`Expected '{' to start match body at line ${current(state).line.toString()}`);
	}
	advance(state);

	const cases: Node[] = [];

	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		const caseNode = try parseMatchCase(state, exprParser, blockParser);
		cases.push(caseNode);

		// Optional comma between cases
		if (current(state).kind === TokenKind.Comma) {
			advance(state);
		}
	}

	if (current(state).kind === TokenKind.RBrace) {
		advance(state);
	}

	return Result.ok(createNode(NodeKind.MatchExpr, {
		matchDisc: disc,
		matchCases: cases,
	}, matchToken));
}

// ===== Single Match Case =====
// pattern1 | pattern2 => expr_or_block

function parseMatchCase(
	state: ParserState,
	exprParser: ExprParser,
	blockParser: BlockParser
): ExprResult {
	// Parse patterns: pattern1 | pattern2 | ...
	const patterns = try parseMatchPatterns(state);

	// Expect =>
	if (current(state).kind !== TokenKind.Arrow) {
		return Result.err(`Expected '=>' after match pattern at line ${current(state).line.toString()}`);
	}
	const arrowToken = current(state);
	advance(state);

	// Parse body: block ({ ... }) or expression
	let body = try parseMatchBody(state, exprParser, blockParser);

	return Result.ok(createNode(NodeKind.MatchCase, {
		casePatterns: patterns,
		caseBody: body,
	}, arrowToken));
}

// ===== Match Body =====

function parseMatchBody(
	state: ParserState,
	exprParser: ExprParser,
	blockParser: BlockParser
): ExprResult {
	if (current(state).kind === TokenKind.LBrace) {
		return blockParser(state);
	}
	return exprParser(state, 0);
}

// ===== Match Patterns =====
// Parses: pattern1 | pattern2 | pattern3
// Each pattern: literal, identifier (incl. _ wildcard), or member_expr (Enum.Member)

type PatternsResult = Result<Node[], string>;

function parseMatchPatterns(state: ParserState): PatternsResult {
	const patterns: Node[] = [];

	const first = try parseSinglePattern(state);
	patterns.push(first);

	// Or-patterns: separated by |
	while (!isAtEnd(state) && current(state).kind === TokenKind.Pipe) {
		advance(state); // consume |
		const next = try parseSinglePattern(state);
		patterns.push(next);
	}

	return Result.ok(patterns);
}

// Parse a single match pattern: literal, identifier, or member_expr
function parseSinglePattern(state: ParserState): ExprResult {
	const token = current(state);

	// Number literal
	if (token.kind === TokenKind.Number) {
		advance(state);
		return Result.ok(createNode(NodeKind.NumberLiteral, { value: parseFloat(token.value) }, token));
	}

	// String literal
	if (token.kind === TokenKind.String) {
		advance(state);
		return Result.ok(createNode(NodeKind.StringLiteral, { value: token.value }, token));
	}

	// Boolean/null/identifier (including _ wildcard)
	if (token.kind === TokenKind.Ident ||
		token.kind === TokenKind.True || token.kind === TokenKind.False ||
		token.kind === TokenKind.Null) {
		advance(state);
		let node = createNode(NodeKind.Identifier, { name: token.value }, token);

		// Handle member access: Enum.Member (e.g., TokenKind.Plus)
		while (!isAtEnd(state) && current(state).kind === TokenKind.Dot) {
			advance(state); // consume .
			const prop = current(state);
			if (prop.kind === TokenKind.Ident) {
				advance(state);
				node = createNode(NodeKind.MemberExpr, { object: node, property: prop.value }, token);
			} else {
				break;
			}
		}

		return Result.ok(node);
	}

	// Prefix minus for negative numbers
	if (token.kind === TokenKind.Minus) {
		advance(state);
		const operand = try parseSinglePattern(state);
		return Result.ok(createNode(NodeKind.UnaryExpr, { unaryOp: "-", operand }, token));
	}

	return Result.err(`Unexpected token in match pattern: ${token.value} at line ${token.line.toString()}`);
}

// ===== Tests =====

testGroup("Expr Match", () => {
	test("number patterns", () => { check(parseOk("match (x) { 1 => \"one\", _ => \"other\" }")); });
	test("string patterns", () => { check(parseOk("match (s) { \"a\" => 1, \"b\" => 2, _ => 0 }")); });
	test("bool patterns", () => { check(parseOk("match (b) { true => \"yes\", _ => \"no\" }")); });
	test("member patterns", () => { check(parseOk("match (k) { Kind.A => 1, Kind.B => 2, _ => 0 }")); });
	test("or-patterns", () => { check(parseOk("match (k) { Kind.A | Kind.B => 1, _ => 0 }")); });
	test("numeric or-patterns", () => { check(parseOk("match (x) { 1 | 2 | 3 => \"few\", _ => \"many\" }")); });
	test("single case", () => { check(parseOk("match (x) { _ => 0 }")); });
	test("wildcard only", () => { check(parseOk("match (x) { _ => x }")); });
	test("call in arm", () => { check(parseOk("match (x) { 1 => foo(), _ => bar() }")); });
	test("binary in arm", () => { check(parseOk("match (x) { 1 => a + b, _ => c }")); });
});
