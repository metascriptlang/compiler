// Arrow Function Parser
// Extracted from expression.ms with callback injection

import { TokenKind } from "../../lexer/token";
import { Node, NodeKind, Expression, createNode, ArrowFunctionData, ConditionalExprData, CallExprData, makeLoc } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd, peek, peekIndex, skipComments, tokenAt, markState, rewindState, angleCloserWidth } from "../context";
import { parseParamList, extractParamNames, extractParamTypes, captureOptionalType, getLastTypeExpr, getLastParamTypeExprs, getLastParamLocations, getLastParamPatterns, prependParamPatterns, getLastParsedDefaults, getLastParamsClosed, isIdentLike } from "../util";
import { lex } from "../../lexer/lexer";
import { parseOk, mockExpr, exprNode } from "./util";


type ExprResult = Result<Expression, string>;
type ExprParser = (state: ParserState, minPrec: int32) => ExprResult;
type BlockParser = (state: ParserState) => ExprResult;

// syntax: arrow = ('async')? ('(' params ')' | ID) (':' type)? '=>' (expr | block)

// ===== Arrow Function Lookahead =====

// Balanced-scan: starting at current LParen, walk tokens until matching RParen,
// then verify '=>' follows (allowing optional ': type' return annotation).
// Used for ambiguous cases where the inside of the paren COULD be either
// arrow params or a paren-wrapped expression (e.g. `({k:v})`, `(x = 5)`).
function scanParenForArrow(state: ParserState): boolean {
	// Bounded by actual remaining token count — finite by construction.
	// Belt-and-suspenders: Eof exit + token-count bound prevents any malformed
	// input from hanging the parser.
	const limit = state.tokens.length;
	let pDepth = 0;
	let i = peekIndex(state, 0);
	while (i < limit) {
		const t = state.tokens[i];
		if (t.kind == TokenKind.Eof) return false;
		if (t.kind == TokenKind.LParen) {
			pDepth = pDepth + 1;
		} else if (t.kind == TokenKind.RParen) {
			pDepth = pDepth - 1;
			if (pDepth == 0) {
				// Closed the outermost paren. Look for '=>' (possibly past return type)
				let j = skipComments(state, i + 1);
				if (tokenAt(state, j).kind == TokenKind.Colon) {
					// Skip return type annotation: walk until top-level '=>' or terminator
					j = skipComments(state, j + 1);
					let tDepth = 0;
					while (j < limit) {
						const tt = state.tokens[j];
						if (tt.kind == TokenKind.Arrow && tDepth == 0) return true;
						if (tt.kind == TokenKind.LParen || tt.kind == TokenKind.LBrace ||
							tt.kind == TokenKind.LBracket || tt.kind == TokenKind.Lt) {
							tDepth = tDepth + 1;
						} else {
							const closes = tt.kind == TokenKind.RParen || tt.kind == TokenKind.RBrace || tt.kind == TokenKind.RBracket ? 1 : angleCloserWidth(tt.kind);
							tDepth = tDepth - closes;
							if (tDepth < 0) return false;
						}
						if (tDepth == 0 &&
							(tt.kind == TokenKind.Semicolon || tt.kind == TokenKind.Comma ||
							 tt.kind == TokenKind.Eof)) return false;
						j = skipComments(state, j + 1);
					}
					return false;
				}
				return tokenAt(state, j).kind == TokenKind.Arrow;
			}
		}
		i = skipComments(state, i + 1);
	}
	return false;
}

export enum ArrowShape { No, Yes, Maybe }

