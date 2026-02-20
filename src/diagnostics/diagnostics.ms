// Diagnostics - Shared error formatting helpers
// Pattern: ~/projects/metascript/src/diagnostics/diagnostics.zig

import { Token } from "../lexer/token";

export function formatError(msg: string, line: number, col: number): string {
	return `Error at line ${line.toString()}, col ${col.toString()}: ${msg}`;
}

export function unexpectedToken(expected: string, got: Token): string {
	return `Expected ${expected}, got '${got.value}' at line ${got.line.toString()}`;
}
