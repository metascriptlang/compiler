// bug556 — the enum discriminant of a union mixing an inline struct and a reference was refused
//
// Symptom:    on `interface Bv { kind: K.B; y: int32 } | struct Av { kind: K.A; x: int32 }`,
//             `e.kind === K.A` failed with "field 'kind' is stored inline in some variants ... and
//             behind a reference in others" at the discriminant read itself, while the same read
//             with a string or boolean discriminant passed. A write to the enum discriminant of a
//             union whose variants all share one representation was accepted and rewrote the tag.
//
// Root cause: the representation gate exempted only a string or boolean discriminant; an enum
//             literal discriminant, which C also reads from the tag, fell under the shared-field
//             rule, and the write refusal keyed on the same string/boolean-only test.
//
// Fix:        the enum discriminant (stamped from the variants' enum literals, a match type's
//             discriminant, or shared by an unaliased union) is the union's tag discriminant: its
//             read needs no narrowing and a write to it is refused. Nim reads the discriminator
//             without a branch check (semexprs.nim lookupInRecordAndBuildCheck) and faults every
//             write that changes the branch (ccgstmts.nim genDiscriminantCheck, assign.nim
//             FieldDiscriminantCheck); each variant holds one enum member, so every such write does.

import { errorCount, hasError } from "../handoff/helpers";

const MIXED556 = "enum K556 { A, B }\ninterface Bv556 { kind: K556.B; y: int32; name: string }\nstruct Av556 { kind: K556.A; x: int32; name: string }\ntype E556 = Bv556 | Av556;\n";
const ORDER556 = "enum K556 { A, B }\nstruct Av556 { kind: K556.A; x: int32 }\ninterface Bv556 { kind: K556.B; y: int32 }\n";
const IFACE556 = "enum K556 { A, B }\ninterface Bv556 { kind: K556.B; y: int32 }\ninterface Av556 { kind: K556.A; x: int32 }\ntype E556 = Bv556 | Av556;\n";
const MATCH556 = "enum S556 { A, B }\ntype D556 = match (kind: S556) { S556.A => { x: int32 }, S556.B => { y: string } };\n";
const STR556 = "interface Nd556 { kind: \"nd\"; y: int32 }\nstruct Pt556 { kind: \"pt\"; x: int32 }\n";

test "bug556: the enum discriminant of a mixed union reads without narrowing" {
	assert errorCount(MIXED556 + "function isA(e: E556): boolean { return e.kind === K556.A; }\n") == 0;
	assert errorCount(MIXED556 + "function tagOf(e: E556): K556 { return e.kind; }\n") == 0;
	assert errorCount(MIXED556 + "function nm(e: E556): string { return match (e.kind) { K556.A => \"a\", K556.B => \"b\" }; }\n") == 0;
	assert errorCount(MIXED556 + "function xOf(e: E556): int32 {\n\tif (e.kind === K556.A) return e.x;\n\treturn e.y;\n}\n") == 0;
}

test "bug556: the enum discriminant reads in either variant order and through an unaliased union" {
	assert errorCount(ORDER556 + "type E556 = Av556 | Bv556;\nfunction isA(e: E556): boolean { return e.kind == K556.A; }\n") == 0;
	assert errorCount(ORDER556 + "function isA(e: Bv556 | Av556): boolean { return e.kind == K556.A; }\n") == 0;
	assert errorCount(STR556 + "function isPt(m: Nd556 | Pt556): boolean { return m.kind == \"pt\"; }\n") == 0;
}

test "bug556: a shared field that is not the discriminant still needs narrowing" {
	assert hasError(MIXED556 + "function nm(e: E556): string { return e.name; }\n", "is stored inline in some variants");
	assert errorCount(MIXED556 + "function nm(e: E556): string {\n\tif (e.kind === K556.A) return e.name;\n\treturn e.name;\n}\n") == 0;
}

test "bug556: a write to an enum discriminant is refused" {
	assert hasError(MIXED556 + "function flip(e: E556): void { e.kind = K556.B; }\n", "cannot assign to 'kind': it is the discriminant");
	assert hasError(IFACE556 + "function flip(e: E556): void { e.kind = K556.B; }\n", "cannot assign to 'kind': it is the discriminant");
	assert hasError(MATCH556 + "function flip(d: D556): void { d.kind = S556.B; }\n", "cannot assign to 'kind': it is the discriminant");
	assert hasError(MATCH556 + "function keep(d: D556): void {\n\tif (d.kind == S556.A) {\n\t\td.kind = S556.A;\n\t}\n}\n", "cannot assign to 'kind': it is the discriminant");
}