export function arrowShape(state: ParserState): ArrowShape {
	// Must start with (
	if (current(state).kind != TokenKind.LParen) { return ArrowShape.No; }

	const p1 = peek(state, 1);
	// () =>  (zero params) — also handle () : Type => via scanParenForArrow,
	// which already knows how to walk past an optional return-type annotation
	// (used by the destructured-params and default-value paths below). Without
	// the Colon branch, `(): Type =>` falls through to paren-expression
	// parsing and blows up on the unexpected `:`. Bug F.
	if (p1.kind == TokenKind.RParen) {
		const p2 = peek(state, 2);
		if (p2.kind == TokenKind.Arrow) return ArrowShape.Yes;
		if (p2.kind == TokenKind.Colon) return scanParenForArrow(state) ? ArrowShape.Yes : ArrowShape.No;
	}

	// Rest params: (...args) =>
	if (p1.kind == TokenKind.DotDotDot) { return ArrowShape.Yes; }

	// Destructured params: ({ ... }) => or ([ ... ]) =>
	// Ambiguous with paren-wrapped object/array literal expression — must verify '=>' follows
	if (p1.kind == TokenKind.LBrace || p1.kind == TokenKind.LBracket) {
		return scanParenForArrow(state) ? ArrowShape.Maybe : ArrowShape.No;
	}

	// Must have identifier as first param
	if (!isIdentLike(p1)) { return ArrowShape.No; }

	const p2 = peek(state, 2);
	// (ident) =>  (single untyped param), (ident) : Type =>  (untyped param, return type)
	if (p2.kind == TokenKind.RParen) {
		const p3 = peek(state, 3).kind;
		if (p3 == TokenKind.Arrow) return ArrowShape.Maybe;
		if (p3 == TokenKind.Colon) return scanParenForArrow(state) ? ArrowShape.Maybe : ArrowShape.No;
	}

	// (ident,  (multiple params — comma is never valid start of paren subexpr)
	if (p2.kind == TokenKind.Comma) { return ArrowShape.Maybe; }

	// (ident:  (typed param — colon never valid after bare ident in expression)
	if (p2.kind == TokenKind.Colon) { return ArrowShape.Yes; }

	// (ident = ...) — default param value. Ambiguous with paren-wrapped assignment expr.
	if (p2.kind == TokenKind.Assign) { return scanParenForArrow(state) ? ArrowShape.Maybe : ArrowShape.No; }

	// (ident?...) — optional param marker (TS-only, currently unsupported but reserved)
	if (p2.kind == TokenKind.Question) { return scanParenForArrow(state) ? ArrowShape.Maybe : ArrowShape.No; }

	return ArrowShape.No;
}

export function isArrowFunction(state: ParserState): boolean {
	return arrowShape(state) != ArrowShape.No;
}

// ===== Arrow Function Parser =====

export function parseArrowFunction(
	state: ParserState,
	exprParser: ExprParser,
	blockParser: BlockParser,
	flags: string
): ExprResult {
	return parseArrowCore(state, exprParser, blockParser, flags, true, false);
}

// A parenthesized form the lookahead cannot settle: parse it as an arrow, and give back a
// null value with the parser rewound when it is something else. `allowReturnType` is false
// in the true arm of a conditional, where `(x): T =>` is accepted only if a `:` follows.
export function tryParseArrowFunction(
	state: ParserState,
	exprParser: ExprParser,
	blockParser: BlockParser,
	flags: string,
	allowReturnType: boolean
): ExprResult {
	const mark = markState(state);
	const result = parseArrowCore(state, exprParser, blockParser, flags, allowReturnType, true);
	if (result.ok && result.value == null) rewindState(state, mark);
	return result;
}

function returnColonEndsConditional(state: ParserState, allowReturnType: boolean, hasReturnColon: boolean): boolean {
	return !allowReturnType && hasReturnColon && (isAtEnd(state) || current(state).kind != TokenKind.Colon);
}

