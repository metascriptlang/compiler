// Scanner — Tokenization of numbers, strings, identifiers, operators, comments
// Pattern: ~/projects/metascript/src/lexer/lexer.zig

import { Token, TokenKind, identToKeyword } from "./token";
import { LexerState, createLexerState, peek, peekAt, advanceChar, skip, addToken } from "./state";
import { isDigit, isHexDigit, isLetter, isAlphanumeric, isBinaryDigit, isOctalDigit } from "./chars";
import { test, check, testGroup } from "std/testing";

// ===== Shared Escape Sequence Handler =====

export function processEscape(s: LexerState): string {
	advanceChar(s); // skip backslash
	const escChar = s.source.charAt(s.pos);
	advanceChar(s);
	return match (escChar) {
		"n" => "\n",
		"t" => "\t",
		"r" => "\r",
		"\\" => "\\",
		"0" => "\0",
		_ => escChar,
	};
}

// ===== Number Scanning =====

export function emitNumber(s: LexerState, numStr: string, startLine: number, startCol: number): void {
	if (s.pos < s.source.length && peek(s) === "n".code) {
		advanceChar(s);
		addToken(s, TokenKind.BigInt, numStr + "n", startLine, startCol);
	} else {
		addToken(s, TokenKind.Number, numStr, startLine, startCol);
	}
}

export function scanHexDigits(s: LexerState): string {
	let result = "";
	while (s.pos < s.source.length && (isHexDigit(peek(s)) || peek(s) === "_".code)) {
		if (peek(s) !== "_".code) result += s.source.charAt(s.pos);
		advanceChar(s);
	}
	return result;
}

export function scanDecDigits(s: LexerState): string {
	let result = "";
	while (s.pos < s.source.length && (isDigit(peek(s)) || peek(s) === "_".code)) {
		if (peek(s) !== "_".code) result += s.source.charAt(s.pos);
		advanceChar(s);
	}
	return result;
}

export function scanBinDigits(s: LexerState): string {
	let result = "";
	while (s.pos < s.source.length && (isBinaryDigit(peek(s)) || peek(s) === "_".code)) {
		if (peek(s) !== "_".code) result += s.source.charAt(s.pos);
		advanceChar(s);
	}
	return result;
}

export function scanOctDigits(s: LexerState): string {
	let result = "";
	while (s.pos < s.source.length && (isOctalDigit(peek(s)) || peek(s) === "_".code)) {
		if (peek(s) !== "_".code) result += s.source.charAt(s.pos);
		advanceChar(s);
	}
	return result;
}

export function scanNumber(s: LexerState): void {
	const startLine = s.line;
	const startCol = s.column;
	const first = peek(s);

	// Check for hex (0x), binary (0b), octal (0o)
	if (first === "0".code && s.pos + 1 < s.source.length) {
		const next = peekAt(s, 1);
		if (next === "x".code || next === "X".code) {
			skip(s, 2);
			emitNumber(s, "0x" + scanHexDigits(s), startLine, startCol);
			return;
		}
		if (next === "b".code || next === "B".code) {
			skip(s, 2);
			emitNumber(s, "0b" + scanBinDigits(s), startLine, startCol);
			return;
		}
		if (next === "o".code || next === "O".code) {
			skip(s, 2);
			emitNumber(s, "0o" + scanOctDigits(s), startLine, startCol);
			return;
		}
	}

	// Decimal integer part
	let numStr = scanDecDigits(s);

	// Decimal point (only if followed by a digit, to avoid consuming `0.toString()`)
	if (s.pos < s.source.length && peek(s) === ".".code) {
		if (s.pos + 1 < s.source.length && isDigit(peekAt(s, 1))) {
			advanceChar(s);
			numStr = numStr + "." + scanDecDigits(s);
		}
	}

	// Exponent (e/E)
	if (s.pos < s.source.length && (peek(s) === "e".code || peek(s) === "E".code)) {
		numStr += s.source.charAt(s.pos);
		advanceChar(s);
		if (s.pos < s.source.length && (peek(s) === "+".code || peek(s) === "-".code)) {
			numStr += s.source.charAt(s.pos);
			advanceChar(s);
		}
		numStr = numStr + scanDecDigits(s);
	}

	emitNumber(s, numStr, startLine, startCol);
}

// ===== String Scanning =====

