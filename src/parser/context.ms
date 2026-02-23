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

// ===== Common Helpers =====

// Consume optional trailing semicolon
export function consumeSemicolon(state: ParserState): void {
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}
}

// Skip balanced <...> generic type parameters (e.g., class Foo<T> or extends Bar<T>)
export function skipGenericParams(state: ParserState): void {
	if (isAtEnd(state) || current(state).kind !== TokenKind.Lt) { return; }
	advance(state);
	let depth = 1;
	while (!isAtEnd(state) && depth > 0) {
		if (current(state).kind === TokenKind.Lt) { depth += 1; }
		if (current(state).kind === TokenKind.Gt) { depth -= 1; }
		advance(state);
	}
}

// ===== Pattern Helpers =====

// Skip a destructuring pattern: { ... } or [ ... ] including nesting.
// Used when we need to consume but not store the pattern (param lists, for-of bindings).
export function skipDestructurePattern(state: ParserState): void {
	let depth = 0;
	while (!isAtEnd(state)) {
		if (current(state).kind === TokenKind.LBrace || current(state).kind === TokenKind.LBracket) {
			depth += 1;
		}
		if (current(state).kind === TokenKind.RBrace || current(state).kind === TokenKind.RBracket) {
			depth -= 1;
			advance(state);
			if (depth === 0) { return; }
			continue;
		}
		advance(state);
	}
}
