// Lexer — Main entry point for tokenization
// Converts source code into a sequence of tokens
// Pattern: ~/projects/metascript/src/lexer/lexer.zig

import { Token, TokenKind } from "./token";
import { LexerState, Tokens, createLexerState, peek, advanceChar, addToken } from "./state";
import { isWhitespace, isNewline, isDigit, isLetter } from "./chars";
import { scanNumber, scanString, scanTemplateString, scanIdentifier, scanOperator, scanPunctuation } from "./scanner";
import { test, check, testGroup } from "std/testing";

// ===== Main Lex Function =====

export function lex(source: string): Result<Tokens, string> {
	const s = createLexerState(source);

	while (s.pos < s.source.length) {
		const ch = peek(s);

		// Skip whitespace and newlines
		if (isWhitespace(ch) || isNewline(ch)) {
			advanceChar(s);
			continue;
		}

		// Numbers
		if (isDigit(ch)) { scanNumber(s); continue; }

		// Identifiers and keywords
		if (isLetter(ch)) { scanIdentifier(s); continue; }

		// String literals
		if (ch === "\"".code || ch === "'".code) { scanString(s, ch); continue; }

		// Template literals
		if (ch === "`".code) { scanTemplateString(s); continue; }

		// Operators (multi-char and single-char)
		if (scanOperator(s)) { continue; }

		// Punctuation (single-char tokens)
		if (scanPunctuation(s)) { continue; }

		// Unknown character - error
		return Result.err(`Unknown character at line ${s.line.toString()}, column ${s.column.toString()}`);
	}

	// Add EOF token
	addToken(s, TokenKind.Eof, "", s.line, s.column);
	return Result.ok(s.tokens);
}

// ===== Test Helpers =====
// Note: helpers return primitives (not Token[]) to avoid DRC closure issues
// with MS_ARRAY_REF_DESTROY in test closure bodies.

function lexOk(input: string): boolean {
	const result = lex(input);
	return result.ok;
}

function lexCount(input: string): number {
	const result = lex(input);
	if (!result.ok) return 0;
	const tokens = result.value;
	if (tokens.length === 0) return 0;
	return tokens.length - 1; // exclude EOF
}

function lexFirst(input: string): TokenKind {
	const result = lex(input);
	if (!result.ok) return TokenKind.Eof;
	const tokens = result.value;
	if (tokens.length === 0) return TokenKind.Eof;
	return tokens[0].kind;
}

function lexFirstVal(input: string): string {
	const result = lex(input);
	if (!result.ok) return "";
	const tokens = result.value;
	if (tokens.length === 0) return "";
	return tokens[0].value;
}

function lexKindAt(input: string, index: number): TokenKind {
	const result = lex(input);
	if (!result.ok) return TokenKind.Eof;
	const tokens = result.value;
	if (index >= tokens.length) return TokenKind.Eof;
	return tokens[index].kind;
}

function lexValAt(input: string, index: number): string {
	const result = lex(input);
	if (!result.ok) return "";
	const tokens = result.value;
	if (index >= tokens.length) return "";
	return tokens[index].value;
}

function lexLen(input: string): number {
	const result = lex(input);
	if (!result.ok) return 0;
	return result.value.length;
}

function lexLineAt(input: string, index: number): number {
	const result = lex(input);
	if (!result.ok) return 0;
	const tokens = result.value;
	if (index >= tokens.length) return 0;
	return tokens[index].line;
}

function lexColAt(input: string, index: number): number {
	const result = lex(input);
	if (!result.ok) return 0;
	const tokens = result.value;
	if (index >= tokens.length) return 0;
	return tokens[index].column;
}

// ===== Integration Tests =====

testGroup("Lexer Basics", () => {
	test("empty string", () => {
		check(lexOk(""));
		check(lexCount("") === 0);
	});

	test("whitespace only", () => {
		check(lexOk("   "));
		check(lexCount("   ") === 0);
		check(lexOk("\t\t"));
		check(lexOk("\n\n\n"));
		check(lexOk("  \n\t  \n  "));
	});
});

