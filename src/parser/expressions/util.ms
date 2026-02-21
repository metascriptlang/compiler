// Expression Test Utilities
// Provides parseOk() for integration tests across expression sub-modules.
// core.ms registers the real parseExpression at module load time.
// Test callbacks are lazy (registered during load, executed after), so
// parseFn is always set by the time tests actually run.

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, Expression } from "../../ast/node";
import { lex } from "../../lexer/lexer";

type ExprResult = Result<Expression, string>;
type ParseExprFn = (tokens: Token[]) => ExprResult;

let parseFn: ParseExprFn = (tokens: Token[]): ExprResult => {
	return Result.err("parseOk not registered");
};

export function registerParseExpr(fn: ParseExprFn): void {
	parseFn = fn;
}

export function parseOk(input: string): boolean {
	const lr = lex(input);
	if (!lr.ok) return false;
	const pr = parseFn(lr.value);
	return pr.ok;
}
