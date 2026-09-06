// cparse — Token definitions

export enum CTokenKind {
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
// and enum values. We store a small enum here (rather than a Type*) to avoid
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

// A single token. Linked-list threaded via `next` to allow cheap splicing
// during macro expansion.
export interface CToken {
	kind: CTokenKind;
	// Links are non-owning (Cursor): every token is owned by its pipeline arena
	// (TokenizeResult.arena / PreprocessResult.arena), so dropping a stream is a
	// flat array destroy — an owning `next` would recurse destroy per node and
	// overflow the stack on long streams. See docs/NIM-REF.md §4-§5.
	next: Cursor<CToken>;    // next token; null at end
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
	line: int32;           // 1-based line number in `file`
	col: int32;            // 1-based column number
	byteOffset: int32;     // byte offset into original source
	byteLength: int32;     // token length in source bytes
	// Preprocessor bookkeeping
	atBol: boolean;         // token sits at beginning of line (for # directive detection)
	hasSpace: boolean;      // token was preceded by whitespace (for # stringify spacing)
	// Macro expansion hide-set (Kernighan & Ritchie algorithm)
	hideset: string[];      // macro names that must not expand inside this token
	// Macro expansion provenance — if this token was produced by expanding a
	// macro, `origin` points at the token that triggered expansion. Used for
	// diagnostic messages ("in expansion of macro FOO at ...") and for detecting
	// redundant re-expansion. null for non-macro tokens. Non-owning like `next`.
	origin: Cursor<CToken>;
}

// Sentinel "null token" we use instead of MetaScript null to avoid null checks
// in tight tokenizer loops. Created by makeEofCToken.
export function makeEofToken(file: string): CToken {
	return {
		kind: CTokenKind.Eof,
		next: null,
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
		origin: null,
	};
}

test "EOF token constructs" {
	const t = makeEofToken("test.h");
	assert t.kind == CTokenKind.Eof;
	assert t.file == "test.h";
	assert t.atBol == true;
}
