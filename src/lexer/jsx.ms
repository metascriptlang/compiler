// JSX lexer mode — lexer-owned JSX tokenization (docs/JSX-ROADMAP.md "Architecture decision").
//
// MS pre-lexes the whole file, so JSX text (which holds chars illegal as MS tokens, e.g. `'`)
// cannot survive a parser-driven scan. The lexer therefore owns JSX: a mode stack (`jsxStack`)
// plus a `<`-decision driven by `lastToken` (Babel's `beforeExpr`). `scanJsx` is called at the
// top of the main lex loop; it returns true when it fully handled the iteration.

import { LexerState, JsxMode, peek, peekAt, advanceChar, addToken } from "./state";
import { TokenKind } from "./token";
import { isLetter, isDigit, isWhitespace, isNewline } from "./chars";
import { scanString } from "./scanner";

// `<` begins JSX only in expression position. This mirrors Babel's `beforeExpr` flag.
// `Eof` covers start-of-input. Comparison/closing-generic `Gt` deliberately excluded so
// `foo<T>()` and `a < b` stay arithmetic.
function isExprPositionToken(k: TokenKind): boolean {
	return match (k) {
		TokenKind.Eof | TokenKind.Assign
		| TokenKind.PlusEq | TokenKind.MinusEq | TokenKind.StarEq | TokenKind.SlashEq | TokenKind.PercentEq
		| TokenKind.EqEq | TokenKind.EqEqEq | TokenKind.BangEq | TokenKind.BangEqEq
		| TokenKind.AmpAmp | TokenKind.PipePipe | TokenKind.Question | TokenKind.QuestionQuestion
		| TokenKind.Colon | TokenKind.Comma | TokenKind.Semicolon
		| TokenKind.LParen | TokenKind.LBracket | TokenKind.LBrace
		| TokenKind.Arrow | TokenKind.Return | TokenKind.Yield | TokenKind.Case => true,
		_ => false,
	};
}

function isJsxStart(s: LexerState): boolean {
	if (!isExprPositionToken(s.lastToken)) return false;
	const next = peekAt(s, 1);
	return isLetter(next) || next === ">".code;
}

function emitSimple(s: LexerState, kind: TokenKind, val: string): void {
	const ln = s.line;
	const cl = s.column;
	advanceChar(s);
	addToken(s, kind, val, ln, cl);
}

function emitTagStart(s: LexerState): void {
	const ln = s.line;
	const cl = s.column;
	advanceChar(s); // '<'
	addToken(s, TokenKind.JsxTagStart, "<", ln, cl);
	s.jsxStack.push(JsxMode.Tag);
}

function emitClose(s: LexerState): void {
	const ln = s.line;
	const cl = s.column;
	advanceChar(s); // '<'
	advanceChar(s); // '/'
	addToken(s, TokenKind.JsxClose, "</", ln, cl);
	s.jsxStack.push(JsxMode.Closing);
}

function emitBraceOpen(s: LexerState): void {
	emitSimple(s, TokenKind.LBrace, "{");
	s.jsxStack.push(JsxMode.Brace);
}

// Raw text run between tags/braces — emitted verbatim (no trim/collapse). JSX whitespace
// rules are the parser's job, keeping the lexer dumb. Runs break only at ASCII `< { }`, so
// every byteSlice stays on a character boundary (multi-byte UTF-8 safe).
function scanJsxText(s: LexerState): void {
	const startLine = s.line;
	const startCol = s.column;
	const startPos = s.pos;
	// Break only at `<` and `{`. A `}` here is stray (the container's `}` is consumed in Brace
	// mode), so treat it as text — this also guarantees progress (the entry char is never `<`/`{`,
	// so at least one byte is always consumed; no empty-text infinite loop).
	while (s.pos < s.source.byteLength) {
		const ch = peek(s);
		if (ch === "<".code || ch === "{".code) break;
		advanceChar(s);
	}
	const text = s.source.byteSlice(startPos, s.pos);
	addToken(s, TokenKind.JsxText, text, startLine, startCol);
}

