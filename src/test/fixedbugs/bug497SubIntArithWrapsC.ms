// bug497 — 8- and 16-bit arithmetic kept the promoted int value
//
// Symptom:    for uint8 s = 200, t = 100, `console.log(s + t)` printed 300 on C while
//             `const u = s + t` printed 44; JS printed 300 for both. uint16 65535 * 65535
//             overflowed C's signed int (UBSan panic in debug), and `int8 -8 >>> 1` was
//             2147483644 on JS; a uint8 `x++` at 255 stored 256 on JS.
// Root cause: C codegen emitted `(s + t)` and let integer promotion decide the width; JS had
//             trimmers for uint32 only.
// Fix:        an 8/16-bit `+ - *`, `-x`, `~x` and `/ %` result is converted back to its own
//             type on C, computed unsigned at 32 bits; a shift masks its count to the left
//             operand's width and wraps there. JS applies `& 0xff`/`& 0xffff` or the
//             `<< 24 >> 24` sign extension to the same results and to a stored `++`/`--`.

import { compileToC, compileToJS } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

function jsOf(source: string): string {
	const js = compileToJS(source);
	return js.ok ? js.value : js.error;
}

test "bug497: uint8 addition wraps at 8 bits on C" {
	assert cOf("export function f(s: uint8, t: uint8): uint8 { return s + t; }\n").contains("((uint8_t)((uint32_t)(s) + (uint32_t)(t)))");
}

test "bug497: uint16 multiplication runs unsigned on C" {
	assert cOf("export function f(a: uint16, b: uint16): uint16 { return a * b; }\n").contains("((uint16_t)((uint32_t)(a) * (uint32_t)(b)))");
}

test "bug497: int8 negation wraps at 8 bits on C" {
	assert cOf("export function f(a: int8): int8 { return -a; }\n").contains("((int8_t)(-a))");
}

test "bug497: uint8 << masks its count to 3 bits on C" {
	assert cOf("export function f(a: uint8, n: uint8): uint8 { return a << n; }\n").contains("((uint8_t)((uint8_t)(a) << ((uint8_t)(n) & 7)))");
}

test "bug497: uint8 addition masks to a byte on JS" {
	assert jsOf("export function f(s: uint8, t: uint8): uint8 { return s + t; }\n").contains("& 255");
}

test "bug497: int16 multiplication sign-extends from 16 bits on JS" {
	assert jsOf("export function f(a: int16, b: int16): int16 { return a * b; }\n").contains("<< 16) >> 16");
}

test "bug497: int8 >>> reads the byte unsigned on JS" {
	assert jsOf("export function f(a: int8, n: int8): int8 { return a >>> n; }\n").contains("& 255) >>> (n & 7)");
}

test "bug497: a uint8 postfix increment wraps on JS" {
	const js = jsOf("export function f(a: uint8): uint8 { let x = a; x++; return x; }\n");
	assert js.contains("& 255");
	assert !js.contains("x++");
}
