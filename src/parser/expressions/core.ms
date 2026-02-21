// Core Expression Parser - Pratt parsing with operator precedence
// Pattern: ~/projects/metascript/src/parser/parser.zig parseExpression()

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, Expression, createNode } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd } from "../context";
import { skipTypeAnnotation } from "../typeAnnotation";
import { getPrecedence, isBinaryOperator } from "./precedence";
import { parseMatchExpr } from "./match";
import { isArrowFunction, parseArrowFunction } from "./arrow";
import { parseObjectLiteral } from "./object";
import { parseExprList, parseCallExpr } from "./call";
import { parseTemplateLiteral } from "./template";
import { registerParseExpr, parseOk } from "./util";
import { test, check, testGroup } from "std/testing";

type ExprResult = Result<Expression, string>;

// ===== Block Parser Callback =====
// Arrow functions with block bodies need parseBlockStmt from statement.ms,
// but importing from statement.ms would create a circular dependency.
// statement.ms registers its block parser at module load time.

type BlockParserFn = (state: ParserState) => ExprResult;

let blockParser: BlockParserFn = (state: ParserState): ExprResult => {
	return Result.err("Block parser not registered");
};

export function registerBlockParser(parser: BlockParserFn): void {
	blockParser = parser;
}

// ===== Main Parse Functions =====

export function parseExpression(tokens: Token[]): ExprResult {
	const state = createState(tokens);
	return parseExprWithPrec(state, 0);
}

export function parseExpressionFromState(state: ParserState): ExprResult {
	return parseExprWithPrec(state, 0);
}

// Register parseExpression into util.ms for sub-module integration tests.
// Wrap in lambda to ensure proper closure calling convention.
registerParseExpr((tokens: Token[]): ExprResult => { return parseExpression(tokens); });

function parseExprWithPrec(state: ParserState, minPrec: number): ExprResult {
	let left = try parsePrimary(state);

	// Postfix operators: call, member access, array indexing, update
	while (!isAtEnd(state)) {
		const token = current(state);
		if (token.kind === TokenKind.LParen) {
			left = try parseCallExpr(state, left, parseExprWithPrec);
			continue;
		}

		if (token.kind === TokenKind.Dot) {
			advance(state);
			const prop = current(state);
			if (prop.kind === TokenKind.Ident) {
				advance(state);
				const memberData: NodeData = {
					object: left,
					property: prop.value
				};
				left = createNode(NodeKind.MemberExpr, memberData, token);
			}
			continue;
		}

		if (token.kind === TokenKind.LBracket) {
			advance(state);
			const idx = try parseExprWithPrec(state, 0);
			if (current(state).kind === TokenKind.RBracket) {
				advance(state);
			}
			const accessData: NodeData = {
				array: left,
				index: idx
			};
			left = createNode(NodeKind.ArrayAccess, accessData, token);
			continue;
		}

		// Postfix increment/decrement
		if (token.kind === TokenKind.PlusPlus || token.kind === TokenKind.MinusMinus) {
			advance(state);
			left = createNode(NodeKind.UnaryExpr, { unaryOp: token.value, operand: left }, token);
			continue;
		}

		// Type assertion: expr as Type
		if (token.kind === TokenKind.As) {
			advance(state);
			skipTypeAnnotation(state);
			left = createNode(NodeKind.TypeAssertion, { asExpr: left }, token);
			continue;
		}

		break;
	}

	// Binary operators with Pratt precedence climbing
	while (!isAtEnd(state) && isBinaryOperator(current(state))) {
		const op = current(state);
		const prec = getPrecedence(op.kind);
		if (prec < minPrec) {
			break;
		}

		advance(state);
		const right = try parseExprWithPrec(state, prec + 1);
		const data: NodeData = {
			operator: op.value,
			left: left,
			right: right
		};
		left = createNode(NodeKind.BinaryExpr, data, op);
	}

	return Result.ok(left);
}

// ===== Primary Expressions =====

