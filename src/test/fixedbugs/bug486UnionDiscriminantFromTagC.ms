// bug486 — a string or boolean discriminant was read through union slot v0 on C
//
// Symptom:    `struct Pt { kind: "pt"; … } | interface Nd { kind: "nd"; … }`: `m.kind` read the
//             inline Pt slot while an Nd pointer was active — the wrong branch ran, or C panicked
//             on a misaligned read (Nd | Pt) or an invalid MS_BOOL (`ok: true | false`). JS ran.
// Root cause: codegen read the discriminant as `u.v0.kind`, assuming every slot starts with it at
//             one offset; since class and interface members are held by pointer (CG-38), a slot
//             is either an inline struct or a pointer, so no such prefix exists.
// Fix:        the discriminant is read from the wrapper's `_tag`, the one discriminator outside
//             the slots, mapped to the literal its variant pins; a narrowed read goes through the
//             narrowed slot, and a write that reaches codegen is an internal error.

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

const MIXED = "export struct Pt { kind: \"pt\"; x: int32; }\nexport interface Nd { kind: \"nd\"; name: string; }\n";

test "bug486: a string discriminant of a struct | interface union is read from _tag" {
	const c = cOf(MIXED + "export function discOf(m: Pt | Nd): string { return m.kind; }\n");
	const body = fnBody(c, "discOf");
	assert body.contains("_tag == 0 ?");
	assert !body.contains("v0.kind");
	assert !body.contains("v0->kind");
}

test "bug486: the interface-first order reads the same tag" {
	const c = cOf(MIXED + "export function discOf(m: Nd | Pt): string { return m.kind; }\n");
	const body = fnBody(c, "discOf");
	assert body.contains("_tag == 0 ?");
	assert !body.contains("v0->kind");
}

test "bug486: a boolean discriminant is read from _tag" {
	const c = cOf("export struct Pt { ok: true; x: int32; }\nexport interface Er { ok: false; msg: string; }\nexport type Res = Pt | Er;\nexport function discOf(r: Res): boolean { return r.ok; }\n");
	const body = fnBody(c, "discOf");
	assert body.contains("_tag == 0 ? MS_TRUE : MS_FALSE");
	assert !body.contains("v0.ok");
}

test "bug486: three variants read the tag once" {
	const c = cOf(MIXED + "export interface Lf { kind: \"lf\"; w: int32; }\nexport function discOf(m: Pt | Nd | Lf): string { return m.kind; }\n");
	const body = fnBody(c, "discOf");
	assert body.contains("_disc");
	assert body.contains("== 1 ?");
	assert !body.contains("v0.kind");
}

test "bug486: a write to an un-narrowed discriminant is refused by codegen" {
	const c = cOf(MIXED + "export function w(m: Pt | Nd): void { m.kind = \"pt\"; }\n");
	assert c.contains("internal: write to the discriminant 'kind'");
}