testGroup("Lexer Token Types", () => {
	test("numbers", () => {
		check(lexFirst("42") === TokenKind.Number);
		check(lexFirstVal("42") === "42");
		check(lexFirst("3.14") === TokenKind.Number);
		check(lexFirstVal("3.14") === "3.14");
		check(lexFirst("0xFF") === TokenKind.Number);
		check(lexFirstVal("0xFF") === "0xFF");
		check(lexFirst("0b1010") === TokenKind.Number);
		check(lexFirst("0o777") === TokenKind.Number);
		check(lexFirst("1e10") === TokenKind.Number);
		check(lexFirst("1.5e-3") === TokenKind.Number);
		check(lexFirst("123n") === TokenKind.BigInt);
		check(lexFirstVal("1_000") === "1000");
		check(lexFirstVal("0xFF_FF") === "0xFFFF");
	});

	test("strings", () => {
		check(lexFirst("\"hello\"") === TokenKind.String);
		check(lexFirstVal("\"hello\"") === "hello");
		check(lexFirstVal("'world'") === "world");
		check(lexFirstVal("\"\"") === "");
		check(lexFirstVal("\"a\\nb\"") === "a\nb");
		check(lexFirstVal("\"a\\tb\"") === "a\tb");
		check(lexFirstVal("\"a\\\\b\"") === "a\\b");
		check(lexFirstVal("\"escaped\\\"quote\"") === "escaped\"quote");
	});

	test("template strings", () => {
		check(lexFirst("`hello`") === TokenKind.TemplateNoSub);
		check(lexFirstVal("`hello`") === "hello");
		check(lexFirst("`hi ${") === TokenKind.TemplateHead);
		check(lexFirstVal("``") === "");
		check(lexFirstVal("`a\\`b`") === "a`b");
		check(lexFirstVal("`\\$100`") === "$100");
	});

	test("template interpolation tokens", () => {
		// `hello ${name}` → TemplateHead("hello "), Ident("name"), TemplateTail("")
		check(lexKindAt("`hello ${name}`", 0) === TokenKind.TemplateHead);
		check(lexValAt("`hello ${name}`", 0) === "hello ");
		check(lexKindAt("`hello ${name}`", 1) === TokenKind.Ident);
		check(lexKindAt("`hello ${name}`", 2) === TokenKind.TemplateTail);
		// `${a} and ${b}` → TemplateHead(""), Ident, TemplateMiddle(" and "), Ident, TemplateTail("")
		check(lexKindAt("`${a} and ${b}`", 0) === TokenKind.TemplateHead);
		check(lexKindAt("`${a} and ${b}`", 1) === TokenKind.Ident);
		check(lexKindAt("`${a} and ${b}`", 2) === TokenKind.TemplateMiddle);
		check(lexValAt("`${a} and ${b}`", 2) === " and ");
		check(lexKindAt("`${a} and ${b}`", 3) === TokenKind.Ident);
		check(lexKindAt("`${a} and ${b}`", 4) === TokenKind.TemplateTail);
		// `${x}` → TemplateHead(""), Ident, TemplateTail("")
		check(lexKindAt("`${x}`", 0) === TokenKind.TemplateHead);
		check(lexKindAt("`${x}`", 1) === TokenKind.Ident);
		check(lexKindAt("`${x}`", 2) === TokenKind.TemplateTail);
	});

	test("keywords", () => {
		check(lexFirst("const") === TokenKind.Const);
		check(lexFirst("let") === TokenKind.Let);
		check(lexFirst("function") === TokenKind.Function);
		check(lexFirst("return") === TokenKind.Return);
		check(lexFirst("if") === TokenKind.If);
		check(lexFirst("else") === TokenKind.Else);
		check(lexFirst("while") === TokenKind.While);
		check(lexFirst("for") === TokenKind.For);
		check(lexFirst("match") === TokenKind.Match);
		check(lexFirst("import") === TokenKind.Import);
		check(lexFirst("export") === TokenKind.Export);
		check(lexFirst("class") === TokenKind.Class);
		check(lexFirst("interface") === TokenKind.Interface);
		check(lexFirst("enum") === TokenKind.Enum);
		check(lexFirst("type") === TokenKind.Type);
		check(lexFirst("true") === TokenKind.True);
		check(lexFirst("false") === TokenKind.False);
		check(lexFirst("null") === TokenKind.Null);
		check(lexFirst("try") === TokenKind.Try);
		check(lexFirst("catch") === TokenKind.Catch);
		check(lexFirst("defer") === TokenKind.Defer);
		check(lexFirst("move") === TokenKind.Move);
		check(lexFirst("extern") === TokenKind.Extern);
		check(lexFirst("int32") === TokenKind.Int32);
		check(lexFirst("float64") === TokenKind.Float64);
	});

	test("identifiers vs keywords", () => {
		check(lexFirst("myVar") === TokenKind.Ident);
		check(lexFirst("_private") === TokenKind.Ident);
		check(lexFirst("constX") === TokenKind.Ident);
		check(lexFirst("ifTrue") === TokenKind.Ident);
		check(lexFirst("returnValue") === TokenKind.Ident);
		check(lexFirst("lethal") === TokenKind.Ident);
		check(lexFirst("classname") === TokenKind.Ident);
		check(lexFirst("enumerate") === TokenKind.Ident);
	});

	test("operators", () => {
		check(lexFirst("+") === TokenKind.Plus);
		check(lexFirst("-") === TokenKind.Minus);
		check(lexFirst("*") === TokenKind.Star);
		check(lexFirst("/") === TokenKind.Slash);
		check(lexFirst("===") === TokenKind.EqEqEq);
		check(lexFirst("!==") === TokenKind.BangEqEq);
		check(lexFirst("&&") === TokenKind.AmpAmp);
		check(lexFirst("||") === TokenKind.PipePipe);
		check(lexFirst("=>") === TokenKind.Arrow);
		check(lexFirst("++") === TokenKind.PlusPlus);
		check(lexFirst("--") === TokenKind.MinusMinus);
		check(lexFirst("**") === TokenKind.StarStar);
		check(lexFirst(">>>") === TokenKind.GtGtGt);
		check(lexFirst("...") === TokenKind.DotDotDot);
		check(lexFirst("?.") === TokenKind.QuestionDot);
		check(lexFirst("??") === TokenKind.QuestionQuestion);
		check(lexFirst("|>") === TokenKind.PipeGt);
	});

	test("punctuation", () => {
		check(lexFirst("(") === TokenKind.LParen);
		check(lexFirst(")") === TokenKind.RParen);
		check(lexFirst("{") === TokenKind.LBrace);
		check(lexFirst("}") === TokenKind.RBrace);
		check(lexFirst("[") === TokenKind.LBracket);
		check(lexFirst("]") === TokenKind.RBracket);
		check(lexFirst(";") === TokenKind.Semicolon);
		check(lexFirst(":") === TokenKind.Colon);
		check(lexFirst(",") === TokenKind.Comma);
		check(lexFirst("@") === TokenKind.At);
		check(lexFirst("~") === TokenKind.Tilde);
		check(lexFirst("^") === TokenKind.Caret);
	});
});