function parsePrimary(state: ParserState): ExprResult {
	const token = current(state);

	if (token.kind === TokenKind.Number) {
		advance(state);
		return Result.ok(createNode(NodeKind.NumberLiteral, { value: parseFloat(token.value) }, token));
	}

	if (token.kind === TokenKind.String) {
		advance(state);
		return Result.ok(createNode(NodeKind.StringLiteral, { value: token.value }, token));
	}

	// Template literal (no substitutions) - desugar to string literal
	if (token.kind === TokenKind.TemplateNoSub) {
		advance(state);
		return Result.ok(createNode(NodeKind.StringLiteral, { value: token.value }, token));
	}

	// Template literal (with substitutions) - desugar to string concatenation
	if (token.kind === TokenKind.TemplateHead) {
		return parseTemplateLiteral(state, parseExprWithPrec);
	}

	if (token.kind === TokenKind.Ident ||
		token.kind === TokenKind.True || token.kind === TokenKind.False ||
		token.kind === TokenKind.Null || token.kind === TokenKind.This ||
		token.kind === TokenKind.Super) {
		advance(state);
		return Result.ok(createNode(NodeKind.Identifier, { name: token.value }, token));
	}

	// Arrow function or parenthesized expression
	if (token.kind === TokenKind.LParen) {
		if (isArrowFunction(state)) {
			return parseArrowFunction(state, parseExprWithPrec, blockParser);
		}
		advance(state);
		const expr = try parseExprWithPrec(state, 0);
		if (current(state).kind === TokenKind.RParen) { advance(state); }
		return Result.ok(expr);
	}

	// Try expression: try expr [catch defaultValue]
	if (token.kind === TokenKind.Try) {
		advance(state);
		const arg = try parsePrimary(state);
		if (!isAtEnd(state) && current(state).kind === TokenKind.Catch) {
			advance(state);
			const catchExpr = try parseExprWithPrec(state, 0);
			return Result.ok(createNode(NodeKind.TryExpr, {
				tryArg: arg, hasCatch: true, catchVal: catchExpr,
			}, token));
		}
		const dummy = createNode(NodeKind.Identifier, { name: "" }, token);
		return Result.ok(createNode(NodeKind.TryExpr, {
			tryArg: arg, hasCatch: false, catchVal: dummy,
		}, token));
	}

	// Match expression: match (expr) { pattern => body, ... }
	if (token.kind === TokenKind.Match) {
		return parseMatchExpr(state, parseExprWithPrec, blockParser);
	}

	// Unary prefix operators
	if (token.kind === TokenKind.Minus || token.kind === TokenKind.Bang || token.kind === TokenKind.Tilde) {
		advance(state);
		const operand = try parsePrimary(state);
		return Result.ok(createNode(NodeKind.UnaryExpr, { unaryOp: token.value, operand: operand }, token));
	}

	// Array literal: [expr, expr, ...]
	if (token.kind === TokenKind.LBracket) {
		advance(state);
		const elems = try parseExprList(state, TokenKind.RBracket, parseExprWithPrec);
		return Result.ok(createNode(NodeKind.ArrayLiteral, { elements: elems }, token));
	}

	// Object literal: { key: value, ... } or { key, ... } (shorthand)
	if (token.kind === TokenKind.LBrace) {
		return parseObjectLiteral(state, parseExprWithPrec);
	}

	return Result.err(`Unexpected token: ${token.value} at line ${token.line.toString()}`);
}

// ===== Core Expression Tests =====
// Tests for logic that lives in core.ms: literals, binary ops, precedence,
// associativity, parentheses, unary, member access, array access, postfix,
// type assertions, try, array literals.
// Call/Object/Arrow/Match integration tests live in their respective sub-modules.

testGroup("Expr Literals", () => {
	test("number literal", () => { check(parseOk("42")); });
	test("float literal", () => { check(parseOk("3.14")); });
	test("string literal", () => { check(parseOk("\"hello\"")); });
	test("identifier", () => { check(parseOk("myVar")); });
	test("true literal", () => { check(parseOk("true")); });
	test("false literal", () => { check(parseOk("false")); });
	test("null literal", () => { check(parseOk("null")); });
	test("this literal", () => { check(parseOk("this")); });
});

testGroup("Expr Binary Operators", () => {
	test("addition", () => { check(parseOk("1 + 2")); });
	test("subtraction", () => { check(parseOk("a - b")); });
	test("multiplication", () => { check(parseOk("x * y")); });
	test("division", () => { check(parseOk("a / b")); });
	test("modulo", () => { check(parseOk("a % b")); });
	test("strict equality", () => { check(parseOk("a === b")); });
	test("strict inequality", () => { check(parseOk("a !== b")); });
	test("less than", () => { check(parseOk("a < b")); });
	test("greater than", () => { check(parseOk("a > b")); });
	test("less or equal", () => { check(parseOk("a <= b")); });
	test("greater or equal", () => { check(parseOk("a >= b")); });
	test("logical and", () => { check(parseOk("a && b")); });
	test("logical or", () => { check(parseOk("a || b")); });
	test("left shift", () => { check(parseOk("a << b")); });
	test("right shift", () => { check(parseOk("a >> b")); });
	test("unsigned right shift", () => { check(parseOk("a >>> b")); });
});

