// Lexer State — Token accumulation and source navigation
// Pattern: ~/projects/metascript/src/lexer/lexer.zig (LexerState)

import { Token, TokenKind } from "./token";

// JSX lexer mode stack frame (docs/JSX-ROADMAP.md "Architecture decision").
// Tag = inside `<… >` opening tag; Children = between `>` and `</`; Closing = inside `</…>`;
// Brace = inside an `{expr}` container (normal code, tracks nesting to know when to pop).
export enum JsxMode { Tag, Children, Closing, Brace }

export interface LexerState {
	source: string;
	pos: int32;
	line: int32;
	column: int32;
	tokens: Token[];
	comments: Token[]; // Added for comment preservation
	templateDepth: int32;
	braceStack: int32[];
	lastToken: TokenKind;
	jsxStack: JsxMode[];
	lexError: string;
}

export function createLexerState(source: string): LexerState {
	return { source, pos: 0, line: 1, column: 1, tokens: [], comments: [], templateDepth: 0, braceStack: [], lastToken: TokenKind.Eof, jsxStack: [], lexError: "" };
}

export function setLexError(s: LexerState, message: string): void {
	if (s.lexError == "") s.lexError = `${message} at line ${s.line}, column ${s.column}`;
}

export function peek(s: LexerState): int32 {
	if (s.pos >= s.source.byteLength) return 0;
	return s.source.byteAt(s.pos);
}

export function peekAt(s: LexerState, offset: int32): int32 {
	const idx = s.pos + offset;
	if (idx >= s.source.byteLength) return 0;
	return s.source.byteAt(idx);
}

export function advanceChar(s: LexerState): int32 {
	const ch = peek(s);
	s.pos += 1;
	if (ch == "\n".code) {
		s.line += 1;
		s.column = 1;
	} else {
		s.column += 1;
	}
	return ch;
}

export function skip(s: LexerState, n: int32): void {
	for (let i = 0; i < n; i++) {
		advanceChar(s);
	}
}

export function addToken(s: LexerState, kind: TokenKind, value: string, line: int32, column: int32): Token {
	const tok: Token = { kind, value, line, column, rawValue: "" };
	s.tokens.push(tok);
	s.lastToken = kind;
	return tok;
}

// Comment preservation: push to tokens array (parser skips via TokenKind.Comment check).
// Note: do NOT also push to s.comments — that creates shared string ownership between
// two arrays. When lex() moves s.tokens out, LexerState_destroy frees s.comments,
// which frees the shared string buffers still referenced by the moved tokens (UAF).
export function addComment(s: LexerState, value: string, line: int32, column: int32): void {
	const tok: Token = { kind: TokenKind.Comment, value, line, column };
	s.tokens.push(tok);
}

export function allowsRegexAfter(s: LexerState): boolean {
	const last = s.lastToken;
	// After operators, punctuation that starts expressions, keywords — regex allowed
	if (last == TokenKind.Assign || last == TokenKind.LParen || last == TokenKind.LBracket ||
		last == TokenKind.LBrace || last == TokenKind.Comma || last == TokenKind.Semicolon ||
		last == TokenKind.Colon || last == TokenKind.Question || last == TokenKind.Bang ||
		last == TokenKind.Tilde || last == TokenKind.Plus || last == TokenKind.Minus ||
		last == TokenKind.Star || last == TokenKind.Percent || last == TokenKind.Amp ||
		last == TokenKind.Pipe || last == TokenKind.Caret || last == TokenKind.EqEq ||
		last == TokenKind.EqEqEq || last == TokenKind.BangEq || last == TokenKind.BangEqEq ||
		last == TokenKind.LtEq || last == TokenKind.Gt || last == TokenKind.GtEq ||
		last == TokenKind.AmpAmp || last == TokenKind.PipePipe || last == TokenKind.PlusEq ||
		last == TokenKind.MinusEq || last == TokenKind.StarEq || last == TokenKind.SlashEq ||
		last == TokenKind.Arrow || last == TokenKind.Eof || last == TokenKind.Return ||
		last == TokenKind.Case || last == TokenKind.Delete || last == TokenKind.In ||
		last == TokenKind.Instanceof || last == TokenKind.New || last == TokenKind.Typeof ||
		last == TokenKind.Void || last == TokenKind.If || last == TokenKind.While ||
		last == TokenKind.For || last == TokenKind.Await || last == TokenKind.Yield) {
		return true;
	}
	// After values, identifiers, closing brackets — expect division, not regex
	return false;
}

// ===== Tests =====
test "createLexerState" {
	const s = createLexerState("abc");
	assert s.pos == 0;
	assert s.line == 1;
	assert s.column == 1;
	assert s.tokens.length == 0;
	assert s.comments.length == 0;
}

test "peek at start" {
	const s = createLexerState("xy");
	assert peek(s) == "x".code;
}

test "peek at EOF returns 0" {
	const s = createLexerState("");
	assert peek(s) == 0;
}

test "peekAt with offset" {
	const s = createLexerState("abc");
	assert peekAt(s, 0) == "a".code;
	assert peekAt(s, 1) == "b".code;
	assert peekAt(s, 2) == "c".code;
	assert peekAt(s, 3) == 0;
}

test "advanceChar updates pos and column" {
	const s = createLexerState("ab");
	const ch = advanceChar(s);
	assert ch == "a".code;
	assert s.pos == 1;
	assert s.column == 2;
	assert s.line == 1;
}

test "advanceChar newline updates line" {
	const s = createLexerState("\nx");
	advanceChar(s);
	assert s.line == 2;
	assert s.column == 1;
}

test "skip advances N chars" {
	const s = createLexerState("abcde");
	skip(s, 3);
	assert s.pos == 3;
	assert peek(s) == "d".code;
}

test "addToken appends to tokens" {
	const s = createLexerState("");
	addToken(s, TokenKind.Number, "42", 1, 1);
	assert s.tokens.length == 1;
	assert s.tokens[0].kind == TokenKind.Number;
	assert s.tokens[0].value == "42";
	assert s.tokens[0].line == 1;
	assert s.tokens[0].column == 1;
}

test "line tracking across multiple newlines" {
	const s = createLexerState("\n\n\nx");
	skip(s, 3);
	assert s.line == 4;
	assert s.column == 1;
	advanceChar(s);
	assert s.column == 2;
}
