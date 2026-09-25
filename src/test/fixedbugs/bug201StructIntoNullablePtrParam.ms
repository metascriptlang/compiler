// bug201 — any struct value passed to a `Ptr<S> | null` parameter reached C unconverted
//
// Symptom:    `function f(p: Ptr<P> | null)` called as `f(v)` with `v: P`, or with a struct of
//             another type, passed the checker; clang then stopped on "passing 'P' to parameter
//             of incompatible type 'P *'". An imported `const S*` parameter is `Ptr<S> | null`,
//             so every config struct passed to a C constructor hit it.
//
// Root cause: `needsStdConv` treated any struct into any union as a tagged-union construction,
//             but `Ptr<S> | null` is a bare pointer in C.
//
// Fix:        for a nullable Ptr union only a struct assignable to its pointee converts, and
//             spanLower lowers that conversion to the address, as it does for Borrow<S>
//             (`promotesToNullablePtr`, src/checker/compat.ms). Behaviour: corpus 805, 807.
//             Since bug209 only an extern callee takes the address.

import { compileToCWithStd } from "../helpers";

const PRELUDE = `
struct P { a: int32; }
struct Q { b: int32; }
function f(p: Ptr<P> | null): int32 { return p == null ? 0 : p.a; }
extern function g(p: Ptr<P> | null): int32;
`;

function errorsOf(body: string): string {
	const r = compileToCWithStd(PRELUDE + "function main(): void { " + body + " }");
	if (r.ok) return "";
	return r.error;
}

test "bug201: a struct of another type into Ptr<P> | null is refused" {
	const e = errorsOf("const q: Q = { b: 1 }; f(q);");
	assert e.contains("Argument type mismatch in 'f' arg 0: got Q, expected Ptr<P> | null"), e;
}

test "bug201: the same holds for an extern parameter" {
	const e = errorsOf("const q: Q = { b: 1 }; g(q);");
	assert e.contains("Argument type mismatch in 'g' arg 0"), e;
}

test "bug201: the pointee struct into an extern, and null, are accepted" {
	assert errorsOf("const p: P = { a: 1 }; g(p); g(null); f(null);") == "";
}
