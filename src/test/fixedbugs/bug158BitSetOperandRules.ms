// bug158 — BitSet operands that fell through to the integer rules
// Symptom: `E.B | s` (member on the left) typed `int32`, so `const n: int32 = E.B | s` compiled and
//          printed 5 while `s | E.B` was a set; `s == E.A` and `BitSet<E> == BitSet<K>` compiled and
//          compared the words; `s <= t` compared the words (`{A} <= {B}` was true); `BitSet<uint8>`
//          resolved to a one-byte set whose `1 << 200` trapped at run time.
// Root cause: inferBitSetOp only mirrored a set on the left; equalityOperandsOk let any enum operand
//             through and never compared the element enums; relationalNeedsOperator did not list
//             sets; resolveAnnotation accepted any element type.
// Fix: the set rules are symmetric, equality needs the same element enum, ordering needs a declared
//      operator, and the element must be an enum with ordinal members.

import { compileToC } from "../helpers";

const E158 = "enum E { A, B, C, D } enum K { X, Y } ";

function errorsOf(body: string): string {
	const r = compileToC(E158 + body);
	if (r.ok) return "";
	return r.error;
}

test "bug158: a member on the left of | joins the set" {
	assert errorsOf("const s: BitSet<E> = E.A | E.C; const t = E.B | s; console.log(t.has(E.B));") == "";
	assert errorsOf("const s: BitSet<E> = E.A | E.C; const n: int32 = E.B | s; console.log(n);").contains("not assignable");
}

test "bug158: a set equals only a set over the same enum" {
	assert errorsOf("const s: BitSet<E> = E.A | E.C; const u: BitSet<E> = E.C | E.A; console.log(s == u, s != u);") == "";
	assert errorsOf("const s: BitSet<E> = E.A | E.C; console.log(s == E.A);").contains("operator '==' cannot be applied");
	assert errorsOf("const s: BitSet<E> = E.A | E.C; const t: BitSet<K> = K.X | K.Y; console.log(s != t);").contains("operator '!=' cannot be applied");
}

test "bug158: ordering a set needs a declared operator" {
	assert errorsOf("const s: BitSet<E> = E.A | E.C; const u: BitSet<E> = E.C | E.A; console.log(s <= u);").contains("operator '<=' cannot be applied");
	assert errorsOf("const s: BitSet<E> = E.A | E.C; const u: BitSet<E> = E.C | E.A; console.log(s < u);").contains("operator '<' cannot be applied");
}

test "bug158: the element must be an enum with ordinal members" {
	assert errorsOf("const a: BitSet<uint8> = 0 as BitSet<uint8>; console.log(a.isEmpty());").contains("BitSet element must be an enum with ordinal members, got 'uint8'");
	assert errorsOf("enum H { X = 1, Y = 5 } const h: BitSet<H> = 0 as BitSet<H>; console.log(h.isEmpty());").contains("BitSet element must be an enum with ordinal members, got 'H'");
	assert errorsOf("const z: BitSet<E> = 0 as BitSet<E>; console.log(z.isEmpty());") == "";
}