export function scanString(s: LexerState, quoteChar: number): void {
	const startLine = s.line;
	const startCol = s.column;
	advanceChar(s); // skip opening quote
	let str = "";

	while (s.pos < s.source.length && peek(s) !== quoteChar && peek(s) !== "\n".code) {
		if (peek(s) === "\\".code) {
			// Check quote-specific escape before common handler
			if (s.pos + 1 < s.source.length && peekAt(s, 1) === quoteChar) {
				advanceChar(s); // skip backslash
				if (quoteChar === "\"".code) { str += "\""; }
				else { str += "'"; }
				advanceChar(s);
			} else {
				str += processEscape(s);
			}
		} else {
			str += s.source.charAt(s.pos);
			advanceChar(s);
		}
	}

	if (s.pos < s.source.length && peek(s) === quoteChar) {
		advanceChar(s); // skip closing quote
	}
	addToken(s, TokenKind.String, str, startLine, startCol);
}

export function scanTemplateString(s: LexerState): void {
	const startLine = s.line;
	const startCol = s.column;
	advanceChar(s); // skip opening backtick
	let str = "";

	while (s.pos < s.source.length && peek(s) !== "`".code) {
		if (peek(s) === "$".code && s.pos + 1 < s.source.length && peekAt(s, 1) === "{".code) {
			addToken(s, TokenKind.TemplateHead, str, startLine, startCol);
			skip(s, 2); // ${
			return;
		}
		if (peek(s) === "\\".code) {
			// Template-specific escapes: backtick and dollar
			if (s.pos + 1 < s.source.length && peekAt(s, 1) === "`".code) {
				advanceChar(s);
				str += "`";
				advanceChar(s);
			} else if (s.pos + 1 < s.source.length && peekAt(s, 1) === "$".code) {
				advanceChar(s);
				str += "$";
				advanceChar(s);
			} else {
				str += processEscape(s);
			}
		} else {
			str += s.source.charAt(s.pos);
			advanceChar(s);
		}
	}

	if (s.pos < s.source.length) advanceChar(s); // skip closing backtick
	addToken(s, TokenKind.TemplateNoSub, str, startLine, startCol);
}

// ===== Identifier Scanning =====

export function scanIdentifier(s: LexerState): void {
	const startLine = s.line;
	const startCol = s.column;
	let ident = "";

	while (s.pos < s.source.length && isAlphanumeric(peek(s))) {
		ident += s.source.charAt(s.pos);
		advanceChar(s);
	}

	const keyword = identToKeyword(ident);
	addToken(s, keyword, ident, startLine, startCol);
}

// ===== Comment Handling =====

export function skipLineComment(s: LexerState): void {
	while (s.pos < s.source.length && peek(s) !== "\n".code) {
		advanceChar(s);
	}
}

export function skipBlockComment(s: LexerState): void {
	while (s.pos < s.source.length) {
		if (peek(s) === "*".code && s.pos + 1 < s.source.length && peekAt(s, 1) === "/".code) {
			skip(s, 2);
			return;
		}
		advanceChar(s);
	}
}

// ===== Operator & Punctuation Scanning =====

export function scanOperator(s: LexerState): boolean {
	const ch = peek(s);
	const startLine = s.line;
	const startCol = s.column;
	const next = peekAt(s, 1);

	return match (ch) {
		"/".code => {
			if (next === "/".code) { skip(s, 2); skipLineComment(s); }
			else if (next === "*".code) { skip(s, 2); skipBlockComment(s); }
			else if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.SlashEq, "/=", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Slash, "/", startLine, startCol); }
			true
		},
		"=".code => {
			if (next === "=".code && peekAt(s, 2) === "=".code) { skip(s, 3); addToken(s, TokenKind.EqEqEq, "===", startLine, startCol); }
			else if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.EqEq, "==", startLine, startCol); }
			else if (next === ">".code) { skip(s, 2); addToken(s, TokenKind.Arrow, "=>", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Assign, "=", startLine, startCol); }
			true
		},
		"!".code => {
			if (next === "=".code && peekAt(s, 2) === "=".code) { skip(s, 3); addToken(s, TokenKind.BangEqEq, "!==", startLine, startCol); }
			else if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.BangEq, "!=", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Bang, "!", startLine, startCol); }
			true
		},
		"<".code => {
			if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.LtEq, "<=", startLine, startCol); }
			else if (next === "<".code) { skip(s, 2); addToken(s, TokenKind.LtLt, "<<", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Lt, "<", startLine, startCol); }
			true
		},
		">".code => {
			if (next === ">".code && peekAt(s, 2) === ">".code) { skip(s, 3); addToken(s, TokenKind.GtGtGt, ">>>", startLine, startCol); }
			else if (next === ">".code) { skip(s, 2); addToken(s, TokenKind.GtGt, ">>", startLine, startCol); }
			else if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.GtEq, ">=", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Gt, ">", startLine, startCol); }
			true
		},
		"&".code => {
			if (next === "&".code) { skip(s, 2); addToken(s, TokenKind.AmpAmp, "&&", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Amp, "&", startLine, startCol); }
			true
		},
		"|".code => {
			if (next === "|".code) { skip(s, 2); addToken(s, TokenKind.PipePipe, "||", startLine, startCol); }
			else if (next === ">".code) { skip(s, 2); addToken(s, TokenKind.PipeGt, "|>", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Pipe, "|", startLine, startCol); }
			true
		},
		"?".code => {
			if (next === "?".code) { skip(s, 2); addToken(s, TokenKind.QuestionQuestion, "??", startLine, startCol); }
			else if (next === ".".code) { skip(s, 2); addToken(s, TokenKind.QuestionDot, "?.", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Question, "?", startLine, startCol); }
			true
		},
		".".code => {
			if (next === ".".code && peekAt(s, 2) === ".".code) { skip(s, 3); addToken(s, TokenKind.DotDotDot, "...", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Dot, ".", startLine, startCol); }
			true
		},
		"+".code => {
			if (next === "+".code) { skip(s, 2); addToken(s, TokenKind.PlusPlus, "++", startLine, startCol); }
			else if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.PlusEq, "+=", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Plus, "+", startLine, startCol); }
			true
		},
		"-".code => {
			if (next === "-".code) { skip(s, 2); addToken(s, TokenKind.MinusMinus, "--", startLine, startCol); }
			else if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.MinusEq, "-=", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Minus, "-", startLine, startCol); }
			true
		},
		"*".code => {
			if (next === "*".code) { skip(s, 2); addToken(s, TokenKind.StarStar, "**", startLine, startCol); }
			else if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.StarEq, "*=", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Star, "*", startLine, startCol); }
			true
		},
		"%".code => {
			if (next === "=".code) { skip(s, 2); addToken(s, TokenKind.PercentEq, "%=", startLine, startCol); }
			else { advanceChar(s); addToken(s, TokenKind.Percent, "%", startLine, startCol); }
			true
		},
		_ => false,
	};
}

