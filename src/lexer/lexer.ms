// Lexer — Main entry point for tokenization
// Converts source code into a sequence of tokens
// Pattern: ~/projects/metascript/src/lexer/lexer.zig

import { Token, TokenKind } from "./token";
import { createLexerState, peek, advanceChar, addToken } from "./state";
import { isWhitespace, isNewline, isDigit, isLetter } from "./chars";
import { scanNumber, scanString, scanTemplateString, scanIdentifier, scanOperator, scanPunctuation } from "./scanner";

// ===== Main Lex Function =====

export function lex(source: string): Result<Token[], string> {
	const s = createLexerState(source);

	while (s.pos < s.source.byteLength) {
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
		return Result.err(`Unknown character at line ${s.line}, column ${s.column}`);
	}

	// Add EOF token
	addToken(s, TokenKind.Eof, "", s.line, s.column);
	return Result.ok(move s.tokens);
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
	assert lexOk("");
	assert lexCount("") === 0;
}

test "whitespace only" {
	assert lexOk("   ");
	assert lexCount("   ") === 0;
	assert lexOk("\t\t");
	assert lexOk("\n\n\n");
	assert lexOk("  \n\t  \n  ");
}

test "numbers" {
	assert lexFirst("42") === TokenKind.Number;
	assert lexFirstVal("42") === "42";
	assert lexFirst("3.14") === TokenKind.Number;
	assert lexFirstVal("3.14") === "3.14";
	assert lexFirst("0xFF") === TokenKind.Number;
	assert lexFirstVal("0xFF") === "0xFF";
	assert lexFirst("0b1010") === TokenKind.Number;
	assert lexFirst("0o777") === TokenKind.Number;
	assert lexFirst("1e10") === TokenKind.Number;
	assert lexFirst("1.5e-3") === TokenKind.Number;
	assert lexFirst("123n") === TokenKind.BigInt;
	assert lexFirstVal("1_000") === "1000";
	assert lexFirstVal("0xFF_FF") === "0xFFFF";
}

test "strings" {
	assert lexFirst("\"hello\"") === TokenKind.String;
	assert lexFirstVal("\"hello\"") === "hello";
	assert lexFirstVal("'world'") === "world";
	assert lexFirstVal("\"\"") === "";
	assert lexFirstVal("\"a\\nb\"") === "a\nb";
	assert lexFirstVal("\"a\\tb\"") === "a\tb";
	assert lexFirstVal("\"a\\\\b\"") === "a\\b";
	assert lexFirstVal("\"escaped\\\"quote\"") === "escaped\"quote";
}

test "template strings" {
	assert lexFirst("`hello`") === TokenKind.TemplateNoSub;
	assert lexFirstVal("`hello`") === "hello";
	assert lexFirst("`hi ${") === TokenKind.TemplateHead;
	assert lexFirstVal("``") === "";
	assert lexFirstVal("`a\\`b`") === "a`b";
	assert lexFirstVal("`\\$100`") === "$100";
}

test "operator identifiers" {
	// Backtick-quoted operator names → OperatorIdent token
	// Reference compiler: lexer.zig:422 scanBacktick
	assert lexFirst("`==`") === TokenKind.OperatorIdent;
	assert lexFirstVal("`==`") === "==";
	assert lexFirst("`!=`") === TokenKind.OperatorIdent;
	assert lexFirstVal("`!=`") === "!=";
	assert lexFirst("`+`") === TokenKind.OperatorIdent;
	assert lexFirst("`[]`") === TokenKind.OperatorIdent;
	assert lexFirstVal("`[]`") === "[]";
	assert lexFirst("`[]=`") === TokenKind.OperatorIdent;
	assert lexFirstVal("`[]=`") === "[]=";
	assert lexFirst("`<>`") === TokenKind.OperatorIdent;
	assert lexFirstVal("`<>`") === "<>";
	// Regular template strings stay as TemplateNoSub
	assert lexFirst("`hello`") === TokenKind.TemplateNoSub;
	assert lexFirst("`hello world`") === TokenKind.TemplateNoSub;
}

