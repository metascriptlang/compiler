// Expression Parser - Pratt parsing with operator precedence
// Pattern: ~/projects/metascript/src/parser/parser.zig parseExpression()

import { Token, TokenKind } from "../lexer/token";
import { Node, NodeKind, NodeData, Expression, createNode } from "../ast/node";
import { ParserState, createState, current, advance, isAtEnd, peek } from "./context";
import { lex } from "../lexer/lexer";
import { test, check, testGroup } from "std/testing";

type ExprResult = Result<Expression, string>;
type Nodes = Node[];
type NodesResult = Result<Nodes, string>;

// ===== Operator Precedence (match expression -> C switch) =====

function getPrecedence(kind: TokenKind): number {
	return match (kind) {
		TokenKind.Star | TokenKind.Slash | TokenKind.Percent => 60,
		TokenKind.Plus | TokenKind.Minus => 50,
		TokenKind.LtLt | TokenKind.GtGt | TokenKind.GtGtGt => 45,
		TokenKind.Lt | TokenKind.Gt | TokenKind.LtEq | TokenKind.GtEq => 40,
		TokenKind.EqEq | TokenKind.BangEq | TokenKind.EqEqEq | TokenKind.BangEqEq => 30,
		TokenKind.AmpAmp => 20,
		TokenKind.PipePipe => 10,
		TokenKind.Assign | TokenKind.PlusEq | TokenKind.MinusEq |
		TokenKind.StarEq | TokenKind.SlashEq | TokenKind.PercentEq => 5,
		_ => 0,
	};
}

function isBinaryOperator(token: Token): boolean {
	return match (token.kind) {
		TokenKind.Plus | TokenKind.Minus | TokenKind.Star |
		TokenKind.Slash | TokenKind.Percent |
		TokenKind.Lt | TokenKind.Gt | TokenKind.LtEq | TokenKind.GtEq |
		TokenKind.EqEq | TokenKind.BangEq | TokenKind.EqEqEq | TokenKind.BangEqEq |
		TokenKind.LtLt | TokenKind.GtGt | TokenKind.GtGtGt |
		TokenKind.AmpAmp | TokenKind.PipePipe |
		TokenKind.Assign | TokenKind.PlusEq | TokenKind.MinusEq |
		TokenKind.StarEq | TokenKind.SlashEq | TokenKind.PercentEq => true,
		_ => false,
	};
}

// ===== Main Parse Functions =====

export function parseExpression(tokens: Token[]): ExprResult {
	const state = createState(tokens);
	return parseExprWithPrec(state, 0);
}

export function parseExpressionFromState(state: ParserState): ExprResult {
	return parseExprWithPrec(state, 0);
}

function parseExprWithPrec(state: ParserState, minPrec: number): ExprResult {
	let left = try parsePrimary(state);

	// Postfix operators: call, member access, array indexing, update
	while (!isAtEnd(state)) {
		const token = current(state);

		if (token.kind === TokenKind.LParen) {
			left = try parseCallExpr(state, left);
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

	if (token.kind === TokenKind.Ident ||
		token.kind === TokenKind.True || token.kind === TokenKind.False ||
		token.kind === TokenKind.Null || token.kind === TokenKind.This ||
		token.kind === TokenKind.Super) {
		advance(state);
		return Result.ok(createNode(NodeKind.Identifier, { name: token.value }, token));
	}

	// Parenthesized expression
	if (token.kind === TokenKind.LParen) {
		advance(state);
		const expr = try parseExprWithPrec(state, 0);
		if (current(state).kind === TokenKind.RParen) { advance(state); }
		return Result.ok(expr);
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
		const elems = try parseExprList(state, TokenKind.RBracket);
		return Result.ok(createNode(NodeKind.ArrayLiteral, { elements: elems }, token));
	}

	// Object literal: { key: value, ... } or { key, ... } (shorthand)
	if (token.kind === TokenKind.LBrace) {
		return parseObjectLiteral(state);
	}

	return Result.err(`Unexpected token: ${token.value} at line ${token.line.toString()}`);
}

// ===== Object Literal =====

function parseObjectLiteral(state: ParserState): ExprResult {
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
			const val = try parseExprWithPrec(state, 0);
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

// ===== Comma-Separated Expression List =====
// Shared by call args and array literals

function parseExprList(state: ParserState, endKind: TokenKind): NodesResult {
	const items: Node[] = [];
	while (!isAtEnd(state) && current(state).kind !== endKind) {
		const item = try parseExprWithPrec(state, 0);
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

function parseCallExpr(state: ParserState, callee: Expression): ExprResult {
	const lparen = current(state);
	advance(state);
	const args = try parseExprList(state, TokenKind.RParen);
	return Result.ok(createNode(NodeKind.CallExpr, { callee, arguments: args }, lparen));
}

// ===== Test Helpers =====

function parseOk(input: string): boolean {
	const lr = lex(input);
	if (!lr.ok) return false;
	const pr = parseExpression(lr.value);
	return pr.ok;
}

// ===== Expression Parser Tests =====

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

testGroup("Expr Call", () => {
	test("empty call", () => { check(parseOk("f()")); });
	test("single arg call", () => { check(parseOk("f(a)")); });
	test("multi arg call", () => { check(parseOk("f(a, b)")); });
	test("three arg call", () => { check(parseOk("f(a, b, c)")); });
	test("expression arg", () => { check(parseOk("f(1 + 2)")); });
	test("nested call", () => { check(parseOk("f(g(x))")); });
	test("mixed args with nested call", () => { check(parseOk("f(a, g(b), c)")); });
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
