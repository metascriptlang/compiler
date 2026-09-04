// Scanner — Tokenization of numbers, strings, identifiers, operators, comments
// Pattern: ~/projects/metascript/src/lexer/lexer.zig

import { TokenKind, identToKeyword } from "./token";
import { LexerState, peek, peekAt, advanceChar, skip, addToken, addComment, allowsRegexAfter, setLexError } from "./state";
import { isDigit, isLetter, isHexDigit, isOctalDigit, isBinaryDigit } from "./chars";

// ===== Number Scanning =====

// `0xffn` / `0b1111n` / `0o17n` are bigint literals like `255n` — the radix
// prefixes reach the same suffix check as the decimal tail.
function addNumericToken(s: LexerState, val: string, line: int32, column: int32): void {
	if (peek(s) === "n".code) {
		advanceChar(s);
		addToken(s, TokenKind.BigInt, val + "n", line, column);
		return;
	}
	addToken(s, TokenKind.Number, val, line, column);
}

export function scanNumber(s: LexerState): void {
	const startLine = s.line;
	const startCol = s.column;
	let val = "";

	// Handle hex, binary, octal prefixes
	if (peek(s) === "0".code) {
		const next = peekAt(s, 1);
		if (next === "x".code || next === "X".code) {
			val = "0x";
			skip(s, 2);
			while (s.pos < s.source.byteLength && (isHexDigit(peek(s)) || peek(s) === "_".code)) {
				if (peek(s) !== "_".code) val += s.source.byteSlice(s.pos, s.pos + 1);
				advanceChar(s);
			}
			addNumericToken(s, val, startLine, startCol);
			return;
		}
		if (next === "b".code || next === "B".code) {
			val = "0b";
			skip(s, 2);
			while (s.pos < s.source.byteLength && (isBinaryDigit(peek(s)) || peek(s) === "_".code)) {
				if (peek(s) !== "_".code) val += s.source.byteSlice(s.pos, s.pos + 1);
				advanceChar(s);
			}
			addNumericToken(s, val, startLine, startCol);
			return;
		}
		if (next === "o".code || next === "O".code) {
			val = "0o";
			skip(s, 2);
			while (s.pos < s.source.byteLength && (isOctalDigit(peek(s)) || peek(s) === "_".code)) {
				if (peek(s) !== "_".code) val += s.source.byteSlice(s.pos, s.pos + 1);
				advanceChar(s);
			}
			addNumericToken(s, val, startLine, startCol);
			return;
		}
	}

	// Decimal number
	let hasDecimal = false;
	let hasExponent = false;

	while (s.pos < s.source.byteLength) {
		const ch = peek(s);
		if (isDigit(ch)) {
			val += s.source.byteSlice(s.pos, s.pos + 1);
			advanceChar(s);
		} else if (ch === ".".code && !hasDecimal && isDigit(peekAt(s, 1))) {
			val += ".";
			hasDecimal = true;
			advanceChar(s);
		} else if ((ch === "e".code || ch === "E".code) && !hasExponent) {
			val += "e";
			hasExponent = true;
			advanceChar(s);
			const next = peek(s);
			if (next === "+".code || next === "-".code) {
				val += s.source.byteSlice(s.pos, s.pos + 1);
				advanceChar(s);
			}
		} else if (ch === "_".code) {
			advanceChar(s); // skip underscore
		} else {
			break;
		}
	}

	addNumericToken(s, val, startLine, startCol);
}

// ===== String Scanning =====

function hexDigitValue(b: int32): int32 {
	if (b >= "0".code && b <= "9".code) return b - "0".code;
	if (b >= "a".code && b <= "f".code) return b - "a".code + 10;
	return b - "A".code + 10;
}

function scanHexDigits(s: LexerState, count: int32): int32 {
	let value = 0;
	let i = 0;
	while (i < count) {
		const d = peek(s);
		if (!isHexDigit(d)) {
			setLexError(s, "Invalid hexadecimal escape sequence");
			return -1;
		}
		value = (value * 16 + hexDigitValue(d)) as int32;
		advanceChar(s);
		i += 1;
	}
	return value;
}

