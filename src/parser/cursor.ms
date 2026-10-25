// Parser cursor - the token stream, comments, errors, recovery and speculation marks

import { Token, TokenKind } from "../lexer/token";
import { lex } from "../lexer/lexer";
import { Node } from "../ast/node";

// ===== Parser State =====

export class ParserState {
	tokens: Token[];
	position: int32;
	errors: string[];
	panicMode: boolean;
	pendingComments: Token[]; // Added for comment preservation
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
	return { tokens, position: 0, errors: [], panicMode: false, pendingComments: [], pendingTypeArg: "", noBareArrow: 0, noArrowReturnType: 0, trailingDecls: [], splits: [], sawImportCall: false };
}

export interface ParserMark {
	position: int32;
	errorCount: int32;
	panicMode: boolean;
	pendingComments: Token[];
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
		pendingComments: state.pendingComments.slice(0),
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
	state.pendingComments = mark.pendingComments;
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

// Stamp a node's end position from the last consumed token (position - 1).
// Call AFTER the node is fully parsed. Safe to call multiple times.
export function stampEnd(state: ParserState, node: Node): void {
	if (node == null || node.location == null) return;
	const prevIdx = state.position - 1;
	if (prevIdx < 0 || prevIdx >= state.tokens.length) return;
	const prev = state.tokens[prevIdx];
	node.location.endLine = prev.line as int32;
	const width = prev.kind == TokenKind.String ? prev.rawValue.byteLength + 2 : prev.value.byteLength;
	node.location.endColumn = (prev.column + width) as int32;
}

function eofToken(): Token {
	return { kind: TokenKind.Eof, value: "", line: 0, column: 0, rawValue: "" };
}

// Public helper to get the next non-comment token.
// Transparently skips comments so parser logic remains focused on semantics.
export function current(state: ParserState): Token {
	return tokenAt(state, skipComments(state, state.position));
}

// Comments are attached to the NEXT non-comment token (leading comments).
function collectLeadingComments(state: ParserState): void {
	while (state.position < state.tokens.length && state.tokens[state.position].kind == TokenKind.Comment) {
		state.pendingComments.push(state.tokens[state.position]);
		state.position += 1;
	}
}

export function advance(state: ParserState): Token {
	collectLeadingComments(state);
	if (state.position >= state.tokens.length) return eofToken();
	const token = state.tokens[state.position];
	if (token.kind != TokenKind.Eof) {
		state.position += 1;
	}
	return token;
}

// Helper to take and clear pending comments (the "Harvest")
// Also collects any comment tokens at the current position that haven't been
// advanced over yet. This ensures comments immediately before a construct
// are attached to it (e.g., leading comments before a function parameter).
export function takePendingComments(state: ParserState): Token[] {
	collectLeadingComments(state);
	const comments: Token[] = [];
	for (const c of state.pendingComments) {
		let seen = false;
		for (const k of comments) {
			if (k.line == c.line && k.column == c.column) seen = true;
		}
		if (!seen) comments.push(c);
	}
	state.pendingComments = [];
	return comments;
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

// Skip tokens until a statement boundary to resume parsing after an error.
export function synchronize(state: ParserState): void {
	state.panicMode = false;
	while (!isAtEnd(state)) {
		const kind = current(state).kind;
		// Statement-starting keywords — resume here
		if (kind == TokenKind.Const || kind == TokenKind.Let ||
			kind == TokenKind.If || kind == TokenKind.While ||
			kind == TokenKind.For || kind == TokenKind.Function ||
			kind == TokenKind.Return || kind == TokenKind.Import ||
			kind == TokenKind.Export || kind == TokenKind.Class ||
			kind == TokenKind.Enum || kind == TokenKind.Interface ||
			kind == TokenKind.Type || kind == TokenKind.Throw ||
			kind == TokenKind.Try || kind == TokenKind.Match ||
			kind == TokenKind.Switch || kind == TokenKind.Defer ||
			kind == TokenKind.At || kind == TokenKind.Break ||
			kind == TokenKind.Continue || kind == TokenKind.Async) {
			return;
		}
		// Closing brace — consume it and resume
		if (kind == TokenKind.RBrace) {
			advance(state);
			return;
		}
		advance(state);
		// Past semicolon — resume on next token
		if (kind == TokenKind.Semicolon) { return; }
	}
}

// ===== Common Helpers =====

function isTypeOperatorKeyword(kind: TokenKind): boolean {
	return kind == TokenKind.Extends || kind == TokenKind.Keyof || kind == TokenKind.Typeof
		|| kind == TokenKind.Infer || kind == TokenKind.Distinct;
}

// Collect token text from a raw index range, skipping Comment tokens.
// Used by type annotation capture, as-type, sizeof, alias, default value reconstruction.
export function collectTokenText(state: ParserState, start: int32, end: int32): string {
	let text = "";
	let previous = TokenKind.Eof;
	for (let i = start; i < end; i += 1) {
		const tok = state.tokens[i];
		if (tok.kind == TokenKind.Comment) continue;
		// Smart spacing: reproduce original token adjacency for type annotations.
		// No space around brackets [], angles <>, parens (), commas, colons, dots.
		if (text != "") {
			const lastCh = text.byteAt(text.byteLength - 1);
			const v = tok.value;
			const noSpaceBefore = v == "[" || v == "]" || v == ">" || v == ">>" || v == ">>>"
				|| v == ")" || v == "," || v == "." || v == "?" || v == ":"
				|| v == "<" || v == "(";
			const noSpaceAfter = lastCh == "[".code || lastCh == "<".code || lastCh == "(".code
				|| lastCh == ".".code || lastCh == "?".code;
			const operandOfKeyword = isTypeOperatorKeyword(previous) && (v == "(" || v == "[");
			if (operandOfKeyword || (!noSpaceBefore && !noSpaceAfter)) text = text + " ";
		}
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

function hasPrecedingLineBreak(state: ParserState): boolean {
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

export function expectCloser(state: ParserState, open: Token, close: TokenKind): void {
	if (current(state).kind == close) {
		advance(state);
		return;
	}
	const closeText = match (close) {
		TokenKind.RParen => ")",
		TokenKind.RBracket => "]",
		TokenKind.RBrace => "}",
		_ => `${close}`,
	};
	addError(state, `Expected '${closeText}' to close the '${open.value}' opened at line ${open.line}, column ${open.column}`);
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