test "template interpolation tokens" {
	// `hello ${name}` → TemplateHead("hello "), Ident("name"), TemplateTail("")
	assert lexKindAt("`hello ${name}`", 0) === TokenKind.TemplateHead;
	assert lexValAt("`hello ${name}`", 0) === "hello ";
	assert lexKindAt("`hello ${name}`", 1) === TokenKind.Ident;
	assert lexKindAt("`hello ${name}`", 2) === TokenKind.TemplateTail;
	// `${a} and ${b}` → TemplateHead(""), Ident, TemplateMiddle(" and "), Ident, TemplateTail("")
	assert lexKindAt("`${a} and ${b}`", 0) === TokenKind.TemplateHead;
	assert lexKindAt("`${a} and ${b}`", 1) === TokenKind.Ident;
	assert lexKindAt("`${a} and ${b}`", 2) === TokenKind.TemplateMiddle;
	assert lexValAt("`${a} and ${b}`", 2) === " and ";
	assert lexKindAt("`${a} and ${b}`", 3) === TokenKind.Ident;
	assert lexKindAt("`${a} and ${b}`", 4) === TokenKind.TemplateTail;
	// `${x}` → TemplateHead(""), Ident, TemplateTail("")
	assert lexKindAt("`${x}`", 0) === TokenKind.TemplateHead;
	assert lexKindAt("`${x}`", 1) === TokenKind.Ident;
	assert lexKindAt("`${x}`", 2) === TokenKind.TemplateTail;
}

test "keywords" {
	assert lexFirst("const") === TokenKind.Const;
	assert lexFirst("let") === TokenKind.Let;
	assert lexFirst("function") === TokenKind.Function;
	assert lexFirst("return") === TokenKind.Return;
	assert lexFirst("if") === TokenKind.If;
	assert lexFirst("else") === TokenKind.Else;
	assert lexFirst("while") === TokenKind.While;
	assert lexFirst("for") === TokenKind.For;
	assert lexFirst("match") === TokenKind.Match;
	assert lexFirst("import") === TokenKind.Import;
	assert lexFirst("export") === TokenKind.Export;
	assert lexFirst("class") === TokenKind.Class;
	assert lexFirst("interface") === TokenKind.Interface;
	assert lexFirst("enum") === TokenKind.Enum;
	assert lexFirst("type") === TokenKind.Type;
	assert lexFirst("true") === TokenKind.True;
	assert lexFirst("false") === TokenKind.False;
	assert lexFirst("null") === TokenKind.Null;
	assert lexFirst("try") === TokenKind.Try;
	assert lexFirst("catch") === TokenKind.Catch;
	assert lexFirst("defer") === TokenKind.Defer;
	assert lexFirst("move") === TokenKind.Move;
	assert lexFirst("extern") === TokenKind.Extern;
	assert lexFirst("int32") === TokenKind.Int32;
	assert lexFirst("float64") === TokenKind.Float64;
}

test "identifiers vs keywords" {
	assert lexFirst("myVar") === TokenKind.Ident;
	assert lexFirst("_private") === TokenKind.Ident;
	assert lexFirst("constX") === TokenKind.Ident;
	assert lexFirst("ifTrue") === TokenKind.Ident;
	assert lexFirst("returnValue") === TokenKind.Ident;
	assert lexFirst("lethal") === TokenKind.Ident;
	assert lexFirst("classname") === TokenKind.Ident;
	assert lexFirst("enumerate") === TokenKind.Ident;
}

test "regex literals" {
	assert lexFirst("/abc/") === TokenKind.Regex;
	assert lexFirstVal("/abc/") === "/abc/";
	assert lexFirstVal("/abc/gi") === "/abc/gi";
	assert lexFirstVal("/[a-z]+/") === "/[a-z]+/";
	assert lexFirstVal("/\\.js$/") === "/\\.js$/";
}

test "regex vs division" {
	// After value → division
	assert lexKindAt("a / b", 1) === TokenKind.Slash;
	assert lexKindAt("1 / 2", 1) === TokenKind.Slash;
	assert lexKindAt(") / x", 1) === TokenKind.Slash;
	// After operator/keyword → regex
	assert lexKindAt("= /abc/", 1) === TokenKind.Regex;
	assert lexKindAt("( /abc/", 1) === TokenKind.Regex;
	assert lexKindAt("return /abc/", 1) === TokenKind.Regex;
}

test "operators" {
	assert lexFirst("+") === TokenKind.Plus;
	assert lexFirst("-") === TokenKind.Minus;
	assert lexFirst("*") === TokenKind.Star;
	assert lexKindAt("a / b", 1) === TokenKind.Slash; // / after value = division
	assert lexFirst("===") === TokenKind.EqEqEq;
	assert lexFirst("!==") === TokenKind.BangEqEq;
	assert lexFirst("&&") === TokenKind.AmpAmp;
	assert lexFirst("||") === TokenKind.PipePipe;
	assert lexFirst("=>") === TokenKind.Arrow;
	assert lexFirst("++") === TokenKind.PlusPlus;
	assert lexFirst("--") === TokenKind.MinusMinus;
	assert lexFirst("**") === TokenKind.StarStar;
	assert lexFirst(">>>") === TokenKind.GtGtGt;
	assert lexFirst("...") === TokenKind.DotDotDot;
	assert lexFirst("?.") === TokenKind.QuestionDot;
	assert lexFirst("??") === TokenKind.QuestionQuestion;
	assert lexFirst("|>") === TokenKind.PipeGt;
}

