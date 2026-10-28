// Parser cursor - the token stream, comments, errors, recovery and speculation marks

import { Token, TokenKind, tokenKindToString } from "../lexer/token";
import { lex } from "../lexer/lexer";
import { Node } from "../ast/node";

// ===== Parser State =====

export class ParserState {
	tokens: Token[];
	position: int32;
	errors: string[];
	panicMode: boolean;
	pendingTypeArg: string; // Captured <T> type arg waiting to be consumed by next CallExpr
	// Restricted production (like JS's NoIn): >0 while parsing a match-case
	// `when` guard, where a bare `ident =>` must NOT start an arrow function —
	// that `=>` belongs to the match arm. Parenthesized arrows still parse.
	noBareArrow: int32;
	// >0 only between a conditional's `?` and the next expression parse, which reads
	// and clears it: the true arm and what it inherits may not take `(x): T =>` unless a
	// `:` follows the arrow, because that `:` ends the conditional.
	noArrowReturnType: int32;
	trailingDecls: Node[];
	splits: TokenSplit[];
	sawImportCall: boolean;
}

export interface TokenSplit {
	position: int32;
	original: Token;
}

export function createState(tokens: Token[]): ParserState {
	return { tokens, position: 0, errors: [], panicMode: false, pendingTypeArg: "", noBareArrow: 0, noArrowReturnType: 0, trailingDecls: [], splits: [], sawImportCall: false };
}

export interface ParserMark {
	position: int32;
	errorCount: int32;
	panicMode: boolean;
	pendingTypeArg: string;
	noBareArrow: int32;
	noArrowReturnType: int32;
	trailingDeclCount: int32;
	splitCount: int32;
}

export function markState(state: ParserState): ParserMark {
	return {
		position: state.position,
		errorCount: state.errors.length,
		panicMode: state.panicMode,
		pendingTypeArg: state.pendingTypeArg,
		noBareArrow: state.noBareArrow,
		noArrowReturnType: state.noArrowReturnType,
		trailingDeclCount: state.trailingDecls.length,
		splitCount: state.splits.length,
	};
}

export function rewindState(state: ParserState, mark: ParserMark): void {
	state.position = mark.position;
	while (state.errors.length > mark.errorCount) state.errors.pop();
	state.panicMode = mark.panicMode;
	state.pendingTypeArg = mark.pendingTypeArg;
	state.noBareArrow = mark.noBareArrow;
	state.noArrowReturnType = mark.noArrowReturnType;
	while (state.trailingDecls.length > mark.trailingDeclCount) state.trailingDecls.pop();
	while (state.splits.length > mark.splitCount) {
		const split = state.splits.pop()!;
		state.tokens.splice(split.position, 2, split.original);
	}
}

export function takeTrailingDecls(state: ParserState, mark: int32): Node[] {
	const taken: Node[] = [];
	for (let i = mark; i < state.trailingDecls.length; i += 1) taken.push(state.trailingDecls[i]);
	while (state.trailingDecls.length > mark) state.trailingDecls.pop();
	return taken;
}

// Ends a node where the lexer recorded that `token` ends; a node that starts past it is empty and ends where it starts.
export function finishToken(node: Node, token: Token): Node {
	const empty = token.endLine < node.location.line || (token.endLine == node.location.line && token.endColumn < node.location.column);
	node.location.endLine = empty ? node.location.line : token.endLine;
	node.location.endColumn = empty ? node.location.column : token.endColumn;
	return node;
}

// Ends a node at the last token consumed, not counting comments the cursor stepped over; call once the node is fully parsed, and again if it grows.
// A node that consumed nothing past its own start is empty: it ends where it starts.
export function finishNode(state: ParserState, node: Node): Node {
	let last = state.position - 1;
	while (last >= 0 && state.tokens[last].kind == TokenKind.Comment) last -= 1;
	if (last < 0) return finishToken(node, { kind: TokenKind.Eof, value: "", line: node.location.line, column: node.location.column, endLine: node.location.line, endColumn: node.location.column, rawValue: "" });
	return finishToken(node, state.tokens[last]);
}

// Ends a node its callee left open; a node the callee already ended keeps that end.
export function finishOnce(state: ParserState, node: Node): Node {
	return node.location.endLine == 0 ? finishNode(state, node) : node;
}

// Ends a node where its last child ends, for a node built after the cursor moved past it.
export function finishAfter(node: Node, last: Node): Node {
	node.location.endLine = last.location.endLine;
	node.location.endColumn = last.location.endColumn;
	return node;
}

function eofToken(): Token {
	return { kind: TokenKind.Eof, value: "", line: 0, column: 0, endLine: 0, endColumn: 0, rawValue: "" };
}

// Public helper to get the next non-comment token.
// Transparently skips comments so parser logic remains focused on semantics.
export function current(state: ParserState): Token {
	return tokenAt(state, skipComments(state, state.position));
}

function skipLeadingComments(state: ParserState): void {
	while (state.position < state.tokens.length && state.tokens[state.position].kind == TokenKind.Comment) {
		state.position += 1;
	}
}

