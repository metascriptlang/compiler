// Parser Context - Shared parser state and helpers
// Pattern: ~/projects/metascript/src/parser/context.zig

import { Token, TokenKind } from "../lexer/token";

// ===== Parser State =====

export interface ParserState {
	tokens: Token[];
	position: number;
}

export function createState(tokens: Token[]): ParserState {
	return { tokens, position: 0 };
}

export function current(state: ParserState): Token {
	return state.tokens[state.position];
}

export function advance(state: ParserState): Token {
	const token = current(state);
	state.position += 1;
	return token;
}

export function isAtEnd(state: ParserState): boolean {
	return current(state).kind === TokenKind.Eof;
}

// ===== Lookahead =====

export function peek(state: ParserState, offset: number): Token {
	const idx = state.position + offset;
	if (idx < state.tokens.length) {
		return state.tokens[idx];
	}
	return state.tokens[state.tokens.length - 1];
}

// ===== Expect Helper =====

export function expect(state: ParserState, kind: TokenKind, msg: string): Result<Token, string> {
	const token = current(state);
	if (token.kind !== kind) {
		return Result.err(`${msg} at line ${token.line.toString()}`);
	}
	advance(state);
	return Result.ok(token);
}
