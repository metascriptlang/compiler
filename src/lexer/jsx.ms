// JSX lexer mode — lexer-owned JSX tokenization (docs/JSX-ROADMAP.md "Architecture decision").
//
// MS pre-lexes the whole file, so JSX text (which holds chars illegal as MS tokens, e.g. `'`)
// cannot survive a parser-driven scan. The lexer therefore owns JSX: a mode stack (`jsxStack`)
// plus a `<`-decision driven by `lastToken`. `scanJsx` is called at the top of the main lex
// loop; it returns true when it fully handled the iteration.

import { LexerState, JsxMode, peek, peekAt, advanceChar, skip, addToken } from "./state";
import { TokenKind, startsExprAfter } from "./token";
import { isLetter, isDigit, whitespaceWidth } from "./chars";
import { scanString, scanTemplateContinuation } from "./scanner";

// `<` begins JSX only in expression position. `Gt` is deliberately excluded so
// `foo<T>()` and `a < b` stay arithmetic.
function isExprPositionToken(k: TokenKind): boolean {
	return startsExprAfter(k) || k == TokenKind.TemplateHead || k == TokenKind.TemplateMiddle;
}

function isJsxStart(s: LexerState): boolean {
	if (!isExprPositionToken(s.lastToken)) return false;
	const next = peekAt(s, 1);
	return isLetter(next) || next == ">".code;
}

function emitSimple(s: LexerState, kind: TokenKind, val: string): void {
	const ln = s.line;
	const cl = s.column;
	advanceChar(s);
	addToken(s, kind, val, ln, cl);
}

function emitTagStart(s: LexerState): void {
	emitSimple(s, TokenKind.JsxTagStart, "<");
	s.jsxStack.push(JsxMode.Tag);
}

function emitClose(s: LexerState): void {
	const ln = s.line;
	const cl = s.column;
	advanceChar(s);
	advanceChar(s);
	addToken(s, TokenKind.JsxClose, "</", ln, cl);
	s.jsxStack.push(JsxMode.Closing);
}

function emitBraceOpen(s: LexerState): void {
	emitSimple(s, TokenKind.LBrace, "{");
	s.jsxStack.push(JsxMode.Brace);
}

// Raw text run, emitted verbatim — whitespace rules are the consuming macro's job. Breaks only
// at `<`/`{` (a stray `}` is text; the container's `}` is consumed in Brace mode), which also
// guarantees forward progress. Breaks fall on ASCII bytes, so each byteSlice stays on a
// character boundary (multi-byte UTF-8 safe).
function scanJsxText(s: LexerState): void {
	const startLine = s.line;
	const startCol = s.column;
	const startPos = s.pos;
	while (s.pos < s.source.byteLength) {
		const ch = peek(s);
		if (ch == "<".code || ch == "{".code) break;
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
		if (isLetter(ch) || isDigit(ch) || ch == "-".code) { advanceChar(s); }
		else { break; }
	}
	const name = s.source.byteSlice(startPos, s.pos);
	addToken(s, TokenKind.Ident, name, startLine, startCol);
}

function scanJsxChildren(s: LexerState): boolean {
	const ch = peek(s);
	if (ch == "<".code) {
		if (peekAt(s, 1) == "/".code) { emitClose(s); }
		else { emitTagStart(s); }
		return true;
	}
	if (ch == "{".code) { emitBraceOpen(s); return true; }
	scanJsxText(s);
	return true;
}

function scanJsxTag(s: LexerState): boolean {
	const ch = peek(s);
	const whitespace = whitespaceWidth(s.source, s.pos);
	if (whitespace > 0) { skip(s, whitespace); return true; }
	if (ch == ">".code) {
		emitSimple(s, TokenKind.Gt, ">");
		s.jsxStack[s.jsxStack.length - 1] = JsxMode.Children;
		return true;
	}
	if (ch == "/".code && peekAt(s, 1) == ">".code) {
		emitSimple(s, TokenKind.Slash, "/");
		emitSimple(s, TokenKind.Gt, ">");
		s.jsxStack.pop();
		return true;
	}
	if (ch == "{".code) { emitBraceOpen(s); return true; }
	if (ch == "=".code) { emitSimple(s, TokenKind.Assign, "="); return true; }
	if (ch == ":".code) { emitSimple(s, TokenKind.Colon, ":"); return true; }
	if (ch == ".".code) { emitSimple(s, TokenKind.Dot, "."); return true; }
	if (ch == "\"".code || ch == "'".code) { scanString(s, ch); return true; }
	if (isLetter(ch)) { scanJsxIdentifier(s); return true; }
	const opensComment = ch == "/".code && (peekAt(s, 1) == "/".code || peekAt(s, 1) == "*".code);
	if (!opensComment) s.jsxStack.pop();
	return false;
}

function scanJsxClosing(s: LexerState): boolean {
	const ch = peek(s);
	const whitespace = whitespaceWidth(s.source, s.pos);
	if (whitespace > 0) { skip(s, whitespace); return true; }
	if (ch == ">".code) {
		emitSimple(s, TokenKind.Gt, ">");
		// pop the Closing frame and the element's own Children frame beneath it
		s.jsxStack.pop();
		if (s.jsxStack.length > 0) { s.jsxStack.pop(); }
		return true;
	}
	if (ch == ":".code) { emitSimple(s, TokenKind.Colon, ":"); return true; }
	if (ch == ".".code) { emitSimple(s, TokenKind.Dot, "."); return true; }
	if (isLetter(ch)) { scanJsxIdentifier(s); return true; }
	return false;
}

function scanJsxBrace(s: LexerState): boolean {
	const ch = peek(s);
	if (ch == "<".code && isJsxStart(s)) { emitTagStart(s); return true; }
	if (ch == "{".code) { emitBraceOpen(s); return true; }
	if (ch == "}".code) {
		emitSimple(s, TokenKind.RBrace, "}");
		s.jsxStack.pop();
		return true;
	}
	return false;
}

function scanTemplateInterp(s: LexerState): boolean {
	const ch = peek(s);
	if (ch == "<".code && isJsxStart(s)) { emitTagStart(s); return true; }
	if (ch == "{".code) { emitBraceOpen(s); return true; }
	if (ch == "}".code) {
		advanceChar(s);
		s.jsxStack.pop();
		scanTemplateContinuation(s);
		return true;
	}
	return false;
}

export function scanJsx(s: LexerState): boolean {
	const n = s.jsxStack.length;
	if (n == 0) {
		if (peek(s) != "<".code) { return false; }
		if (!isJsxStart(s)) { return false; }
		emitTagStart(s);
		return true;
	}
	return match (s.jsxStack[n - 1]) {
		JsxMode.Children => scanJsxChildren(s),
		JsxMode.Tag => scanJsxTag(s),
		JsxMode.Closing => scanJsxClosing(s),
		JsxMode.Template => scanTemplateInterp(s),
		JsxMode.Brace => scanJsxBrace(s),
	};
}