export function advance(state: ParserState): Token {
	skipLeadingComments(state);
	if (state.position >= state.tokens.length) return eofToken();
	const token = state.tokens[state.position];
	if (token.kind != TokenKind.Eof) {
		state.position += 1;
	}
	return token;
}

export function isAtEnd(state: ParserState): boolean {
	const pos = skipComments(state, state.position);
	if (pos >= state.tokens.length) return true;
	return state.tokens[pos].kind == TokenKind.Eof;
}

// ===== Lookahead =====

export function skipComments(state: ParserState, from: int32): int32 {
	let pos = from;
	while (pos < state.tokens.length && state.tokens[pos].kind == TokenKind.Comment) pos += 1;
	return pos;
}

export function tokenAt(state: ParserState, pos: int32): Token {
	if (pos < state.tokens.length) return state.tokens[pos];
	if (state.tokens.length == 0) return eofToken();
	return state.tokens[state.tokens.length - 1];
}

// Raw token index of the offset-th non-comment token; a scanner steps on from it with skipComments(pos + 1).
export function peekIndex(state: ParserState, offset: int32): int32 {
	let pos = skipComments(state, state.position);
	for (let n = 0; n < offset && pos < state.tokens.length; n += 1) {
		pos = skipComments(state, pos + 1);
	}
	return pos;
}

export function peek(state: ParserState, offset: int32): Token {
	return tokenAt(state, peekIndex(state, offset));
}

// ===== Error Recovery =====

// Record a parse error. In panic mode, suppress cascading errors.
export function addError(state: ParserState, msg: string): void {
	if (!state.panicMode) {
		state.errors.push(msg);
		state.panicMode = true;
	}
}

function startsStatement(kind: TokenKind): boolean {
	return match (kind) {
		TokenKind.Const | TokenKind.Let | TokenKind.If | TokenKind.While | TokenKind.For
		| TokenKind.Function | TokenKind.Return | TokenKind.Import | TokenKind.Export
		| TokenKind.Class | TokenKind.Enum | TokenKind.Interface | TokenKind.Type
		| TokenKind.Throw | TokenKind.Try | TokenKind.Match | TokenKind.Switch
		| TokenKind.Defer | TokenKind.At | TokenKind.Break | TokenKind.Continue
		| TokenKind.Async => true,
		_ => false,
	};
}

// Skip tokens until a statement boundary to resume parsing after an error.
export function synchronize(state: ParserState): void {
	state.panicMode = false;
	while (!isAtEnd(state)) {
		const kind = current(state).kind;
		if (startsStatement(kind)) return;
		advance(state);
		if (kind == TokenKind.RBrace || kind == TokenKind.Semicolon) return;
	}
}

// ===== Common Helpers =====

function isTypeOperatorKeyword(kind: TokenKind): boolean {
	return kind == TokenKind.Extends || kind == TokenKind.Keyof || kind == TokenKind.Typeof
		|| kind == TokenKind.Infer || kind == TokenKind.Distinct || kind == TokenKind.Readonly;
}

// Collect token text from a raw index range, skipping Comment tokens.
// Used by type annotation capture, as-type, sizeof, alias, default value reconstruction.
export function collectTokenText(state: ParserState, start: int32, end: int32): string {
	let text = "";
	let previous = TokenKind.Eof;
	let depth = 0;
	const extendsDepths: int32[] = [];
	const conditionalDepths: int32[] = [];
	let conditionalOperand = false;
	for (let i = start; i < end; i += 1) {
		const tok = state.tokens[i];
		if (tok.kind == TokenKind.Comment) continue;
		const v = tok.value;
		const opens = v == "(" || v == "[" || v == "{" || v == "<";
		const closes = v == ")" || v == "]" || v == "}" ? 1 : v == ">" ? 1 : v == ">>" ? 2 : v == ">>>" ? 3 : 0;
		if (closes > 0) {
			depth -= closes;
			while (extendsDepths.length > 0 && extendsDepths[extendsDepths.length - 1] > depth) extendsDepths.pop();
			while (conditionalDepths.length > 0 && conditionalDepths[conditionalDepths.length - 1] > depth) conditionalDepths.pop();
		}
		let conditionalOperator = false;
		if (v == "?" && extendsDepths.length > 0 && extendsDepths[extendsDepths.length - 1] == depth) {
			extendsDepths.pop();
			conditionalDepths.push(depth);
			conditionalOperator = true;
		} else if (v == ":" && conditionalDepths.length > 0 && conditionalDepths[conditionalDepths.length - 1] == depth) {
			conditionalDepths.pop();
			conditionalOperator = true;
		}
		// Smart spacing: reproduce original token adjacency for type annotations.
		// No space around brackets [], angles <>, parens (), commas, colons, dots.
		if (text != "") {
			const lastCh = text.byteAt(text.byteLength - 1);
			const noSpaceBefore = !conditionalOperator && !conditionalOperand && (v == "[" || v == "]" || v == ">" || v == ">>" || v == ">>>"
				|| v == ")" || v == "," || v == ";" || v == "." || v == "?" || v == ":"
				|| v == "<" || (v == "(" && previous != TokenKind.Colon));
			const noSpaceAfter = !conditionalOperand && (lastCh == "[".code || lastCh == "<".code || lastCh == "(".code
				|| lastCh == ".".code || lastCh == "?".code);
			const operandOfKeyword = isTypeOperatorKeyword(previous) && (v == "(" || v == "[");
			if (operandOfKeyword || (!noSpaceBefore && !noSpaceAfter)) text = text + " ";
		}
		if (tok.kind == TokenKind.Extends) extendsDepths.push(depth);
		if (opens) depth += 1;
		conditionalOperand = conditionalOperator;
		previous = tok.kind;
		// Preserve quotes on string literal tokens so resolveAnnotation can
		// distinguish string literal union members ("r8unorm") from type names.
		if (tok.kind == TokenKind.String) {
			text = text + "\"" + tok.value + "\"";
		} else {
			text = text + tok.value;
		}
	}
	return text;
}