function scanUnicodeEscape(s: LexerState): string {
	if (peek(s) === "{".code) {
		advanceChar(s);
		let cp = 0;
		let digits = 0;
		while (isHexDigit(peek(s))) {
			cp = (cp * 16 + hexDigitValue(peek(s))) as int32;
			advanceChar(s);
			digits += 1;
		}
		if (digits === 0 || peek(s) !== "}".code) {
			setLexError(s, "Invalid Unicode escape sequence");
			return "";
		}
		advanceChar(s);
		if (cp > 1114111) {
			setLexError(s, "Unicode codepoint must not be greater than 0x10FFFF");
			return "";
		}
		return fromCodePoint(cp);
	}
	const unit = scanHexDigits(s, 4);
	if (unit < 0) return "";
	if (unit >= 0xD800 && unit <= 0xDBFF
			&& peek(s) === "\\".code && peekAt(s, 1) === "u".code
			&& isHexDigit(peekAt(s, 2)) && isHexDigit(peekAt(s, 3))
			&& isHexDigit(peekAt(s, 4)) && isHexDigit(peekAt(s, 5))) {
		const low = hexDigitValue(peekAt(s, 2)) * 4096 + hexDigitValue(peekAt(s, 3)) * 256
			+ hexDigitValue(peekAt(s, 4)) * 16 + hexDigitValue(peekAt(s, 5));
		if (low >= 0xDC00 && low <= 0xDFFF) {
			skip(s, 6);
			return fromCodePoint(65536 + (unit - 0xD800) * 1024 + (low - 0xDC00));
		}
	}
	return fromCodePoint(unit);
}

function scanEscape(s: LexerState): string {
	advanceChar(s); // skip backslash
	const first = peek(s);

	if (first === "x".code) {
		advanceChar(s);
		const cu = scanHexDigits(s, 2);
		if (cu < 0) return "";
		return fromCodePoint(cu);
	}
	if (first === "u".code) {
		advanceChar(s);
		return scanUnicodeEscape(s);
	}
	if (first === "0".code && !isDigit(peekAt(s, 1))) {
		advanceChar(s);
		return fromCodePoint(0);
	}
	if (isDigit(first)) {
		setLexError(s, "Octal escape sequences are not allowed in strict mode");
		advanceChar(s);
		return "";
	}
	if (first === "\n".code) {
		advanceChar(s);
		return "";
	}
	if (first === "\r".code) {
		advanceChar(s);
		if (peek(s) === "\n".code) advanceChar(s);
		return "";
	}

	const esc = advanceChar(s);
	return match (esc) {
		"n".code => "\n",
		"t".code => "\t",
		"r".code => "\r",
		"b".code => fromCodePoint(8),
		"f".code => fromCodePoint(12),
		"v".code => fromCodePoint(11),
		"\\".code => "\\",
		"\"".code => "\"",
		"'".code => "'",
		"`".code => "`",
		"$".code => "$",
		_ => {
			// Unknown escape: pass the escaped character through verbatim. A
			// multi-byte UTF-8 char must be consumed whole — slicing just the
			// lead byte leaves continuation bytes behind.
			if (esc < 0x80) return s.source.byteSlice(s.pos - 1, s.pos);
			let tail = 1;
			if (esc >= 0xF0) { tail = 3; }
			else if (esc >= 0xE0) { tail = 2; }
			const start = s.pos - 1;
			let k = 0;
			while (k < tail && s.pos < s.source.byteLength) { advanceChar(s); k += 1; }
			return s.source.byteSlice(start, s.pos);
		},
	};
}

export function scanString(s: LexerState, quote: int32): void {
	const startLine = s.line;
	const startCol = s.column;
	let val = "";
	advanceChar(s); // skip opening quote
	const rawStart = s.pos; // capture raw source start (after opening quote)

	// Plain bytes are copied in RUNS, not one byte at a time. Runs only break
	// at ASCII bytes (quote/backslash), so every slice stays on character
	// bounds and multi-byte UTF-8 sequences are never split.
	let runStart = s.pos;
	while (s.pos < s.source.byteLength) {
		const ch = peek(s);
		if (ch === quote) {
			if (runStart < s.pos) val += s.source.byteSlice(runStart, s.pos);
			const rawEnd = s.pos; // before closing quote
			advanceChar(s);
			const tok = addToken(s, TokenKind.String, val, startLine, startCol);
			// Store raw source text for formatter (Prettier pattern: preserve original escapes)
			tok.rawValue = s.source.byteSlice(rawStart, rawEnd);
			return;
		}
		if (ch === "\\".code) {
			if (runStart < s.pos) val += s.source.byteSlice(runStart, s.pos);
			val += scanEscape(s);
			runStart = s.pos;
		} else {
			advanceChar(s);
		}
	}
}

