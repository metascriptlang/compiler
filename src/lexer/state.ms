// Lexer State — Token accumulation and source navigation
// Pattern: ~/projects/metascript/src/lexer/lexer.zig (LexerState)

import { Token, TokenKind } from "./token";
import { test, check, testGroup } from "std/testing";

// Type alias avoids Token[] inside Result<> angle brackets (parser ambiguity)
export type Tokens = Token[];

export interface LexerState {
	source: string;
	pos: number;
	line: number;
	column: number;
	tokens: Token[];
}

export function createLexerState(source: string): LexerState {
	return { source, pos: 0, line: 1, column: 1, tokens: [] };
}

export function peek(s: LexerState): number {
	if (s.pos >= s.source.length) return 0;
	return s.source.charCodeAt(s.pos);
}

export function peekAt(s: LexerState, offset: number): number {
	const idx = s.pos + offset;
	if (idx >= s.source.length) return 0;
	return s.source.charCodeAt(idx);
}

export function advanceChar(s: LexerState): number {
	const ch = peek(s);
	s.pos += 1;
	if (ch === "\n".code) {
		s.line += 1;
		s.column = 1;
	} else {
		s.column += 1;
	}
	return ch;
}

export function skip(s: LexerState, n: number): void {
	for (let i = 0; i < n; i++) {
		advanceChar(s);
	}
}

export function addToken(s: LexerState, kind: TokenKind, value: string, line: number, column: number): void {
	s.tokens.push({ kind, value, line, column });
}

// ===== Tests =====

testGroup("Lexer State", () => {
	test("createLexerState", () => {
		const s = createLexerState("abc");
		check(s.pos === 0);
		check(s.line === 1);
		check(s.column === 1);
		check(s.tokens.length === 0);
	});

	test("peek at start", () => {
		const s = createLexerState("xy");
		check(peek(s) === "x".code);
	});

	test("peek at EOF returns 0", () => {
		const s = createLexerState("");
		check(peek(s) === 0);
	});

	test("peekAt with offset", () => {
		const s = createLexerState("abc");
		check(peekAt(s, 0) === "a".code);
		check(peekAt(s, 1) === "b".code);
		check(peekAt(s, 2) === "c".code);
		check(peekAt(s, 3) === 0);
	});

	test("advanceChar updates pos and column", () => {
		const s = createLexerState("ab");
		const ch = advanceChar(s);
		check(ch === "a".code);
		check(s.pos === 1);
		check(s.column === 2);
		check(s.line === 1);
	});

	test("advanceChar newline updates line", () => {
		const s = createLexerState("\nx");
		advanceChar(s);
		check(s.line === 2);
		check(s.column === 1);
	});

	test("skip advances N chars", () => {
		const s = createLexerState("abcde");
		skip(s, 3);
		check(s.pos === 3);
		check(peek(s) === "d".code);
	});

	test("addToken appends to tokens", () => {
		const s = createLexerState("");
		addToken(s, TokenKind.Number, "42", 1, 1);
		check(s.tokens.length === 1);
		check(s.tokens[0].kind === TokenKind.Number);
		check(s.tokens[0].value === "42");
		check(s.tokens[0].line === 1);
		check(s.tokens[0].column === 1);
	});

	test("line tracking across multiple newlines", () => {
		const s = createLexerState("\n\n\nx");
		skip(s, 3);
		check(s.line === 4);
		check(s.column === 1);
		advanceChar(s);
		check(s.column === 2);
	});
});
