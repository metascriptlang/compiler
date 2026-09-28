// bug599 — unknown took raw addresses and value reinterprets
//
// Symptom:    a Ptr<void> or a cstring stored as unknown, `int32 as unknown as K`
//             and C externs typed unknown all compiled, so one unknown slot held
//             either a managed object or a foreign address the DRC cannot tell apart.
// Root cause: the unknown gate admitted every pointer-shaped kind, `x as unknown`
//             was never checked, and `x as unknown as T` collapsed into `x as T`.
// Fix:        one admission rule (checker/types.ms unknownRefusal) at every entry,
//             no collapse, and a C extern signature may not name unknown.

import { hasError, strictErrorCount } from "../handoff/helpers";

function accepts(src: string): boolean {
	return strictErrorCount(src) == 0;
}

test "bug599: a Ptr<void> is not returned as unknown" {
	assert hasError("function f(p: Ptr<void>): unknown { return p; }", "raw address");
}

test "bug599: a Ptr<void> argument is not passed as unknown" {
	assert hasError("function g(u: unknown): void {}\nfunction f(p: Ptr<void>): void { g(p); }", "raw address");
}

test "bug599: a cstring does not become unknown through an explicit cast" {
	assert hasError("function f(c: cstring): unknown { return c as unknown; }", "raw address");
}

test "bug599: unknown does not cast to cstring" {
	assert hasError("function f(u: unknown): cstring { return u as cstring; }", "never a C string");
}

test "bug599: an int32 is not reinterpreted as an enum through unknown" {
	assert hasError("enum K { A, B }\nfunction f(i: int32): K { return i as unknown as K; }", "convert with `as K`");
}

test "bug599: an int32 converts to an enum directly" {
	assert accepts("enum K { A, B }\nfunction f(i: int32): K { return i as K; }");
}

test "bug599: an object held as unknown gives up its address explicitly" {
	assert accepts("class C { v: int32 = 1; }\nfunction f(c: C): Ptr<void> { const u: unknown = c; return u as Ptr<void>; }");
}

test "bug599: null still reaches any type through unknown" {
	assert accepts("interface P { x: int32; }\nfunction f(): P { return null as unknown as P; }");
}

test "bug599: a C extern may not take unknown" {
	assert hasError("extern function h(p: unknown): void;", "declare it Ptr<void>");
}

test "bug599: a C extern may not return unknown | null" {
	assert hasError("extern function h(): unknown | null;", "declare it Ptr<void>");
}

test "bug599: a C variadic tail stays open" {
	assert accepts("extern function printf(fmt: cstring, ...args: unknown[]): int32;");
}

test "bug599: a function cast may not carry a string through an unknown return" {
	assert hasError("function f(g: () => string): () => unknown { return g as () => unknown; }", "through an unknown slot");
}

test "bug599: a function cast may not carry an int32 through an unknown parameter" {
	assert hasError("function f(g: (x: unknown) => void): (x: int32) => void { return g as (x: int32) => void; }", "through an unknown slot");
}
