// bug480 — `>>>` passed the checker and failed the C build
//
// Symptom:    `a >>> n` on any integer type stopped the C build with
//             `internal: operator '>>>' reached codegen unresolved`; JS ran it.
// Root cause: the C binary-expression emitter had no arm for `>>>`, so it fell through to the
//             operator map, which has no C operator for it.
// Fix:        C codegen emits a logical shift: the left operand viewed as the unsigned type of
//             its own width, the count masked to that width, the result cast back.

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

test "bug480: int32 >>> compiles to a uint32 logical shift with a 5-bit count" {
	const c = cOf("export function f(a: int32, n: int32): int32 { return a >>> n; }\n");
	assert c.contains("(uint32_t)(a) >> ((uint32_t)(n) & 31)");
}

test "bug480: int8 >>> shifts the 8-bit view, not the promoted int" {
	const c = cOf("export function f(a: int8, n: int8): int8 { return a >>> n; }\n");
	assert c.contains("(uint8_t)(a) >> ((uint8_t)(n) & 7)");
}

test "bug480: int64 >>> shifts the 64-bit view with a 6-bit count" {
	const c = cOf("export function f(a: int64, n: int64): int64 { return a >>> n; }\n");
	assert c.contains("(uint64_t)(a) >> ((uint64_t)(n) & 63)");
}
