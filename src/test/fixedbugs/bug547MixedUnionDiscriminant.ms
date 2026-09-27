// bug547 — a union of an inline struct and a reference variant read shared fields through slot v0
//
// Symptom:    on `struct Pt { kind: "pt"; name: string; x: int32 } | interface Nd { kind: "nd"; name:
//             string }`, an un-narrowed `m.name` compiled and C read it through the inline slot v0
//             while the active variant was the Nd pointer; `m.kind = "pt"` was accepted narrowed or
//             not and wrote into the overlapping storage.
//
// Root cause: the shared-field gate compared field offsets only; an inline variant and a pointer
//             variant share no layout even when their prefixes match. Nothing refused a write to a
//             literal discriminant, which only a new value of the other variant may change.
//
// Fix:        a field shared by inline and reference variants needs narrowing, except the literal
//             discriminant, which C reads from the tag; a discriminant at different offsets stays
//             refused. A write to a string or boolean discriminant is refused (Nim checks a
//             discriminant write at run time, FieldDiscriminantCheck, assign.nim:293; a literal-typed
//             discriminant has one value per variant, so the write is refused statically).

import { errorCount, hasError } from "../handoff/helpers";

const MIXED547 = "struct Pt547 { kind: \"pt\"; name: string; x: int32 }\ninterface Nd547 { kind: \"nd\"; name: string }\ntype Mixed547 = Pt547 | Nd547;\n";
const BOOL547 = "struct Ok547 { ok: true; v: int32 }\ninterface Er547 { ok: false; msg: string }\ntype Res547 = Ok547 | Er547;\n";

test "bug547: the discriminant of a mixed union reads without narrowing" {
	assert errorCount(MIXED547 + "function tag(m: Mixed547): string { return m.kind; }\n") == 0;
	assert errorCount(BOOL547 + "function okOf(r: Res547): boolean { return r.ok; }\n") == 0;
}

test "bug547: a shared field of an inline and a reference variant needs narrowing" {
	assert hasError(MIXED547 + "function nameOf(m: Mixed547): string { return m.name; }\n", "is stored inline in some variants");
	assert errorCount(MIXED547 + "function nameOf(m: Mixed547): string {\n\tif (m.kind === \"pt\") return m.name;\n\treturn m.name;\n}\n") == 0;
}

test "bug547: a discriminant at different offsets stays refused" {
	assert hasError("struct A547 { x: int32; kind: \"a\" }\nstruct B547 { kind: \"b\"; y: int32 }\ntype AB547 = A547 | B547;\nfunction k(u: AB547): string { return u.kind; }\n", "sits at different offsets");
}

test "bug547: a write to a string or boolean discriminant is refused" {
	assert hasError(MIXED547 + "function setPt(m: Mixed547): void { m.kind = \"pt\"; }\n", "cannot assign to 'kind': it is the discriminant");
	assert hasError(MIXED547 + "function relabel(m: Mixed547): void {\n\tif (m.kind === \"nd\") {\n\t\tm.kind = \"nd\";\n\t}\n}\n", "cannot assign to 'kind': it is the discriminant");
	assert hasError(BOOL547 + "function flip(r: Res547): void { r.ok = false; }\n", "cannot assign to 'ok': it is the discriminant");
}