// ===== Template Literal Scanning =====

export function scanTemplateString(s: LexerState): void {
	scanTemplateStringImpl(s, false);
}

export function scanTemplateContinuation(s: LexerState): void {
	scanTemplateStringImpl(s, true);
}

function scanTemplateStringImpl(s: LexerState, isContinuation: boolean): void {
	const startLine = s.line;
	const startCol = s.column;
	let val = "";
	if (!isContinuation) advanceChar(s); // skip ` (} already consumed by caller)

	// Detect operator identifiers: `==`, `[]`, `[]=`, `+`, `<>`, etc.
	// Peek ahead for stropped identifiers.
	if (!isContinuation) {
		let tempPos = s.pos;
		let hasInterpolation = false;
		let hasNewline = false;
		while (tempPos < s.source.byteLength && s.source.byteAt(tempPos) !== "`".code) {
			const tc = s.source.byteAt(tempPos);
			if (tc === "$".code && tempPos + 1 < s.source.byteLength && s.source.byteAt(tempPos + 1) === "{".code) {
				hasInterpolation = true;
				break;
			}
			if (tc === "\n".code) { hasNewline = true; break; }
			tempPos = tempPos + 1;
		}
		if (!hasInterpolation && !hasNewline && tempPos < s.source.byteLength) {
			const contentLen = tempPos - s.pos;
			if (contentLen > 0) {
				const content = s.source.byteSlice(s.pos, tempPos);
				if (isOperatorName(content)) {
					s.pos = tempPos;
					s.column = s.column + contentLen;
					advanceChar(s); // closing backtick
					addToken(s, TokenKind.OperatorIdent, content, startLine, startCol);
					return;
				}
			}
		}
	}

	// Run-copied for the same reason as scanString: never split multi-byte UTF-8.
	let runStart = s.pos;
	while (s.pos < s.source.byteLength) {
		const ch = peek(s);
		if (ch === "`".code) {
			if (runStart < s.pos) val += s.source.byteSlice(runStart, s.pos);
			advanceChar(s);
			addToken(s, isContinuation ? TokenKind.TemplateTail : TokenKind.TemplateNoSub, val, startLine, startCol);
			return;
		}
		if (ch === "$".code && peekAt(s, 1) === "{".code) {
			if (runStart < s.pos) val += s.source.byteSlice(runStart, s.pos);
			skip(s, 2);
			s.templateDepth += 1;
			addToken(s, isContinuation ? TokenKind.TemplateMiddle : TokenKind.TemplateHead, val, startLine, startCol);
			return;
		}
		if (ch === "\\".code) {
			if (runStart < s.pos) val += s.source.byteSlice(runStart, s.pos);
			val += scanEscape(s);
			runStart = s.pos;
		} else {
			advanceChar(s);
		}
	}
}

// Check if a backtick-quoted string is an operator name.
function isOperatorChar(ch: int32): boolean {
	return ch === "|".code || ch === ">".code || ch === "<".code || ch === "=".code
		|| ch === "+".code || ch === "-".code || ch === "*".code || ch === "/".code
		|| ch === "%".code || ch === "&".code || ch === "^".code || ch === "~".code
		|| ch === "!".code || ch === "?".code || ch === ".".code || ch === "\\".code;
}

function isOperatorName(name: string): boolean {
	if (name.length === 0) return false;
	// Special case: subscript operators `[]` and `[]=`
	if (name === "[]" || name === "[]=") return true;
	let i = 0;
	while (i < name.length) {
		if (!isOperatorChar(name.byteAt(i))) return false;
		i = i + 1;
	}
	return true;
}

// ===== Identifier & Keyword Scanning =====