test "punctuation" {
	assert lexFirst("(") === TokenKind.LParen;
	assert lexFirst(")") === TokenKind.RParen;
	assert lexFirst("{") === TokenKind.LBrace;
	assert lexFirst("}") === TokenKind.RBrace;
	assert lexFirst("[") === TokenKind.LBracket;
	assert lexFirst("]") === TokenKind.RBracket;
	assert lexFirst(";") === TokenKind.Semicolon;
	assert lexFirst(":") === TokenKind.Colon;
	assert lexFirst(",") === TokenKind.Comma;
	assert lexFirst("@") === TokenKind.At;
	assert lexFirst("~") === TokenKind.Tilde;
	assert lexFirst("^") === TokenKind.Caret;
}

test "comments are now tokens" {
	assert lexKindAt("a // comment", 1) === TokenKind.Comment;
	assert lexValAt("a // comment", 1) === "// comment";
	assert lexKindAt("a /* block */ b", 1) === TokenKind.Comment;
	assert lexValAt("a /* block */ b", 1) === "/* block */";
}

test "inside strings are not comments" {
	assert lexCount("\"a//b\"") === 1;
	assert lexCount("\"a/*b*/c\"") === 1;
}

test "operator disambiguation (greedy)" {
	assert lexKindAt("a===b", 1) === TokenKind.EqEqEq;
	assert lexKindAt("a!==b", 1) === TokenKind.BangEqEq;
	assert lexKindAt("a>>>b", 1) === TokenKind.GtGtGt;
	assert lexKindAt("a**b", 1) === TokenKind.StarStar;
	assert lexKindAt("a?.b", 1) === TokenKind.QuestionDot;
	assert lexKindAt("a??b", 1) === TokenKind.QuestionQuestion;
	assert lexKindAt("a|>b", 1) === TokenKind.PipeGt;
	assert lexKindAt("a||b", 1) === TokenKind.PipePipe;
	assert lexKindAt("a&&b", 1) === TokenKind.AmpAmp;
}

test "operators jammed without spaces" {
	assert lexCount("a+b") === 3;
	assert lexCount("a-b") === 3;
	assert lexCount("x=1") === 3;
	assert lexCount("x+=1") === 3;
	assert lexCount("a<b") === 3;
}

test "dot-dot is range operator" {
	assert lexLen("..") === 2;
	assert lexKindAt("..", 0) === TokenKind.DotDot;
}

test "CRLF handling" {
	assert lexOk("\r\n");
	assert lexCount("\r\n") === 0;
	assert lexCount("a\r\nb") === 2;
}

test "error on unknown character" {
	assert !lexOk("#");
	assert !lexOk("~#~");
}

test "line/column tracking" {
	assert lexLineAt("abc", 0) === 1;
	assert lexColAt("abc", 0) === 1;
	assert lexLineAt("a\nb", 0) === 1;
	assert lexLineAt("a\nb", 1) === 2;
	assert lexColAt("a\nb", 1) === 1;
	assert lexColAt("  x", 0) === 3;
	assert lexLineAt("\n\n\nx", 0) === 4;
}

test "token counts" {
	assert lexCount("a + b") === 3;
	assert lexCount("const x = 42;") === 5;
	assert lexCount("f(a, b, c)") === 8;
	assert lexCount("a.b.c") === 5;
	assert lexCount("if (x) { y; }") === 8;
}

test "realistic code" {
	assert lexKindAt("const x: number = 42;", 0) === TokenKind.Const;
	assert lexKindAt("const x: number = 42;", 4) === TokenKind.Assign;
	assert lexKindAt("const x: number = 42;", 5) === TokenKind.Number;
	assert lexKindAt("import { Token } from \"./token\";", 0) === TokenKind.Import;
	assert lexKindAt("import { Token } from \"./token\";", 4) === TokenKind.From;
	assert lexKindAt("import { Token } from \"./token\";", 5) === TokenKind.String;
	assert lexValAt("import { Token } from \"./token\";", 5) === "./token";
	assert lexOk("for (let i = 0; i < 10; i++) { }");
	assert lexOk("match (x) { 1 => \"one\", _ => \"other\" }");
	assert lexOk("a?.b?.c");
	assert lexOk("data |> transform |> output");
}
