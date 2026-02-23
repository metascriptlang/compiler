// Parser Context - Shared parser state and helpers
// Pattern: ~/projects/metascript/src/parser/context.zig

import { Token, TokenKind } from "../lexer/token";

// ===== Parser State =====

export interface ParserState {
	tokens: Token[];
	position: number;
	errors: string[];
	panicMode: boolean;
}

export function createState(tokens: Token[]): ParserState {
	return { tokens, position: 0, errors: [], panicMode: false };
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

// ===== Error Recovery =====
// Pattern: ~/projects/metascript/src/parser/parser.zig reportError + synchronize

// Record a parse error. In panic mode, suppress cascading errors.
export function addError(state: ParserState, msg: string): void {
	if (!state.panicMode) {
		state.errors.push(msg);
		state.panicMode = true;
	}
}

// Skip tokens until a statement boundary to resume parsing after an error.
// Pattern: Zig parser.zig:7504-7546
export function synchronize(state: ParserState): void {
	state.panicMode = false;
	while (!isAtEnd(state)) {
		const kind = current(state).kind;
		// Statement-starting keywords — resume here
		if (kind === TokenKind.Const || kind === TokenKind.Let ||
			kind === TokenKind.If || kind === TokenKind.While ||
			kind === TokenKind.For || kind === TokenKind.Function ||
			kind === TokenKind.Return || kind === TokenKind.Import ||
			kind === TokenKind.Export || kind === TokenKind.Class ||
			kind === TokenKind.Enum || kind === TokenKind.Interface ||
			kind === TokenKind.Type || kind === TokenKind.Throw ||
			kind === TokenKind.Try || kind === TokenKind.Match ||
			kind === TokenKind.Switch || kind === TokenKind.Defer ||
			kind === TokenKind.At || kind === TokenKind.Break ||
			kind === TokenKind.Continue || kind === TokenKind.Async) {
			return;
		}
		// Closing brace — consume it and resume
		if (kind === TokenKind.RBrace) {
			advance(state);
			return;
		}
		advance(state);
		// Past semicolon — resume on next token
		if (kind === TokenKind.Semicolon) { return; }
	}
}

// ===== Common Helpers =====

// Consume optional trailing semicolon
export function consumeSemicolon(state: ParserState): void {
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}
}

// Skip balanced delimiter pairs: parens, braces, brackets.
// Consumes the opening token and everything through the matching close.
// Caller must ensure current token is `open` before calling.
export function skipBalanced(state: ParserState, open: TokenKind, close: TokenKind): void {
	if (isAtEnd(state) || current(state).kind !== open) { return; }
	advance(state);
	let depth = 1;
	while (!isAtEnd(state) && depth > 0) {
		if (current(state).kind === open) { depth += 1; }
		if (current(state).kind === close) { depth -= 1; }
		if (depth > 0) { advance(state); }
	}
	if (!isAtEnd(state) && current(state).kind === close) { advance(state); }
}

// Skip balanced <...> generic type parameters (e.g., class Foo<T> or extends Bar<T>)
// Handles >> and >>> for nested generics like Result<Array<number>>
export function skipGenericParams(state: ParserState): void {
	if (isAtEnd(state) || current(state).kind !== TokenKind.Lt) { return; }
	advance(state);
	let depth = 1;
	while (!isAtEnd(state) && depth > 0) {
		if (current(state).kind === TokenKind.Lt) { depth += 1; }
		if (current(state).kind === TokenKind.Gt) { depth -= 1; }
		if (current(state).kind === TokenKind.GtGt) { depth -= 2; }
		if (current(state).kind === TokenKind.GtGtGt) { depth -= 3; }
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
