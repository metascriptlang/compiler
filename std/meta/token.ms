// std/meta/token — Token definitions for MetaScript.
// Source of truth; the compiler re-exports via src/lexer/token.ms.

export enum TokenKind {
	// Literals
	Number, BigInt, String, Regex, TemplateHead, TemplateMiddle, TemplateTail, TemplateNoSub,
	// Identifier
	Ident,
	// Operator identifier: backtick-quoted operator name like `==`, `[]`, `[]=`
	OperatorIdent,
	// Operators
	Plus, Minus, Star, Slash, Percent, StarStar,
	Assign, PlusEq, MinusEq, StarEq, SlashEq, PercentEq,
	EqEq, EqEqEq, BangEq, BangEqEq,
	Lt, LtEq, Gt, GtEq,
	AmpAmp, PipePipe, Bang,
	Amp, Pipe, Caret, Tilde, LtLt, GtGt, GtGtGt,
	PlusPlus, MinusMinus,
	Question, QuestionQuestion, QuestionDot,
	Dot, DotDot, DotDotDot, Arrow, PipeGt,
	LParen, RParen, LBrace, RBrace, LBracket, RBracket,
	Semicolon, Colon, Comma, At,
	// Keywords
	Break, Case, Catch, Class, Const, Continue, Debugger, Default, Delete, Do,
	Else, Enum, Export, Extends, False, Finally, For, Function,
	If, Import, In, Instanceof, Interface, Let, New, Null,
	Return, Super, Switch, This, Throw, True, Try, Typeof, Var, Void, While, With,
	Abstract, As, Asserts, Async, Await, Constructor, Declare, From, Get,
	Implements, Infer, Is, Keyof, Namespace, Never, Of,
	Private, Protected, Public, Readonly, Require, Set, Static, Type, Unknown, Yield,
	Match, When, Unreachable, Defer, Distinct, Move, Out, Ref, Test, Assert, Macro, Extern, Quote, Char, Sizeof, Struct,
	Int8, Int16, Int32, Int64, Uint8, Uint16, Uint32, Uint64,
	Float32, Float64, Int, Float, Double, CString,
	Comment,
	// EOF
	Eof,
	// Actor (appended after Eof to preserve enum ordering — isIdentOrKeyword range check still works
	// because Actor > Break and Actor !== Comment and Actor !== Eof)
	Actor,
	// Quote interpolation: ${ — appended at end to preserve all existing ordinals.
	QuoteInterp,
	// Template keyword — appended at end to preserve ordinals.
	Template,
	// Converter keyword — third routine kind (LANG.md "Converter Declarations"). Placed
	// before the JSX block so it stays inside the isIdentLike contextual-keyword range.
	Converter,
	// JSX structural tokens — appended to preserve ordinals. Unlike Actor these are NOT
	// ident-like; the `>= Break`/`>= Abstract` range checks lack an upper bound (guard: the
	// "jsx tokens are not ident-like" test).
	JsxTagStart, JsxClose, JsxText,
}

export interface Token {
	kind: TokenKind;
	value: string;
	line: number;
	column: number;
	rawValue: string;
}
