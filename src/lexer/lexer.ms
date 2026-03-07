// Lexer — Main entry point for tokenization
// Converts source code into a sequence of tokens
// Pattern: ~/projects/metascript/src/lexer/lexer.zig

import { Token, TokenKind } from "./token";
import { LexerState, createLexerState, peek, advanceChar, addToken } from "./state";
import { isWhitespace, isNewline, isDigit, isLetter } from "./chars";
import { scanNumber, scanString, scanTemplateString, scanIdentifier, scanOperator, scanPunctuation } from "./scanner";

// ===== Main Lex Function =====

export function lex(source: string): Result<Token[], string> {
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
		// scanOperator now handles comments and adds them to s.tokens if TokenKind.Comment was added there
		// Wait, I should make sure scanOperator actually adds them to s.tokens or s.comments
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
test "empty string" {
	expect(lexOk(""));
	expect(lexCount("") === 0);
}

test "whitespace only" {
	expect(lexOk("   "));
	expect(lexCount("   ") === 0);
	expect(lexOk("\t\t"));
	expect(lexOk("\n\n\n"));
	expect(lexOk("  \n\t  \n  "));
}

test "numbers" {
	expect(lexFirst("42") === TokenKind.Number);
	expect(lexFirstVal("42") === "42");
	expect(lexFirst("3.14") === TokenKind.Number);
	expect(lexFirstVal("3.14") === "3.14");
	expect(lexFirst("0xFF") === TokenKind.Number);
	expect(lexFirstVal("0xFF") === "0xFF");
	expect(lexFirst("0b1010") === TokenKind.Number);
	expect(lexFirst("0o777") === TokenKind.Number);
	expect(lexFirst("1e10") === TokenKind.Number);
	expect(lexFirst("1.5e-3") === TokenKind.Number);
	expect(lexFirst("123n") === TokenKind.BigInt);
	expect(lexFirstVal("1_000") === "1000");
	expect(lexFirstVal("0xFF_FF") === "0xFFFF");
}

test "strings" {
	expect(lexFirst("\"hello\"") === TokenKind.String);
	expect(lexFirstVal("\"hello\"") === "hello");
	expect(lexFirstVal("'world'") === "world");
	expect(lexFirstVal("\"\"") === "");
	expect(lexFirstVal("\"a\\nb\"") === "a\nb");
	expect(lexFirstVal("\"a\\tb\"") === "a\tb");
	expect(lexFirstVal("\"a\\\\b\"") === "a\\b");
	expect(lexFirstVal("\"escaped\\\"quote\"") === "escaped\"quote");
}

test "template strings" {
	expect(lexFirst("`hello`") === TokenKind.TemplateNoSub);
	expect(lexFirstVal("`hello`") === "hello");
	expect(lexFirst("`hi ${") === TokenKind.TemplateHead);
	expect(lexFirstVal("``") === "");
	expect(lexFirstVal("`a\\`b`") === "a`b");
	expect(lexFirstVal("`\\$100`") === "$100");
}

test "template interpolation tokens" {
	// `hello ${name}` → TemplateHead("hello "), Ident("name"), TemplateTail("")
	expect(lexKindAt("`hello ${name}`", 0) === TokenKind.TemplateHead);
	expect(lexValAt("`hello ${name}`", 0) === "hello ");
	expect(lexKindAt("`hello ${name}`", 1) === TokenKind.Ident);
	expect(lexKindAt("`hello ${name}`", 2) === TokenKind.TemplateTail);
	// `${a} and ${b}` → TemplateHead(""), Ident, TemplateMiddle(" and "), Ident, TemplateTail("")
	expect(lexKindAt("`${a} and ${b}`", 0) === TokenKind.TemplateHead);
	expect(lexKindAt("`${a} and ${b}`", 1) === TokenKind.Ident);
	expect(lexKindAt("`${a} and ${b}`", 2) === TokenKind.TemplateMiddle);
	expect(lexValAt("`${a} and ${b}`", 2) === " and ");
	expect(lexKindAt("`${a} and ${b}`", 3) === TokenKind.Ident);
	expect(lexKindAt("`${a} and ${b}`", 4) === TokenKind.TemplateTail);
	// `${x}` → TemplateHead(""), Ident, TemplateTail("")
	expect(lexKindAt("`${x}`", 0) === TokenKind.TemplateHead);
	expect(lexKindAt("`${x}`", 1) === TokenKind.Ident);
	expect(lexKindAt("`${x}`", 2) === TokenKind.TemplateTail);
}

test "keywords" {
	expect(lexFirst("const") === TokenKind.Const);
	expect(lexFirst("let") === TokenKind.Let);
	expect(lexFirst("function") === TokenKind.Function);
	expect(lexFirst("return") === TokenKind.Return);
	expect(lexFirst("if") === TokenKind.If);
	expect(lexFirst("else") === TokenKind.Else);
	expect(lexFirst("while") === TokenKind.While);
	expect(lexFirst("for") === TokenKind.For);
	expect(lexFirst("match") === TokenKind.Match);
	expect(lexFirst("import") === TokenKind.Import);
	expect(lexFirst("export") === TokenKind.Export);
	expect(lexFirst("class") === TokenKind.Class);
	expect(lexFirst("interface") === TokenKind.Interface);
	expect(lexFirst("enum") === TokenKind.Enum);
	expect(lexFirst("type") === TokenKind.Type);
	expect(lexFirst("true") === TokenKind.True);
	expect(lexFirst("false") === TokenKind.False);
	expect(lexFirst("null") === TokenKind.Null);
	expect(lexFirst("try") === TokenKind.Try);
	expect(lexFirst("catch") === TokenKind.Catch);
	expect(lexFirst("defer") === TokenKind.Defer);
	expect(lexFirst("move") === TokenKind.Move);
	expect(lexFirst("extern") === TokenKind.Extern);
	expect(lexFirst("int32") === TokenKind.Int32);
	expect(lexFirst("float64") === TokenKind.Float64);
}

test "identifiers vs keywords" {
	expect(lexFirst("myVar") === TokenKind.Ident);
	expect(lexFirst("_private") === TokenKind.Ident);
	expect(lexFirst("constX") === TokenKind.Ident);
	expect(lexFirst("ifTrue") === TokenKind.Ident);
	expect(lexFirst("returnValue") === TokenKind.Ident);
	expect(lexFirst("lethal") === TokenKind.Ident);
	expect(lexFirst("classname") === TokenKind.Ident);
	expect(lexFirst("enumerate") === TokenKind.Ident);
}

test "regex literals" {
	expect(lexFirst("/abc/") === TokenKind.Regex);
	expect(lexFirstVal("/abc/") === "/abc/");
	expect(lexFirstVal("/abc/gi") === "/abc/gi");
	expect(lexFirstVal("/[a-z]+/") === "/[a-z]+/");
	expect(lexFirstVal("/\\.js$/") === "/\\.js$/");
}

test "regex vs division" {
	// After value → division
	expect(lexKindAt("a / b", 1) === TokenKind.Slash);
	expect(lexKindAt("1 / 2", 1) === TokenKind.Slash);
	expect(lexKindAt(") / x", 1) === TokenKind.Slash);
	// After operator/keyword → regex
	expect(lexKindAt("= /abc/", 1) === TokenKind.Regex);
	expect(lexKindAt("( /abc/", 1) === TokenKind.Regex);
	expect(lexKindAt("return /abc/", 1) === TokenKind.Regex);
}

test "operators" {
	expect(lexFirst("+") === TokenKind.Plus);
	expect(lexFirst("-") === TokenKind.Minus);
	expect(lexFirst("*") === TokenKind.Star);
	expect(lexKindAt("a / b", 1) === TokenKind.Slash); // / after value = division
	expect(lexFirst("===") === TokenKind.EqEqEq);
	expect(lexFirst("!==") === TokenKind.BangEqEq);
	expect(lexFirst("&&") === TokenKind.AmpAmp);
	expect(lexFirst("||") === TokenKind.PipePipe);
	expect(lexFirst("=>") === TokenKind.Arrow);
	expect(lexFirst("++") === TokenKind.PlusPlus);
	expect(lexFirst("--") === TokenKind.MinusMinus);
	expect(lexFirst("**") === TokenKind.StarStar);
	expect(lexFirst(">>>") === TokenKind.GtGtGt);
	expect(lexFirst("...") === TokenKind.DotDotDot);
	expect(lexFirst("?.") === TokenKind.QuestionDot);
	expect(lexFirst("??") === TokenKind.QuestionQuestion);
	expect(lexFirst("|>") === TokenKind.PipeGt);
}

test "punctuation" {
	expect(lexFirst("(") === TokenKind.LParen);
	expect(lexFirst(")") === TokenKind.RParen);
	expect(lexFirst("{") === TokenKind.LBrace);
	expect(lexFirst("}") === TokenKind.RBrace);
	expect(lexFirst("[") === TokenKind.LBracket);
	expect(lexFirst("]") === TokenKind.RBracket);
	expect(lexFirst(";") === TokenKind.Semicolon);
	expect(lexFirst(":") === TokenKind.Colon);
	expect(lexFirst(",") === TokenKind.Comma);
	expect(lexFirst("@") === TokenKind.At);
	expect(lexFirst("~") === TokenKind.Tilde);
	expect(lexFirst("^") === TokenKind.Caret);
}

test "comments are now tokens" {
	expect(lexKindAt("a // comment", 1) === TokenKind.Comment);
	expect(lexValAt("a // comment", 1) === "// comment");
	expect(lexKindAt("a /* block */ b", 1) === TokenKind.Comment);
	expect(lexValAt("a /* block */ b", 1) === "/* block */");
}

test "inside strings are not comments" {
	expect(lexCount("\"a//b\"") === 1);
	expect(lexCount("\"a/*b*/c\"") === 1);
}

test "operator disambiguation (greedy)" {
	expect(lexKindAt("a===b", 1) === TokenKind.EqEqEq);
	expect(lexKindAt("a!==b", 1) === TokenKind.BangEqEq);
	expect(lexKindAt("a>>>b", 1) === TokenKind.GtGtGt);
	expect(lexKindAt("a**b", 1) === TokenKind.StarStar);
	expect(lexKindAt("a?.b", 1) === TokenKind.QuestionDot);
	expect(lexKindAt("a??b", 1) === TokenKind.QuestionQuestion);
	expect(lexKindAt("a|>b", 1) === TokenKind.PipeGt);
	expect(lexKindAt("a||b", 1) === TokenKind.PipePipe);
	expect(lexKindAt("a&&b", 1) === TokenKind.AmpAmp);
}

test "operators jammed without spaces" {
	expect(lexCount("a+b") === 3);
	expect(lexCount("a-b") === 3);
	expect(lexCount("x=1") === 3);
	expect(lexCount("x+=1") === 3);
	expect(lexCount("a<b") === 3);
}

test "dot-dot is range operator" {
	expect(lexLen("..") === 2);
	expect(lexKindAt("..", 0) === TokenKind.DotDot);
}

test "CRLF handling" {
	expect(lexOk("\r\n"));
	expect(lexCount("\r\n") === 0);
	expect(lexCount("a\r\nb") === 2);
}

test "error on unknown character" {
	expect(!lexOk("#"));
	expect(!lexOk("~#~"));
}

test "line/column tracking" {
	expect(lexLineAt("abc", 0) === 1);
	expect(lexColAt("abc", 0) === 1);
	expect(lexLineAt("a\nb", 0) === 1);
	expect(lexLineAt("a\nb", 1) === 2);
	expect(lexColAt("a\nb", 1) === 1);
	expect(lexColAt("  x", 0) === 3);
	expect(lexLineAt("\n\n\nx", 0) === 4);
}

test "token counts" {
	expect(lexCount("a + b") === 3);
	expect(lexCount("const x = 42;") === 5);
	expect(lexCount("f(a, b, c)") === 8);
	expect(lexCount("a.b.c") === 5);
	expect(lexCount("if (x) { y; }") === 8);
}

test "realistic code" {
	expect(lexKindAt("const x: number = 42;", 0) === TokenKind.Const);
	expect(lexKindAt("const x: number = 42;", 4) === TokenKind.Assign);
	expect(lexKindAt("const x: number = 42;", 5) === TokenKind.Number);
	expect(lexKindAt("import { Token } from \"./token\";", 0) === TokenKind.Import);
	expect(lexKindAt("import { Token } from \"./token\";", 4) === TokenKind.From);
	expect(lexKindAt("import { Token } from \"./token\";", 5) === TokenKind.String);
	expect(lexValAt("import { Token } from \"./token\";", 5) === "./token");
	expect(lexOk("for (let i = 0; i < 10; i++) { }"));
	expect(lexOk("match (x) { 1 => \"one\", _ => \"other\" }"));
	expect(lexOk("a?.b?.c"));
	expect(lexOk("data |> transform |> output"));
}