testGroup("Lexer Comments", () => {
	test("stripped from output", () => {
		check(lexCount("a // comment") === 1);
		check(lexCount("a /* block */ b") === 2);
		check(lexCount("/* entire line */") === 0);
		check(lexCount("//\n42") === 1);
		check(lexCount("/**/42") === 1);
		check(lexCount("// first\n// second\n42") === 1);
	});

	test("inside strings are not comments", () => {
		check(lexCount("\"a//b\"") === 1);
		check(lexCount("\"a/*b*/c\"") === 1);
	});
});

testGroup("Lexer Edge Cases", () => {
	test("operator disambiguation (greedy)", () => {
		check(lexKindAt("a===b", 1) === TokenKind.EqEqEq);
		check(lexKindAt("a!==b", 1) === TokenKind.BangEqEq);
		check(lexKindAt("a>>>b", 1) === TokenKind.GtGtGt);
		check(lexKindAt("a**b", 1) === TokenKind.StarStar);
		check(lexKindAt("a?.b", 1) === TokenKind.QuestionDot);
		check(lexKindAt("a??b", 1) === TokenKind.QuestionQuestion);
		check(lexKindAt("a|>b", 1) === TokenKind.PipeGt);
		check(lexKindAt("a||b", 1) === TokenKind.PipePipe);
		check(lexKindAt("a&&b", 1) === TokenKind.AmpAmp);
	});

	test("operators jammed without spaces", () => {
		check(lexCount("a+b") === 3);
		check(lexCount("a-b") === 3);
		check(lexCount("x=1") === 3);
		check(lexCount("x+=1") === 3);
		check(lexCount("a<b") === 3);
	});

	test("dot-dot is two dots not spread", () => {
		check(lexLen("..") === 3);
		check(lexKindAt("..", 0) === TokenKind.Dot);
		check(lexKindAt("..", 1) === TokenKind.Dot);
	});

	test("CRLF handling", () => {
		check(lexOk("\r\n"));
		check(lexCount("\r\n") === 0);
		check(lexCount("a\r\nb") === 2);
	});

	test("error on unknown character", () => {
		check(!lexOk("#"));
		check(!lexOk("~#~"));
	});
});

testGroup("Lexer Integration", () => {
	test("line/column tracking", () => {
		check(lexLineAt("abc", 0) === 1);
		check(lexColAt("abc", 0) === 1);
		check(lexLineAt("a\nb", 0) === 1);
		check(lexLineAt("a\nb", 1) === 2);
		check(lexColAt("a\nb", 1) === 1);
		check(lexColAt("  x", 0) === 3);
		check(lexLineAt("\n\n\nx", 0) === 4);
	});

	test("token counts", () => {
		check(lexCount("a + b") === 3);
		check(lexCount("const x = 42;") === 5);
		check(lexCount("f(a, b, c)") === 8);
		check(lexCount("a.b.c") === 5);
		check(lexCount("if (x) { y; }") === 8);
	});

	test("realistic code", () => {
		check(lexKindAt("const x: number = 42;", 0) === TokenKind.Const);
		check(lexKindAt("const x: number = 42;", 4) === TokenKind.Assign);
		check(lexKindAt("const x: number = 42;", 5) === TokenKind.Number);
		check(lexKindAt("import { Token } from \"./token\";", 0) === TokenKind.Import);
		check(lexKindAt("import { Token } from \"./token\";", 4) === TokenKind.From);
		check(lexKindAt("import { Token } from \"./token\";", 5) === TokenKind.String);
		check(lexValAt("import { Token } from \"./token\";", 5) === "./token");
		check(lexOk("for (let i = 0; i < 10; i++) { }"));
		check(lexOk("match (x) { 1 => \"one\", _ => \"other\" }"));
		check(lexOk("a?.b?.c"));
		check(lexOk("data |> transform |> output"));
	});
});
