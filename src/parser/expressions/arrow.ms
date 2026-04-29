// Arrow Function Parser
// Extracted from expression.ms with callback injection

import { TokenKind } from "../../lexer/token";
import { Node, NodeKind, Expression, createNode, ArrowFunctionData, makeLoc } from "../../ast/node";
import { ParserState, createState, current, advance, isAtEnd, peek } from "../context";
import { parseParamList, extractParamNames, extractParamTypes, captureOptionalType, getLastTypeExpr, getLastParamTypeExprs, getLastParamLocations, getLastParsedDefaults, isIdentLike } from "../util";
import { lex } from "../../lexer/lexer";
import { parseOk, mockExpr } from "./util";


type ExprResult = Result<Expression, string>;
type ExprParser = (state: ParserState, minPrec: number) => ExprResult;
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
	let i = 0;
	while (i < limit) {
		const t = peek(state, i);
		if (t.kind === TokenKind.Eof) return false;
		if (t.kind === TokenKind.LParen) {
			pDepth = pDepth + 1;
		} else if (t.kind === TokenKind.RParen) {
			pDepth = pDepth - 1;
			if (pDepth === 0) {
				// Closed the outermost paren. Look for '=>' (possibly past return type)
				let j = i + 1;
				if (peek(state, j).kind === TokenKind.Colon) {
					// Skip return type annotation: walk until top-level '=>' or terminator
					j = j + 1;
					let tDepth = 0;
					while (j < limit) {
						const tt = peek(state, j);
						if (tt.kind === TokenKind.Arrow && tDepth === 0) return true;
						if (tt.kind === TokenKind.LParen || tt.kind === TokenKind.LBrace ||
							tt.kind === TokenKind.LBracket || tt.kind === TokenKind.Lt) {
							tDepth = tDepth + 1;
						} else if (tt.kind === TokenKind.RParen || tt.kind === TokenKind.RBrace ||
							tt.kind === TokenKind.RBracket || tt.kind === TokenKind.Gt) {
							tDepth = tDepth - 1;
							if (tDepth < 0) return false;
						}
						if (tDepth === 0 &&
							(tt.kind === TokenKind.Semicolon || tt.kind === TokenKind.Comma ||
							 tt.kind === TokenKind.Eof)) return false;
						j = j + 1;
					}
					return false;
				}
				return peek(state, j).kind === TokenKind.Arrow;
			}
		}
		i = i + 1;
	}
	return false;
}

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
	// Ambiguous with paren-wrapped object/array literal expression — must verify '=>' follows
	if (p1.kind === TokenKind.LBrace || p1.kind === TokenKind.LBracket) {
		return scanParenForArrow(state);
	}

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

	// (ident = ...) — default param value. Ambiguous with paren-wrapped assignment expr.
	if (p2.kind === TokenKind.Assign) { return scanParenForArrow(state); }

	// (ident?...) — optional param marker (TS-only, currently unsupported but reserved)
	if (p2.kind === TokenKind.Question) { return scanParenForArrow(state); }

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
	const arrowParamTypeExprs = getLastParamTypeExprs();
	const arrowParamLocs = getLastParamLocations();
	const arrowParams = extractParamNames(raw);
	const arrowParamTypes = extractParamTypes(raw);
	// Pad defaults to match arrowParams length (parser only pushes when default present)
	const rawDefaults = getLastParsedDefaults();
	const arrowDefaults: (Node | null)[] = [];
	let di = 0;
	while (di < arrowParams.length) {
		arrowDefaults.push(di < rawDefaults.length ? rawDefaults[di] : null);
		di = di + 1;
	}

	// Optional return type annotation: (): string => ...
	const arrowReturnType = captureOptionalType(state);
	const arrowRetTypeExpr = getLastTypeExpr();

	if (isAtEnd(state) || current(state).kind !== TokenKind.Arrow) {
		return Result.err(`Expected '=>' in arrow function at line ${current(state).line}`);
	}

	advance(state); // consume =>
	// Body: block { ... } or expression
	if (!isAtEnd(state) && current(state).kind === TokenKind.LBrace) {
		const body = try blockParser(state);
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

	const body = try exprParser(state, 0);
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
	flags: string
): ExprResult {
	const identToken = current(state);
	advance(state); // consume Ident

	if (isAtEnd(state) || current(state).kind !== TokenKind.Arrow) {
		return Result.err(`Expected '=>' after bare-ident arrow param at line ${identToken.line}`);
	}
	advance(state); // consume =>

	// Body: block { ... } or expression
	if (!isAtEnd(state) && current(state).kind === TokenKind.LBrace) {
		const blockBody = try blockParser(state);
		const blockNode = createNode(NodeKind.ArrowFunction, {
			arrowParams: [identToken.value],
			arrowParamTypes: [""],
			arrowBody: blockBody,
			arrowFlags: flags,
			arrowReturnType: "",
			arrowDefaults: [null],
		}, identToken);
		blockNode.typeExpr = null;
		blockNode.typeExprs = [null];
		blockNode.paramLocations = [makeLoc(identToken.line, identToken.column)];
		return Result.ok(blockNode);
	}

	const exprBody = try exprParser(state, 0);
	const exprNode = createNode(NodeKind.ArrowFunction, {
		arrowParams: [identToken.value],
		arrowParamTypes: [""],
		arrowBody: exprBody,
		arrowFlags: flags,
		arrowReturnType: "",
		arrowDefaults: [null],
	}, identToken);
	exprNode.typeExpr = null;
	exprNode.typeExprs = [null];
	exprNode.paramLocations = [makeLoc(identToken.line, identToken.column)];
	return Result.ok(exprNode);
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
