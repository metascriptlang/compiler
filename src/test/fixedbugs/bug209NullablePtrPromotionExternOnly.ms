// bug209 — a MetaScript function with a `Ptr<S> | null` parameter received `&local`
//
// Symptom:    `function keep(p: Ptr<C> | null)` called as `keep(c)` with `c: C` compiled and
//             passed the address of the caller's local; nothing stopped `keep` from storing it,
//             so the pointer outlived `c`.
//
// Root cause: the implicit address taken for a struct passed to `Ptr<S> | null` (bug201) was
//             granted to every callee. The language takes an address implicitly only at an
//             extern C parameter (docs/CODE-STYLE.md §5, Borrow design point 3); MetaScript code
//             says `ref` or passes the value, as Nim says `var` (a `ptr T` formal takes no object).
//
// Fix:        relateCallArgs (src/checker/callResolve.ms) refuses the promotion unless the callee
//             symbol is ImportC. NIM-REF CK-102.

import { compileToCWithStd } from "../helpers";

const PRELUDE = `
struct C { a: int32; }
function keep(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; }
function pick<T>(p: Ptr<C> | null, t: T): int32 { return p == null ? 0 : p.a; }
class K { take(p: Ptr<C> | null): int32 { return p == null ? 0 : p.a; } }
extern function ext(p: Ptr<C> | null): int32;
function bump(ref p: C): void { p.a = p.a + 1; }
`;

function errorsOf(body: string): string {
	const r = compileToCWithStd(PRELUDE + "function main(): void { const c: C = { a: 1 }; " + body + " }");
	if (r.ok) return "";
	return r.error;
}

test "bug209: a struct into a MetaScript function's Ptr<C> | null param is refused" {
	const e = errorsOf("keep(c);");
	assert e.contains("Argument type mismatch in 'keep' arg 0: got C, expected Ptr<C> | null"), e;
	assert e.contains("only for an extern C function"), e;
}

test "bug209: the same through a method, a closure and a generic function" {
	assert errorsOf("const k = new K(); k.take(c);").contains("in 'take' arg 0"), "method";
	assert errorsOf("const f = (p: Ptr<C> | null): int32 => 0; f(c);").contains("in 'f' arg 0"), "closure";
	assert errorsOf("pick(c, 1);").contains("in 'pick' arg 0"), "generic";
}

test "bug209: an extern callee still takes the address, and null and ref still work" {
	assert errorsOf("ext(c); ext(null); keep(null); let m: C = { a: 1 }; bump(m);") == "";
}
