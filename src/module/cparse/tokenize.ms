// cparse — C tokenizer
//
// Entry point: tokenizeFile(source, path) -> TokenizeResult
// Byte-level scanning via byteAt (O(1)) — same pattern as src/lexer/state.ms.

import { CToken, CTokenKind, LitKind, makeEofToken } from "./token";
import { Diagnostic, DiagSeverity, makeDiag } from "./error";
import { decodeUtf8, isIdent1, isIdent2, fromHex, stripBom, canonicalizeNewline, removeBackslashNewline, convertUniversalChars } from "./unicode";

export interface TokenizeResult {
	head: CToken;
	diagnostics: Diagnostic[];
	// Owns every token created during tokenization — `next` links are non-owning
	// Ptr, so the stream is only alive while this array is. Keep the result in
	// scope for as long as any token from it is used.
	arena: CToken[];
}

// ===== Scan State =====

interface ScanState {
	source: string;
	pos: int32;
	line: int32;
	col: int32;
	file: string;
	atBol: boolean;
	hasSpace: boolean;
	diags: Diagnostic[];
	arena: CToken[];
}

// ===== Byte-level helpers =====

function peek(s: ScanState): int32 {
	return s.source.byteAt(s.pos);
}

function peekAt(s: ScanState, offset: int32): int32 {
	return s.source.byteAt(s.pos + offset);
}

function advance(s: ScanState): void {
	if (s.pos < s.source.byteLength) {
		if (s.source.byteAt(s.pos) === "\n".code) {
			s.line = s.line + 1;
			s.col = 1;
		} else {
			s.col = s.col + 1;
		}
		s.pos = s.pos + 1;
	}
}

function skipN(s: ScanState, n: int32): void {
	let i = 0;
	while (i < n) { advance(s); i = i + 1; }
}

// ===== Character classification =====

function isDigit(ch: int32): boolean {
	return ch >= "0".code && ch <= "9".code;
}

function isAlpha(ch: int32): boolean {
	return (ch >= "a".code && ch <= "z".code) || (ch >= "A".code && ch <= "Z".code) || ch === "_".code;
}

function isAlnum(ch: int32): boolean {
	return isAlpha(ch) || isDigit(ch);
}

function isSpace(ch: int32): boolean {
	return ch === " ".code || ch === "\t".code || ch === 11 || ch === 12;
}

function isPunct(ch: int32): boolean {
	return (ch >= "!".code && ch <= "/".code) ||
		(ch >= ":".code && ch <= "@".code) ||
		(ch >= "[".code && ch <= "^".code) ||
		ch === "`".code ||
		(ch >= "{".code && ch <= "~".code);
}

// ===== Token construction =====

