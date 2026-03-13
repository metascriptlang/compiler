// Scanner — Tokenization of numbers, strings, identifiers, operators, comments
// Pattern: ~/projects/metascript/src/lexer/lexer.zig

import { TokenKind, identToKeyword } from "./token";
import { LexerState, peek, peekAt, advanceChar, skip, addToken, addComment, allowsRegexAfter } from "./state";
import { isDigit, isLetter, isHexDigit, isOctalDigit, isBinaryDigit } from "./chars";

// ===== Number Scanning =====

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
			addToken(s, TokenKind.Number, val, startLine, startCol);
			return;
		}
		if (next === "b".code || next === "B".code) {
			val = "0b";
			skip(s, 2);
			while (s.pos < s.source.byteLength && (isBinaryDigit(peek(s)) || peek(s) === "_".code)) {
				if (peek(s) !== "_".code) val += s.source.byteSlice(s.pos, s.pos + 1);
				advanceChar(s);
			}
			addToken(s, TokenKind.Number, val, startLine, startCol);
			return;
		}
		if (next === "o".code || next === "O".code) {
			val = "0o";
			skip(s, 2);
			while (s.pos < s.source.byteLength && (isOctalDigit(peek(s)) || peek(s) === "_".code)) {
				if (peek(s) !== "_".code) val += s.source.byteSlice(s.pos, s.pos + 1);
				advanceChar(s);
			}
			addToken(s, TokenKind.Number, val, startLine, startCol);
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

	// BigInt suffix
	if (peek(s) === "n".code) {
		advanceChar(s);
		addToken(s, TokenKind.BigInt, val + "n", startLine, startCol);
	} else {
		addToken(s, TokenKind.Number, val, startLine, startCol);
	}
}

// ===== String Scanning =====

function scanEscape(s: LexerState): string {
	advanceChar(s); // skip backslash
	// Hex escape: \xHH — read 2 hex digits, preserve as \xHH for C codegen
	if (peek(s) === "x".code && s.pos + 2 < s.source.byteLength) {
		advanceChar(s); // skip 'x'
		const d1 = s.source.byteSlice(s.pos, s.pos + 1);
		advanceChar(s);
		const d2 = s.source.byteSlice(s.pos, s.pos + 1);
		advanceChar(s);
		return "\\" + "x" + d1 + d2;
	}
	const esc = advanceChar(s);
	return match (esc) {
		"n".code => "\n",
		"t".code => "\t",
		"r".code => "\r",
		"0".code => "\\" + "0",
		"\\".code => "\\",
		"\"".code => "\"",
		"'".code => "'",
		"`".code => "`",
		"$".code => "$",
		_ => s.source.byteSlice(s.pos - 1, s.pos),
	};
}

export function scanString(s: LexerState, quote: number): void {
	const startLine = s.line;
	const startCol = s.column;
	let val = "";
	advanceChar(s); // skip opening quote

	while (s.pos < s.source.byteLength) {
		const ch = peek(s);
		if (ch === quote) {
			advanceChar(s);
			addToken(s, TokenKind.String, val, startLine, startCol);
			return;
		}
		if (ch === "\\".code) {
			val += scanEscape(s);
		} else {
			val += s.source.byteSlice(s.pos, s.pos + 1);
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
	// Reference compiler: lexer.zig:422 scanBacktick — peek ahead for stropped identifiers
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
				let content = "";
				let ci = s.pos;
				while (ci < tempPos) {
					content = content + s.source.byteSlice(ci, ci + 1);
					ci = ci + 1;
				}
				if (isOperatorName(content)) {
					// Skip content and closing backtick
					s.pos = tempPos;
					s.column = s.column + contentLen;
					advanceChar(s); // closing backtick
					addToken(s, TokenKind.OperatorIdent, content, startLine, startCol);
					return;
				}
			}
		}
	}

	while (s.pos < s.source.byteLength) {
		const ch = peek(s);
		if (ch === "`".code) {
			advanceChar(s);
			addToken(s, isContinuation ? TokenKind.TemplateTail : TokenKind.TemplateNoSub, val, startLine, startCol);
			return;
		}
		if (ch === "$".code && peekAt(s, 1) === "{".code) {
			skip(s, 2);
			s.templateDepth += 1;
			addToken(s, isContinuation ? TokenKind.TemplateMiddle : TokenKind.TemplateHead, val, startLine, startCol);
			return;
		}
		if (ch === "\\".code) {
			val += scanEscape(s);
		} else {
			val += s.source.byteSlice(s.pos, s.pos + 1);
			advanceChar(s);
		}
	}
}

// Check if a backtick-quoted string is an operator name.
// Reference compiler: parser.zig:7162 isOperatorName
function isOperatorChar(ch: number): boolean {
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
	let content = "//";
	while (s.pos < s.source.byteLength && peek(s) !== "\n".code && peek(s) !== "\r".code) {
		content += s.source.byteSlice(s.pos, s.pos + 1);
		advanceChar(s);
	}
	addComment(s, content, startLine, startCol);
}

export function scanBlockComment(s: LexerState): void {
	const startLine = s.line;
	const startCol = s.column - 2; // includes /*
	let content = "/*";
	while (s.pos < s.source.byteLength) {
		const ch = peek(s);
		if (ch === "*".code && peekAt(s, 1) === "/".code) {
			content += "*/";
			skip(s, 2);
			addComment(s, content, startLine, startCol);
			return;
		}
		content += s.source.byteSlice(s.pos, s.pos + 1);
		advanceChar(s);
	}
}

// ===== Regex Literal Scanning =====

function scanRegex(s: LexerState): void {
	const startLine = s.line;
	const startCol = s.column;
	let pattern = "/";
	advanceChar(s); // skip opening /

	while (s.pos < s.source.byteLength) {
		const ch = peek(s);
		if (ch === "/".code) {
			pattern += "/";
			advanceChar(s);
			break;
		}
		if (ch === "\\".code) {
			pattern += "\\";
			advanceChar(s);
			pattern += s.source.byteSlice(s.pos, s.pos + 1);
			advanceChar(s);
			continue;
		}
		if (ch === "\n".code) {
			// Regex cannot span lines
			break;
		}
		pattern += s.source.byteSlice(s.pos, s.pos + 1);
		advanceChar(s);
	}

	// Scan flags (g, i, m, s, u, y, d)
	while (s.pos < s.source.byteLength && isLetter(peek(s))) {
		pattern += s.source.byteSlice(s.pos, s.pos + 1);
		advanceChar(s);
	}

	addToken(s, TokenKind.Regex, pattern, startLine, startCol);
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