export function scanIdentifier(s: LexerState): void {
	const startLine = s.line;
	const startCol = s.column;
	let ident = "";

	while (s.pos < s.source.byteLength) {
		const ch = peek(s);
		if (isLetter(ch) || isDigit(ch) || ch === "_".code || ch === "$".code) {
			ident += s.source.byteSlice(s.pos, s.pos + 1);
			advanceChar(s);
		} else {
			break;
		}
	}

	const keyword = identToKeyword(ident);
	addToken(s, keyword, ident, startLine, startCol);
}

// ===== Comment Handling =====

export function scanLineComment(s: LexerState): void {
	const startLine = s.line;
	const startCol = s.column - 2; // includes //
	const runStart = s.pos;
	while (s.pos < s.source.byteLength && peek(s) !== "\n".code && peek(s) !== "\r".code) {
		advanceChar(s);
	}
	addComment(s, "//" + s.source.byteSlice(runStart, s.pos), startLine, startCol);
}

export function scanBlockComment(s: LexerState): void {
	const startLine = s.line;
	const startCol = s.column - 2; // includes /*
	const runStart = s.pos;
	while (s.pos < s.source.byteLength) {
		if (peek(s) === "*".code && peekAt(s, 1) === "/".code) {
			const content = "/*" + s.source.byteSlice(runStart, s.pos) + "*/";
			skip(s, 2);
			addComment(s, content, startLine, startCol);
			return;
		}
		advanceChar(s);
	}
}

// ===== Regex Literal Scanning =====

function scanRegex(s: LexerState): void {
	const startLine = s.line;
	const startCol = s.column;
	advanceChar(s); // skip opening /

	// The whole pattern (escapes included) is taken verbatim — one contiguous
	// span instead of per-byte slices (multi-byte UTF-8 safety, see scanString).
	const bodyStart = s.pos;
	while (s.pos < s.source.byteLength) {
		const ch = peek(s);
		if (ch === "/".code) {
			advanceChar(s);
			break;
		}
		if (ch === "\\".code) {
			advanceChar(s);
			if (s.pos < s.source.byteLength) advanceChar(s);
			continue;
		}
		if (ch === "\n".code) {
			// Regex cannot span lines
			break;
		}
		advanceChar(s);
	}

	// Scan flags (g, i, m, s, u, y, d)
	while (s.pos < s.source.byteLength && isLetter(peek(s))) {
		advanceChar(s);
	}

	addToken(s, TokenKind.Regex, "/" + s.source.byteSlice(bodyStart, s.pos), startLine, startCol);
}

// ===== Operator & Punctuation Scanning =====

