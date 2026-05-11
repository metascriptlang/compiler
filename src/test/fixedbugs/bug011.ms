// bug011 — duplicate extension registration broke value-typed accessor dispatch
//
// Symptom:    `JSON.parse<Foo>` failed at C compile when Foo had a numeric
//             field:
//                 "no member named 'asNumber' in 'struct JsonValueData'"
//             Direct member-call probe `jv.asNumber()` reported MS-level
//             error: "Ambiguous call to overloaded extension method
//             'asNumber'". asString happened to work — a competing
//             `uint8[]→string` definition occupied the duplicate slot.
//
// Root cause: `registerExtension` (src/checker/context.ms) deduplicated only
//             by Symbol-instance identity (`existing.sym === method.sym`).
//             The same logical extension method registered through multiple
//             import paths produced multiple distinct Symbol instances for
//             the same logical definition, slipping through identity dedup.
//
// Fix:        Add a content-keyed dedup pass after the identity dedup:
//             same (sym.name, sym.modulePath, receiverTypeName, isStatic)
//             → at most one registry entry.

import { compileToC } from "../helpers";

test "bug011: JSON.parse<T> with numeric field compiles (asNumber dispatch)" {
	const src = `
interface Foo { a: string; b: number; }

function main(): void {
	const r = JSON.parse<Foo>("{\\"a\\":\\"hi\\",\\"b\\":1}");
	if (r.ok) { const _b = r.value.b; }
}
`;
	const c = compileToC(src);
	assert c.ok;
}
