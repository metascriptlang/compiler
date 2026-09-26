// bug499 — a char of 0x80 or more read as a negative number on C
//
// Symptom:    for c = "é".byteAt(0) as char, C printed `c as int32` as -61, `c as uint32` as
//             4294967235 and found c below 'a'; JS printed 195 and found it above.
// Root cause: C codegen emitted a char as plain `char`, which is signed on x86 and aarch64
//             Windows, so every widening sign-extended a byte past 127.
// Fix:        a char is emitted as `uint8_t` on C, the 0..255 range JS and Nim's char have.

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

test "bug499: a char parameter is an unsigned byte on C" {
	const c = cOf("export function f(c: char): int32 { return c as int32; }\n");
	assert c.contains("uint8_t c");
	assert !c.contains("char c");
}

test "bug499: a conversion to char narrows to an unsigned byte on C" {
	assert cOf("export function f(n: int32): char { return n as char; }\n").contains("(uint8_t)");
}
