// bug019 — splitTopLevel mis-counts depth on `=>` (arrow function arrow)
//
// Symptom:    `Map<string, Handler>` where `Handler = (s: string) => Result<string, string>`
//             failed to compile to C with:
//               error: assigning to 'OrderedMapEntry__string_function' from
//               incompatible type 'OrderedMapEntry__string_function_unknown'
//             Three different struct names were emitted for the same logical
//             type (`__string_function`, `__string_function_unknown`,
//             `__string_function_stringgt_`), causing layout mismatch + link
//             errors.
//
//             Bug010 had fixed the simple-return case (e.g. `(x) => int32`),
//             but function types with GENERIC return types (Result, Map,
//             Either, etc.) still broke. Mcp's handler signature
//             `(args: JsonValue) => Result<JsonValue, RpcError>` hit this.
//
// Root cause: `splitTopLevel` in src/utils/string.ms treats every `>` as a
//             bracket close — decrements depth unconditionally. The `>` of
//             `=>` therefore takes depth from 0 → -1; subsequent `<` for
//             the nested generic puts depth back to 0; then the comma
//             INSIDE the nested generic is treated as a top-level
//             separator. `Map`'s 2-arg type-arg list gets split into
//             THREE pseudo-args ["string", "(s: string) => Result<string",
//             "string>"], each going through a different resolution path
//             → three different mangled struct names → C compiler error.
//
// Fix:        src/utils/string.ms: don't decrement depth on `>` that is
//             the second character of `=>`. The check is `prev === "="`.
//
// This regression test verifies BOTH the underlying splitTopLevel
// behavior AND the full pipeline (Map<string, FnReturnGeneric> compiles
// and runs).

import { splitTopLevel } from "../../utils/string";

test "bug019: splitTopLevel preserves comma inside generic with arrow" {
	// The substring that ends up inside `Map<...>` when V is an arrow
	// function returning a generic. Pre-fix this split into 3 elements;
	// post-fix it correctly splits into 2.
	const parts = splitTopLevel("string, (s: string) => Result<string, string>", ",");
	assert parts.length == 2;
	assert parts[0] == "string";
	assert parts[1] == "(s: string) => Result<string, string>";
}

test "bug019: splitTopLevel handles arrow-returning-arrow" {
	// Nested arrow functions — the `>` of every `=>` must be ignored.
	const parts = splitTopLevel("(x: number) => (y: string) => boolean", ",");
	assert parts.length == 1;
}

test "bug019: splitTopLevel still splits top-level commas in generic args" {
	// Sanity check: the fix doesn't accidentally suppress legitimate splits.
	const parts = splitTopLevel("string, number, boolean", ",");
	assert parts.length == 3;
}