function parseArrowCore(
	state: ParserState,
	exprParser: ExprParser,
	blockParser: BlockParser,
	flags: string,
	allowReturnType: boolean,
	speculative: boolean
): ExprResult {
	const rejected: ExprResult = Result.ok(null as unknown as Expression);
	const arrowToken = current(state);
	const raw = parseParamList(state, "");
	if (speculative && !getLastParamsClosed()) return rejected;
	const arrowParamTypeExprs = getLastParamTypeExprs();
	const arrowParamLocs = getLastParamLocations();
	const arrowPatterns = getLastParamPatterns();
	const arrowParams = extractParamNames(raw);
	const arrowParamTypes = extractParamTypes(raw);
	// Pad defaults to match arrowParams length (parser only pushes when default present)
	const rawDefaults = getLastParsedDefaults();
	const arrowDefaults: Node[] = [];
	let di = 0;
	while (di < arrowParams.length) {
		arrowDefaults.push(di < rawDefaults.length ? rawDefaults[di] : null as unknown as Node);
		di = di + 1;
	}

	// Optional return type annotation: (): string => ...
	const hasReturnColon = !isAtEnd(state) && current(state).kind == TokenKind.Colon;
	const arrowReturnType = captureOptionalType(state);
	const arrowRetTypeExpr = getLastTypeExpr();

	if (isAtEnd(state) || current(state).kind != TokenKind.Arrow) {
		if (speculative) return rejected;
		return Result.err(`Expected '=>' in arrow function at line ${current(state).line}`);
	}

	advance(state); // consume =>
	// Body: block { ... } or expression
	if (!isAtEnd(state) && current(state).kind == TokenKind.LBrace) {
		const blockBody = try blockParser(state);
		if (returnColonEndsConditional(state, allowReturnType, hasReturnColon)) return rejected;
		const body = prependParamPatterns(blockBody, arrowPatterns, arrowParamLocs);
		const arrowNode1 = createNode(NodeKind.ArrowFunction, {
			arrowParams,
			arrowParamTypes,
			arrowBody: body,
			arrowFlags: flags,
			arrowReturnType,
			arrowDefaults,
		}, arrowToken);
		arrowNode1.typeExpr = arrowRetTypeExpr;
		arrowNode1.typeExprs = arrowParamTypeExprs;
		arrowNode1.paramLocations = arrowParamLocs;
		return Result.ok(arrowNode1);
	}

	state.noArrowReturnType = allowReturnType ? 0 : 1;
	const bodyExpr = try exprParser(state, 0);
	if (returnColonEndsConditional(state, allowReturnType, hasReturnColon)) return rejected;
	const body = prependParamPatterns(bodyExpr, arrowPatterns, arrowParamLocs);
	const arrowNode2 = createNode(NodeKind.ArrowFunction, {
		arrowParams,
		arrowParamTypes,
		arrowBody: body,
		arrowFlags: flags,
		arrowReturnType,
		arrowDefaults,
	}, arrowToken);
	arrowNode2.typeExpr = arrowRetTypeExpr;
	arrowNode2.typeExprs = arrowParamTypeExprs;
	arrowNode2.paramLocations = arrowParamLocs;
	return Result.ok(arrowNode2);
}

// ===== Bare-Ident Arrow =====
// syntax: ID '=>' (expr | block)
// Caller must verify peek(state, 1).kind === TokenKind.Arrow before invoking.
// Used for ES6 single-untyped-param shorthand: x => x + 1, effect => {...}.