export function scanOperator(s: LexerState): boolean {
	const ch = peek(s);
	const startLine = s.line;
	const startCol = s.column;
	const next = peekAt(s, 1);

	return match (ch) {
		"/".code => {
			if (next === "/".code) { skip(s, 2); scanLineComment(s); }
			else if (next === "*".code) { skip(s, 2); scanBlockComment(s); }
			else if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.SlashEq, "/=", startLine, startCol); }
			else if (allowsRegexAfter(s)) { scanRegex(s); }
			else { advanceChar(s); addToken(s, TokenKind.Slash, "/", startLine, startCol); }
			return true;
		},
		"=".code => {
			if (next === "=".code && peekAt(s, 2) === "=".code) { skip(s, 3); addToken(s, TokenKind.EqEqEq, "===", startLine, startCol); }
			else if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.EqEq, "==", startLine, startCol); }
			else if (next === ">".code) { skip(s, 2); addToken(s, TokenKind.Arrow, "=>", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Assign, "=", startLine, startCol); }
			return true;
		},
		"!".code => {
			if (next === "=".code && peekAt(s, 2) === "=".code) { skip(s, 3); addToken(s, TokenKind.BangEqEq, "!==", startLine, startCol); }
			else if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.BangEq, "!=", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Bang, "!", startLine, startCol); }
			return true;
		},
		"<".code => {
			if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.LtEq, "<=", startLine, startCol); }
			else if (next === "<".code) { skip(s, 2); addToken(s, TokenKind.LtLt, "<<", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Lt, "<", startLine, startCol); }
			return true;
		},
		">".code => {
			if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.GtEq, ">=", startLine, startCol); }
			else if (next === ">".code && peekAt(s, 2) === ">".code) { skip(s, 3); addToken(s, TokenKind.GtGtGt, ">>>", startLine, startCol); }
			else if (next === ">".code) { skip(s, 2); addToken(s, TokenKind.GtGt, ">>", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Gt, ">", startLine, startCol); }
			return true;
		},
		"+".code => {
			if (next === "+".code) { skip(s, 2); addToken(s, TokenKind.PlusPlus, "++", startLine, startCol); }
			else if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.PlusEq, "+=", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Plus, "+", startLine, startCol); }
			return true;
		},
		"-".code => {
			if (next === "-".code) { skip(s, 2); addToken(s, TokenKind.MinusMinus, "--", startLine, startCol); }
			else if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.MinusEq, "-=", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Minus, "-", startLine, startCol); }
			return true;
		},
		"*".code => {
			if (next === "*".code) { skip(s, 2); addToken(s, TokenKind.StarStar, "**", startLine, startCol); }
			else if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.StarEq, "*=", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Star, "*", startLine, startCol); }
			return true;
		},
		"%".code => {
			if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.PercentEq, "%=", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Percent, "%", startLine, startCol); }
			return true;
		},
		"&".code => {
			if (next === "&".code) { skip(s, 2); addToken(s, TokenKind.AmpAmp, "&&", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Amp, "&", startLine, startCol); }
			return true;
		},
		"|".code => {
			if (next === "|".code) { skip(s, 2); addToken(s, TokenKind.PipePipe, "||", startLine, startCol); }
			else if (next === ">".code) { skip(s, 2); addToken(s, TokenKind.PipeGt, "|>", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Pipe, "|", startLine, startCol); }
			return true;
		},
		"?".code => {
			if (next === ".".code && !isDigit(peekAt(s, 2))) { skip(s, 2); addToken(s, TokenKind.QuestionDot, "?.", startLine, startCol); }
			else if (next === "?".code) { skip(s, 2); addToken(s, TokenKind.QuestionQuestion, "??", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Question, "?", startLine, startCol); }
			return true;
		},
		".".code => {
			if (next === ".".code && peekAt(s, 2) === ".".code) { skip(s, 3); addToken(s, TokenKind.DotDotDot, "...", startLine, startCol); }
			else if (next === ".".code) { skip(s, 2); addToken(s, TokenKind.DotDot, "..", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Dot, ".", startLine, startCol); }
			return true;
		},
		_ => false,
	};
}

export function scanPunctuation(s: LexerState): boolean {
	const ch = peek(s);
	const startLine = s.line;
	const startCol = s.column;

	return match (ch) {
		"(".code => { advanceChar(s); addToken(s, TokenKind.LParen, "(", startLine, startCol); return true; },
		")".code => { advanceChar(s); addToken(s, TokenKind.RParen, ")", startLine, startCol); return true; },
		"{".code => { advanceChar(s); addToken(s, TokenKind.LBrace, "{", startLine, startCol); return true; },
		"}".code => {
			advanceChar(s);
			if (s.templateDepth > 0) {
				s.templateDepth -= 1;
				scanTemplateContinuation(s);
			} else {
				addToken(s, TokenKind.RBrace, "}", startLine, startCol);
			}
			return true;
		},
		"[".code => { advanceChar(s); addToken(s, TokenKind.LBracket, "[", startLine, startCol); return true; },
		"]".code => { advanceChar(s); addToken(s, TokenKind.RBracket, "]", startLine, startCol); return true; },
		";".code => { advanceChar(s); addToken(s, TokenKind.Semicolon, ";", startLine, startCol); return true; },
		":".code => { advanceChar(s); addToken(s, TokenKind.Colon, ":", startLine, startCol); return true; },
		",".code => { advanceChar(s); addToken(s, TokenKind.Comma, ",", startLine, startCol); return true; },
		"@".code => { advanceChar(s); addToken(s, TokenKind.At, "@", startLine, startCol); return true; },
		"~".code => { advanceChar(s); addToken(s, TokenKind.Tilde, "~", startLine, startCol); return true; },
		"^".code => { advanceChar(s); addToken(s, TokenKind.Caret, "^", startLine, startCol); return true; },
		_ => false,
	};
}
