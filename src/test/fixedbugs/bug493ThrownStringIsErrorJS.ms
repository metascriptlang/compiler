// bug493 — a thrown string was an Error on C and a bare string on JS
//
// Symptom:    `throw "x"` caught as `catch (e)` printed `m=x` for `"m=" + e.message` on C and
//             `m=undefined` on JS; throwing a string-literal union (`type Lit = "a" | "b"`) did
//             not compile on C (`msString` cast to `msException*`).
// Root cause: the checker types every catch binding as Error. C minted an Error from a thrown
//             `string` (msThrow) but not from a string-literal type, and JS threw the string as is.
// Fix:        every string-like throw argument becomes an Error with that message: msThrow on C,
//             `throw new Error(...)` on JS.

import { compileToC, compileToJS } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

function jsOf(source: string): string {
	const js = compileToJS(source);
	return js.ok ? js.value : js.error;
}

const PLAIN = "export function f(): void { throw \"x\"; }\n";
const LIT = "export type Lit = \"a\" | \"b\";\nexport function h(l: Lit): void { throw l; }\n";

test "bug493: a thrown string is an Error on JS" {
	const js = jsOf(PLAIN);
	assert js.contains("throw new Error(\"x\")");
}

test "bug493: a thrown string-literal union is an Error on JS" {
	const js = jsOf(LIT);
	assert js.contains("throw new Error(l)");
}

test "bug493: a thrown string-literal union mints an exception on C" {
	const c = cOf(LIT);
	assert c.contains("msThrow(");
	assert !c.contains("(msException*)(l");
}
