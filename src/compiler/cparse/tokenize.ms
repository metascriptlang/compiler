// cparse — C tokenizer
// Port of: ~/projects/chibicc tokenize.c
//
// STATUS: skeleton. Real implementation lands in task #14.
//
// Entry point: tokenizeFile(source, path) → Token (head of linked list,
// terminated with an Eof token).

import { Token, TokenKind, makeEofToken } from "./token";
import { Diagnostic } from "./error";

export interface TokenizeResult {
	head: Token;
	diagnostics: Diagnostic[];
}

// Tokenize C source text into a linked list of Token. The head is a dummy
// sentinel; real tokens start at head.next. Terminated by an Eof token.
//
// TODO(task #14): full port of chibicc tokenize.c
//   - identifiers / keywords
//   - pp-numbers (deferred numeric conversion until after preprocessing)
//   - string literals: "", L"", u"", U"", u8"", with escape sequences
//   - character literals: '', L'', u'', U''
//   - punctuators (multi-char: <<=, >>=, ..., etc.)
//   - line and block comments
//   - universal character names \uXXXX, \UXXXXXXXX
//   - atBol / hasSpace tracking for the preprocessor
export function tokenizeFile(source: string, path: string): TokenizeResult {
	// Skeleton: returns an Eof-only list so callers can wire without crashing.
	const eof = makeEofToken(path);
	return { head: eof, diagnostics: [] };
}

test "tokenize empty source yields eof" {
	const r = tokenizeFile("", "empty.h");
	assert r.head.kind === TokenKind.Eof;
	assert r.diagnostics.length === 0;
}
