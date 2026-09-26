// bug535 — two object types of another field order or width met at a declaration or constructor slot
//
// Symptom:    once `{…}` object types became references, `const a2: A = lit` with `A = { w: int32; v: string }`
//             and `lit = { v: "q", w: 3 }` compiled to a raw pointer cast and read `v` at `w`'s offset
//             (a null-pointer panic); `const x: { v: string } = t` for `t: { w; v }` and `new Box(lit)` for a
//             reordered literal did the same. With value structs clang had refused the program.
//
// Root cause: the declaration and constructor-argument slots did not apply the relation the call argument
//             applies, which refuses a structural assignment whose target fields are not a prefix of the
//             source's in the same order.
//
// Fix:        every fit slot refuses what the argument relation refuses (slotRefuses, bug520), and a
//             constructor argument goes through the same fit; this file pins it for reference object types.

import { hasError } from "../handoff/helpers";
import { compileToC } from "../helpers";

test "bug535: a declaration refuses an object type of another field order" {
	assert hasError("type A535 = { w: int32; v: string };\nfunction run(): void {\n\tconst lit = { v: \"q\", w: 3 };\n\tconst a2: A535 = lit;\n}\n", "is not assignable");
}

test "bug535: a declaration refuses an object type whose fields are not a prefix" {
	assert hasError("type T535 = { w: int32; v: string };\nfunction run(): void {\n\tconst t: T535 = { w: 2, v: \"r\" };\n\tconst x: { v: string } = t;\n}\n", "is not assignable");
	assert hasError("class Leaf535 { w: int32; v: string; constructor(v: string) { this.w = 7; this.v = v; } }\nfunction run(): void {\n\tconst l = new Leaf535(\"p\");\n\tconst y: { v: string } = l;\n}\n", "is not assignable");
}

test "bug535: a constructor argument refuses an object type of another field order" {
	assert hasError("type T535 = { a: int32; s: string };\nclass Box535 { t: T535; constructor(t: T535) { this.t = t; } }\nfunction run(): void {\n\tconst lit = { s: \"l\", a: 4 };\n\tconst b = new Box535(lit);\n}\n", "is not assignable");
}

test "bug535: the same layout and a prefix still fit" {
	const c = compileToC("type T535 = { w: int32; v: string };\nfunction run(): void {\n\tconst lit = { w: 3, v: \"q\" };\n\tconst a: T535 = lit;\n\tconst p: { w: int32 } = a;\n\tconsole.log(a.v + p.w.toString());\n}\nrun();\n");
	assert c.ok, c.error;
}