function newToken(s: ScanState, kind: CTokenKind, start: int32, startLine: int32, startCol: int32: CToken {
	const tok: CToken = {
		kind,
		next: null,
		intVal: 0 as int64,
		floatVal: 0.0,
		litKind: LitKind.None,
		stringVal: s.source.byteSlice(start, s.pos),
		file: s.file,
		line: startLine,
		col: startCol,
		byteOffset: start,
		byteLength: s.pos - start,
		atBol: s.atBol,
		hasSpace: s.hasSpace,
		hideset: [],
		origin: null,
	};
	s.arena.push(tok);
	s.atBol = false;
	s.hasSpace = false;
	return tok;
}

// ===== Identifier reader =====

function readIdent(s: ScanState): int32 {
	const start = s.pos;
	let ch = peek(s);

	if (isAlpha(ch)) {
		advance(s);
	} else if (ch >= 0x80) {
		const decoded = decodeUtf8(s.source, s.pos);
		if (!isIdent1(decoded[0])) return 0;
		skipN(s, decoded[1]);
	} else {
		return 0;
	}

	while (s.pos < s.source.byteLength) {
		ch = peek(s);
		if (isAlnum(ch)) {
			advance(s);
		} else if (ch >= 0x80) {
			const decoded = decodeUtf8(s.source, s.pos);
			if (!isIdent2(decoded[0])) break;
			skipN(s, decoded[1]);
		} else {
			break;
		}
	}
	return s.pos - start;
}

// ===== Punctuator reader =====

function readPunct(s: ScanState): int32 {
	const c0 = peek(s);
	const c1 = peekAt(s, 1);
	const c2 = peekAt(s, 2);

	// 3-char
	if (c0 === "<".code && c1 === "<".code && c2 === "=".code) return 3;
	if (c0 === ">".code && c1 === ">".code && c2 === "=".code) return 3;
	if (c0 === ".".code && c1 === ".".code && c2 === ".".code) return 3;

	// 2-char
	if (c1 >= 0) {
		if (c0 === "=".code && c1 === "=".code) return 2;
		if (c0 === "!".code && c1 === "=".code) return 2;
		if (c0 === "<".code && c1 === "=".code) return 2;
		if (c0 === ">".code && c1 === "=".code) return 2;
		if (c0 === "-".code && c1 === ">".code) return 2;
		if (c0 === "+".code && c1 === "=".code) return 2;
		if (c0 === "-".code && c1 === "=".code) return 2;
		if (c0 === "*".code && c1 === "=".code) return 2;
		if (c0 === "/".code && c1 === "=".code) return 2;
		if (c0 === "+".code && c1 === "+".code) return 2;
		if (c0 === "-".code && c1 === "-".code) return 2;
		if (c0 === "%".code && c1 === "=".code) return 2;
		if (c0 === "&".code && c1 === "=".code) return 2;
		if (c0 === "|".code && c1 === "=".code) return 2;
		if (c0 === "^".code && c1 === "=".code) return 2;
		if (c0 === "&".code && c1 === "&".code) return 2;
		if (c0 === "|".code && c1 === "|".code) return 2;
		if (c0 === "<".code && c1 === "<".code) return 2;
		if (c0 === ">".code && c1 === ">".code) return 2;
		if (c0 === "#".code && c1 === "#".code) return 2;
	}

	if (isPunct(c0)) return 1;
	return 0;
}

// ===== Escape sequence reader =====

function readEscapedChar(s: ScanState): int32 {
	const ch = peek(s);

	// Octal
	if (ch >= "0".code && ch <= "7".code) {
		let c: int32 = (ch - "0".code) as int32;
		advance(s);
		if (peek(s) >= "0".code && peek(s) <= "7".code) {
			c = (c << 3) + (peek(s) - "0".code);
			advance(s);
			if (peek(s) >= "0".code && peek(s) <= "7".code) {
				c = (c << 3) + (peek(s) - "0".code);
				advance(s);
			}
		}
		return c;
	}

	// Hex
	if (ch === "x".code) {
		advance(s);
		if (fromHex(peek(s)) < 0) {
			s.diags.push(makeDiag(DiagSeverity.Error, s.file, s.line, s.col, "invalid hex escape sequence"));
			return 0;
		}
		let c: int32 = 0;
		let h = fromHex(peek(s));
		while (h >= 0) {
			c = (c << 4) + h as int32;
			advance(s);
			h = fromHex(peek(s));
		}
		return c;
	}

	// Named escapes
	advance(s);
	return match (ch) {
		"a".code => 7,
		"b".code => 8,
		"t".code => 9,
		"n".code => 10,
		"v".code => 11,
		"f".code => 12,
		"r".code => 13,
		"e".code => 27,
		_ => ch,
	};
}

// ===== String literal =====

function stringLiteralEnd(s: ScanState): int32 {
	let p = s.pos;
	const len = s.source.byteLength;
	while (p < len) {
		const ch = s.source.byteAt(p);
		if (ch === "\"".code) return p;
		if (ch === "\n".code || ch < 0) {
			s.diags.push(makeDiag(DiagSeverity.Error, s.file, s.line, s.col, "unclosed string literal"));
			return p;
		}
		if (ch === "\\".code) p = p + 1;
		p = p + 1;
	}
	s.diags.push(makeDiag(DiagSeverity.Error, s.file, s.line, s.col, "unclosed string literal"));
	return p;
}

function readStringLiteral(s: ScanState, tokenStart: int32, startLine: int32, startCol: int32, quotePos: int32, litKind: LitKind): CToken {
	s.pos = quotePos + 1;
	const endPos = stringLiteralEnd(s);

	let val = "";
	s.pos = quotePos + 1;
	let batchStart = s.pos;
	while (s.pos < endPos) {
		if (peek(s) === "\\".code) {
			// Flush batch of non-escape characters
			if (s.pos > batchStart) val = val + s.source.byteSlice(batchStart, s.pos);
			advance(s);
			const c = readEscapedChar(s);
			val = val + fromCodePoint(c);
			batchStart = s.pos;
		} else {
			advance(s);
		}
	}
	// Flush remaining batch
	if (s.pos > batchStart) val = val + s.source.byteSlice(batchStart, s.pos);

	if (s.pos < s.source.byteLength && peek(s) === "\"".code) advance(s);

	const tok = newToken(s, CTokenKind.Str, tokenStart, startLine, startCol);
	tok.stringVal = val;
	tok.litKind = litKind;
	return tok;
}

// ===== Character literal =====

function readCharLiteral(s: ScanState, tokenStart: int32, startLine: int32, startCol: int32, quotePos: int32, litKind: LitKind): CToken {
	s.pos = quotePos + 1;

	if (s.pos >= s.source.byteLength || peek(s) === "'".code) {
		s.diags.push(makeDiag(DiagSeverity.Error, s.file, s.line, s.col, "empty character literal"));
		if (peek(s) === "'".code) advance(s);
		const tok = newToken(s, CTokenKind.Num, tokenStart, startLine, startCol);
		tok.intVal = 0 as int64;
		return tok;
	}

	let c: int32 = 0;
	if (peek(s) === "\\".code) {
		advance(s);
		c = readEscapedChar(s);
	} else {
		const decoded = decodeUtf8(s.source, s.pos);
		c = decoded[0];
		skipN(s, decoded[1]);
	}

	while (s.pos < s.source.byteLength && peek(s) !== "'".code) advance(s);
	if (s.pos < s.source.byteLength) advance(s);
	else s.diags.push(makeDiag(DiagSeverity.Error, s.file, s.line, s.col, "unclosed char literal"));

	const tok = newToken(s, CTokenKind.Num, tokenStart, startLine, startCol);
	if (litKind === LitKind.StrU16) {
		tok.intVal = (c & 0xFFFF) as int64;
	} else {
		tok.intVal = c as int64;
	}
	tok.litKind = litKind;
	return tok;
}

// ===== PP-number reader =====

function readPPNumber(s: ScanState, tokenStart: int32, startLine: int32, startCol: int32): CToken {
	while (s.pos < s.source.byteLength) {
		const ch = peek(s);
		if ((ch === "e".code || ch === "E".code || ch === "p".code || ch === "P".code) &&
			(peekAt(s, 1) === "+".code || peekAt(s, 1) === "-".code)) {
			advance(s);
			advance(s);
		} else if (isAlnum(ch) || ch === ".".code) {
			advance(s);
		} else {
			break;
		}
	}
	return newToken(s, CTokenKind.PPNum, tokenStart, startLine, startCol);
}

// ===== Keyword detection =====

const KEYWORDS: string[] = [
	"return", "if", "else", "for", "while", "int", "sizeof", "char",
	"struct", "union", "short", "long", "void", "typedef", "_Bool",
	"enum", "static", "goto", "break", "continue", "switch", "case",
	"default", "extern", "_Alignof", "_Alignas", "do", "signed",
	"unsigned", "const", "volatile", "auto", "register", "restrict",
	"__restrict", "__restrict__", "_Noreturn", "float", "double",
	"typeof", "asm", "_Thread_local", "__thread", "_Atomic",
	"__attribute__", "inline", "__inline", "__inline__",
];

function isKeyword(lexeme: string): boolean {
	for (const kw of KEYWORDS) {
		if (lexeme === kw) return true;
	}
	return false;
}

// ===== PP-number conversion =====

function toLower(ch: int32): int32 {
	if (ch >= "A".code && ch <= "Z".code) return ch + 32;
	return ch;
}

export function convertPPInt(tok: CToken): boolean {
	const s = tok.stringVal;
	let p = 0;
	const len = s.byteLength;

	let base = 10;
	if (len >= 2 && s.byteAt(0) === "0".code) {
		const c1 = toLower(s.byteAt(1));
		if (c1 === "x".code && len >= 3 && fromHex(s.byteAt(2)) >= 0) {
			p = 2; base = 16;
		} else if (c1 === "b".code && len >= 3 && (s.byteAt(2) === "0".code || s.byteAt(2) === "1".code)) {
			p = 2; base = 2;
		} else {
			base = 8;
		}
	}

	let val: number = 0;
	const digitStart = p;
	while (p < len) {
		const ch = s.byteAt(p);
		let digit = -1;
		if (base === 16) { digit = fromHex(ch); }
		else if (base === 2) {
			if (ch === "0".code) digit = 0;
			else if (ch === "1".code) digit = 1;
		} else if (base === 8) {
			if (ch >= "0".code && ch <= "7".code) digit = ch - "0".code;
		} else {
			if (ch >= "0".code && ch <= "9".code) digit = ch - "0".code;
		}
		if (digit < 0) break;
		val = val * base + digit;
		p = p + 1;
	}
	if (p === digitStart && base !== 8) return false;

	// Parse suffix: U, L, LL, UL/LU, ULL/LLU (case-insensitive)
	let isLL = false;   // long long (LL)
	let isL = false;    // long (single L)
	let isUnsigned = false;
	const remaining = len - p;

	if (remaining >= 3) {
		const r0 = toLower(s.byteAt(p));
		const r1 = toLower(s.byteAt(p + 1));
		const r2 = toLower(s.byteAt(p + 2));
		if ((r0 === "l".code && r1 === "l".code && r2 === "u".code) ||
			(r0 === "u".code && r1 === "l".code && r2 === "l".code)) {
			isLL = true; isUnsigned = true; p = p + 3;
		}
	}
	if (!isLL && !isL && !isUnsigned && remaining >= 2) {
		const r0 = toLower(s.byteAt(p));
		const r1 = toLower(s.byteAt(p + 1));
		if (r0 === "l".code && r1 === "l".code) { isLL = true; p = p + 2; }
		else if ((r0 === "l".code && r1 === "u".code) || (r0 === "u".code && r1 === "l".code)) {
			isL = true; isUnsigned = true; p = p + 2;
		}
	}
	if (!isLL && !isL && !isUnsigned && remaining >= 1) {
		const r0 = toLower(s.byteAt(p));
		if (r0 === "l".code) { isL = true; p = p + 1; }
		else if (r0 === "u".code) { isUnsigned = true; p = p + 1; }
	}

	if (p !== len) return false;

	// Map suffix to LitKind
	if (isLL && isUnsigned) tok.litKind = LitKind.ULongLong;
	else if (isLL) tok.litKind = LitKind.LongLong;
	else if (isL && isUnsigned) tok.litKind = LitKind.ULong;
	else if (isL) tok.litKind = LitKind.Long;
	else if (isUnsigned) tok.litKind = LitKind.UInt;
	else tok.litKind = LitKind.Int;

	tok.kind = CTokenKind.Num;
	tok.intVal = val as int64;
	return true;
}

export function convertPPNumber(tok: CToken, diags: Diagnostic[]): void {
	if (convertPPInt(tok)) return;

	const val = tok.stringVal.parseFloat();
	const s = tok.stringVal;
	const len = s.byteLength;

	if (len > 0) {
		const last = toLower(s.byteAt(len - 1));
		if (last === "f".code) tok.litKind = LitKind.Float;
		else if (last === "l".code) tok.litKind = LitKind.LongDouble;
		else tok.litKind = LitKind.Double;
	} else {
		tok.litKind = LitKind.Double;
	}

	tok.kind = CTokenKind.Num;
	tok.floatVal = val;
}

export function convertPPTokens(head: CToken, diags: Diagnostic[]): void {
	let t = head;
	while (t.kind !== CTokenKind.Eof) {
		if (t.kind === CTokenKind.Ident && isKeyword(t.stringVal)) {
			t.kind = CTokenKind.Keyword;
		} else if (t.kind === CTokenKind.PPNum) {
			convertPPNumber(t, diags);
		}
		t = t.next;
	}
}

// ===== Source preprocessing =====

function prepareSource(source: string): string {
	let s = stripBom(source);
	s = canonicalizeNewline(s);
	s = removeBackslashNewline(s);
	s = convertUniversalChars(s);
	return s;
}

// ===== Main tokenizer =====

function tokenize(source: string, file: string): TokenizeResult {
	const s: ScanState = {
		source, pos: 0, line: 1, col: 1, file,
		atBol: true, hasSpace: false, diags: [], arena: [],
	};

	const head = makeEofToken(file);
	s.arena.push(head);
	let cur = head;
	const len = source.byteLength;

	while (s.pos < len) {
		const ch = peek(s);

		// Line comments
		if (ch === "/".code && peekAt(s, 1) === "/".code) {
			skipN(s, 2);
			while (s.pos < len && peek(s) !== "\n".code) advance(s);
			s.hasSpace = true;
			continue;
		}

		// Block comments
		if (ch === "/".code && peekAt(s, 1) === "*".code) {
			const commentLine = s.line;
			const commentCol = s.col;
			skipN(s, 2);
			let found = false;
			while (s.pos < len) {
				if (peek(s) === "*".code && peekAt(s, 1) === "/".code) {
					skipN(s, 2);
					found = true;
					break;
				}
				advance(s);
			}
			if (!found) {
				s.diags.push(makeDiag(DiagSeverity.Error, s.file, commentLine, commentCol, "unclosed block comment"));
			}
			s.hasSpace = true;
			continue;
		}

		// Newline
		if (ch === "\n".code) {
			advance(s);
			s.atBol = true;
			s.hasSpace = false;
			continue;
		}

		// Whitespace
		if (isSpace(ch)) {
			advance(s);
			s.hasSpace = true;
			continue;
		}

		const tokenStart = s.pos;
		const startLine = s.line;
		const startCol = s.col;

		// PP-number
		if (isDigit(ch) || (ch === ".".code && isDigit(peekAt(s, 1)))) {
			const tok = readPPNumber(s, tokenStart, startLine, startCol);
			cur.next = tok; cur = tok;
			continue;
		}

		// String/char literal dispatch (longest prefix first)
		if (ch === "u".code && peekAt(s, 1) === "8".code && peekAt(s, 2) === "\"".code) {
			const tok = readStringLiteral(s, tokenStart, startLine, startCol, s.pos + 2, LitKind.StrUtf8);
			cur.next = tok; cur = tok; continue;
		}
		if (ch === "u".code && peekAt(s, 1) === "\"".code) {
			const tok = readStringLiteral(s, tokenStart, startLine, startCol, s.pos + 1, LitKind.StrU16);
			cur.next = tok; cur = tok; continue;
		}
		if (ch === "U".code && peekAt(s, 1) === "\"".code) {
			const tok = readStringLiteral(s, tokenStart, startLine, startCol, s.pos + 1, LitKind.StrU32);
			cur.next = tok; cur = tok; continue;
		}
		if (ch === "L".code && peekAt(s, 1) === "\"".code) {
			const tok = readStringLiteral(s, tokenStart, startLine, startCol, s.pos + 1, LitKind.StrWide);
			cur.next = tok; cur = tok; continue;
		}
		if (ch === "\"".code) {
			const tok = readStringLiteral(s, tokenStart, startLine, startCol, s.pos, LitKind.StrChar);
			cur.next = tok; cur = tok; continue;
		}
		if (ch === "u".code && peekAt(s, 1) === "'".code) {
			const tok = readCharLiteral(s, tokenStart, startLine, startCol, s.pos + 1, LitKind.StrU16);
			cur.next = tok; cur = tok; continue;
		}
		if (ch === "U".code && peekAt(s, 1) === "'".code) {
			const tok = readCharLiteral(s, tokenStart, startLine, startCol, s.pos + 1, LitKind.StrU32);
			cur.next = tok; cur = tok; continue;
		}
		if (ch === "L".code && peekAt(s, 1) === "'".code) {
			const tok = readCharLiteral(s, tokenStart, startLine, startCol, s.pos + 1, LitKind.StrWide);
			cur.next = tok; cur = tok; continue;
		}
		if (ch === "'".code) {
			const tok = readCharLiteral(s, tokenStart, startLine, startCol, s.pos, LitKind.None);
			cur.next = tok; cur = tok; continue;
		}

		// Identifier
		const identLen = readIdent(s);
		if (identLen > 0) {
			const tok = newToken(s, CTokenKind.Ident, tokenStart, startLine, startCol);
			cur.next = tok; cur = tok; continue;
		}

		// Punctuator
		const punctLen = readPunct(s);
		if (punctLen > 0) {
			skipN(s, punctLen);
			const tok = newToken(s, CTokenKind.Punct, tokenStart, startLine, startCol);
			cur.next = tok; cur = tok; continue;
		}

		// Invalid token
		s.diags.push(makeDiag(DiagSeverity.Error, s.file, s.line, s.col, "invalid token"));
		advance(s);
	}

	// EOF
	const eof = newToken(s, CTokenKind.Eof, s.pos, s.line, s.col);
	eof.atBol = s.atBol;
	cur.next = eof;

	return { head: head.next, diagnostics: s.diags, arena: s.arena };
}

// ===== Public entry point =====

export function tokenizeFile(source: string, path: string): TokenizeResult {
	const prepared = prepareSource(source);
	return tokenize(prepared, path);
}

// ===== Token utilities =====

export function equal(tok: CToken, str: string): boolean {
	return tok.stringVal === str;
}

export function skipTok(tok: CToken, str: string, diags: Diagnostic[]): CToken {
	if (tok.stringVal !== str) {
		diags.push(makeDiag(DiagSeverity.Error, tok.file, tok.line, tok.col,
			`expected '${str}'`));
	}
	return tok.next;
}

export function consume(tok: CToken, str: string): boolean {
	return tok.stringVal === str;
}

// ===== Tests =====

test "tokenize empty source yields eof" {
	const r = tokenizeFile("", "empty.h");
	assert r.head.kind === CTokenKind.Eof;
	assert r.diagnostics.length === 0;
}

test "tokenize int x semicolon" {
	const r = tokenizeFile("int x;", "test.h");
	assert r.head.kind === CTokenKind.Ident;
	assert r.head.stringVal === "int";
	assert r.head.next.kind === CTokenKind.Ident;
	assert r.head.next.stringVal === "x";
	assert r.head.next.next.kind === CTokenKind.Punct;
	assert r.head.next.next.stringVal === ";";
	assert r.head.next.next.next.kind === CTokenKind.Eof;
}

test "tokenize line comment" {
	const r = tokenizeFile("// hello\nint", "test.h");
	assert r.head.kind === CTokenKind.Ident;
	assert r.head.stringVal === "int";
	assert r.head.atBol === true;
}

test "tokenize block comment" {
	const r = tokenizeFile("/* block */ int", "test.h");
	assert r.head.kind === CTokenKind.Ident;
	assert r.head.stringVal === "int";
	assert r.head.hasSpace === true;
}

test "tokenize string literal" {
	const r = tokenizeFile("\"hello\"", "test.h");
	assert r.head.kind === CTokenKind.Str;
	assert r.head.stringVal === "hello";
	assert r.head.litKind === LitKind.StrChar;
}

test "tokenize string escape" {
	const r = tokenizeFile("\"a\\nb\"", "test.h");
	assert r.head.stringVal === "a\nb";
}

test "tokenize char literal" {
	const r = tokenizeFile("'A'", "test.h");
	assert r.head.kind === CTokenKind.Num;
	assert r.head.intVal === 65 as int64;
}

test "tokenize pp-number hex" {
	const r = tokenizeFile("0xFF", "test.h");
	assert r.head.kind === CTokenKind.PPNum;
	assert r.head.stringVal === "0xFF";
}

test "tokenize multi-char punctuator" {
	const r = tokenizeFile("<<= >>=", "test.h");
	assert r.head.stringVal === "<<=";
	assert r.head.next.stringVal === ">>=";
}

test "tokenize ellipsis" {
	const r = tokenizeFile("...", "test.h");
	assert r.head.stringVal === "...";
}

test "tokenize atBol tracking" {
	const r = tokenizeFile("#define FOO", "test.h");
	const hash = r.head;
	assert hash.stringVal === "#";
	assert hash.atBol === true;
	const define = hash.next;
	assert define.hasSpace === false;
	const foo = define.next;
	assert foo.hasSpace === true;
}

test "convertPPInt decimal" {
	const tok = makeEofToken("t");
	tok.kind = CTokenKind.PPNum;
	tok.stringVal = "42";
	assert convertPPInt(tok) === true;
	assert tok.intVal === 42 as int64;
	assert tok.litKind === LitKind.Int;
}

test "convertPPInt hex" {
	const tok = makeEofToken("t");
	tok.kind = CTokenKind.PPNum;
	tok.stringVal = "0xFF";
	assert convertPPInt(tok) === true;
	assert tok.intVal === 255 as int64;
}

test "convertPPInt binary" {
	const tok = makeEofToken("t");
	tok.kind = CTokenKind.PPNum;
	tok.stringVal = "0b1010";
	assert convertPPInt(tok) === true;
	assert tok.intVal === 10 as int64;
}

test "convertPPInt suffix ULL" {
	const tok = makeEofToken("t");
	tok.kind = CTokenKind.PPNum;
	tok.stringVal = "100ULL";
	assert convertPPInt(tok) === true;
	assert tok.litKind === LitKind.ULongLong;
}

test "convertPPInt suffix L vs LL" {
	const tok1 = makeEofToken("t");
	tok1.kind = CTokenKind.PPNum;
	tok1.stringVal = "42L";
	assert convertPPInt(tok1) === true;
	assert tok1.litKind === LitKind.Long;

	const tok2 = makeEofToken("t");
	tok2.kind = CTokenKind.PPNum;
	tok2.stringVal = "42LL";
	assert convertPPInt(tok2) === true;
	assert tok2.litKind === LitKind.LongLong;

	const tok3 = makeEofToken("t");
	tok3.kind = CTokenKind.PPNum;
	tok3.stringVal = "42UL";
	assert convertPPInt(tok3) === true;
	assert tok3.litKind === LitKind.ULong;
}

test "isKeyword" {
	assert isKeyword("int") === true;
	assert isKeyword("struct") === true;
	assert isKeyword("foo") === false;
}

test "convertPPTokens keywords" {
	const r = tokenizeFile("int x;", "test.h");
	convertPPTokens(r.head, r.diagnostics);
	assert r.head.kind === CTokenKind.Keyword;
	assert r.head.stringVal === "int";
	assert r.head.next.kind === CTokenKind.Ident;
}

test "tokenize wide string prefix" {
	const r = tokenizeFile("L\"wide\"", "test.h");
	assert r.head.kind === CTokenKind.Str;
	assert r.head.litKind === LitKind.StrWide;
	assert r.head.stringVal === "wide";
}

test "tokenize backslash newline removed" {
	const r = tokenizeFile("in\\\nt", "test.h");
	assert r.head.kind === CTokenKind.Ident;
	assert r.head.stringVal === "int";
}

test "tokenize octal escape in string" {
	const r = tokenizeFile("\"\\0\\101\"", "test.h");
	// \0 = 0, \101 = 65 = 'A'
	assert r.head.kind === CTokenKind.Str;
}

test "tokenize hex escape in string" {
	const r = tokenizeFile("\"\\x41\"", "test.h");
	// \x41 = 65 = 'A'
	assert r.head.kind === CTokenKind.Str;
	assert r.head.stringVal === "A";
}

test "tokenize float with exponent" {
	const r = tokenizeFile("1.5e-3", "test.h");
	assert r.head.kind === CTokenKind.PPNum;
	assert r.head.stringVal === "1.5e-3";
}

test "tokenize dot not followed by digit is punct" {
	const r = tokenizeFile("a.b", "test.h");
	assert r.head.stringVal === "a";
	assert r.head.next.stringVal === ".";
	assert r.head.next.kind === CTokenKind.Punct;
	assert r.head.next.next.stringVal === "b";
}

test "tokenize arrow operator" {
	const r = tokenizeFile("p->x", "test.h");
	assert r.head.stringVal === "p";
	assert r.head.next.stringVal === "->";
	assert r.head.next.next.stringVal === "x";
}

test "tokenize all 2-char punctuators" {
	const r = tokenizeFile("== != <= >= -> += -= *= /= ++ -- %= &= |= ^= && || << >> ##", "test.h");
	let tok = r.head;
	const expected: string[] = ["==", "!=", "<=", ">=", "->", "+=", "-=", "*=", "/=", "++", "--", "%=", "&=", "|=", "^=", "&&", "||", "<<", ">>", "##"];
	let i = 0;
	while (i < expected.length) {
		assert tok.stringVal === expected[i];
		assert tok.kind === CTokenKind.Punct;
		tok = tok.next;
		i = i + 1;
	}
}

test "tokenize line tracking across newlines" {
	const r = tokenizeFile("a\nb\nc", "test.h");
	assert r.head.line === 1;
	assert r.head.next.line === 2;
	assert r.head.next.next.line === 3;
}

test "convertPPInt octal" {
	const tok = makeEofToken("t");
	tok.kind = CTokenKind.PPNum;
	tok.stringVal = "0777";
	assert convertPPInt(tok) === true;
	assert tok.intVal === 511 as int64; // 7*64 + 7*8 + 7
}

test "convertPPNumber float suffix f" {
	const tok = makeEofToken("t");
	tok.kind = CTokenKind.PPNum;
	tok.stringVal = "3.14f";
	const diags: Diagnostic[] = [];
	convertPPNumber(tok, diags);
	assert tok.kind === CTokenKind.Num;
	assert tok.litKind === LitKind.Float;
}

test "tokenize unclosed string produces diagnostic" {
	const r = tokenizeFile("\"hello\n", "test.h");
	assert r.diagnostics.length > 0;
}

test "tokenize unclosed block comment produces diagnostic" {
	const r = tokenizeFile("/* unclosed", "test.h");
	assert r.diagnostics.length > 0;
}