// Tag / attribute name. Always an `Ident` (never a keyword — `<label for=…>` is valid) and
// folds hyphens (`data-x`, `aria-label`). Member `.` and namespace `:` are separate tokens.
function scanJsxIdentifier(s: LexerState): void {
	const startLine = s.line;
	const startCol = s.column;
	const startPos = s.pos;
	while (s.pos < s.source.byteLength) {
		const ch = peek(s);
		if (isLetter(ch) || isDigit(ch) || ch === "-".code) { advanceChar(s); }
		else { break; }
	}
	const name = s.source.byteSlice(startPos, s.pos);
	addToken(s, TokenKind.Ident, name, startLine, startCol);
}

function scanJsxChildren(s: LexerState): boolean {
	const ch = peek(s);
	if (ch === "<".code) {
		if (peekAt(s, 1) === "/".code) { emitClose(s); }
		else { emitTagStart(s); }
		return true;
	}
	if (ch === "{".code) { emitBraceOpen(s); return true; }
	scanJsxText(s);
	return true;
}

function scanJsxTag(s: LexerState): boolean {
	const ch = peek(s);
	if (isWhitespace(ch) || isNewline(ch)) { advanceChar(s); return true; }
	if (ch === ">".code) {
		emitSimple(s, TokenKind.Gt, ">");
		s.jsxStack[s.jsxStack.length - 1] = JsxMode.Children;
		return true;
	}
	if (ch === "/".code && peekAt(s, 1) === ">".code) {
		emitSimple(s, TokenKind.Slash, "/");
		emitSimple(s, TokenKind.Gt, ">");
		s.jsxStack.pop();
		return true;
	}
	if (ch === "{".code) { emitBraceOpen(s); return true; }
	if (ch === "=".code) { emitSimple(s, TokenKind.Assign, "="); return true; }
	if (ch === ":".code) { emitSimple(s, TokenKind.Colon, ":"); return true; }
	if (ch === ".".code) { emitSimple(s, TokenKind.Dot, "."); return true; }
	if (ch === "\"".code || ch === "'".code) { scanString(s, ch); return true; }
	if (isLetter(ch)) { scanJsxIdentifier(s); return true; }
	return false;
}

function scanJsxClosing(s: LexerState): boolean {
	const ch = peek(s);
	if (isWhitespace(ch) || isNewline(ch)) { advanceChar(s); return true; }
	if (ch === ">".code) {
		emitSimple(s, TokenKind.Gt, ">");
		s.jsxStack.pop(); // Closing
		if (s.jsxStack.length > 0) { s.jsxStack.pop(); } // the element's Children frame
		return true;
	}
	if (ch === ":".code) { emitSimple(s, TokenKind.Colon, ":"); return true; }
	if (ch === ".".code) { emitSimple(s, TokenKind.Dot, "."); return true; }
	if (isLetter(ch)) { scanJsxIdentifier(s); return true; }
	return false;
}

function scanJsxBrace(s: LexerState): boolean {
	const ch = peek(s);
	if (ch === "<".code && isJsxStart(s)) { emitTagStart(s); return true; }
	if (ch === "{".code) { emitBraceOpen(s); return true; }
	if (ch === "}".code) {
		emitSimple(s, TokenKind.RBrace, "}");
		s.jsxStack.pop();
		return true;
	}
	return false; // normal code — fall through to the main lexer
}

// Main entry: called at the top of the lex loop. Returns true if the iteration was handled.
export function scanJsx(s: LexerState): boolean {
	const n = s.jsxStack.length;
	if (n === 0) {
		if (peek(s) !== "<".code) { return false; }
		if (!isJsxStart(s)) { return false; }
		emitTagStart(s);
		return true;
	}
	const top = s.jsxStack[n - 1];
	if (top === JsxMode.Children) { return scanJsxChildren(s); }
	if (top === JsxMode.Tag) { return scanJsxTag(s); }
	if (top === JsxMode.Closing) { return scanJsxClosing(s); }
	return scanJsxBrace(s);
}
