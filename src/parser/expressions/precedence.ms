// Operator Precedence - Pure functions for Pratt parser
// Extracted from expression.ms to keep it focused

import { Token, TokenKind } from "../../lexer/token";

// ===== Operator Precedence (match expression -> C switch) =====
// JS-aligned precedence: ** > * / % > + - > << >> >>> > < > <= >= >
// == != === !== > & > ^ > | > && > || > ?? > |> > = += etc.

export function getPrecedence(kind: TokenKind): number {
	return match (kind) {
		TokenKind.StarStar => 65,
		TokenKind.Star | TokenKind.Slash | TokenKind.Percent => 60,
		TokenKind.Plus | TokenKind.Minus => 50,
		TokenKind.LtLt | TokenKind.GtGt | TokenKind.GtGtGt => 45,
		TokenKind.Lt | TokenKind.Gt | TokenKind.LtEq | TokenKind.GtEq |
		TokenKind.In | TokenKind.Instanceof => 40,
		TokenKind.EqEq | TokenKind.BangEq | TokenKind.EqEqEq | TokenKind.BangEqEq => 30,
		TokenKind.Amp => 27,
		TokenKind.Caret => 25,
		TokenKind.Pipe => 23,
		TokenKind.AmpAmp => 20,
		TokenKind.PipePipe => 10,
		TokenKind.QuestionQuestion => 8,
		TokenKind.Assign | TokenKind.PlusEq | TokenKind.MinusEq |
		TokenKind.StarEq | TokenKind.SlashEq | TokenKind.PercentEq => 5,
		TokenKind.PipeGt => 3,
		_ => 0,
	};
}

export function isBinaryOperator(token: Token): boolean {
	return match (token.kind) {
		TokenKind.Plus | TokenKind.Minus | TokenKind.Star |
		TokenKind.Slash | TokenKind.Percent | TokenKind.StarStar |
		TokenKind.Lt | TokenKind.Gt | TokenKind.LtEq | TokenKind.GtEq |
		TokenKind.In | TokenKind.Instanceof |
		TokenKind.EqEq | TokenKind.BangEq | TokenKind.EqEqEq | TokenKind.BangEqEq |
		TokenKind.LtLt | TokenKind.GtGt | TokenKind.GtGtGt |
		TokenKind.Amp | TokenKind.Caret | TokenKind.Pipe |
		TokenKind.AmpAmp | TokenKind.PipePipe |
		TokenKind.QuestionQuestion | TokenKind.PipeGt |
		TokenKind.Assign | TokenKind.PlusEq | TokenKind.MinusEq |
		TokenKind.StarEq | TokenKind.SlashEq | TokenKind.PercentEq => true,
		_ => false,
	};
}

// Right-associative operators: a ** b ** c => a ** (b ** c)
// Assignment: a = b = c => a = (b = c)
export function isRightAssociative(kind: TokenKind): boolean {
	return match (kind) {
		TokenKind.StarStar |
		TokenKind.Assign | TokenKind.PlusEq | TokenKind.MinusEq |
		TokenKind.StarEq | TokenKind.SlashEq | TokenKind.PercentEq => true,
		_ => false,
	};
}
