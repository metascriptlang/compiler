import { Token, TokenKind, tokenKindToString, isIdentLikeKind, isIdentOrKeyword } from "../../lexer/token";
import { lex } from "../../lexer/lexer";

function isCloser(kind: TokenKind): boolean {
	return match (kind) {
		TokenKind.RParen | TokenKind.RBracket | TokenKind.RBrace => true,
		_ => false,
	};
}

function nextSignificant(tokens: Token[], from: int32): Token | null {
	for (let i = from; i < tokens.length; i += 1) {
		if (tokens[i].kind != TokenKind.Comment) return tokens[i];
	}
	return null;
}

export function significantTokens(tokens: Token[]): Token[] {
	const out: Token[] = [];
	const open: TokenKind[] = [];
	for (let i = 0; i < tokens.length; i += 1) {
		const t = tokens[i];
		match (t.kind) {
			TokenKind.Eof => {},
			TokenKind.LParen | TokenKind.LBracket | TokenKind.LBrace => {
				open.push(t.kind);
				out.push(t);
			},
			TokenKind.RParen | TokenKind.RBracket | TokenKind.RBrace => {
				if (open.length > 0) open.pop();
				out.push(t);
			},
			TokenKind.Semicolon => {
				if (open.length > 0 && open[open.length - 1] == TokenKind.LParen) out.push(t);
			},
			TokenKind.Comma => {
				const next = nextSignificant(tokens, i + 1);
				if (next != null && !isCloser(next.kind)) out.push(t);
			},
			_ => { out.push(t); },
		}
	}
	return out;
}

function sameToken(a: Token, b: Token): boolean {
	return a.kind == b.kind && a.value == b.value;
}

function greaterUnits(tokens: Token[]): Token[] {
	const out: Token[] = [];
	for (const t of tokens) {
		const joined = match (t.kind) {
			TokenKind.GtGt | TokenKind.GtGtGt | TokenKind.GtEq | TokenKind.GtGtEq | TokenKind.GtGtGtEq => true,
			_ => false,
		};
		if (!joined) {
			out.push(t);
			continue;
		}
		for (let k = 0; k < t.value.byteLength; k += 1) {
			const assign = t.value.byteAt(k) == "=".code;
			out.push({ kind: assign ? TokenKind.Assign : TokenKind.Gt, value: assign ? "=" : ">", line: t.line, column: t.column + k, endLine: t.line, endColumn: t.column + k + 1, rawValue: "" });
		}
	}
	return out;
}

function describe(t: Token, kind: boolean): string {
	let text = t.value != "" ? t.value : tokenKindToString(t.kind);
	if (kind) text = tokenKindToString(t.kind) + " " + text;
	const nl = text.indexOf("\n");
	if (nl >= 0) text = text.byteSlice(0, nl) + "…";
	return "`" + text + "` at " + t.line.toString() + ":" + t.column.toString();
}

function addsArrowParens(a: Token[], i: int32, b: Token[], j: int32): boolean {
	if (!isIdentLikeKind(a[i].kind) || i + 1 >= a.length || a[i + 1].kind != TokenKind.Arrow) return false;
	return j + 3 < b.length && b[j].kind == TokenKind.LParen && sameToken(a[i], b[j + 1])
		&& b[j + 2].kind == TokenKind.RParen && b[j + 3].kind == TokenKind.Arrow;
}

function unquotesKey(a: Token[], i: int32, b: Token[], j: int32): boolean {
	if (a[i].kind != TokenKind.String || i == 0 || i + 1 >= a.length) return false;
	if (a[i - 1].kind != TokenKind.LBrace && a[i - 1].kind != TokenKind.Comma) return false;
	return a[i + 1].kind == TokenKind.Colon && isIdentOrKeyword(b[j].kind) && b[j].value == a[i].value
		&& j + 1 < b.length && b[j + 1].kind == TokenKind.Colon;
}

