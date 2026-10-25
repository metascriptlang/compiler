// Angle-bracket scanning - generic parameter lists and call-site type arguments

import { Token, TokenKind, isIdentLikeKind } from "../lexer/token";
import { lex } from "../lexer/lexer";
import { ParserState, createState, current, advance, peek, peekIndex, tokenAt, skipComments, isAtEnd, addError } from "./cursor";

// Skip balanced <...> generic type parameters (e.g., class Foo<T> or extends Bar<T>)
// Handles >> and >>> for nested generics like Result<Array<number>>
export function skipGenericParams(state: ParserState): void {
	if (isAtEnd(state) || current(state).kind != TokenKind.Lt) { return; }
	const open = current(state);
	advance(state);
	let depth = 1;
	let nest = 0;
	while (depth > 0) {
		splitAngleAssign(state);
		const k = current(state).kind;
		if (isAtEnd(state) || (nest == 0 && (k == TokenKind.Semicolon || k == TokenKind.RParen || k == TokenKind.RBracket || k == TokenKind.RBrace))) {
			addError(state, `Expected '>' to close the type arguments opened at line ${open.line}, column ${open.column}`);
			return;
		}
		if (k == TokenKind.LParen || k == TokenKind.LBracket || k == TokenKind.LBrace) nest += 1;
		if (k == TokenKind.RParen || k == TokenKind.RBracket || k == TokenKind.RBrace) nest -= 1;
		if (k == TokenKind.Lt) { depth += 1; }
		depth -= angleCloserWidth(k);
		advance(state);
	}
}

export function splitAngleAssign(state: ParserState): void {
	const pos = skipComments(state, state.position);
	if (pos >= state.tokens.length) return;
	const tok = state.tokens[pos];
	const closer = match (tok.kind) {
		TokenKind.GtEq => TokenKind.Gt,
		TokenKind.GtGtEq => TokenKind.GtGt,
		TokenKind.GtGtGtEq => TokenKind.GtGtGt,
		_ => TokenKind.Eof,
	};
	if (closer == TokenKind.Eof) return;
	const width = tok.value.byteLength - 1;
	state.tokens[pos] = { kind: closer, value: ">".repeat(width), line: tok.line, column: tok.column, rawValue: "" };
	const assign: Token = { kind: TokenKind.Assign, value: "=", line: tok.line, column: tok.column + width, rawValue: "" };
	state.tokens.splice(pos + 1, 0, assign);
	state.splits.push({ position: pos, original: tok });
}

interface CapturedConstraint {
	text: string;
	closed: int32;
}

function captureConstraint(state: ParserState): CapturedConstraint {
	const parts: string[] = [];
	let nest = 0;
	let union = false;
	let closed = 0;
	while (!isAtEnd(state)) {
		const k = current(state).kind;
		if (nest == 0 && (k == TokenKind.Comma || k == TokenKind.Assign || k == TokenKind.Gt || k == TokenKind.GtGt || k == TokenKind.GtGtGt)) break;
		let value = current(state).value;
		if (k == TokenKind.Lt || k == TokenKind.LParen || k == TokenKind.LBracket || k == TokenKind.LBrace) nest += 1;
		else if (k == TokenKind.Gt || k == TokenKind.RParen || k == TokenKind.RBracket || k == TokenKind.RBrace) nest -= 1;
		else if (k == TokenKind.GtGt || k == TokenKind.GtGtGt) {
			const width = k == TokenKind.GtGt ? 2 : 3;
			if (width > nest) {
				closed = width - nest;
				value = ">".repeat(nest);
			}
			nest -= width - closed;
		}
		if (k == TokenKind.Pipe && nest == 0) union = true;
		parts.push(value);
		advance(state);
		if (closed > 0) break;
	}
	let text = "";
	for (let i = 0; i < parts.length; i += 1) {
		text = i == 0 || parts[i] == "," ? text + parts[i] : text + " " + parts[i];
	}
	return { text: union ? `(${text})` : text, closed: closed };
}

// Capture generic param names: <T, U> → "T,U", no generics → ""
// Same depth-tracking as skipGenericParams but returns names instead of discarding.
export function captureGenericParams(state: ParserState): string {
	if (isAtEnd(state) || current(state).kind != TokenKind.Lt) return "";
	advance(state); // consume <
	let names = "";
	let depth = 1;
	while (!isAtEnd(state) && depth > 0) {
		if (current(state).kind == TokenKind.Const && depth == 1) {
			const constTok = current(state);
			addError(state, `const generic parameter '${peek(state, 1).value}' is not supported: a generic parameter is a type, pass the value as an argument at line ${constTok.line}`);
			advance(state);
			skipGenericParamRest(state);
			continue;
		}
		if (isIdentLikeKind(current(state).kind) && depth == 1) {
			if (names != "") { names = `${names},`; }
			names = `${names}${current(state).value}`;
			advance(state);
			if (!isAtEnd(state) && current(state).kind == TokenKind.Extends && depth == 1) {
				advance(state);
				const constraint = captureConstraint(state);
				if (constraint.text != "") names = `${names}:${constraint.text}`;
				depth -= constraint.closed;
			}
			if (!isAtEnd(state) && current(state).kind == TokenKind.Assign && depth == 1) {
				advance(state);
				skipGenericParamRest(state);
			}
			continue;
		}
		if (current(state).kind == TokenKind.Lt) { depth += 1; }
		if (current(state).kind == TokenKind.Gt) { depth -= 1; }
		if (current(state).kind == TokenKind.GtGt) { depth -= 2; }
		if (current(state).kind == TokenKind.GtGtGt) { depth -= 3; }
		advance(state);
	}
	return names;
}

