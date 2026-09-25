// bug481 — `<<` and `>>` reached C verbatim, undefined for a count at or past the width
//
// Symptom:    `1 << 33` on int32 trapped under UBSan in debug and printed garbage under
//             --release (a denormal, 1000000000000000); JS printed 2.
// Root cause: the C binary-expression emitter passed `<<` / `>>` to the operator map, so C
//             shifted the signed operand by the raw count.
// Fix:        C codegen masks the count to the operand width; `<<` shifts the unsigned view,
//             `>>` keeps the signed operand (arithmetic) and is logical on an unsigned one.

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

test "bug481: int32 << shifts the uint32 view with a 5-bit count" {
	const c = cOf("export function f(a: int32, n: int32): int32 { return a << n; }\n");
	assert c.contains("((int32_t)((uint32_t)(a) << ((uint32_t)(n) & 31)))");
}

test "bug481: int64 >> stays arithmetic with a 6-bit count" {
	const c = cOf("export function f(a: int64, n: int64): int64 { return a >> n; }\n");
	assert c.contains("((int64_t)((int64_t)(a) >> ((uint64_t)(n) & 63)))");
}

test "bug481: uint32 >> is logical with a 5-bit count" {
	const c = cOf("export function f(a: uint32, n: uint32): uint32 { return a >> n; }\n");
	assert c.contains("((uint32_t)((uint32_t)(a) >> ((uint32_t)(n) & 31)))");
}

test "bug481: an int8 << shifts the promoted int32 with a 5-bit count" {
	const c = cOf("export function f(a: int8, n: int8): int8 { return a << n; }\n");
	assert c.contains("((int32_t)((uint32_t)(a) << ((uint32_t)(n) & 31)))");
}
