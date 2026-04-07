// cparse — Token definitions
// Port of: ~/projects/chibicc chibicc.h (Token, TokenKind section)

export enum TokenKind {
	Ident,       // identifiers
	Punct,       // punctuators
	Keyword,     // keywords
	Str,         // string literals
	Num,         // numeric literals (integer or float)
	PPNum,       // preprocessing number (before numeric conversion)
	Eof,         // end-of-file marker
}

// Literal type classification attached to Num / Str tokens. Driven by numeric
// suffix (L, LL, U, UL, ULL, f) or string prefix (L"", u"", U"", u8""). Needed
// by the const expression evaluator to pick the right width for #if conditions
// and enum values. chibicc stores a Type* here; we store a small enum to avoid
// a circular dependency between token.ms and type.ms.
export enum LitKind {
	None,        // not a Num/Str token
	Int,         // 42
	UInt,        // 42u
	Long,        // 42L
	ULong,       // 42uL
	LongLong,    // 42LL
	ULongLong,   // 42uLL
	Float,       // 3.14f
	Double,      // 3.14
	LongDouble,  // 3.14L
	StrChar,     // "..."
	StrWide,     // L"..."
	StrU16,      // u"..."
	StrU32,      // U"..."
	StrUtf8,     // u8"..."
}

// A single token. Linked-list threaded via `next` to mirror chibicc's structure
// and allow cheap splicing during macro expansion.
export interface Token {
	kind: TokenKind;
	next: Token;            // next token; null as Token at end
	// Numeric payload (valid when kind === Num)
	intVal: int64;
	floatVal: float64;
	// Literal classification (valid when kind === Num or kind === Str)
	litKind: LitKind;
	// String payload
	stringVal: string;      // raw lexeme (Ident/Punct/Keyword/PPNum) OR decoded
	                        // string-literal contents with embedded NULs allowed
	// Source location
	file: string;           // absolute path of containing file
	line: number;           // 1-based line number in `file`
	col: number;            // 1-based column number
	byteOffset: number;     // byte offset into original source
	byteLength: number;     // token length in source bytes
	// Preprocessor bookkeeping
	atBol: boolean;         // token sits at beginning of line (for # directive detection)
	hasSpace: boolean;      // token was preceded by whitespace (for # stringify spacing)
	// Macro expansion hide-set (Kernighan & Ritchie algorithm from chibicc)
	hideset: string[];      // macro names that must not expand inside this token
	// Macro expansion provenance — if this token was produced by expanding a
	// macro, `origin` points at the token that triggered expansion. Used for
	// diagnostic messages ("in expansion of macro FOO at ...") and for detecting
	// redundant re-expansion. null as Token for non-macro tokens.
	origin: Token;
}

// Sentinel "null token" we use instead of MetaScript null to avoid null checks
// in tight tokenizer loops. Created by makeEofToken.
export function makeEofToken(file: string): Token {
	return {
		kind: TokenKind.Eof,
		next: null as unknown as Token,
		intVal: 0 as int64,
		floatVal: 0.0,
		litKind: LitKind.None,
		stringVal: "",
		file,
		line: 1,
		col: 1,
		byteOffset: 0,
		byteLength: 0,
		atBol: true,
		hasSpace: false,
		hideset: [],
		origin: null as unknown as Token,
	};
}

test "EOF token constructs" {
	const t = makeEofToken("test.h");
	assert t.kind === TokenKind.Eof;
	assert t.file === "test.h";
	assert t.atBol === true;
}
