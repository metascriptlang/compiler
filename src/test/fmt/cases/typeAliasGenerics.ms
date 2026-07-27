// Generic params on type aliases.
//
// Symptom:    `type Body<T, E> = { ok: boolean }` formats to
//             `type Body = { ok: boolean }` — the `<T, E>` clause is
//             silently dropped. Subsequent uses `Body<X, Y>` then
//             fail because `Body` is no longer generic.
// Symptom 2:  Discriminated-union form `type Body<T, E> = match (...) {}`
//             also drops generics.
// Fix:        printTypeAliasDecl emits `<...>` around aliasGenericParams
//             when non-empty (both regular and DU branches).

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: type Body<T, E> preserves generics" {
	assert assertFmtPreservesAst("type Body<T, E> = T;");
}

test "fmt: discriminated-union type Body<T, E> preserves generics" {
	assert assertFmtPreservesAst("enum K { A, B } type Body<T, E> = match (k: K) { K.A => { value: T }, K.B => { error: E } };");
}
