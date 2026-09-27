// bug492 — an enum discriminant was read as the raw variant tag on C
//
// Symptom:    `interface Bv { kind: K.B } | struct Av { kind: K.A }` printed `B A` where JS printed
//             `A B`; `match (kind: S)` with `S { A = 5, B = 10 }` read 0/1 as the kind, and match
//             arms out of enum order took the wrong branch.
// Root cause: every union stores the variant index in `_tag`, and the discriminant read emitted
//             `_tag` as the enum value, which holds only when variant i carries the member of
//             value i.
// Fix:        the read maps the tag to the variant's enum member (the mapping the string and
//             boolean discriminants already use) and emits `_tag` alone only when every variant's
//             member value equals its index.

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

function fnBody(c: string, name: string): string {
	let at = c.indexOf(`${name}__`, 0);
	while (at >= 0) {
		const eol = c.indexOf("\n", at);
		if (eol > 0 && c.slice(eol - 1, eol) == "{") {
			const end = c.indexOf("\n}\n", eol);
			return c.slice(at, end > 0 ? end : c.byteLength);
		}
		at = c.indexOf(`${name}__`, at + 1);
	}
	return "";
}

const KBA = "export enum K { A, B }\nexport interface Bv { kind: K.B; y: int32 }\nexport struct Av { kind: K.A; x: int32 }\n";

test "bug492: variants out of enum order read the kind through the tag mapping" {
	const c = cOf(KBA + "export type E = Bv | Av;\nexport function kindOf(e: E): K { return e.kind; }\n");
	const body = fnBody(c, "kindOf");
	assert body.contains("_tag == 0 ?");
	assert body.contains("_B :");
}

test "bug492: an unaliased union reads its enum discriminant from the tag, not slot v0" {
	const c = cOf(KBA + "export function kindOf(e: Bv | Av): K { return e.kind; }\n");
	const body = fnBody(c, "kindOf");
	assert body.contains("_tag == 0 ?");
	assert !body.contains("v0->kind");
}

test "bug492: a match type over a sparse enum maps the tag to the member value" {
	const c = cOf("export enum S { A = 5, B = 10 }\nexport type D = match (kind: S) { S.A => { x: int32 }, S.B => { y: string } };\nexport function kindOf(d: D): S { return d.kind; }\n");
	const body = fnBody(c, "kindOf");
	assert body.contains("_tag == 0 ?");
}

test "bug492: three arms out of order read the tag once" {
	const c = cOf("export enum K3 { A, B, C }\nexport type D3 = match (kind: K3) { K3.C => { z: int32 }, K3.A => { x: int32 }, K3.B => { y: string } };\nexport function kindOf(d: D3): K3 { return d.kind; }\n");
	const body = fnBody(c, "kindOf");
	assert body.contains("_disc");
	assert body.contains("== 1 ?");
}

test "bug492: variants in enum order still read the tag directly" {
	const c = cOf("export enum K { A, B }\nexport type Same = match (kind: K) { K.A => { x: int32 }, K.B => { y: string } };\nexport function kindOf(s: Same): K { return s.kind; }\n");
	const body = fnBody(c, "kindOf");
	assert body.contains("_tag");
	assert !body.contains("_tag == 0 ?");
}
