// Core Expression Parser - Pratt parsing with operator precedence
// Pattern: ~/projects/metascript/src/parser/parser.zig parseExpression()

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, Expression, createNode } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd } from "../context";
import { skipTypeAnnotation } from "../typeAnnotation";
import { parseParamList, skipOptionalType } from "../util";
import { getPrecedence, isBinaryOperator, isRightAssociative } from "./precedence";
import { parseMatchExpr } from "./match";
import { isArrowFunction, parseArrowFunction } from "./arrow";
import { parseObjectLiteral } from "./object";
import { parseExprList, parseCallExpr } from "./call";
import { parseTemplateLiteral } from "./template";
import { registerParseExpr, parseOk, exprKind, exprNode, exprOp, binLeftKind } from "./util";
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

// syntax: expr = primary (postfix)* (binop primary (postfix)*)* ('?' expr ':' expr)?
// syntax: postfix = '(' args ')' | '.' ID | '?.' ID | '[' expr ']' | '++' | '--' | 'as' type
function parseExprWithPrec(state: ParserState, minPrec: number): ExprResult {
	let left = try parsePrimary(state);

	// Postfix operators: call, member access, optional chaining, array indexing, update
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

		// Optional chaining: expr?.prop
		if (token.kind === TokenKind.QuestionDot) {
			advance(state);
			const prop = current(state);
			if (prop.kind === TokenKind.Ident) {
				advance(state);
				left = createNode(NodeKind.MemberExpr, { object: left, property: prop.value }, token);
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
			left = createNode(NodeKind.UpdateExpr, { updateOp: token.value, updateArg: left, isPrefix: false }, token);
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
		// Right-associative operators (**, =, +=, etc.) use prec instead of prec+1
		let nextPrec = prec + 1;
		if (isRightAssociative(op.kind)) {
			nextPrec = prec;
		}
		const right = try parseExprWithPrec(state, nextPrec);
		const data: NodeData = {
			operator: op.value,
			left: left,
			right: right
		};
		left = createNode(NodeKind.BinaryExpr, data, op);
	}

	// Ternary conditional: expr ? consequent : alternate
	if (!isAtEnd(state) && current(state).kind === TokenKind.Question) {
		const ternaryPrec = 6;
		if (ternaryPrec >= minPrec) {
			const qToken = current(state);
			advance(state);
			const consequent = try parseExprWithPrec(state, 0);
			if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
				advance(state);
			}
			const alternate = try parseExprWithPrec(state, ternaryPrec);
			left = createNode(NodeKind.ConditionalExpr, {
				ternaryCondition: left,
				ternaryConsequent: consequent,
				ternaryAlternate: alternate,
			}, qToken);
		}
	}

	return Result.ok(left);
}

// ===== Function Expression Helper =====
// syntax: funcExpr = 'function' ID? '(' params ')' (':' type)? block
// Shared by async function expr and regular function expr paths

function parseFuncExprBody(state: ParserState, token: Token, feFlags: string): ExprResult {
	// Optional name
	if (!isAtEnd(state) && current(state).kind === TokenKind.Ident) {
		advance(state);
	}
	// Parse params
	const feParams = parseParamList(state);
	// Skip optional return type
	skipOptionalType(state);
	const feBody = try blockParser(state);
	return Result.ok(createNode(NodeKind.FunctionExpr, { funcExprParams: feParams, funcExprBody: feBody, funcExprFlags: feFlags }, token));
}