export function parseBareIdentArrow(
	state: ParserState,
	exprParser: ExprParser,
	blockParser: BlockParser,
	flags: string,
	allowReturnType: boolean
): ExprResult {
	const identToken = current(state);
	advance(state); // consume Ident

	if (isAtEnd(state) || current(state).kind != TokenKind.Arrow) {
		return Result.err(`Expected '=>' after bare-ident arrow param at line ${identToken.line}`);
	}
	advance(state); // consume =>

	// Body: block { ... } or expression
	if (!isAtEnd(state) && current(state).kind == TokenKind.LBrace) {
		const blockBody = try blockParser(state);
		const blockNode = createNode(NodeKind.ArrowFunction, {
			arrowParams: [identToken.value],
			arrowParamTypes: [""],
			arrowBody: blockBody,
			arrowFlags: flags,
			arrowReturnType: "",
			arrowDefaults: [null as unknown as Node],
		}, identToken);
		blockNode.typeExpr = null;
		blockNode.typeExprs = [null as unknown as Node];
		blockNode.paramLocations = [makeLoc(identToken.line, identToken.column)];
		return Result.ok(blockNode);
	}

	state.noArrowReturnType = allowReturnType ? 0 : 1;
	const exprBody = try exprParser(state, 0);
	const exprNode = createNode(NodeKind.ArrowFunction, {
		arrowParams: [identToken.value],
		arrowParamTypes: [""],
		arrowBody: exprBody,
		arrowFlags: flags,
		arrowReturnType: "",
		arrowDefaults: [null as unknown as Node],
	}, identToken);
	exprNode.typeExpr = null;
	exprNode.typeExprs = [null as unknown as Node];
	exprNode.paramLocations = [makeLoc(identToken.line, identToken.column)];
	return Result.ok(exprNode);
}

// ===== Tests =====

import "../statements/core"; // registers parser callbacks

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

