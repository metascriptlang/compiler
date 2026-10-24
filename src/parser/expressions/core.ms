// Core Expression Parser - Pratt parsing with operator precedence

import { Token, TokenKind, isIdentOrKeyword } from "../../lexer/token";
import { Node, NodeKind, NodeFlag, NodeData, Expression, createNode, QuoteExprData, BlockStmtData, UnaryExprData, UpdateExprData, TypeAssertionData, AwaitExprData, IdentifierData, MemberExprData, NumberLiteralData, BinaryExprData } from "../../ast/node";
import { ParserState, createState, current, advance, peek, isAtEnd, captureGenericTypeArgs, collectTokenText, stampEnd, takePendingComments, parenGroupThen, expectCloser } from "../context";
import { skipTypeAnnotation, parseTypeExpr, isGenericCallAhead } from "../typeAnnotation";
import { parseParamList, extractParamNames, extractParamTypes, captureOptionalType, getLastTypeExpr, getLastParamTypeExprs, getLastParamLocations, getLastParamPatterns, prependParamPatterns, isIdentLike, continuesIdentifier } from "../util";
import { getPrecedence, isBinaryOperator, isRightAssociative } from "./precedence";
import { parseMatchExpr } from "./match";
import { ArrowShape, arrowShape, parseArrowFunction, tryParseArrowFunction, parseBareIdentArrow } from "./arrow";
import { parseObjectLiteral } from "./object";
import { parseJsxRoot } from "./jsx";
import { parseExprList, parseCallExpr, takeListEndComments } from "./call";
import { parseTemplateLiteral } from "./template";
import { parseBlockStmt } from "../statements/core";
import { tryParseLiteralKeyword } from "./util";
import { parseOk, exprKind, exprNode, exprOp, binLeftKind } from "./testUtil";
import { parseNumberLiteral, parseIntegerLiteral, integerLiteralFits, integerLiteralIsBitPattern, numericLiteralIsFloat } from "../../utils/string";


type ExprResult = Result<Expression, string>;

// ===== Main Parse Functions =====

export function parseExpression(tokens: Token[]): ExprResult {
	const state = createState(tokens);
	return parseExprWithPrec(state, 0);
}

export function parseExpressionFromState(state: ParserState): ExprResult {
	const result = parseExprWithPrec(state, 0);
	if (result.ok) stampEnd(state, result.value);
	return result;
}


const NO_BINARY_PREC: int32 = 100;

function parseAsType(state: ParserState, left: Node, token: Token): Node {
	advance(state);
	const asStart = state.position;
	skipTypeAnnotation(state);
	const asType = collectTokenText(state, asStart, state.position);
	const asSavedPos = state.position;
	state.position = asStart;
	const asTypeExpr = parseTypeExpr(state);
	state.position = asSavedPos;
	const asNode = createNode(NodeKind.TypeAssertion, { asExpr: left, asType }, token);
	asNode.typeExpr = asTypeExpr;
	return asNode;
}

// After `a op b as T`, an operator that binds tighter than `op` would have taken
// `b` had the assertion been erased, so the expression stops there instead.
function bindsBefore(next: Token, lastPrec: int32): boolean {
	if (!isBinaryOperator(next) && next.kind != TokenKind.As) return false;
	const p = getPrecedence(next.kind);
	return p > lastPrec || (p == lastPrec && next.kind == TokenKind.StarStar);
}

