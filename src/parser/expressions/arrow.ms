// Arrow Function Parser
// Extracted from expression.ms with callback injection

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, Expression, createNode, ArrowFunctionData } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd, peek } from "../context";
import { parseParamList, extractParamNames, extractParamTypes, captureOptionalType, skipOptionalType, isIdentLike } from "../util";
import { lex } from "../../lexer/lexer";
import { parseOk, mockExpr } from "./util";


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
	if (!isIdentLike(p1)) { return false; }

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
	const raw = parseParamList(state, "");
	const arrowParams = extractParamNames(raw);
	const arrowParamTypes = extractParamTypes(raw);

	// Optional return type annotation: (): string => ...
	const arrowReturnType = captureOptionalType(state);

	if (isAtEnd(state) || current(state).kind !== TokenKind.Arrow) {
		return Result.err(`Expected '=>' in arrow function at line ${current(state).line}`);
	}

	advance(state); // consume =>
	// Body: block { ... } or expression
	if (!isAtEnd(state) && current(state).kind === TokenKind.LBrace) {
		const body = try blockParser(state);
		return Result.ok(createNode(NodeKind.ArrowFunction, {
			arrowParams,
			arrowParamTypes,
			arrowBody: body,
			arrowFlags: flags,
			arrowReturnType,
		}, arrowToken));
	}

	const body = try exprParser(state, 0);
	return Result.ok(createNode(NodeKind.ArrowFunction, {
		arrowParams,
		arrowParamTypes,
		arrowBody: body,
		arrowFlags: flags,
		arrowReturnType,
	}, arrowToken));
}

// ===== Tests =====

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
	const data = result.value.data as ArrowFunctionData;
	return data.arrowParams.length;
}
// Detection
test "detect arrow" { assert checkArrow("() => 42"); }

test "detect typed" { assert checkArrow("(x: number) => x"); }

test "reject paren expr" { assert !checkArrow("(a + b)"); }

test "reject call" { assert !checkArrow("f(a)"); }
// Param counts
test "zero params" { assert arrowParamCount("() => 42") === 0; }

test "two params" { assert arrowParamCount("(a, b) => a") === 2; }
// Integration
test "arrow as arg" { assert parseOk("f((x) => x)"); }

test "paren expr still works" { assert parseOk("(a + b) * c"); }