export function scanPunctuation(s: LexerState): boolean {
	const ch = peek(s);
	const startLine = s.line;
	const startCol = s.column;
	return match (ch) {
		"(".code => { advanceChar(s); addToken(s, TokenKind.LParen, "(", startLine, startCol); true },
		")".code => { advanceChar(s); addToken(s, TokenKind.RParen, ")", startLine, startCol); true },
		"{".code => { advanceChar(s); addToken(s, TokenKind.LBrace, "{", startLine, startCol); true },
		"}".code => { advanceChar(s); addToken(s, TokenKind.RBrace, "}", startLine, startCol); true },
		"[".code => { advanceChar(s); addToken(s, TokenKind.LBracket, "[", startLine, startCol); true },
		"]".code => { advanceChar(s); addToken(s, TokenKind.RBracket, "]", startLine, startCol); true },
		";".code => { advanceChar(s); addToken(s, TokenKind.Semicolon, ";", startLine, startCol); true },
		":".code => { advanceChar(s); addToken(s, TokenKind.Colon, ":", startLine, startCol); true },
		",".code => { advanceChar(s); addToken(s, TokenKind.Comma, ",", startLine, startCol); true },
		"@".code => { advanceChar(s); addToken(s, TokenKind.At, "@", startLine, startCol); true },
		"~".code => { advanceChar(s); addToken(s, TokenKind.Tilde, "~", startLine, startCol); true },
		"^".code => { advanceChar(s); addToken(s, TokenKind.Caret, "^", startLine, startCol); true },
		_ => false,
	};
}

// ===== Tests =====

testGroup("Scan Number", () => {
	test("integer", () => {
		const s = createLexerState("42");
		scanNumber(s);
		check(s.tokens.length === 1);
		check(s.tokens[0].kind === TokenKind.Number);
		check(s.tokens[0].value === "42");
	});

	test("float", () => {
		const s = createLexerState("3.14");
		scanNumber(s);
		check(s.tokens[0].kind === TokenKind.Number);
		check(s.tokens[0].value === "3.14");
	});

	test("hex", () => {
		const s = createLexerState("0xFF");
		scanNumber(s);
		check(s.tokens[0].value === "0xFF");
	});

	test("hex with underscore", () => {
		const s = createLexerState("0xFF_FF");
		scanNumber(s);
		check(s.tokens[0].value === "0xFFFF");
	});

	test("binary", () => {
		const s = createLexerState("0b1010");
		scanNumber(s);
		check(s.tokens[0].value === "0b1010");
	});

	test("octal", () => {
		const s = createLexerState("0o777");
		scanNumber(s);
		check(s.tokens[0].value === "0o777");
	});

	test("underscore separator", () => {
		const s = createLexerState("1_000_000");
		scanNumber(s);
		check(s.tokens[0].value === "1000000");
	});

	test("exponent", () => {
		const s = createLexerState("1e10");
		scanNumber(s);
		check(s.tokens[0].value === "1e10");
	});

	test("negative exponent", () => {
		const s = createLexerState("1.5e-3");
		scanNumber(s);
		check(s.tokens[0].value === "1.5e-3");
	});

	test("bigint", () => {
		const s = createLexerState("123n");
		scanNumber(s);
		check(s.tokens[0].kind === TokenKind.BigInt);
		check(s.tokens[0].value === "123n");
	});

	test("does not consume dot before non-digit", () => {
		const s = createLexerState("0.x");
		scanNumber(s);
		check(s.tokens[0].value === "0");
		check(s.pos === 1);
	});
});