// ===== Primary Expressions =====
// syntax: primary = NUMBER | STRING | BOOL | NULL | BIGINT | REGEX | IDENT | 'this' | 'super'
//                 | '(' expr ')' | '[' exprList ']' | '{' objectBody '}'
//                 | 'function' ... | 'try' expr | 'match' (...) | 'new' expr
//                 | 'await' expr | 'yield' expr? | 'move' expr | 'out' expr
//                 | ('typeof' | 'void' | 'delete') expr | ('++' | '--') expr
//                 | ('-' | '!' | '~') expr | 'async' (funcExpr | arrow) | '...' expr

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

	// Boolean literal: true / false
	if (token.kind === TokenKind.True || token.kind === TokenKind.False) {
		advance(state);
		return Result.ok(createNode(NodeKind.BooleanLiteral, { boolValue: token.kind === TokenKind.True }, token));
	}

	// Null literal
	if (token.kind === TokenKind.Null) {
		advance(state);
		return Result.ok(createNode(NodeKind.NullLiteral, { nullPlaceholder: true }, token));
	}

	// BigInt literal: 123n
	if (token.kind === TokenKind.BigInt) {
		advance(state);
		return Result.ok(createNode(NodeKind.BigIntLiteral, { bigintValue: token.value }, token));
	}

	// Regex literal: /pattern/flags
	if (token.kind === TokenKind.Regex) {
		advance(state);
		return Result.ok(createNode(NodeKind.RegexLiteral, { regexPattern: token.value }, token));
	}

	if (token.kind === TokenKind.Ident ||
		token.kind === TokenKind.This ||
		token.kind === TokenKind.Super) {
		advance(state);
		return Result.ok(createNode(NodeKind.Identifier, { name: token.value }, token));
	}

	// Arrow function or parenthesized expression
	if (token.kind === TokenKind.LParen) {
		if (isArrowFunction(state)) {
			return parseArrowFunction(state, parseExprWithPrec, blockParser, "");
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

	// typeof / void / delete prefix operators
	if (token.kind === TokenKind.Typeof || token.kind === TokenKind.Void || token.kind === TokenKind.Delete) {
		advance(state);
		const operand = try parsePrimary(state);
		return Result.ok(createNode(NodeKind.UnaryExpr, { unaryOp: token.value, operand: operand }, token));
	}

	// new expression: new Callee(args)
	if (token.kind === TokenKind.New) {
		advance(state);
		let callee = try parsePrimary(state);
		// Handle member access: new A.B(args)
		while (!isAtEnd(state) && current(state).kind === TokenKind.Dot) {
			const dotToken = current(state);
			advance(state);
			const prop = current(state);
			if (prop.kind === TokenKind.Ident) {
				advance(state);
				callee = createNode(NodeKind.MemberExpr, { object: callee, property: prop.value }, dotToken);
			}
		}
		// Parse arguments if present
		const args: Node[] = [];
		if (!isAtEnd(state) && current(state).kind === TokenKind.LParen) {
			advance(state);
			const argList = try parseExprList(state, TokenKind.RParen, parseExprWithPrec);
			return Result.ok(createNode(NodeKind.NewExpr, { newCallee: callee, newArguments: argList }, token));
		}
		return Result.ok(createNode(NodeKind.NewExpr, { newCallee: callee, newArguments: args }, token));
	}

	// Await expression: await expr
	if (token.kind === TokenKind.Await) {
		advance(state);
		const awaitOperand = try parseExprWithPrec(state, 0);
		return Result.ok(createNode(NodeKind.AwaitExpr, { awaitArg: awaitOperand }, token));
	}

	// Yield expression: yield expr, yield* expr
	if (token.kind === TokenKind.Yield) {
		advance(state);
		let delegate = false;
		if (!isAtEnd(state) && current(state).kind === TokenKind.Star) {
			delegate = true;
			advance(state);
		}
		const yieldOperand = try parseExprWithPrec(state, 0);
		return Result.ok(createNode(NodeKind.YieldExpr, { yieldArg: yieldOperand, isDelegate: delegate }, token));
	}

	// Move expression: move x
	if (token.kind === TokenKind.Move) {
		advance(state);
		const moveOperand = try parsePrimary(state);
		return Result.ok(createNode(NodeKind.MoveExpr, { moveArg: moveOperand }, token));
	}

	// Out expression: out x
	if (token.kind === TokenKind.Out) {
		advance(state);
		const outOperand = try parsePrimary(state);
		return Result.ok(createNode(NodeKind.OutExpr, { outArg: outOperand }, token));
	}

	// Prefix increment/decrement: ++x, --x
	if (token.kind === TokenKind.PlusPlus || token.kind === TokenKind.MinusMinus) {
		advance(state);
		const updateTarget = try parsePrimary(state);
		return Result.ok(createNode(NodeKind.UpdateExpr, { updateOp: token.value, updateArg: updateTarget, isPrefix: true }, token));
	}

	// Async: async function expr or async arrow
	if (token.kind === TokenKind.Async) {
		// async function expression: async function() {} or async function*() {}
		if (state.position + 1 < state.tokens.length &&
			state.tokens[state.position + 1].kind === TokenKind.Function) {
			advance(state); // consume 'async'
			advance(state); // consume 'function'
			let feFlags = "async";
			if (!isAtEnd(state) && current(state).kind === TokenKind.Star) {
				feFlags = "async_generator";
				advance(state);
			}
			return parseFuncExprBody(state, token, feFlags);
		}
		// async arrow: async () => ... or async (x) => ...
		if (state.position + 1 < state.tokens.length &&
			state.tokens[state.position + 1].kind === TokenKind.LParen) {
			advance(state); // consume 'async'
			return parseArrowFunction(state, parseExprWithPrec, blockParser, "async");
		}
		// Otherwise treat 'async' as identifier
		advance(state);
		return Result.ok(createNode(NodeKind.Identifier, { name: token.value }, token));
	}

	// Function expression: function() {} or function name() {} or function*() {}
	if (token.kind === TokenKind.Function) {
		advance(state);
		let feFlags = "";
		if (!isAtEnd(state) && current(state).kind === TokenKind.Star) {
			feFlags = "generator";
			advance(state);
		}
		return parseFuncExprBody(state, token, feFlags);
	}

	// Quote expression: quote { ... }
	if (token.kind === TokenKind.Quote) {
		advance(state);
		const quoteBlock = try blockParser(state);
		return Result.ok(createNode(NodeKind.QuoteExpr, { quoteBody: quoteBlock }, token));
	}

	// Spread: ...expr
	if (token.kind === TokenKind.DotDotDot) {
		advance(state);
		const spreadOperand = try parsePrimary(state);
		return Result.ok(createNode(NodeKind.SpreadExpr, { spreadArg: spreadOperand }, token));
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

// --- Structural: verify AST node kinds, operators, precedence tree shape ---

testGroup("Expr Structure", () => {
	// Kind verification
	test("number kind", () => { check(exprKind("42") === NodeKind.NumberLiteral); });
	test("string kind", () => { check(exprKind("\"hi\"") === NodeKind.StringLiteral); });
	test("ident kind", () => { check(exprKind("x") === NodeKind.Identifier); });
	test("binary kind", () => { check(exprKind("a + b") === NodeKind.BinaryExpr); });
	test("unary kind", () => { check(exprKind("-x") === NodeKind.UnaryExpr); });
	test("call kind", () => { check(exprKind("f()") === NodeKind.CallExpr); });
	test("member kind", () => { check(exprKind("a.b") === NodeKind.MemberExpr); });
	test("index kind", () => { check(exprKind("a[0]") === NodeKind.ArrayAccess); });
	test("array kind", () => { check(exprKind("[1]") === NodeKind.ArrayLiteral); });
	test("ternary kind", () => { check(exprKind("a ? b : c") === NodeKind.ConditionalExpr); });
	test("new kind", () => { check(exprKind("new X()") === NodeKind.NewExpr); });
	test("spread kind", () => { check(exprKind("...x") === NodeKind.SpreadExpr); });
	test("try kind", () => { check(exprKind("try x") === NodeKind.TryExpr); });
	test("as kind", () => { check(exprKind("x as number") === NodeKind.TypeAssertion); });
	test("true kind", () => { check(exprKind("true") === NodeKind.BooleanLiteral); });
	test("false kind", () => { check(exprKind("false") === NodeKind.BooleanLiteral); });
	test("null kind", () => { check(exprKind("null") === NodeKind.NullLiteral); });
	test("bigint kind", () => { check(exprKind("123n") === NodeKind.BigIntLiteral); });
	test("regex kind", () => { check(exprKind("/abc/g") === NodeKind.RegexLiteral); });
	test("update kind", () => { check(exprKind("x++") === NodeKind.UpdateExpr); });
	test("await kind", () => { check(exprKind("await p") === NodeKind.AwaitExpr); });
	test("move kind", () => { check(exprKind("move x") === NodeKind.MoveExpr); });
	test("yield kind", () => { check(exprKind("yield x") === NodeKind.YieldExpr); });
	test("out kind", () => { check(exprKind("out x") === NodeKind.OutExpr); });
	test("quote kind", () => { check(exprKind("quote { const x = 1; }") === NodeKind.QuoteExpr); });
	test("quote body is block", () => {
		const d = exprNode("quote { const x = 1; }").data as { quoteBody: Node };
		check(d.quoteBody.kind === NodeKind.BlockStmt);
	});
	test("quote multi ok", () => { check(parseOk("quote { const x = 1; const y = 2; }")); });
	test("quote multi stmt", () => {
		const d = exprNode("quote { const x = 1; const y = 2; }").data as { quoteBody: Node };
		const block = d.quoteBody.data as { statements: Node[] };
		check(block.statements.length === 2);
	});
	test("func expr kind", () => { check(exprKind("function() {}") === NodeKind.FunctionExpr); });
	test("generator func expr", () => { check(exprKind("function*() {}") === NodeKind.FunctionExpr); });
	test("async func expr", () => { check(exprKind("async function() {}") === NodeKind.FunctionExpr); });
	test("async arrow kind", () => { check(exprKind("async () => 42") === NodeKind.ArrowFunction); });
	// Operator extraction
	test("+ op", () => { check(exprOp("a + b") === "+"); });
	test("=== op", () => { check(exprOp("a === b") === "==="); });
	test("&& op", () => { check(exprOp("a && b") === "&&"); });
	test("?? op", () => { check(exprOp("a ?? b") === "??"); });
	test("unary - op", () => { check(exprOp("-x") === "-"); });
	test("unary ! op", () => { check(exprOp("!x") === "!"); });
	test("pre++ op", () => { check(exprOp("++x") === "++"); });
	test("typeof op", () => { check(exprOp("typeof x") === "typeof"); });
	// Precedence tree shape
	test("* tighter than +", () => { check(binLeftKind("a + b * c") === NodeKind.Identifier); });
	test("+ left-assoc", () => { check(binLeftKind("a + b + c") === NodeKind.BinaryExpr); });
	test("* in + left", () => { check(binLeftKind("a * b + c") === NodeKind.BinaryExpr); });
	test("&& tighter than ||", () => { check(binLeftKind("a || b && c") === NodeKind.Identifier); });
});

// --- Smoke: each tests a distinct parser path not covered by structural tests ---

testGroup("Expr Smoke", () => {
	// Postfix combinations
	test("member call", () => { check(parseOk("a.b(c)")); });
	test("call member", () => { check(parseOk("a(b).c")); });
	test("optional chain", () => { check(parseOk("a?.b?.c")); });
	test("postfix ++", () => { check(parseOk("x++")); });
	// Parenthesized
	test("parens", () => { check(parseOk("(a + b) * c")); });
	// Right-associative
	test("** right assoc", () => { check(parseOk("a ** b ** c")); });
	test("assign right assoc", () => { check(parseOk("a = b = c")); });
	// Compound expressions
	test("complex mixed", () => { check(parseOk("f(a).b + g(c).d")); });
	test("nested arrays", () => { check(parseOk("[[1], [2]][0]")); });
	// Try
	test("try catch", () => { check(parseOk("try f() catch 0")); });
	test("nested try", () => { check(parseOk("try f(try g())")); });
	// Type assertions
	test("as object type", () => { check(parseOk("node.data as { name: string }")); });
	// Remaining operators
	test("in operator", () => { check(parseOk("\"x\" in obj")); });
	test("instanceof", () => { check(parseOk("a instanceof Foo")); });
	test("pipe", () => { check(parseOk("a |> b")); });
	// Await
	test("await call", () => { check(parseOk("await fetch(url)")); });
	// New with member
	test("new member", () => { check(parseOk("new A.B()")); });
	// Delete/void
	test("delete", () => { check(parseOk("delete obj.x")); });
	test("void", () => { check(parseOk("void 0")); });
	// Move/out/yield
	test("move ident", () => { check(parseOk("move data")); });
	test("out ident", () => { check(parseOk("out result")); });
	test("yield value", () => { check(parseOk("yield 42")); });
	test("yield star", () => { check(parseOk("yield* gen()")); });
	// Function expressions
	test("named func expr", () => { check(parseOk("function foo(x) { return x; }")); });
	test("func expr params", () => { check(parseOk("function(a, b) { return a + b; }")); });
});

testGroup("Expr Rejects", () => {
	test("lone operator", () => { check(!parseOk("+")); });
	test("empty string", () => { check(!parseOk("")); });
});