export function angleCloserWidth(kind: TokenKind): int32 {
	if (kind == TokenKind.Gt) return 1;
	if (kind == TokenKind.GtGt) return 2;
	if (kind == TokenKind.GtGtGt) return 3;
	return 0;
}

// Skip the rest of one generic parameter: up to its `,` or the `>` that closes the list.
function skipGenericParamRest(state: ParserState): void {
	let inner = 0;
	while (!isAtEnd(state)) {
		const kind = current(state).kind;
		if (kind == TokenKind.Comma && inner == 0) return;
		const closers = angleCloserWidth(kind);
		if (closers > inner) return;
		if (kind == TokenKind.Lt) inner += 1;
		inner -= closers;
		advance(state);
	}
}

// Lookahead: the peek offset of the '(' right after the '>' that balances
// this '<', or -1. Does NOT consume tokens — only peeks.
export function genericCallParenOffset(state: ParserState): int32 {
	// Current token should be '<'
	if (isAtEnd(state) || current(state).kind != TokenKind.Lt) return -1;
	let angleDepth = 1;
	let braceDepth = 0;
	let bracketDepth = 0;
	let parenDepth = 0;
	let raw = peekIndex(state, 1);
	for (let pos = 1; pos < 100; pos += 1) {
		const tok = tokenAt(state, raw);
		if (tok.kind == TokenKind.Eof) return -1;
		if (tok.kind == TokenKind.LBrace) { braceDepth += 1; }
		if (tok.kind == TokenKind.RBrace) { braceDepth -= 1; if (braceDepth < 0) return -1; }
		if (tok.kind == TokenKind.LBracket) { bracketDepth += 1; }
		if (tok.kind == TokenKind.RBracket) { bracketDepth -= 1; if (bracketDepth < 0) return -1; }
		if (tok.kind == TokenKind.LParen) { parenDepth += 1; }
		if (tok.kind == TokenKind.RParen) { parenDepth -= 1; if (parenDepth < 0) return -1; }
		// Only count angle brackets at top level (not inside {} [] ())
		if (braceDepth == 0 && bracketDepth == 0 && parenDepth == 0) {
			if (tok.kind == TokenKind.Lt) { angleDepth += 1; }
			angleDepth -= angleCloserWidth(tok.kind);
			if (angleDepth < 0) return -1;
			if (angleDepth == 0) {
				return tokenAt(state, skipComments(state, raw + 1)).kind == TokenKind.LParen ? pos + 1 : -1;
			}
		}
		// Bail on tokens that can't appear in type args
		if (tok.kind == TokenKind.Semicolon) return -1;
		if (tok.kind == TokenKind.Assign) return -1;
		if (tok.kind == TokenKind.GtEq || tok.kind == TokenKind.GtGtEq || tok.kind == TokenKind.GtGtGtEq) return -1;
		raw = skipComments(state, raw + 1);
	}
	return -1;
}

// Capture generic type args at call site: <number, string> → "number,string"
// Unlike captureGenericParams (which captures parameter NAMES like T, U),
// this captures full type expressions (identifiers, keywords, nested generics).
export function captureGenericTypeArgs(state: ParserState): string {
	if (isAtEnd(state) || current(state).kind != TokenKind.Lt) return "";
	advance(state); // consume <
	// Two-pass: first collect token values with separators, then split.
	// Avoid `let str = ""; str = "";` — DRC generates msDecref on struct msString.
	const tokens: string[] = [];
	const depths: int32[] = [];
	let depth = 1;
	while (!isAtEnd(state) && depth > 0) {
		const tok = current(state);
		const closers = angleCloserWidth(tok.kind);
		if (closers == 0) {
			if (tok.kind == TokenKind.Lt) { depth += 1; }
			tokens.push(tok.kind == TokenKind.String ? "\"" + tok.value + "\"" : tok.value);
			depths.push(depth);
		}
		for (let c = 0; c < closers && depth > 0; c += 1) {
			depth -= 1;
			if (depth > 0) {
				tokens.push(">");
				depths.push(depth);
			}
		}
		advance(state);
	}
	// Build comma-separated type args in single pass.
	// Depth-1 commas are arg separators → emit our ",".
	// NEVER reset a string variable to "" — DRC generates msDecref(msString) → void* mismatch.
	let result = "";
	let afterSep = false;
	let argHasTokens = false;
	for (let i = 0; i < tokens.length; i += 1) {
		if (tokens[i] == "," && depths[i] == 1) {
			afterSep = true;
			argHasTokens = false;
		} else {
			if (afterSep) {
				result = result + ",";
				afterSep = false;
			}
			if (argHasTokens && tokens[i] != ",") {
				result = result + " ";
			}
			result = result + tokens[i];
			argHasTokens = true;
		}
	}
	return result;
}

function stateOf(input: string): ParserState {
	const lr = lex(input);
	return createState(lr.ok ? lr.value : []);
}

test "genericCallParenOffset counts offsets without comments" {
	const state = stateOf("< /*c*/ A<B> /*d*/ , C /*e*/ > /*f*/ ( )");
	assert genericCallParenOffset(state) == 8;
	const bad = stateOf("< A ; B > ( )");
	assert genericCallParenOffset(bad) == -1;
}