testGroup("Scan String", () => {
	test("double-quoted", () => {
		const s = createLexerState("\"hello\"");
		scanString(s, "\"".code);
		check(s.tokens[0].kind === TokenKind.String);
		check(s.tokens[0].value === "hello");
	});

	test("single-quoted", () => {
		const s = createLexerState("'world'");
		scanString(s, "'".code);
		check(s.tokens[0].value === "world");
	});

	test("escape sequences", () => {
		const s = createLexerState("\"a\\nb\\tc\"");
		scanString(s, "\"".code);
		check(s.tokens[0].value === "a\nb\tc");
	});

	test("escaped quote", () => {
		const s = createLexerState("\"say \\\"hi\\\"\"");
		scanString(s, "\"".code);
		check(s.tokens[0].value === "say \"hi\"");
	});

	test("empty", () => {
		const s = createLexerState("\"\"");
		scanString(s, "\"".code);
		check(s.tokens[0].value === "");
	});
});

testGroup("Scan Template Strings", () => {
	test("simple", () => {
		const s = createLexerState("`hello`");
		scanTemplateString(s);
		check(s.tokens[0].kind === TokenKind.TemplateNoSub);
		check(s.tokens[0].value === "hello");
	});

	test("with substitution start", () => {
		const s = createLexerState("`hi ${");
		scanTemplateString(s);
		check(s.tokens[0].kind === TokenKind.TemplateHead);
		check(s.tokens[0].value === "hi ");
	});

	test("escaped backtick", () => {
		const s = createLexerState("`a\\`b`");
		scanTemplateString(s);
		check(s.tokens[0].value === "a`b");
	});

	test("escaped dollar", () => {
		const s = createLexerState("`\\$100`");
		scanTemplateString(s);
		check(s.tokens[0].value === "$100");
	});
});

testGroup("Scan Identifiers", () => {
	test("simple", () => {
		const s = createLexerState("myVar");
		scanIdentifier(s);
		check(s.tokens[0].kind === TokenKind.Ident);
		check(s.tokens[0].value === "myVar");
	});

	test("keyword", () => {
		const s = createLexerState("const");
		scanIdentifier(s);
		check(s.tokens[0].kind === TokenKind.Const);
		check(s.tokens[0].value === "const");
	});

	test("keyword prefix is ident", () => {
		const s = createLexerState("constX");
		scanIdentifier(s);
		check(s.tokens[0].kind === TokenKind.Ident);
		check(s.tokens[0].value === "constX");
	});
});

testGroup("Skip Comment", () => {
	test("line comment", () => {
		const s = createLexerState("// comment\ncode");
		skip(s, 2);
		skipLineComment(s);
		check(peek(s) === "\n".code);
	});

	test("block comment", () => {
		const s = createLexerState("/* block */rest");
		skip(s, 2);
		skipBlockComment(s);
		check(s.source.charAt(s.pos) === "r");
	});
});

testGroup("Scan Operators", () => {
	test("===", () => {
		const s = createLexerState("===");
		check(scanOperator(s));
		check(s.tokens[0].kind === TokenKind.EqEqEq);
	});

	test("!==", () => {
		const s = createLexerState("!==");
		check(scanOperator(s));
		check(s.tokens[0].kind === TokenKind.BangEqEq);
	});

	test(">>>", () => {
		const s = createLexerState(">>>");
		check(scanOperator(s));
		check(s.tokens[0].kind === TokenKind.GtGtGt);
	});

	test("=>", () => {
		const s = createLexerState("=>");
		check(scanOperator(s));
		check(s.tokens[0].kind === TokenKind.Arrow);
	});

	test("line comment consumed", () => {
		const s = createLexerState("// comment\nx");
		check(scanOperator(s));
		check(s.tokens.length === 0);
	});

	test("unrecognized char returns false", () => {
		const s = createLexerState("a");
		check(!scanOperator(s));
		check(s.tokens.length === 0);
	});
});

testGroup("Scan Punctuation", () => {
	test("all delimiters", () => {
		const s = createLexerState("(");
		check(scanPunctuation(s));
		check(s.tokens[0].kind === TokenKind.LParen);
	});

	test("unrecognized returns false", () => {
		const s = createLexerState("a");
		check(!scanPunctuation(s));
	});
});
