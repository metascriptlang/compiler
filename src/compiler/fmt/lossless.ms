import { Token, TokenKind, tokenKindToString } from "../../lexer/token";
import { lex } from "../../lexer/lexer";

function isCloser(kind: TokenKind): boolean {
	return kind == TokenKind.RParen || kind == TokenKind.RBracket || kind == TokenKind.RBrace;
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

function describe(t: Token, kind: boolean): string {
	let text = t.value != "" ? t.value : tokenKindToString(t.kind);
	if (kind) text = tokenKindToString(t.kind) + " " + text;
	const nl = text.indexOf("\n");
	if (nl >= 0) text = text.byteSlice(0, nl) + "…";
	return "`" + text + "` at " + t.line.toString() + ":" + t.column.toString();
}

export function checkLossless(source: string, formatted: string): Result<void, string> {
	const before = lex(source);
	if (!before.ok) return Result.err("source does not lex: " + before.error);
	const after = lex(formatted);
	if (!after.ok) return Result.err("formatted output does not lex: " + after.error);
	const a = significantTokens(before.value);
	const b = significantTokens(after.value);
	const n = a.length < b.length ? a.length : b.length;
	for (let i = 0; i < n; i += 1) {
		if (!sameToken(a[i], b[i])) {
			const kind = a[i].value == b[i].value;
			return Result.err("fmt changes " + describe(a[i], kind) + " into " + describe(b[i], kind) + " of the output");
		}
	}
	if (a.length > n) return Result.err("fmt drops " + describe(a[n], false) + " and everything after it");
	if (b.length > n) return Result.err("fmt adds " + describe(b[n], false) + " of the output at the end");
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

test "lossless: the error names the first differing token" {
	const r = checkLossless("try { f(); } finally { g(); }", "try { f(); } catch { } finally { g(); }");
	assert !r.ok && r.error.contains("`finally` at 1:14");
}
