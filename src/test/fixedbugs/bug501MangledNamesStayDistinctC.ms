// bug501 — identifiers that mangle to one C spelling collided
//
// Symptom:    `function a$b` and `function adollarb_` in one module were both
//             `adollarb___<module>_u0` (C: redefinition; JS: identifier already declared); the
//             same for two such globals, for method `A.m` beside function `A_m`, and for a local
//             `dollarv` (`dollarv_1_`) beside a `$v_1` temp (`dollarv_1_`).
// Root cause: `$` expands to `dollar` plus a trailing `_`, which a MetaScript identifier can
//             also end with, while the routine ordinal was keyed on the source name (the method
//             name alone for a method) and a local's suffix could equal a temp's spelling.
// Fix:        the ordinal is keyed on the mangled C base and minted for globals too (suffix
//             `_u<n>` past the first); every emitted local name is registered as a conflict key.

import { compileToC, compileToJS } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

function jsOf(source: string): string {
	const js = compileToJS(source);
	return js.ok ? js.value : js.error;
}

test "bug501: two functions that mangle alike get distinct ordinals on C" {
	const c = cOf("export function a$b(): int32 { return 1; }\nexport function adollarb_(): int32 { return 2; }\n");
	assert c.contains("Oms_u0(void) {");
	assert c.contains("Oms_u1(void) {");
}

test "bug501: two globals that mangle alike get distinct names on C" {
	const c = cOf("export const g$h: int32 = 7;\nexport const gdollarh_: int32 = 8;\n");
	assert c.contains("Oms_u1 = (int32_t)8;");
}

test "bug501: a method and a function spelling its C base get distinct ordinals on C" {
	const c = cOf("class A { m(): int32 { return 9; } }\nexport function A_m(): int32 { return 10; }\nexport function g(): int32 { return new A().m(); }\n");
	assert c.contains("A_m__");
	assert c.contains("Oms_u1(");
}

test "bug501: a local spelled like a temp's suffix is not redeclared on C" {
	const c = cOf("export function f(): int32 { const dollarv: int32 = 11; const $v_1: int32 = 12; return dollarv + $v_1; }\n");
	assert c.contains("dollarv_1_ + dollarv_1__2");
}

test "bug501: two functions that mangle alike get distinct names on JS" {
	const js = jsOf("function a$b(): int32 { return 1; }\nfunction adollarb_(): int32 { return 2; }\nconsole.log(a$b(), adollarb_());\n");
	assert js.contains("_u0()");
	assert js.contains("_u1()");
}
