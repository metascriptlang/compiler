// Lexer - Tokenization
// Converts source code into a sequence of tokens

import { Token } from "./token.ms";

// Helper: Check if character is whitespace
function isWhitespace(ch: number): boolean {
	return ch === 32 || ch === 10 || ch === 13 || ch === 9; // space, \n, \r, \t
}

// Helper: Check if character is a digit (0-9)
function isDigit(ch: number): boolean {
	return ch >= 48 && ch <= 57; // '0' to '9'
}

// Helper: Check if character is a letter (a-z, A-Z)
function isLetter(ch: number): boolean {
	return (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122); // A-Z or a-z
}

// Lexer: Convert source code string into tokens
export function lex(source: string): Token[] {
	const tokens: Token[] = [];
	let pos = 0;
	let line = 1;

	while (pos < source.length) {
		const ch = source.charCodeAt(pos);

		// Skip whitespace
		if (isWhitespace(ch)) {
			if (ch === 10) line = line + 1; // newline
			pos = pos + 1;
			continue;
		}

		// Number: 123, 45, etc.
		if (isDigit(ch)) {
			let numStr = "";
			while (pos < source.length && isDigit(source.charCodeAt(pos))) {
				numStr = numStr + source.charAt(pos);
				pos = pos + 1;
			}
			// Force string copy to avoid lifetime issues
			const numValue = numStr + "";
			tokens.push({ type: "NUMBER", value: numValue, line: line });
			continue;
		}

		// Identifier or keyword: abc, function, let, etc.
		if (isLetter(ch)) {
			let ident = "";
			while (pos < source.length) {
				const c = source.charCodeAt(pos);
				if (isLetter(c) || isDigit(c)) {
					ident = ident + source.charAt(pos);
					pos = pos + 1;
				} else {
					break;
				}
			}
			// Force string copy to avoid lifetime issues
			const identValue = ident + "";
			tokens.push({ type: "IDENT", value: identValue, line: line });
			continue;
		}

		// Unknown character - skip for now
		pos = pos + 1;
	}

	// Add EOF token
	tokens.push({ type: "EOF", value: "", line: line });
	return tokens;
}