export function checkLossless(source: string, formatted: string): Result<void, string> {
	const before = lex(source);
	if (!before.ok) return Result.err("source does not lex: " + before.error);
	const after = lex(formatted);
	if (!after.ok) return Result.err("formatted output does not lex: " + after.error);
	const a = greaterUnits(significantTokens(before.value));
	const b = greaterUnits(significantTokens(after.value));
	let i = 0;
	let j = 0;
	while (i < a.length && j < b.length) {
		if (addsArrowParens(a, i, b, j)) {
			i += 1;
			j += 3;
			continue;
		}
		if (unquotesKey(a, i, b, j)) {
			i += 1;
			j += 1;
			continue;
		}
		if (!sameToken(a[i], b[j])) {
			const kind = a[i].value == b[j].value;
			return Result.err("fmt changes " + describe(a[i], kind) + " into " + describe(b[j], kind) + " of the output");
		}
		i += 1;
		j += 1;
	}
	if (i < a.length) return Result.err("fmt drops " + describe(a[i], false) + " and everything after it");
	if (j < b.length) return Result.err("fmt adds " + describe(b[j], false) + " of the output at the end");
	return Result.ok(null);
}

test "lossless: whitespace, statement semicolons and trailing commas are free" {
	assert checkLossless("const a = [1, 2,]\nf(a)", "const a = [1, 2];\nf(a);\n").ok;
}

test "lossless: a for-header semicolon is a token" {
	assert !checkLossless("for (;;) {}", "for (;) {}").ok;
}

test "lossless: a dropped keyword is caught" {
	assert !checkLossless("const t = typeof v;", "const t = typeofv;").ok;
}

test "lossless: dropped parentheses are caught" {
	assert !checkLossless("const w = a - (b ? 2 : 0);", "const w = a - b ? 2 : 0;").ok;
}

test "lossless: literal spelling is a token" {
	assert !checkLossless("const x = 1.0;", "const x = 1;").ok;
}

test "lossless: a comment is a token" {
	assert !checkLossless("// keep\nf();", "f();").ok;
}

test "lossless: a type-argument closer joined to = may print apart" {
	assert checkLossless("let t: A<B<int32>>= v;", "let t: A<B<int32>> = v;\n").ok;
	assert checkLossless("let t: A<int32>= v;", "let t: A<int32> = v;\n").ok;
}

test "lossless: a bitwise compound assignment keeps its operator" {
	assert checkLossless("x >>>= 1;", "x >>>= 1;\n").ok;
	assert !checkLossless("x >>= 1;", "x >> 1;\n").ok;
	assert !checkLossless("x |= 1;", "x = 1;\n").ok;
}

test "lossless: the error names the first differing token" {
	const r = checkLossless("try { f(); } finally { g(); }", "try { f(); } catch { } finally { g(); }");
	assert !r.ok && r.error.contains("`finally` at 1:14");
}

test "lossless: type-argument closers written apart may print joined" {
	assert checkLossless("let t: Array<Array<T> > = v;", "let t: Array<Array<T>> = v;\n").ok;
	assert checkLossless("const f = (): Array<Array<Array<T> > > => v;", "const f = (): Array<Array<Array<T>>> => v;\n").ok;
	assert !checkLossless("let t: Array<Array<T> > = v;", "let t: Array<Array<T>> v;\n").ok;
}

test "lossless: parentheses added around a lone arrow parameter are free" {
	assert checkLossless("set(c => c + 1);", "set((c) => c + 1);\n").ok;
	assert checkLossless("const k = a => b => a;", "const k = (a) => (b) => a;\n").ok;
	assert checkLossless("const e = async p => p;", "const e = async (p) => p;\n").ok;
}

test "lossless: other added or removed parentheses stay refused" {
	assert !checkLossless("f(c);", "f((c));\n").ok;
	assert !checkLossless("set((c) => c);", "set(c => c);\n").ok;
	assert !checkLossless("const f = c => c;", "const f = (c, d) => c;\n").ok;
	assert !checkLossless("const f = c => c;", "const f = (c) => (c);\n").ok;
}

test "lossless: a string token whose decoded value is unchanged may change quotes" {
	assert checkLossless("f('a', \"it\\'s\");", "f(\"a\", \"it's\");\n").ok;
	assert !checkLossless("f('a');", "f(\"b\");\n").ok;
}

test "lossless: an object key may lose the quotes it did not need" {
	assert checkLossless("const o = { 'a': 1, \"class\": 2 };", "const o = { a: 1, class: 2 };\n").ok;
	assert !checkLossless("const o = { 'a': 1 };", "const o = { b: 1 };\n").ok;
	assert !checkLossless("const v = c ? 'a' : b;", "const v = c ? a : b;\n").ok;
	assert !checkLossless("f('a');", "f(a);\n").ok;
}
