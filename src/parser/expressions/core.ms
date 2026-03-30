// Core Expression Parser - Pratt parsing with operator precedence
// Pattern: ~/projects/metascript/src/parser/parser.zig parseExpression()

import { Token, TokenKind, isIdentOrKeyword } from "../../lexer/token";
import { Node, NodeKind, NodeData, Expression, createNode, QuoteExprData, BlockStmtData } from "../../ast/node";
import { ParserState, createState, current, advance, peek, isAtEnd, isGenericCallAhead, captureGenericTypeArgs, addExplicitTypeArg, collectTokenText, consumePendingTypeArg } from "../context";
import { skipTypeAnnotation, parseTypeExpr } from "../typeAnnotation";
import { parseParamList, extractParamNames, extractParamTypes, captureOptionalType, getLastTypeExpr, getLastParamTypeExprs, skipOptionalType, isIdentLike } from "../util";
import { getPrecedence, isBinaryOperator, isRightAssociative } from "./precedence";
import { parseMatchExpr } from "./match";
import { isArrowFunction, parseArrowFunction } from "./arrow";
import { parseObjectLiteral } from "./object";
import { parseExprList, parseCallExpr } from "./call";
import { parseTemplateLiteral } from "./template";
import { registerParseExpr, parseOk, exprKind, exprNode, exprOp, binLeftKind } from "./util";
import { parseNumberLiteral } from "../../utils/string";


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

		// Explicit generic type args: foo<number>(args) or obj.method<T>(args)
		// Store type args in side-channel keyed by call site location.
		// Callee name stays clean so checker can look it up normally.
		if (token.kind === TokenKind.Lt && (left.kind === NodeKind.Identifier || left.kind === NodeKind.MemberExpr)) {
			if (isGenericCallAhead(state)) {
				const typeArgs = captureGenericTypeArgs(state);
				if (typeArgs !== "") {
					addExplicitTypeArg(token.line, token.column, typeArgs);
					state.pendingTypeArg = typeArgs;
				}
				continue;
			}
		}

		if (token.kind === TokenKind.LParen) {
			left = try parseCallExpr(state, left, parseExprWithPrec);
			continue;
		}

		if (token.kind === TokenKind.Dot) {
			advance(state);
			const prop = current(state);
			let propName = "";
			if (isIdentOrKeyword(prop.kind)) {
				propName = prop.value;
				advance(state);
			}
			const memberData: NodeData = {
				object: left,
				property: propName,
				isOptional: false
			};
			left = createNode(NodeKind.MemberExpr, memberData, token);
			continue;
		}

		// Optional chaining: expr?.prop
		if (token.kind === TokenKind.QuestionDot) {
			advance(state);
			const prop = current(state);
			let optPropName = "";
			if (isIdentOrKeyword(prop.kind)) {
				optPropName = prop.value;
				advance(state);
			}
			left = createNode(NodeKind.MemberExpr, { object: left, property: optPropName, isOptional: true }, token);
			continue;
		}

		if (token.kind === TokenKind.LBracket) {
			advance(state);
			let idx = try parseExprWithPrec(state, 0);
			// Range syntax: arr[start..end] → ArrayAccess(arr, BinaryExpr("..", start, end))
			if (current(state).kind === TokenKind.DotDot || current(state).kind === TokenKind.DotDotDot) {
				const rangeTok = current(state);
				advance(state);
				const endIdx = try parseExprWithPrec(state, 0);
				idx = createNode(NodeKind.BinaryExpr, { operator: rangeTok.value, left: idx, right: endIdx }, rangeTok);
			}
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
			const asStart = state.position;
			skipTypeAnnotation(state);
			const asEnd = state.position;
			const asType = collectTokenText(state, asStart, asEnd);
			// Build positioned TypeExpr by re-parsing the same range
			const asSavedPos = state.position;
			state.position = asStart;
			const asTypeExpr = parseTypeExpr(state);
			state.position = asSavedPos;
			const asNode = createNode(NodeKind.TypeAssertion, { asExpr: left, asType }, token);
			asNode.typeExpr = asTypeExpr;
			left = asNode;
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
			left,
			right
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
	if (!isAtEnd(state) && isIdentLike(current(state))) {
		advance(state);
	}
	// Parse params
	const raw = parseParamList(state, "");
	const feParamTypeExprs = getLastParamTypeExprs();
	const funcExprParams = extractParamNames(raw);
	const funcExprParamTypes = extractParamTypes(raw);
	// Optional return type
	const funcExprReturnType = captureOptionalType(state);
	const funcExprRetTypeExpr = getLastTypeExpr();
	const feBody = try blockParser(state);
	const feNode = createNode(NodeKind.FunctionExpr, { funcExprParams, funcExprParamTypes, funcExprBody: feBody, funcExprFlags: feFlags, funcExprReturnType }, token);
	feNode.typeExpr = funcExprRetTypeExpr;
	feNode.typeExprs = feParamTypeExprs;
	return Result.ok(feNode);
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
		const isFloat = token.value.indexOf(".") >= 0 || token.value.indexOf("e") >= 0 || token.value.indexOf("E") >= 0;
		return Result.ok(createNode(NodeKind.NumberLiteral, { value: parseNumberLiteral(token.value), isFloat }, token));
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
		// Parse full expression (not just primary) so try f(x) → TryExpr(CallExpr(f, [x]))
		const arg = try parseExprWithPrec(state, 0);
		if (!isAtEnd(state) && current(state).kind === TokenKind.Catch) {
			advance(state);
			const catchExpr = try parseExprWithPrec(state, 0);
			return Result.ok(createNode(NodeKind.TryExpr, {
				tryArg: arg, hasCatch: true, catchVal: catchExpr,
			}, token));
		}
		return Result.ok(createNode(NodeKind.TryExpr, {
			tryArg: arg, hasCatch: false, catchVal: null as unknown as Node,
		}, token));
	}

	// Match expression: match (expr) { pattern => body, ... }
	// Only if followed by '(' — otherwise 'match' is used as identifier
	if (token.kind === TokenKind.Match) {
		if (peek(state, 1).kind === TokenKind.LParen) {
			return parseMatchExpr(state, parseExprWithPrec, blockParser);
		}
		advance(state);
		return Result.ok(createNode(NodeKind.Identifier, { name: token.value }, token));
	}

	// typeof / void / delete prefix operators
	if (token.kind === TokenKind.Typeof || token.kind === TokenKind.Void || token.kind === TokenKind.Delete) {
		advance(state);
		const operand = try parsePrimary(state);
		return Result.ok(createNode(NodeKind.UnaryExpr, { unaryOp: token.value, operand }, token));
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
			if (isIdentOrKeyword(prop.kind)) {
				advance(state);
				callee = createNode(NodeKind.MemberExpr, { object: callee, property: prop.value, isOptional: false }, dotToken);
			}
		}
		// Capture generic type args: new Box<number>(42)
		let newTypeArg = "";
		if (!isAtEnd(state) && current(state).kind === TokenKind.Lt) {
			if (isGenericCallAhead(state)) {
				const ltToken = current(state);
				const typeArgs = captureGenericTypeArgs(state);
				if (typeArgs !== "") {
					addExplicitTypeArg(ltToken.line, ltToken.column, typeArgs);
					newTypeArg = typeArgs;
				}
			}
		}
		// Parse arguments if present
		const args: Node[] = [];
		if (!isAtEnd(state) && current(state).kind === TokenKind.LParen) {
			advance(state);
			const argList = try parseExprList(state, TokenKind.RParen, parseExprWithPrec);
			const newNode = createNode(NodeKind.NewExpr, { newCallee: callee, newArguments: argList }, token);
			if (newTypeArg !== "") newNode.typeArg = newTypeArg;
			return Result.ok(newNode);
		}
		const newNode2 = createNode(NodeKind.NewExpr, { newCallee: callee, newArguments: args }, token);
		if (newTypeArg !== "") newNode2.typeArg = newTypeArg;
		return Result.ok(newNode2);
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

	// Move expression: move x, move x.field, move arr[i]
	if (token.kind === TokenKind.Move) {
		advance(state);
		const moveOperand = try parseExprWithPrec(state, 0);
		return Result.ok(createNode(NodeKind.MoveExpr, { moveArg: moveOperand }, token));
	}

	// Sizeof expression: sizeof Type
	if (token.kind === TokenKind.Sizeof) {
		advance(state);
		const sStart = state.position;
		skipTypeAnnotation(state);
		const sEnd = state.position;
		const sizeofType = collectTokenText(state, sStart, sEnd);
		if (sizeofType === "") {
			return Result.err(`Expected type after sizeof at line ${token.line}`);
		}
		return Result.ok(createNode(NodeKind.SizeofExpr, { sizeofType }, token));
	}

	// Out expression: out x — keyword only when followed by an identifier-like token.
	// Otherwise 'out' is treated as a variable name (falls through to identifier handler below).
	if (token.kind === TokenKind.Out && isIdentLike(peek(state, 1))) {
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

	// Comptime expression: @comptime { ... }
	if (token.kind === TokenKind.At) {
		if (state.position + 1 < state.tokens.length &&
			state.tokens[state.position + 1].value === "comptime") {
			advance(state); // consume '@'
			advance(state); // consume 'comptime'
			const comptimeBlock = try blockParser(state);
			return Result.ok(createNode(NodeKind.ComptimeBlock, { comptimeBody: comptimeBlock }, token));
		}
	}

	// Quote expression: quote { ... }
	// Only if followed by '{' — otherwise 'quote' is used as identifier
	if (token.kind === TokenKind.Quote) {
		if (state.position + 1 < state.tokens.length &&
			state.tokens[state.position + 1].kind === TokenKind.LBrace) {
			advance(state);
			const quoteBlock = try blockParser(state);
			return Result.ok(createNode(NodeKind.QuoteExpr, { quoteBody: quoteBlock }, token));
		}
		advance(state);
		return Result.ok(createNode(NodeKind.Identifier, { name: token.value }, token));
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
		// Parse operand with high precedence to capture postfix (., (), []) but not binary ops.
		// This ensures !result.ok → !(result.ok), not (!result).ok
		const operand = try parseExprWithPrec(state, 70);
		return Result.ok(createNode(NodeKind.UnaryExpr, { unaryOp: token.value, operand }, token));
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

	// Contextual keywords as identifiers — MUST be after all keyword-specific handlers
	// so that match/move/quote/sizeof/out/etc. hit their own parsers first
	if (isIdentLike(token)) {
		advance(state);
		return Result.ok(createNode(NodeKind.Identifier, { name: token.value }, token));
	}

	return Result.err(`Unexpected token: ${token.value} at line ${token.line}`);
}

// ===== Core Expression Tests =====

// --- Structural: verify AST node kinds, operators, precedence tree shape ---
// Kind verification
test "number kind" { assert exprKind("42") === NodeKind.NumberLiteral; }

test "string kind" { assert exprKind("\"hi\"") === NodeKind.StringLiteral; }

test "ident kind" { assert exprKind("x") === NodeKind.Identifier; }

test "binary kind" { assert exprKind("a + b") === NodeKind.BinaryExpr; }

test "unary kind" { assert exprKind("-x") === NodeKind.UnaryExpr; }

test "call kind" { assert exprKind("f()") === NodeKind.CallExpr; }

test "member kind" { assert exprKind("a.b") === NodeKind.MemberExpr; }

test "index kind" { assert exprKind("a[0]") === NodeKind.ArrayAccess; }

test "array kind" { assert exprKind("[1]") === NodeKind.ArrayLiteral; }

test "ternary kind" { assert exprKind("a ? b : c") === NodeKind.ConditionalExpr; }

test "new kind" { assert exprKind("new X()") === NodeKind.NewExpr; }

test "spread kind" { assert exprKind("...x") === NodeKind.SpreadExpr; }

test "try kind" { assert exprKind("try x") === NodeKind.TryExpr; }

test "as kind" { assert exprKind("x as number") === NodeKind.TypeAssertion; }

test "true kind" { assert exprKind("true") === NodeKind.BooleanLiteral; }

test "false kind" { assert exprKind("false") === NodeKind.BooleanLiteral; }

test "null kind" { assert exprKind("null") === NodeKind.NullLiteral; }

test "bigint kind" { assert exprKind("123n") === NodeKind.BigIntLiteral; }

test "regex kind" { assert exprKind("/abc/g") === NodeKind.RegexLiteral; }

test "update kind" { assert exprKind("x++") === NodeKind.UpdateExpr; }

test "await kind" { assert exprKind("await p") === NodeKind.AwaitExpr; }

test "move kind" { assert exprKind("move x") === NodeKind.MoveExpr; }

test "yield kind" { assert exprKind("yield x") === NodeKind.YieldExpr; }

test "out kind" { assert exprKind("out x") === NodeKind.OutExpr; }

test "sizeof kind" { assert exprKind("sizeof int32") === NodeKind.SizeofExpr; }

test "quote kind" { assert exprKind("quote { const x = 1; }") === NodeKind.QuoteExpr; }

test "quote body is block" {
	const d = exprNode("quote { const x = 1; }").data as QuoteExprData;
	assert d.quoteBody.kind === NodeKind.BlockStmt;
}

test "quote multi ok" { assert parseOk("quote { const x = 1; const y = 2; }"); }

test "quote multi stmt" {
	const d = exprNode("quote { const x = 1; const y = 2; }").data as QuoteExprData;
	const block = d.quoteBody.data as BlockStmtData;
	assert block.statements.length === 2;
}

test "func expr kind" { assert exprKind("function() {}") === NodeKind.FunctionExpr; }

test "generator func expr" { assert exprKind("function*() {}") === NodeKind.FunctionExpr; }

test "async func expr" { assert exprKind("async function() {}") === NodeKind.FunctionExpr; }

test "async arrow kind" { assert exprKind("async () => 42") === NodeKind.ArrowFunction; }
// Operator extraction
test "+ op" { assert exprOp("a + b") === "+"; }

test "=== op" { assert exprOp("a === b") === "==="; }

test "&& op" { assert exprOp("a && b") === "&&"; }

test "?? op" { assert exprOp("a ?? b") === "??"; }

test "unary - op" { assert exprOp("-x") === "-"; }

test "unary ! op" { assert exprOp("!x") === "!"; }

test "pre++ op" { assert exprOp("++x") === "++"; }

test "typeof op" { assert exprOp("typeof x") === "typeof"; }
// Precedence tree shape
test "* tighter than +" { assert binLeftKind("a + b * c") === NodeKind.Identifier; }

test "+ left-assoc" { assert binLeftKind("a + b + c") === NodeKind.BinaryExpr; }

test "* in + left" { assert binLeftKind("a * b + c") === NodeKind.BinaryExpr; }

test "&& tighter than ||" { assert binLeftKind("a || b && c") === NodeKind.Identifier; }

// --- Smoke: each tests a distinct parser path not covered by structural tests ---
// Postfix combinations
test "member call" { assert parseOk("a.b(c)"); }

test "call member" { assert parseOk("a(b).c"); }

test "optional chain" { assert parseOk("a?.b?.c"); }
// Parenthesized
test "parens" { assert parseOk("(a + b) * c"); }
// Right-associative
test "** right assoc" { assert parseOk("a ** b ** c"); }

test "assign right assoc" { assert parseOk("a = b = c"); }
// Compound expressions
test "complex mixed" { assert parseOk("f(a).b + g(c).d"); }

test "nested arrays" { assert parseOk("[[1], [2]][0]"); }
// Try
test "try catch" { assert parseOk("try f() catch 0"); }

test "nested try" { assert parseOk("try f(try g())"); }
// Type assertions
test "as object type" { assert parseOk("node.data as { name: string }"); }
// Remaining operators
test "in operator" { assert parseOk("\"x\" in obj"); }

test "instanceof" { assert parseOk("a instanceof Foo"); }

test "pipe" { assert parseOk("a |> b"); }
// New with member
test "new member" { assert parseOk("new A.B()"); }
// Delete/void
test "delete" { assert parseOk("delete obj.x"); }

test "void" { assert parseOk("void 0"); }

test "lone operator" { assert !parseOk("+"); }

test "empty string" { assert !parseOk(""); }

