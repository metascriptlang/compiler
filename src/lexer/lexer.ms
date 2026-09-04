// Lexer — Main entry point for tokenization
// Converts source code into a sequence of tokens
// Pattern: ~/projects/metascript/src/lexer/lexer.zig

import { Token, TokenKind, isIdentOrKeyword } from "./token";
import { createLexerState, peek, peekAt, advanceChar, skip, addToken } from "./state";
import { isWhitespace, isNewline, isDigit, isLetter } from "./chars";
import { scanNumber, scanString, scanTemplateString, scanIdentifier, scanOperator, scanPunctuation } from "./scanner";
import { scanJsx } from "./jsx";

// ===== Main Lex Function =====

export function lex(source: string): Result<Token[], string> {
	const s = createLexerState(source);

	while (s.pos < s.source.byteLength) {
		if (s.lexError !== "") return Result.err(s.lexError);
		const ch = peek(s);

		// JSX mode (lexer-owned). Handles JSX-start in expression position and all scanning
		// inside JSX tags/children/expression-containers. Must run before whitespace so JSX
		// child text is captured raw.
		if (scanJsx(s)) { continue; }

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

		// Dollar sign: `${` → QuoteInterp token for quote interpolation.
		// `$` followed by letter/digit/underscore → identifier (e.g. `$result`).
		if (ch === "$".code) {
			if (peekAt(s, 1) === "{".code) {
				const dl = s.line;
				const dc = s.column;
				skip(s, 2);
				addToken(s, TokenKind.QuoteInterp, "${", dl, dc);
				continue;
			}
			// $identifier — treat $ as identifier start (JS/TS parity)
			scanIdentifier(s);
			continue;
		}

		// Unknown character - error
		return Result.err(`Unknown character at line ${s.line}, column ${s.column}`);
	}

	if (s.lexError !== "") return Result.err(s.lexError);
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

function lexCount(input: string): int32 {
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

function lexKindAt(input: string, index: int32): TokenKind {
	const result = lex(input);
	if (!result.ok) return TokenKind.Eof;
	const tokens = result.value;
	if (index >= tokens.length) return TokenKind.Eof;
	return tokens[index].kind;
}

function lexValAt(input: string, index: int32): string {
	const result = lex(input);
	if (!result.ok) return "";
	const tokens = result.value;
	if (index >= tokens.length) return "";
	return tokens[index].value;
}

function lexLen(input: string): int32 {
	const result = lex(input);
	if (!result.ok) return 0;
	return result.value.length;
}

function lexLineAt(input: string, index: int32): int32 {
	const result = lex(input);
	if (!result.ok) return 0;
	const tokens = result.value;
	if (index >= tokens.length) return 0;
	return tokens[index].line;
}

function lexColAt(input: string, index: int32): int32 {
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
	assert lexFirst("0xffn") === TokenKind.BigInt;
	assert lexFirst("0XFFn") === TokenKind.BigInt;
	assert lexFirst("0b1111n") === TokenKind.BigInt;
	assert lexFirst("0o17n") === TokenKind.BigInt;
	assert lexFirst("1_000n") === TokenKind.BigInt;
	assert lexFirst("0xff") === TokenKind.Number;
	assert lexFirst("0b1111") === TokenKind.Number;
	assert lexFirst("0o17") === TokenKind.Number;
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

// ===== JSX Lexer Tests (Phase 2, docs/JSX-ROADMAP.md) =====
// RED until the lexer JSX mode lands — they pin the target token stream now (TDD).
// `<` at start-of-input: lastToken is Eof → expression position → JSX.

test "jsx self-closing element" {
	assert lexKindAt("<Img/>", 0) === TokenKind.JsxTagStart;
	assert lexValAt("<Img/>", 1) === "Img";
	assert lexKindAt("<Img/>", 2) === TokenKind.Slash;
	assert lexKindAt("<Img/>", 3) === TokenKind.Gt;
}

test "jsx element with text child" {
	assert lexKindAt("<p>hi</p>", 0) === TokenKind.JsxTagStart;
	assert lexKindAt("<p>hi</p>", 2) === TokenKind.Gt;
	assert lexKindAt("<p>hi</p>", 3) === TokenKind.JsxText;
	assert lexValAt("<p>hi</p>", 3) === "hi";
	assert lexKindAt("<p>hi</p>", 4) === TokenKind.JsxClose;
	assert lexValAt("<p>hi</p>", 5) === "p";
}

test "jsx text keeps apostrophe (no string-literal choke)" {
	assert lexOk("<p>Don't</p>");
	assert lexValAt("<p>Don't</p>", 3) === "Don't";
}

test "jsx fragment" {
	assert lexKindAt("<></>", 0) === TokenKind.JsxTagStart;
	assert lexKindAt("<></>", 1) === TokenKind.Gt;
	assert lexKindAt("<></>", 2) === TokenKind.JsxClose;
	assert lexKindAt("<></>", 3) === TokenKind.Gt;
}

test "jsx expression container" {
	assert lexKindAt("<p>{x}</p>", 0) === TokenKind.JsxTagStart;
	assert lexKindAt("<p>{x}</p>", 3) === TokenKind.LBrace;
	assert lexKindAt("<p>{x}</p>", 4) === TokenKind.Ident;
	assert lexKindAt("<p>{x}</p>", 5) === TokenKind.RBrace;
	assert lexKindAt("<p>{x}</p>", 6) === TokenKind.JsxClose;
}

test "jsx empty expression container" {
	assert lexKindAt("<p>{}</p>", 0) === TokenKind.JsxTagStart;
	assert lexKindAt("<p>{}</p>", 3) === TokenKind.LBrace;
	assert lexKindAt("<p>{}</p>", 4) === TokenKind.RBrace;
	assert lexKindAt("<p>{}</p>", 5) === TokenKind.JsxClose;
}

test "jsx attribute single-quoted string" {
	assert lexKindAt("<a href='x'/>", 0) === TokenKind.JsxTagStart;
	assert lexValAt("<a href='x'/>", 2) === "href";
	assert lexKindAt("<a href='x'/>", 3) === TokenKind.Assign;
	assert lexKindAt("<a href='x'/>", 4) === TokenKind.String;
	assert lexValAt("<a href='x'/>", 4) === "x";
}

test "jsx hyphenated attribute name folds to one ident" {
	assert lexKindAt("<a data-x='1'/>", 0) === TokenKind.JsxTagStart;
	assert lexValAt("<a data-x='1'/>", 2) === "data-x";
}

test "jsx spread attribute" {
	assert lexKindAt("<a {...p}/>", 0) === TokenKind.JsxTagStart;
	assert lexKindAt("<a {...p}/>", 2) === TokenKind.LBrace;
	assert lexKindAt("<a {...p}/>", 3) === TokenKind.DotDotDot;
	assert lexValAt("<a {...p}/>", 4) === "p";
}

test "jsx namespaced and member tag names" {
	assert lexKindAt("<svg:rect/>", 0) === TokenKind.JsxTagStart;
	assert lexKindAt("<svg:rect/>", 2) === TokenKind.Colon;
	assert lexValAt("<svg:rect/>", 3) === "rect";
	assert lexKindAt("<Foo.Bar/>", 2) === TokenKind.Dot;
	assert lexValAt("<Foo.Bar/>", 3) === "Bar";
}

test "jsx nested element child" {
	assert lexKindAt("<a><b/></a>", 0) === TokenKind.JsxTagStart;
	assert lexKindAt("<a><b/></a>", 3) === TokenKind.JsxTagStart;
	assert lexValAt("<a><b/></a>", 4) === "b";
	assert lexKindAt("<a><b/></a>", 7) === TokenKind.JsxClose;
}

test "jsx less-than inside expression container stays Lt" {
	assert lexKindAt("<p>{a < b}</p>", 0) === TokenKind.JsxTagStart;
	assert lexKindAt("<p>{a < b}</p>", 5) === TokenKind.Lt;
	assert lexKindAt("<p>{a < b}</p>", 8) === TokenKind.JsxClose;
}

test "jsx double-quoted and multiple attributes" {
	assert lexKindAt("<a x=\"1\" y=\"2\"/>", 0) === TokenKind.JsxTagStart;
	assert lexValAt("<a x=\"1\" y=\"2\"/>", 2) === "x";
	assert lexKindAt("<a x=\"1\" y=\"2\"/>", 4) === TokenKind.String;
	assert lexValAt("<a x=\"1\" y=\"2\"/>", 5) === "y";
}

test "jsx does not hijack less-than or generic call" {
	assert lexKindAt("a < b", 1) === TokenKind.Lt;
	assert lexKindAt("a < b", 1) !== TokenKind.JsxTagStart;
	assert lexKindAt("foo<T>()", 1) === TokenKind.Lt;
	assert lexKindAt("new Box<T>()", 2) === TokenKind.Lt;
}

test "jsx tokens are not ident-like (range-check guard)" {
	assert isIdentOrKeyword(TokenKind.JsxTagStart) === false;
	assert isIdentOrKeyword(TokenKind.JsxClose) === false;
	assert isIdentOrKeyword(TokenKind.JsxText) === false;
}

test "jsx attribute value expression" {
	assert lexKindAt("<a x={y}/>", 0) === TokenKind.JsxTagStart;
	assert lexValAt("<a x={y}/>", 2) === "x";
	assert lexKindAt("<a x={y}/>", 3) === TokenKind.Assign;
	assert lexKindAt("<a x={y}/>", 4) === TokenKind.LBrace;
	assert lexValAt("<a x={y}/>", 5) === "y";
	assert lexKindAt("<a x={y}/>", 6) === TokenKind.RBrace;
	assert lexKindAt("<a x={y}/>", 7) === TokenKind.Slash;
}

test "jsx object literal inside expression container" {
	// nested braces must not close the container early — index 10 stays JsxClose
	assert lexKindAt("<p>{ {a: 1} }</p>", 3) === TokenKind.LBrace;
	assert lexKindAt("<p>{ {a: 1} }</p>", 4) === TokenKind.LBrace;
	assert lexValAt("<p>{ {a: 1} }</p>", 5) === "a";
	assert lexKindAt("<p>{ {a: 1} }</p>", 8) === TokenKind.RBrace;
	assert lexKindAt("<p>{ {a: 1} }</p>", 9) === TokenKind.RBrace;
	assert lexKindAt("<p>{ {a: 1} }</p>", 10) === TokenKind.JsxClose;
}

test "jsx element inside expression container" {
	assert lexKindAt("<p>{<b/>}</p>", 3) === TokenKind.LBrace;
	assert lexKindAt("<p>{<b/>}</p>", 4) === TokenKind.JsxTagStart;
	assert lexValAt("<p>{<b/>}</p>", 5) === "b";
	assert lexKindAt("<p>{<b/>}</p>", 8) === TokenKind.RBrace;
	assert lexKindAt("<p>{<b/>}</p>", 9) === TokenKind.JsxClose;
}

test "jsx text element text mix" {
	assert lexKindAt("<p>a<b/>c</p>", 3) === TokenKind.JsxText;
	assert lexValAt("<p>a<b/>c</p>", 3) === "a";
	assert lexKindAt("<p>a<b/>c</p>", 4) === TokenKind.JsxTagStart;
	assert lexKindAt("<p>a<b/>c</p>", 8) === TokenKind.JsxText;
	assert lexValAt("<p>a<b/>c</p>", 8) === "c";
	assert lexKindAt("<p>a<b/>c</p>", 9) === TokenKind.JsxClose;
}

test "jsx in statement resumes normal lexing after close" {
	assert lexKindAt("const x = <a/>; const y = b;", 3) === TokenKind.JsxTagStart;
	assert lexKindAt("const x = <a/>; const y = b;", 6) === TokenKind.Gt;
	assert lexKindAt("const x = <a/>; const y = b;", 7) === TokenKind.Semicolon;
	assert lexKindAt("const x = <a/>; const y = b;", 8) === TokenKind.Const;
	assert lexValAt("const x = <a/>; const y = b;", 9) === "y";
}

test "jsx stray brace in text does not hang" {
	assert lexOk("<p>a}b</p>");
	assert lexValAt("<p>a}b</p>", 3) === "a}b";
	assert lexKindAt("<p>a}b</p>", 4) === TokenKind.JsxClose;
}

test "jsx text preserves raw whitespace" {
	assert lexValAt("<p> hi </p>", 3) === " hi ";
}

test "jsx greater-than in text is not structural" {
	assert lexValAt("<p>a > b</p>", 3) === "a > b";
	assert lexKindAt("<p>a > b</p>", 4) === TokenKind.JsxClose;
}

test "jsx bare boolean attribute" {
	assert lexValAt("<input disabled/>", 1) === "input";
	assert lexValAt("<input disabled/>", 2) === "disabled";
	assert lexKindAt("<input disabled/>", 3) === TokenKind.Slash;
}

test "jsx deeply nested elements balance the stack" {
	assert lexKindAt("<a><b><c/></b></a>", 0) === TokenKind.JsxTagStart;
	assert lexKindAt("<a><b><c/></b></a>", 3) === TokenKind.JsxTagStart;
	assert lexKindAt("<a><b><c/></b></a>", 6) === TokenKind.JsxTagStart;
	assert lexKindAt("<a><b><c/></b></a>", 10) === TokenKind.JsxClose;
	assert lexKindAt("<a><b><c/></b></a>", 13) === TokenKind.JsxClose;
	assert lexValAt("<a><b><c/></b></a>", 14) === "a";
}

test "jsx starts after return and inside array literal" {
	assert lexKindAt("return <a/>", 0) === TokenKind.Return;
	assert lexKindAt("return <a/>", 1) === TokenKind.JsxTagStart;
	assert lexKindAt("[<a/>, <b/>]", 1) === TokenKind.JsxTagStart;
	assert lexKindAt("[<a/>, <b/>]", 5) === TokenKind.Comma;
	assert lexKindAt("[<a/>, <b/>]", 6) === TokenKind.JsxTagStart;
}