export function hasPrecedingLineBreak(state: ParserState): boolean {
	let pos = state.position - 1;
	while (pos >= 0 && state.tokens[pos].kind == TokenKind.Comment) pos -= 1;
	return pos < 0 || current(state).line > state.tokens[pos].line;
}

export function consumeSemicolon(state: ParserState): void {
	if (!isAtEnd(state) && current(state).kind == TokenKind.Semicolon) {
		advance(state);
		return;
	}
	if (isAtEnd(state) || current(state).kind == TokenKind.RBrace || hasPrecedingLineBreak(state)) return;
	addError(state, `';' expected before '${current(state).value}' at line ${current(state).line}`);
}

function closerText(close: TokenKind): string {
	return match (close) {
		TokenKind.RParen => ")",
		TokenKind.RBracket => "]",
		TokenKind.RBrace => "}",
		_ => {
			throw new Error(`internal: no closer text for ${tokenKindToString(close)}`);
		},
	};
}

export function expectCloser(state: ParserState, open: Token, close: TokenKind): void {
	if (current(state).kind == close) {
		advance(state);
		return;
	}
	addError(state, `Expected '${closerText(close)}' to close the '${open.value}' opened at line ${open.line}, column ${open.column}`);
}

// Skip balanced delimiter pairs: parens, braces, brackets.
// Consumes the opening token and everything through the matching close.
// Caller must ensure current token is `open` before calling.
export function skipBalanced(state: ParserState, open: TokenKind, close: TokenKind): void {
	if (isAtEnd(state) || current(state).kind != open) { return; }
	advance(state);
	let depth = 1;
	while (!isAtEnd(state) && depth > 0) {
		if (current(state).kind == open) { depth += 1; }
		if (current(state).kind == close) { depth -= 1; }
		if (depth > 0) { advance(state); }
	}
	if (!isAtEnd(state) && current(state).kind == close) { advance(state); }
}

// Raw index of the ')' that closes the '(' counted from raw index `from`, or -1 when Eof or the end comes first.
export function matchingParenIndex(state: ParserState, from: int32): int32 {
	let depth = 0;
	let pos = from;
	while (pos < state.tokens.length) {
		const k = state.tokens[pos].kind;
		if (k == TokenKind.Eof) return -1;
		if (k == TokenKind.LParen) depth += 1;
		if (k == TokenKind.RParen) {
			depth -= 1;
			if (depth == 0) return pos;
		}
		pos = skipComments(state, pos + 1);
	}
	return -1;
}

// Lookahead: the '(' at peek(offset) closes, and the token after its ')' is `follow`.
export function parenGroupThen(state: ParserState, offset: int32, follow: TokenKind): boolean {
	if (peek(state, offset).kind != TokenKind.LParen) return false;
	const close = matchingParenIndex(state, peekIndex(state, offset));
	return close >= 0 && tokenAt(state, skipComments(state, close + 1)).kind == follow;
}

function stateOf(input: string): ParserState {
	const lr = lex(input);
	return createState(lr.ok ? lr.value : []);
}

test "peek skips comments at every offset" {
	const state = stateOf("a /*1*/ /*2*/ ( /*3*/ b // 4\n ) c");
	assert peek(state, 0).value == "a";
	assert peek(state, 1).kind == TokenKind.LParen;
	assert peek(state, 2).value == "b";
	assert peek(state, 3).kind == TokenKind.RParen;
	assert peek(state, 4).value == "c";
	assert peek(state, 5).kind == TokenKind.Eof;
	assert peek(state, 50).kind == TokenKind.Eof;
}

test "peek counts from the current position after advance" {
	const state = stateOf("a /*1*/ b /*2*/ c");
	advance(state);
	assert peek(state, 0).value == "b";
	assert peek(state, 1).value == "c";
}

test "parenGroupThen sees past nested parens and comments" {
	const state = stateOf("x /*c*/ ( (a) /*d*/ , (b) ) /*e*/ => y");
	assert parenGroupThen(state, 1, TokenKind.Arrow);
	assert !parenGroupThen(state, 1, TokenKind.Colon);
	assert !parenGroupThen(state, 0, TokenKind.Arrow);
}
