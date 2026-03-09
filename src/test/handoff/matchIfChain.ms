// Test: match expression with multiple patterns generates valid if-else chain
// The codegen must not insert statements between } and else if {}.

import { compileToC } from "../helpers";

test "match on enum with side-effect arms produces valid C if-else" {
	const src = `
enum TokenKind { LParen, RParen, Comma, Dot, Arrow, LBracket }

interface Token {
	kind: TokenKind;
	value: string;
}

function current(idx: number): Token {
	return { kind: TokenKind.LParen, value: "" };
}

export function parse(idx: number): string {
	const tok = current(idx);
	if (tok.kind === TokenKind.LParen) {
		return "paren";
	} else if (tok.kind === TokenKind.RParen) {
		return "rparen";
	} else if (tok.kind === TokenKind.Comma) {
		return "comma";
	} else {
		return "other";
	}
}
`;
	const r = compileToC(src);
	assert r.ok;
	const code = r.value;
	// The if-else chain must not have orphaned else
	assert !code.contains(";\n else if");
}

test "match statement with current() calls between branches is valid C" {
	const src = `
enum Kind { A, B, C }

export function dispatch(k: Kind): number {
	const result = match (k) {
		Kind.A => 1,
		Kind.B => 2,
		_ => 3,
	};
	return result;
}
`;
	const r = compileToC(src);
	assert r.ok;
	const code = r.value;
	// Should not have MS_NIL assigned to a number variable
	assert !code.contains("result = MS_NIL");
}
