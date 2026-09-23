// bug200 — null passed to a Borrow<T> parameter reached C as `&NULL`
//
// Symptom:    `extern function f(p: Borrow<S>)` called as `f(null)` passed the checker, and
//             clang then stopped on "cannot take the address of an rvalue of type 'void *'".
//             The C header importer used to map `const S*` to `Borrow<S>`, so `NULL` into
//             any const struct pointer of an imported header hit it.
//
// Root cause: borrow promotion checked the argument against the pointee `S`, and a value
//             struct accepts null; `needsStdConv` also counted null as a promotable source.
//
// Fix:        null is not a source of borrow promotion in `isAssignable` or `needsStdConv`
//             (src/checker/compat.ms), so the call is refused as an argument mismatch.

import { compileToCWithStd } from "../helpers";

const PRELUDE = `
struct P { a: int32; }
extern function takesBorrow(p: Borrow<P>): int32;
extern function takesScalar(v: Borrow<float32>): int32;
function local(p: Borrow<P>): int32 { return p.a; }
`;

function errorsOf(body: string): string {
	const r = compileToCWithStd(PRELUDE + "function main(): void { " + body + " }");
	if (r.ok) return "";
	return r.error;
}

test "bug200: null into an extern Borrow<struct> param is refused" {
	const e = errorsOf("takesBorrow(null);");
	assert e.contains("Argument type mismatch in 'takesBorrow' arg 0: got null, expected Borrow<P>"), e;
}

test "bug200: null into a Borrow<scalar> param is refused" {
	const e = errorsOf("takesScalar(null);");
	assert e.contains("Argument type mismatch in 'takesScalar' arg 0"), e;
}

test "bug200: null into a MetaScript function's Borrow param is refused" {
	const e = errorsOf("local(null);");
	assert e.contains("Argument type mismatch in 'local' arg 0"), e;
}

test "bug200: a value still promotes to Borrow" {
	assert errorsOf("const p: P = { a: 1 }; local(p);") == "";
}