// syntax: expr = primary (postfix)* ((binop primary (postfix)*) | 'as' type)* ('?' expr ':' expr)?
// syntax: postfix = '(' args ')' | '.' ID | '?.' ID | '[' expr ']' | '++' | '--'
function parseExprWithPrec(state: ParserState, minPrec: int32): ExprResult {
	const arrowReturnTypeBan = state.noArrowReturnType;
	let left = try parsePrimary(state);

	// Postfix operators: call, member access, optional chaining, array indexing, update
	let chainOpen = false;
	while (!isAtEnd(state)) {
		const token = current(state);

		// Explicit generic type args: foo<number>(args) or obj.method<T>(args)
		// Store type args in side-channel keyed by call site location.
		// Callee name stays clean so checker can look it up normally.
		if (token.kind == TokenKind.Lt && (left.kind == NodeKind.Identifier || left.kind == NodeKind.MemberExpr)) {
			if (isGenericCallAhead(state)) {
				const typeArgs = captureGenericTypeArgs(state);
				if (typeArgs != "") {
					state.pendingTypeArg = typeArgs;
				}
				continue;
			}
		}

		if (token.kind == TokenKind.LParen) {
			left = try parseCallExpr(state, left, parseExprWithPrec);
			continue;
		}

		if (token.kind == TokenKind.Dot) {
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
		if (token.kind == TokenKind.QuestionDot) {
			advance(state);
			const prop = current(state);
			let optPropName = "";
			if (isIdentOrKeyword(prop.kind)) {
				optPropName = prop.value;
				advance(state);
			}
			if (chainOpen) left.flags = left.flags.incl(NodeFlag.OptionalChainEnd);
			left = createNode(NodeKind.MemberExpr, { object: left, property: optPropName, isOptional: true }, token);
			chainOpen = true;
			continue;
		}

		if (token.kind == TokenKind.LBracket) {
			if (chainOpen && peek(state, 1).kind == TokenKind.RBracket) {
				left.flags = left.flags.incl(NodeFlag.OptionalChainEnd);
				chainOpen = false;
			}
			advance(state);
			if (current(state).kind == TokenKind.RBracket) {
				advance(state);
				left = createNode(NodeKind.HiddenDeref, { expr: left }, token);
				left.flags = left.flags.incl(NodeFlag.ExplicitDeref);
				continue;
			}
			let idx = try parseExprWithPrec(state, 0);
			// Range syntax: arr[start..end] → ArrayAccess(arr, BinaryExpr("..", start, end))
			if (current(state).kind == TokenKind.DotDot || current(state).kind == TokenKind.DotDotDot) {
				const rangeTok = current(state);
				advance(state);
				const endIdx = try parseExprWithPrec(state, 0);
				idx = createNode(NodeKind.BinaryExpr, { operator: rangeTok.value, left: idx, right: endIdx }, rangeTok);
			}
			expectCloser(state, token, TokenKind.RBracket);
			const accessData: NodeData = {
				array: left,
				index: idx
			};
			left = createNode(NodeKind.ArrayAccess, accessData, token);
			continue;
		}

		// Postfix increment/decrement
		if (token.kind == TokenKind.PlusPlus || token.kind == TokenKind.MinusMinus) {
			if (chainOpen) left.flags = left.flags.incl(NodeFlag.OptionalChainEnd);
			chainOpen = false;
			advance(state);
			left = createNode(NodeKind.UpdateExpr, { updateOp: token.value, updateArg: left, isPrefix: false }, token);
			continue;
		}

		// Non-null assertion: expr! — sentinel asType "!" strips the nullable
		if (token.kind == TokenKind.Bang) {
			advance(state);
			left = createNode(NodeKind.TypeAssertion, { asExpr: left, asType: "!" }, token);
			continue;
		}

		break;
	}
	if (chainOpen) left.flags = left.flags.incl(NodeFlag.OptionalChainEnd);

	// Binary operators with Pratt precedence climbing; `as` binds at relational precedence
	let lastPrec = NO_BINARY_PREC;
	while (!isAtEnd(state) && (isBinaryOperator(current(state)) || current(state).kind == TokenKind.As)) {
		const op = current(state);
		const prec = getPrecedence(op.kind);
		if (prec < minPrec) {
			break;
		}
		if (op.kind == TokenKind.As) {
			left = parseAsType(state, left, op);
			if (bindsBefore(current(state), lastPrec)) break;
			continue;
		}

		advance(state);
		const afterOperator: Token[] = [];
		const beforeOperator: Token[] = [];
		for (const c of takePendingComments(state)) {
			if (c.line > op.line || (c.line == op.line && c.column > op.column)) afterOperator.push(c); else beforeOperator.push(c);
		}
		state.pendingComments = beforeOperator;
		// Right-associative operators (**, =, +=, etc.) use prec instead of prec+1
		let nextPrec = prec + 1;
		if (isRightAssociative(op.kind)) {
			nextPrec = prec;
		}
		if (isRightAssociative(op.kind) && op.kind != TokenKind.StarStar) state.noArrowReturnType = arrowReturnTypeBan;
		const right = try parseExprWithPrec(state, nextPrec);
		if (afterOperator.length > 0) {
			for (const c of right.comments) afterOperator.push(c);
			right.comments = afterOperator;
		}
		const data: NodeData = {
			operator: op.value,
			left,
			right
		};
		left = createNode(NodeKind.BinaryExpr, data, op);
		lastPrec = prec;
	}

	// Ternary conditional: expr ? consequent : alternate
	if (!isAtEnd(state) && current(state).kind == TokenKind.Question) {
		const ternaryPrec = 6;
		if (ternaryPrec >= minPrec) {
			const qToken = current(state);
			advance(state);
			state.noArrowReturnType = 1;
			const consequent = try parseExprWithPrec(state, 0);
			if (!isAtEnd(state) && current(state).kind == TokenKind.Colon) {
				advance(state);
			}
			state.noArrowReturnType = arrowReturnTypeBan;
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
	const raw = parseParamList(state, "");
	const feParamTypeExprs = getLastParamTypeExprs();
	const feParamLocs = getLastParamLocations();
	const fePatterns = getLastParamPatterns();
	const funcExprParams = extractParamNames(raw);
	const funcExprParamTypes = extractParamTypes(raw);
	// Optional return type
	const funcExprReturnType = captureOptionalType(state);
	const funcExprRetTypeExpr = getLastTypeExpr();
	const feBody = prependParamPatterns(try parseBlockStmt(state), fePatterns, feParamLocs);
	const feNode = createNode(NodeKind.FunctionExpr, { funcExprParams, funcExprParamTypes, funcExprBody: feBody, funcExprFlags: feFlags, funcExprReturnType }, token);
	feNode.typeExpr = funcExprRetTypeExpr;
	feNode.typeExprs = feParamTypeExprs;
	feNode.paramLocations = feParamLocs;
	return Result.ok(feNode);
}

// ===== Primary Expressions =====
// syntax: primary = NUMBER | STRING | BOOL | NULL | BIGINT | REGEX | IDENT | 'this' | 'super'
//                 | '(' expr ')' | '[' exprList ']' | '{' objectBody '}'
//                 | 'function' ... | 'try' expr | 'match' (...) | 'new' expr
//                 | 'await' expr | 'yield' expr? | 'move' expr | 'out' expr
//                 | ('typeof' | 'void' | 'delete') expr | ('++' | '--') expr
//                 | ('-' | '!' | '~') expr | 'async' (funcExpr | arrow) | '...' expr

// The postfix pass consumes `as` unconditionally, but TS binds it outside a
// prefix op: `-x as T` = `(-x) as T`, `typeof x as T` = `(typeof x) as T`.
// Wraps the operand of the innermost unparenthesized `as`; a `!` below it stays
// in the operand, one above it stays outside.
function prefixed(operand: Node, wrap: (inner: Node) => Node): Node {
	let target: Node | null = null;
	let cur = operand;
	while (cur.kind == NodeKind.TypeAssertion && !cur.flags.has(NodeFlag.Parenthesized)) {
		const ad = cur.data as TypeAssertionData;
		if (ad.asType != "!") target = cur;
		cur = ad.asExpr;
	}
	if (target == null) return wrap(operand);
	const td = target.data as TypeAssertionData;
	td.asExpr = wrap(td.asExpr);
	return operand;
}

function parsePrimary(state: ParserState): ExprResult {
	const token = current(state);
	const allowArrowReturnType = state.noArrowReturnType == 0;
	state.noArrowReturnType = 0;

	// JSX — the lexer emits JsxTagStart only for JSX, so no disambiguation here.
	if (token.kind == TokenKind.JsxTagStart) {
		return parseJsxRoot(state, parseExprWithPrec);
	}

	if (token.kind == TokenKind.Number) {
		advance(state);
		const isFloat = numericLiteralIsFloat(token.value);
		const intVal = isFloat ? 0 as int64 : parseIntegerLiteral(token.value);
		const outOfRangeText = isFloat || integerLiteralFits(token.value) ? "" : token.value;
		const isBitPattern = !isFloat && integerLiteralIsBitPattern(token.value);
		return Result.ok(createNode(NodeKind.NumberLiteral, { value: parseNumberLiteral(token.value), isFloat, intVal, outOfRangeText, isBitPattern }, token));
	}

	if (token.kind == TokenKind.String) {
		advance(state);
		return Result.ok(createNode(NodeKind.StringLiteral, { value: token.value }, token));
	}

	// Template literal (no substitutions) - desugar to string literal
	if (token.kind == TokenKind.TemplateNoSub) {
		advance(state);
		return Result.ok(createNode(NodeKind.StringLiteral, { value: token.value }, token));
	}

	// Template literal (with substitutions) - desugar to string concatenation
	if (token.kind == TokenKind.TemplateHead) {
		return parseTemplateLiteral(state, parseExprWithPrec);
	}

	// Literal keywords (true/false/null) — shared helper with match-pattern parser.
	const literalNode = tryParseLiteralKeyword(state);
	if (literalNode != null) return Result.ok(literalNode);

	// BigInt literal: 123n
	if (token.kind == TokenKind.BigInt) {
		advance(state);
		return Result.ok(createNode(NodeKind.BigIntLiteral, { bigintValue: token.value }, token));
	}

	// Regex literal: /pattern/flags
	if (token.kind == TokenKind.Regex) {
		advance(state);
		return Result.ok(createNode(NodeKind.RegexLiteral, { regexPattern: token.value }, token));
	}

	// Bare-ident arrow: x => body  (ES6 single-untyped-param shorthand)
	// Detected before plain Ident handler — must run first or `x` is consumed as identifier.
	// Suppressed inside match-case `when` guards (state.noBareArrow): there a
	// trailing `=>` belongs to the match arm, so `2 when flag => 200` must parse
	// the guard as `flag`, not as the arrow function `flag => 200`.
	if (token.kind == TokenKind.Ident && peek(state, 1).kind == TokenKind.Arrow && state.noBareArrow == 0) {
		return parseBareIdentArrow(state, parseExprWithPrec, parseBlockStmt, "", allowArrowReturnType);
	}

	if (token.kind == TokenKind.Import && peek(state, 1).kind == TokenKind.LParen) {
		advance(state);
		state.sawImportCall = true;
		return Result.ok(createNode(NodeKind.Identifier, { name: "import" }, token));
	}

	if (token.kind == TokenKind.Ident ||
		token.kind == TokenKind.This ||
		token.kind == TokenKind.Super) {
		advance(state);
		return Result.ok(createNode(NodeKind.Identifier, { name: token.value }, token));
	}

	// Arrow function or parenthesized expression
	if (token.kind == TokenKind.LParen) {
		const shape = arrowShape(state);
		if (shape == ArrowShape.Yes) {
			return parseArrowFunction(state, parseExprWithPrec, parseBlockStmt, "");
		}
		if (shape == ArrowShape.Maybe) {
			const arrow = tryParseArrowFunction(state, parseExprWithPrec, parseBlockStmt, "", allowArrowReturnType);
			if (!arrow.ok || arrow.value != null) return arrow;
		}
		advance(state);
		const expr = try parseExprWithPrec(state, 0);
		expectCloser(state, token, TokenKind.RParen);
		expr.flags = expr.flags.incl(NodeFlag.Parenthesized);
		return Result.ok(expr);
	}

	// Try expression: try expr [catch defaultValue]
	if (token.kind == TokenKind.Try) {
		advance(state);
		// Parse full expression (not just primary) so try f(x) → TryExpr(CallExpr(f, [x]))
		const arg = try parseExprWithPrec(state, 0);
		if (!isAtEnd(state) && current(state).kind == TokenKind.Catch) {
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
	// Only if '(' ... ')' is followed by '{' — otherwise 'match' is used as identifier
	if (token.kind == TokenKind.Match) {
		if (parenGroupThen(state, 1, TokenKind.LBrace)) {
			return parseMatchExpr(state, parseExprWithPrec, parseBlockStmt);
		}
		advance(state);
		return Result.ok(createNode(NodeKind.Identifier, { name: token.value }, token));
	}

	// typeof / void / delete prefix operators. Operand = postfix chain but no
	// binary op (99 > max binary prec 65): `typeof s.width === "x"` parses as
	// `(typeof (s.width)) === "x"`, `delete obj.prop` reaches the member.
	if (token.kind == TokenKind.Typeof || token.kind == TokenKind.Void || token.kind == TokenKind.Delete) {
		advance(state);
		const operand = try parseExprWithPrec(state, 99);
		return Result.ok(prefixed(operand, (inner: Node): Node => {
			return createNode(NodeKind.UnaryExpr, { unaryOp: token.value, operand: inner }, token);
		}));
	}

	// new expression: new Callee(args)
	if (token.kind == TokenKind.New) {
		advance(state);
		let callee = try parsePrimary(state);
		// Handle member access: new A.B(args)
		while (!isAtEnd(state) && current(state).kind == TokenKind.Dot) {
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
		if (!isAtEnd(state) && current(state).kind == TokenKind.Lt) {
			if (isGenericCallAhead(state)) {
				const typeArgs = captureGenericTypeArgs(state);
				if (typeArgs != "") {
					newTypeArg = typeArgs;
				}
			}
		}
		// Parse arguments if present
		const args: Node[] = [];
		if (!isAtEnd(state) && current(state).kind == TokenKind.LParen) {
			const lparen = advance(state);
			const argList = try parseExprList(state, lparen, TokenKind.RParen, parseExprWithPrec);
			const newNode = createNode(NodeKind.NewExpr, { newCallee: callee, newArguments: argList }, token);
			newNode.comments = takeListEndComments();
			if (newTypeArg != "") newNode.typeArg = newTypeArg;
			return Result.ok(newNode);
		}
		const newNode2 = createNode(NodeKind.NewExpr, { newCallee: callee, newArguments: args }, token);
		if (newTypeArg != "") newNode2.typeArg = newTypeArg;
		return Result.ok(newNode2);
	}

	// Await expression: await expr (unary precedence — same as !, -, ~)
	// `await a + await b` → `(await a) + (await b)`, not `await (a + await b)`
	if (token.kind == TokenKind.Await) {
		advance(state);
		const awaitOperand = try parseExprWithPrec(state, 70);
		return Result.ok(prefixed(awaitOperand, (inner: Node): Node => {
			return createNode(NodeKind.AwaitExpr, { awaitArg: inner }, token);
		}));
	}

	// Yield expression: yield expr, yield* expr
	if (token.kind == TokenKind.Yield) {
		advance(state);
		let delegate = false;
		if (!isAtEnd(state) && current(state).kind == TokenKind.Star) {
			delegate = true;
			advance(state);
		}
		const yieldOperand = try parseExprWithPrec(state, 0);
		return Result.ok(createNode(NodeKind.YieldExpr, { yieldArg: yieldOperand, isDelegate: delegate }, token));
	}

	// Move expression: move x, move x.field, move arr[i]
	if (token.kind == TokenKind.Move && !continuesIdentifier(peek(state, 1))) {
		advance(state);
		const moveOperand = try parseExprWithPrec(state, 0);
		return Result.ok(createNode(NodeKind.MoveExpr, { moveArg: moveOperand }, token));
	}

	// Sizeof expression: sizeof Type
	if (token.kind == TokenKind.Sizeof) {
		advance(state);
		const sStart = state.position;
		skipTypeAnnotation(state);
		const sEnd = state.position;
		const sizeofType = collectTokenText(state, sStart, sEnd);
		if (sizeofType == "") {
			return Result.err(`Expected type after sizeof at line ${token.line}`);
		}
		return Result.ok(createNode(NodeKind.SizeofExpr, { sizeofType }, token));
	}

	// Out expression: out x — keyword only when followed by an identifier-like token.
	// Otherwise 'out' is treated as a variable name (falls through to identifier handler below).
	if (token.kind == TokenKind.Out && isIdentLike(peek(state, 1))) {
		advance(state);
		const outOperand = try parsePrimary(state);
		return Result.ok(createNode(NodeKind.OutExpr, { outArg: outOperand }, token));
	}

	// Prefix increment/decrement: ++x, --x. Operand = postfix chain, no binary
	// op, same as typeof: `++a[i]` and `--o.n` reach the element / member.
	if (token.kind == TokenKind.PlusPlus || token.kind == TokenKind.MinusMinus) {
		advance(state);
		const updateTarget = try parseExprWithPrec(state, 99);
		const wrapUpdate = (inner: Node): Node => {
			return createNode(NodeKind.UpdateExpr, { updateOp: token.value, updateArg: inner, isPrefix: true }, token);
		};
		return Result.ok(prefixed(updateTarget, wrapUpdate));
	}

	// Async: async function expr or async arrow
	if (token.kind == TokenKind.Async) {
		// async function expression: async function() {} or async function*() {}
		if (peek(state, 1).kind == TokenKind.Function) {
			advance(state); // consume 'async'
			advance(state); // consume 'function'
			let feFlags = "async";
			if (!isAtEnd(state) && current(state).kind == TokenKind.Star) {
				feFlags = "async_generator";
				advance(state);
			}
			return parseFuncExprBody(state, token, feFlags);
		}
		// async bare-ident arrow: async x => ... (same noBareArrow restriction
		// as the plain bare-ident arrow above — match-guard `=>` ownership)
		if (isIdentLike(peek(state, 1)) && peek(state, 2).kind == TokenKind.Arrow && state.noBareArrow == 0) {
			advance(state); // consume 'async'
			return parseBareIdentArrow(state, parseExprWithPrec, parseBlockStmt, "async", allowArrowReturnType);
		}
		// async arrow: async () => ... or async (x) => ...; `async(x)` alone is a call
		if (peek(state, 1).kind == TokenKind.LParen) {
			advance(state); // consume 'async'
			const shape = arrowShape(state);
			if (shape == ArrowShape.Yes) {
				return parseArrowFunction(state, parseExprWithPrec, parseBlockStmt, "async");
			}
			if (shape == ArrowShape.Maybe) {
				const arrow = tryParseArrowFunction(state, parseExprWithPrec, parseBlockStmt, "async", allowArrowReturnType);
				if (!arrow.ok || arrow.value != null) return arrow;
			}
			return Result.ok(createNode(NodeKind.Identifier, { name: token.value }, token));
		}
		// Otherwise treat 'async' as identifier
		advance(state);
		return Result.ok(createNode(NodeKind.Identifier, { name: token.value }, token));
	}

	// Function expression: function() {} or function name() {} or function*() {}
	if (token.kind == TokenKind.Function) {
		advance(state);
		let feFlags = "";
		if (!isAtEnd(state) && current(state).kind == TokenKind.Star) {
			feFlags = "generator";
			advance(state);
		}
		return parseFuncExprBody(state, token, feFlags);
	}

	// Comptime expression: @comptime { ... }
	if (token.kind == TokenKind.At) {
		if (peek(state, 1).value == "comptime") {
			advance(state); // consume '@'
			advance(state); // consume 'comptime'
			const comptimeBlock = try parseBlockStmt(state);
			return Result.ok(createNode(NodeKind.ComptimeBlock, { comptimeBody: comptimeBlock }, token));
		}
	}

	// Quote expression: quote { ... }
	// Only if followed by '{' — otherwise 'quote' is used as identifier
	if (token.kind == TokenKind.Quote) {
		if (peek(state, 1).kind == TokenKind.LBrace) {
			advance(state);
			const quoteBlock = try parseBlockStmt(state);
			return Result.ok(createNode(NodeKind.QuoteExpr, { quoteBody: quoteBlock }, token));
		}
		advance(state);
		return Result.ok(createNode(NodeKind.Identifier, { name: token.value }, token));
	}

	// Quote interpolation: ${ expr } → desugared to splice(expr) call.
	// The preprocessor in expand.ms handles splice() calls inside quote
	// bodies. Outside quote, splice is undefined → checker error.
	if (token.kind == TokenKind.QuoteInterp) {
		advance(state);
		const spliceExpr = try parseExpressionFromState(state);
		if (!isAtEnd(state) && current(state).kind == TokenKind.RBrace) {
			advance(state);
		}
		const spliceCallee = createNode(NodeKind.Identifier, { name: "splice" }, token);
		const spliceCall = createNode(NodeKind.CallExpr, {
			callee: spliceCallee, arguments: [spliceExpr],
			isDirectCall: true, resolvedOverloadIdx: -1,
		}, token);
		spliceCall.flags = spliceCall.flags.incl(NodeFlag.QuoteSplice);
		return Result.ok(spliceCall);
	}

	// Spread: ...expr
	if (token.kind == TokenKind.DotDotDot) {
		advance(state);
		const spreadOperand = try parseExprWithPrec(state, 0);
		return Result.ok(createNode(NodeKind.SpreadExpr, { spreadArg: spreadOperand }, token));
	}

	// Unary prefix operators
	if (token.kind == TokenKind.Minus || token.kind == TokenKind.Bang || token.kind == TokenKind.Tilde) {
		advance(state);
		// Parse operand with high precedence to capture postfix (., (), []) but not binary ops.
		// This ensures !result.ok → !(result.ok), not (!result).ok
		const operand = try parseExprWithPrec(state, 70);
		return Result.ok(prefixed(operand, (inner: Node): Node => {
			return createNode(NodeKind.UnaryExpr, { unaryOp: token.value, operand: inner }, token);
		}));
	}

	// Array literal: [expr, expr, ...]
	if (token.kind == TokenKind.LBracket) {
		advance(state);
		const elems = try parseExprList(state, token, TokenKind.RBracket, parseExprWithPrec);
		const arrayNode = createNode(NodeKind.ArrayLiteral, { elements: elems }, token);
		arrayNode.comments = takeListEndComments();
		return Result.ok(arrayNode);
	}

	// Object literal: { key: value, ... } or { key, ... } (shorthand)
	if (token.kind == TokenKind.LBrace) {
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
test "number kind" { assert exprKind("42") == NodeKind.NumberLiteral; }

test "string kind" { assert exprKind("\"hi\"") == NodeKind.StringLiteral; }

test "ident kind" { assert exprKind("x") == NodeKind.Identifier; }

test "binary kind" { assert exprKind("a + b") == NodeKind.BinaryExpr; }

test "unary kind" { assert exprKind("-x") == NodeKind.UnaryExpr; }

test "call kind" { assert exprKind("f()") == NodeKind.CallExpr; }

test "member kind" { assert exprKind("a.b") == NodeKind.MemberExpr; }

test "index kind" { assert exprKind("a[0]") == NodeKind.ArrayAccess; }

test "array kind" { assert exprKind("[1]") == NodeKind.ArrayLiteral; }

test "ternary kind" { assert exprKind("a ? b : c") == NodeKind.ConditionalExpr; }

test "new kind" { assert exprKind("new X()") == NodeKind.NewExpr; }

test "spread kind" { assert exprKind("...x") == NodeKind.SpreadExpr; }

test "try kind" { assert exprKind("try x") == NodeKind.TryExpr; }

test "as kind" { assert exprKind("x as number") == NodeKind.TypeAssertion; }

test "true kind" { assert exprKind("true") == NodeKind.BooleanLiteral; }

test "false kind" { assert exprKind("false") == NodeKind.BooleanLiteral; }

test "null kind" { assert exprKind("null") == NodeKind.NullLiteral; }

test "bigint kind" { assert exprKind("123n") == NodeKind.BigIntLiteral; }

test "regex kind" { assert exprKind("/abc/g") == NodeKind.RegexLiteral; }

test "update kind" { assert exprKind("x++") == NodeKind.UpdateExpr; }

test "await kind" { assert exprKind("await p") == NodeKind.AwaitExpr; }

test "move kind" { assert exprKind("move x") == NodeKind.MoveExpr; }

test "yield kind" { assert exprKind("yield x") == NodeKind.YieldExpr; }

test "out kind" { assert exprKind("out x") == NodeKind.OutExpr; }

test "sizeof kind" { assert exprKind("sizeof int32") == NodeKind.SizeofExpr; }

test "quote kind" { assert exprKind("quote { const x = 1; }") == NodeKind.QuoteExpr; }

test "quote body is block" {
	const d = exprNode("quote { const x = 1; }").data as QuoteExprData;
	assert d.quoteBody.kind == NodeKind.BlockStmt;
}

test "quote multi ok" { assert parseOk("quote { const x = 1; const y = 2; }"); }

test "quote multi stmt" {
	const d = exprNode("quote { const x = 1; const y = 2; }").data as QuoteExprData;
	const block = d.quoteBody.data as BlockStmtData;
	assert block.statements.length == 2;
}

test "func expr kind" { assert exprKind("function() {}") == NodeKind.FunctionExpr; }

test "generator func expr" { assert exprKind("function*() {}") == NodeKind.FunctionExpr; }

test "async func expr" { assert exprKind("async function() {}") == NodeKind.FunctionExpr; }

test "async arrow kind" { assert exprKind("async () => 42") == NodeKind.ArrowFunction; }
// Operator extraction
test "+ op" { assert exprOp("a + b") == "+"; }

test "=== op" { assert exprOp("a === b") == "==="; }

test "&& op" { assert exprOp("a && b") == "&&"; }

test "?? op" { assert exprOp("a ?? b") == "??"; }

test "unary - op" { assert exprOp("-x") == "-"; }

test "unary ! op" { assert exprOp("!x") == "!"; }

test "pre++ op" { assert exprOp("++x") == "++"; }
test "prefix update reaches the element" {
	const d = exprNode("++a[1]").data as UpdateExprData;
	assert d.isPrefix;
	assert d.updateArg.kind == NodeKind.ArrayAccess;
}
test "prefix update reaches the member" {
	const d = exprNode("--o.n").data as UpdateExprData;
	assert d.updateArg.kind == NodeKind.MemberExpr;
}
test "prefix update binds inside as" {
	const n = exprNode("++x as int32");
	assert n.kind == NodeKind.TypeAssertion;
	assert (n.data as TypeAssertionData).asExpr.kind == NodeKind.UpdateExpr;
}

test "typeof op" { assert exprOp("typeof x") == "typeof"; }

test "typeof member operand stops before binary" {
	assert binLeftKind("typeof s.width === \"string\"") == NodeKind.UnaryExpr;
}

test "typeof operand is full member chain" {
	const n = exprNode("typeof s.width");
	assert n.kind == NodeKind.UnaryExpr;
	const d = n.data as UnaryExprData;
	assert d.operand.kind == NodeKind.MemberExpr;
}

test "delete operand reaches member" {
	const n = exprNode("delete obj.prop");
	assert n.kind == NodeKind.UnaryExpr;
	const d = n.data as UnaryExprData;
	assert d.operand.kind == NodeKind.MemberExpr;
}

test "typeof x as T binds as outside" {
	const n = exprNode("typeof x as string");
	assert n.kind == NodeKind.TypeAssertion;
	const d = n.data as TypeAssertionData;
	assert d.asExpr.kind == NodeKind.UnaryExpr;
}

function shapeOf(n: Node): string {
	const mark = n.flags.has(NodeFlag.Parenthesized) ? "p:" : "";
	if (n.kind == NodeKind.TypeAssertion) {
		const d = n.data as TypeAssertionData;
		return mark + (d.asType == "!" ? "nn(" : "as[" + d.asType + "](") + shapeOf(d.asExpr) + ")";
	}
	if (n.kind == NodeKind.UnaryExpr) {
		const d = n.data as UnaryExprData;
		return mark + d.unaryOp + "(" + shapeOf(d.operand) + ")";
	}
	if (n.kind == NodeKind.UpdateExpr) {
		const d = n.data as UpdateExprData;
		return mark + d.updateOp + "(" + shapeOf(d.updateArg) + ")";
	}
	if (n.kind == NodeKind.AwaitExpr) return mark + "await(" + shapeOf((n.data as AwaitExprData).awaitArg) + ")";
	if (n.kind == NodeKind.MemberExpr) {
		const d = n.data as MemberExprData;
		return mark + shapeOf(d.object) + "." + d.property;
	}
	if (n.kind == NodeKind.Identifier) return mark + (n.data as IdentifierData).name;
	if (n.kind == NodeKind.NumberLiteral) return mark + `${(n.data as NumberLiteralData).value}`;
	return mark + "?";
}

function shape(input: string): string { return shapeOf(exprNode(input)); }

test "every prefix operator binds inside as, as in TS" {
	assert shape("-128 as int8") == "as[int8](-(128))";
	assert shape("-x as uint8") == "as[uint8](-(x))";
	assert shape("!b as boolean") == "as[boolean](!(b))";
	assert shape("~x as uint32") == "as[uint32](~(x))";
	assert shape("await p as T") == "as[T](await(p))";
	assert shape("void x as T") == "as[T](void(x))";
	assert shape("--x as int32") == "as[int32](--(x))";
}

test "a prefix operator reaches the innermost as of a chain" {
	assert shape("-x as T as U") == "as[U](as[T](-(x)))";
	assert shape("-a.b as T") == "as[T](-(a.b))";
	assert shape("-(x) as T") == "as[T](-(p:x))";
}

test "parentheses keep an as inside the prefix operator" {
	assert shape("-(x as T)") == "-(p:as[T](x))";
	assert shape("typeof (x as T)") == "typeof(p:as[T](x))";
	assert shape("-(x as T) as U") == "as[U](-(p:as[T](x)))";
}

test "a non-null assertion binds tighter than a prefix operator" {
	assert shape("-a!") == "-(nn(a))";
	assert shape("-a! as T") == "as[T](-(nn(a)))";
	assert shape("typeof a! as T") == "as[T](typeof(nn(a)))";
	assert shape("(-a as T)!") == "nn(p:as[T](-(a)))";
}
test "as binds at relational precedence, left to right" {
	for (const src of ["a ** b as T", "a * b as T", "a + b as T", "a << b as T", "a < b as T", "a in b as T"]) {
		const n = exprNode(src);
		assert n.kind == NodeKind.TypeAssertion, src;
		assert (n.data as TypeAssertionData).asExpr.kind == NodeKind.BinaryExpr, src;
	}
	for (const src of ["a == b as T", "a & b as T", "a && b as T", "a ?? b as T", "a = b as T"]) {
		const n = exprNode(src);
		assert n.kind == NodeKind.BinaryExpr, src;
		assert (n.data as BinaryExprData).right.kind == NodeKind.TypeAssertion, src;
	}
	assert binLeftKind("a as T * b") == NodeKind.TypeAssertion;
	assert binLeftKind("a as Box<int32> < b") == NodeKind.TypeAssertion;
}

test "after a + b as T, an operator that would have taken b ends the expression" {
	for (const src of ["a + b as T * c", "a < b as T + c", "a + b as T ** c"]) {
		assert exprNode(src).kind == NodeKind.TypeAssertion, src;
	}
	assert exprKind("a * b as T + c") == NodeKind.BinaryExpr;
}

// Precedence tree shape
test "* tighter than +" { assert binLeftKind("a + b * c") == NodeKind.Identifier; }

test "+ left-assoc" { assert binLeftKind("a + b + c") == NodeKind.BinaryExpr; }

test "* in + left" { assert binLeftKind("a * b + c") == NodeKind.BinaryExpr; }

test "&& tighter than ||" { assert binLeftKind("a || b && c") == NodeKind.Identifier; }

// --- Smoke: each tests a distinct parser path not covered by structural tests ---
// Postfix combinations
test "member call" { assert parseOk("a.b(c)"); }

test "call member" { assert parseOk("a(b).c"); }

test "optional chain" { assert parseOk("a?.b?.c"); }
// Parenthesized
test "parens" { assert parseOk("(a + b) * c"); }
// Right-associative
test "** right assoc" { assert parseOk("a ** b ** c"); }

test "**= binds loosest" { assert exprOp("a **= b ** 2") == "**="; }

test "assign right assoc" { assert parseOk("a = b = c"); }

test "bitwise compound assignments bind loosest" {
	assert exprOp("a |= b | c") == "|=";
	assert exprOp("a &= b & c") == "&=";
	assert exprOp("a ^= b ^ c") == "^=";
	assert exprOp("a <<= b + 1") == "<<=";
	assert exprOp("a >>= b >> 1") == ">>=";
	assert exprOp("a >>>= b >>> 1") == ">>>=";
	assert binLeftKind("a |= b |= c") == NodeKind.Identifier;
}
// Compound expressions
test "complex mixed" { assert parseOk("f(a).b + g(c).d"); }

test "nested arrays" { assert parseOk("[[1], [2]][0]"); }
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
test "delete" { assert parseOk("delete obj.x"); }

test "void" { assert parseOk("void 0"); }

test "lone operator" { assert !parseOk("+"); }

test "empty string" { assert !parseOk(""); }

test "match without a block after its parens is a call" { assert exprKind("match(1)") == NodeKind.CallExpr; }

test "async without an arrow after its parens is a call" { assert exprKind("async(1)") == NodeKind.CallExpr; }

test "move before a member access is a name" { assert exprKind("move.x") == NodeKind.MemberExpr; }

test "comparisons around a parenthesized operand are not a generic call" {
	assert exprOp("b < (x) && a > (y)") == "&&";
	assert exprOp("b < x && a > (y)") == "&&";
	assert exprOp("b < (0 as int32) || a > (5 as int32)") == "||";
}

test "explicit type arguments before a call stay a call" {
	assert exprKind("id<int32>(x)") == NodeKind.CallExpr;
	assert exprKind("id<Array<int32>>(x)") == NodeKind.CallExpr;
	assert exprKind("id<Map<string, Array<int32>>>(x)") == NodeKind.CallExpr;
	assert exprKind("id<int32 | string>(x)") == NodeKind.CallExpr;
}

test "a comment after async leaves an async function expression" {
	assert exprKind("async /* c */ function() {}") == NodeKind.FunctionExpr;
	assert exprKind("async // c\nfunction() {}") == NodeKind.FunctionExpr;
}

test "a comment between @ and comptime leaves a comptime block" {
	assert exprKind("@ /* c */ comptime { 1; }") == NodeKind.ComptimeBlock;
	assert exprKind("@ // c\ncomptime { 1; }") == NodeKind.ComptimeBlock;
}

test "a comment between quote and its brace leaves a quote expression" {
	assert exprKind("quote /* c */ { const x = 1; }") == NodeKind.QuoteExpr;
	assert exprKind("quote // c\n{ const x = 1; }") == NodeKind.QuoteExpr;
}
