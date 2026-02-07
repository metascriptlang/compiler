// Token interface - heap-allocated, stores token information
export interface Token {
	type: string; // Token type: "NUMBER", "IDENT", "PLUS", etc.
	value: string; // Token value: the actual text
	line: number; // Line number for error reporting
}

// Create a token (heap-allocated via interface)
export function createToken(tokenType: string, tokenValue: string, lineNum: number): Token {
	return { type: tokenType, value: tokenValue, line: lineNum };
}

// Format token for display
export function formatToken(token: Token): string {
	return "[" + token.type + ": '" + token.value + "' at line " + token.line.toString() + "]";
}
