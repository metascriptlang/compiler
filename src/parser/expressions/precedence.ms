// Operator Precedence - Pure functions for Pratt parser
// Extracted from expression.ms to keep it focused

import { Token, TokenKind } from "../../lexer/token";

// ===== Operator Precedence (match expression -> C switch) =====

export function getPrecedence(kind: TokenKind): number {
	return match (kind) {
		TokenKind.Star | TokenKind.Slash | TokenKind.Percent => 60,
		TokenKind.Plus | TokenKind.Minus => 50,
		TokenKind.LtLt | TokenKind.GtGt | TokenKind.GtGtGt => 45,
		TokenKind.Lt | TokenKind.Gt | TokenKind.LtEq | TokenKind.GtEq => 40,
		TokenKind.EqEq | TokenKind.BangEq | TokenKind.EqEqEq | TokenKind.BangEqEq => 30,
		TokenKind.AmpAmp => 20,
		TokenKind.PipePipe => 10,
		TokenKind.Assign | TokenKind.PlusEq | TokenKind.MinusEq |
		TokenKind.StarEq | TokenKind.SlashEq | TokenKind.PercentEq => 5,
		_ => 0,
	};
}

export function isBinaryOperator(token: Token): boolean {
	return match (token.kind) {
		TokenKind.Plus | TokenKind.Minus | TokenKind.Star |
		TokenKind.Slash | TokenKind.Percent |
		TokenKind.Lt | TokenKind.Gt | TokenKind.LtEq | TokenKind.GtEq |
		TokenKind.EqEq | TokenKind.BangEq | TokenKind.EqEqEq | TokenKind.BangEqEq |
		TokenKind.LtLt | TokenKind.GtGt | TokenKind.GtGtGt |
		TokenKind.AmpAmp | TokenKind.PipePipe |
		TokenKind.Assign | TokenKind.PlusEq | TokenKind.MinusEq |
		TokenKind.StarEq | TokenKind.SlashEq | TokenKind.PercentEq => true,
		_ => false,
	};
}