function arrowParamCount(input: string): int32 {
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
test "detect arrow with comments between tokens" { assert checkArrow("(/*a*/ x /*b*/) /*c*/ => /*d*/ x"); }

test "detect arrow past nested parens and comments" { assert checkArrow("(a = (1) /*c*/, b = (2)) => a"); }

test "detect arrow past return type with comments" { assert checkArrow("(x) /*c*/ : /*d*/ (number) // e\n => x"); }

test "reject nested paren expr with comments" { assert !checkArrow("((a) /*c*/ + (b)) /*d*/ * c"); }

test "reject paren object literal with comments" { assert !checkArrow("({ a: 1, /*c*/ b: (2) })"); }

// Param counts
test "zero params" { assert arrowParamCount("() => 42") == 0; }

test "two params" { assert arrowParamCount("(a, b) => a") == 2; }
// Integration
test "arrow as arg" { assert parseOk("f((x) => x)"); }

test "paren expr still works" { assert parseOk("(a + b) * c"); }

// Bare-ident arrow (ES6 single-untyped-param shorthand)
test "bare ident expr body" { assert parseOk("x => x + 1"); }

test "bare ident block body" { assert parseOk("x => { return x; }"); }

test "bare ident in call arg" { assert parseOk("arr.forEach(x => console.log(x))"); }

test "bare ident chained" { assert parseOk("arr.map(x => x * 2).filter(y => y > 0)"); }

test "bare ident async" { assert parseOk("async x => x + 1"); }

// Negative — bare ident NOT followed by => still parses as identifier
test "bare ident alone" { assert parseOk("x"); }
test "bare ident in expr" { assert parseOk("x + y"); }
test "match arm not arrow" { assert parseOk("match (k) { 1 => \"one\", _ => \"other\" }"); }

// Critical: match patterns that ARE bare identifiers must NOT trigger bare-ident arrow.
// parseSinglePattern owns the pattern path, not parsePrimary.
test "match ident pattern not bare arrow" { assert parseOk("match (v) { Kind.A => 1, Kind.B => 2, _ => 0 }"); }
test "match number-or-pattern with arrow body" { assert parseOk("match (k) { 1 | 2 => \"few\", _ => \"many\" }"); }

// Phase 1: default param in arrow
test "default param expr body" { assert parseOk("(x = 10) => x + 1"); }
test "default param block body" { assert parseOk("(x = 0) => { return x; }"); }
test "default param typed" { assert parseOk("(x: number = 10) => x"); }

// Phase 2: object/array literal arrow body (paren-wrapped) — must not be misread as destructured arrow
test "object literal body" { assert parseOk("x => ({ k: x })"); }
test "array literal body" { assert parseOk("x => ([1, x, 2])"); }
test "object literal in call arg" { assert parseOk("f(x => ({ k: x }))"); }

// Pre-existing destructured arrow MUST still work (negative regression check for Phase 2)
test "destructured object param" { assert parseOk("({a, b}) => a + b"); }
test "destructured array param" { assert parseOk("([a, b]) => a + b"); }

// Paren-wrapped object/array expressions (NO arrow) must NOT trigger isArrowFunction
test "paren object expr no arrow" { assert parseOk("({k: 1, v: 2})"); }
test "paren assignment expr" { assert parseOk("(x = 5)"); }

// Return type after one untyped parameter, and the conditional's true arm
function armKinds(input: string): string {
	const node = exprNode(input);
	if (node.kind != NodeKind.ConditionalExpr) return "not a conditional";
	const d = node.data as ConditionalExprData;
	return `${d.ternaryConsequent.kind == NodeKind.ArrowFunction ? "arrow" : "other"}/${d.ternaryAlternate.kind == NodeKind.ArrowFunction ? "arrow" : "other"}`;
}

function arrowReturnTypeOf(input: string): string {
	const node = exprNode(input);
	if (node.kind != NodeKind.ArrowFunction) return "not an arrow";
	return (node.data as ArrowFunctionData).arrowReturnType;
}

function trueArmCallArgIsArrow(input: string): boolean {
	const node = exprNode(input);
	if (node.kind != NodeKind.ConditionalExpr) return false;
	const arm = (node.data as ConditionalExprData).ternaryConsequent;
	if (arm.kind != NodeKind.CallExpr) return false;
	return (arm.data as CallExprData).arguments[0].kind == NodeKind.ArrowFunction;
}

test "untyped param return type expr body" { assert arrowReturnTypeOf("(n): string => n") == "string"; }
test "untyped param return type block body" { assert arrowReturnTypeOf("(n): string => { return n; }") == "string"; }
test "untyped param return type async" { assert arrowReturnTypeOf("async (n): Promise<string> => n") == "Promise<string>"; }
test "untyped param return type destructured" { assert arrowReturnTypeOf("({ a }): string => a") == "string"; }
test "two untyped params return type" { assert arrowReturnTypeOf("(a, b): number => a + b") == "number"; }
test "zero params return type" { assert arrowReturnTypeOf("(): string => 'v'") == "string"; }
test "a return type closing nested type arguments together" {
	assert arrowReturnTypeOf("(): Box<Box<int32>> => v") == "Box<Box<int32>>";
	assert arrowReturnTypeOf("(n): Box<Box<Box<int32>>> => n") == "Box<Box<Box<int32>>>";
}
test "typed param return type" { assert arrowReturnTypeOf("(n: number): string => n") == "string"; }

test "true arm paren is not an arrow" { assert armKinds("c ? (y) : (n: number): number => n + 1") == "other/arrow"; }
test "true arm paren, untyped false arrow" { assert armKinds("c ? (y) : z => z") == "other/arrow"; }
test "true arm arrow with return type ended by colon" { assert armKinds("a ? (x): string => x : null") == "arrow/other"; }
test "true arm bare arrow body paren object" { assert armKinds("c ? y => ({ y }) : z => ({ z })") == "arrow/arrow"; }
test "true arm paren object, bare false arrow" { assert armKinds("c ? ({ a: 1 }) : z => z") == "other/arrow"; }
test "true arm paren object, false identifier" { assert armKinds("c ? ({ a: 1 }) : y") == "other/other"; }
test "true arm paren object, next line an arrow" { assert armKinds("c ? ({ a: 1 }) : y\nconst g = (z: number): number => z + 1") == "other/other"; }
test "false arm keeps return type" { assert armKinds("c ? 1 : (n): string => n") == "other/arrow"; }
test "call in true arm takes a return type" { assert trueArmCallArgIsArrow("c ? f((n): string => n) : 1"); }
test "true arm block body arrow ended by colon" { assert armKinds("a ? (x): string => { return x; } : null") == "arrow/other"; }

test "rewound speculation gives back the token it split" { assert armKinds("t ? (y) : a < b >= c > d => d") == "other/other"; }
