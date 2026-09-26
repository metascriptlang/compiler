// bug487 — the C name of a recursive object type never finished computing
//
// Symptom:    `type T = { kids: T[]; v: int32 }` killed msc (stack overflow, exit 127, no
//             message) on every C build; JS ran. Mutually recursive aliases did the same.
// Root cause: an object type with no name is named by a structural key of its fields, and the
//             key recursed into a field that leads back to the type being keyed.
// Fix:        the keyer keeps the object types it is inside and writes a back-reference
//             (`rec(<depth>)`) when a field leads back to one of them, as the reference hashes a
//             re-entered anonymous object by its symbol instead of its fields.

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

test "bug487: a self-recursive object alias through an array gets a C name" {
	const c = cOf("export type T = { kids: T[]; v: int32 };\nexport function sum(t: T): int32 { return t.v + t.kids.length; }\n");
	assert c.contains("struct msAnon_");
	assert !c.contains("check:");
}

test "bug487: two mutually recursive object aliases get two C names" {
	const c = cOf("export type A = { bs: B[]; x: int32 };\nexport type B = { as: A[]; y: string };\nexport function f(a: A): int32 { return a.x + a.bs.length; }\nexport function g(b: B): string { return b.y; }\n");
	let names = 0;
	let at = c.indexOf("#define msAnon_", 0);
	while (at >= 0) {
		names += 1;
		at = c.indexOf("#define msAnon_", at + 1);
	}
	assert names >= 2;
}

test "bug487: an object alias recursive one level deeper is named apart from its inner type" {
	const c = cOf("export type T = { inner: { back: T[]; w: int32 }; v: int32 };\nexport function f(t: T): int32 { return t.v + t.inner.w; }\n");
	assert c.contains("struct msAnon_");
	assert !c.contains("check:");
}