testGroup("Expr Precedence", () => {
	test("mul before add", () => { check(parseOk("1 + 2 * 3")); });
	test("two muls with add", () => { check(parseOk("a * b + c * d")); });
	test("and before or", () => { check(parseOk("a || b && c")); });
	test("comparison before and", () => { check(parseOk("a < b && c > d")); });
});

testGroup("Expr Associativity", () => {
	test("left assoc subtraction", () => { check(parseOk("a - b - c")); });
	test("left assoc addition", () => { check(parseOk("a + b + c")); });
	test("left assoc multiplication", () => { check(parseOk("a * b * c")); });
});

testGroup("Expr Parenthesized", () => {
	test("parenthesized number", () => { check(parseOk("(42)")); });
	test("parenthesized binary", () => { check(parseOk("(a + b)")); });
	test("paren changes precedence", () => { check(parseOk("(a + b) * c")); });
	test("double parens", () => { check(parseOk("((a))")); });
	test("nested parens", () => { check(parseOk("(a + (b * c))")); });
});

testGroup("Expr Unary Operators", () => {
	test("logical not", () => { check(parseOk("!x")); });
	test("negation", () => { check(parseOk("-42")); });
	test("bitwise not", () => { check(parseOk("~bits")); });
	test("double negation", () => { check(parseOk("!!x")); });
	test("double negate with parens", () => { check(parseOk("-(-x)")); });
});

testGroup("Expr Member Access", () => {
	test("simple member", () => { check(parseOk("a.b")); });
	test("chained member", () => { check(parseOk("a.b.c")); });
	test("triple chain", () => { check(parseOk("a.b.c.d")); });
});

testGroup("Expr Array Access", () => {
	test("simple index", () => { check(parseOk("a[0]")); });
	test("variable index", () => { check(parseOk("a[i]")); });
	test("expression index", () => { check(parseOk("a[i + 1]")); });
});

testGroup("Expr Mixed Postfix", () => {
	test("member then call", () => { check(parseOk("a.b(c)")); });
	test("call then member", () => { check(parseOk("a(b).c")); });
	test("index then member", () => { check(parseOk("a[0].b")); });
	test("member then index", () => { check(parseOk("a.b[0]")); });
	test("member-call-member chain", () => { check(parseOk("a.b(c).d")); });
	test("chained member then call", () => { check(parseOk("a.b.c(d, e)")); });
	test("chained calls (curried)", () => { check(parseOk("f(a)(b)")); });
});

testGroup("Expr Complex", () => {
	test("multi-op expression", () => { check(parseOk("a + b * c - d")); });
	test("ops in call args", () => { check(parseOk("f(a + b, c * d)")); });
	test("member access in binary", () => { check(parseOk("a.b + c.d")); });
	test("not of call", () => { check(parseOk("!f(x)")); });
	test("complex mixed", () => { check(parseOk("f(a).b + g(c).d")); });
});

testGroup("Expr Array Literals", () => {
	test("empty array", () => { check(parseOk("f([])")); });
	test("single element", () => { check(parseOk("f([1])")); });
	test("two elements", () => { check(parseOk("f([1, 2])")); });
	test("three elements", () => { check(parseOk("f([1, 2, 3])")); });
	test("string elements", () => { check(parseOk("f([\"a\", \"b\"])")); });
	test("expression elements", () => { check(parseOk("f([a + b, c * d])")); });
	test("nested arrays", () => { check(parseOk("f([[1], [2]])")); });
	test("mixed types", () => { check(parseOk("f([1, \"two\", x])")); });
	test("trailing comma", () => { check(parseOk("f([1, 2, ])")); });
	test("array then index", () => { check(parseOk("[1, 2][0]")); });
	test("object in array", () => { check(parseOk("f([{ x: 1 }, { x: 2 }])")); });
});

testGroup("Expr Type Assertions", () => {
	test("as simple type", () => { check(parseOk("x as number")); });
	test("as object type", () => { check(parseOk("x as { value: number }")); });
	test("member then as", () => { check(parseOk("node.data as { name: string }")); });
	test("call then as", () => { check(parseOk("f(x) as { result: boolean }")); });
	test("as in call arg", () => { check(parseOk("f(x as { v: number })")); });
});

testGroup("Expr Try", () => {
	test("basic try", () => { check(parseOk("try foo()")); });
	test("try with catch", () => { check(parseOk("try foo() catch 0")); });
	test("try catch string", () => { check(parseOk("try f() catch \"default\"")); });
	test("try call with args", () => { check(parseOk("try bar(a, b)")); });
	test("try member call", () => { check(parseOk("try x.method()")); });
	test("nested try", () => { check(parseOk("try f(try g())")); });
	test("try identifier", () => { check(parseOk("try x")); });
});

