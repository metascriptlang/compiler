// Generic params on function declarations.
//
// Symptom:    `function f<T>(x: T): T { ... }` formats to
//             `function f(x: T): T { ... }` — the `<T>` clause is
//             silently dropped. Subsequent calls `f<X>(...)` then
//             fail because `f` is no longer generic.
// Root cause: printFunctionDecl ignores generic params, which the
//             parser stashes in fnFlags as `gen:T,U`.
// Fix:        Extract `gen:` segment from fnFlags and emit `<...>`.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: function f<T>(x: T): T preserves generics" {
	assertFmtPreservesAst("function id<T>(x: T): T { return x; }");
}

test "fmt: function f<T, U>(...) multi-param generics" {
	assertFmtPreservesAst("function pair<T, U>(a: T, b: U): T { return a; }");
}
