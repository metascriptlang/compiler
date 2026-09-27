// bug502 — a constructor argument was passed by its own type, not the parameter's
//
// Symptom:    `new Box(l)` with `l: "a" | "b"` and `constructor(m: string)` emitted
//             `Box_init(_new1_, &((*l)))` (msString* into msString), and `new LitBox("a")` with
//             `constructor(l: "a" | "b")` passed the string by value into msString*; neither
//             compiled. The checker's `throw l` → `new Error(l)` boxing reaches the same path.
// Root cause: the NewExpr `_init` call took the address when the ARGUMENT type was passed by
//             pointer, while the `_init` prototype follows the PARAMETER type.
// Fix:        each `_init` argument goes through `shimCallArg` with the constructor's parameter
//             type, as every other call does (Nim genArg decides by the formal).

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

const LIT = "export type Lit = \"a\" | \"b\";\n";
const BOX = "export class Box { m: string; constructor(m: string) { this.m = m; } }\n";
const LITBOX = "export class LitBox { l: Lit; constructor(l: Lit) { this.l = l; } }\n";
const GBOX = "export class GBox<T> { v: T; constructor(v: T) { this.v = v; } }\n";

test "bug502: a union argument reaches a string constructor parameter by value on C" {
	const c = cOf(LIT + BOX + "export function f(l: Lit): string { return new Box(l).m; }\n");
	assert c.contains(", (*l));");
	assert !c.contains("&((*l))");
}

test "bug502: a string argument reaches a union constructor parameter by address on C" {
	const c = cOf(LIT + LITBOX + "export function g(): Lit { return new LitBox(\"a\").l; }\n");
	assert c.contains(", &_clit");
}

test "bug502: a generic instance constructor takes its argument by the substituted parameter on C" {
	const c = cOf(LIT + GBOX + "export function h(l: Lit): string { return new GBox<string>(l).v; }\n");
	assert c.contains("__string_init(_new");
	assert c.contains(", (*l));");
	assert !c.contains("&((*l))");
}
