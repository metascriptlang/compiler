// Generic params on class and interface declarations.
//
// Symptom:    `class Box<T> { value: T }` formats to `class Box { value: T }`.
//             `interface Pair<T, U> { ... }` similarly drops generics.
// Note:       Generic params for classes/interfaces are stored in a parser
//             side-channel (getGenericDecl by name), not in the AST node
//             data — so the printer must consult that channel.
// Fix:        printClassDecl + printInterfaceDecl emit `<...>` after name
//             when getGenericDecl returns non-empty.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: class Box<T> preserves generics" {
	assert assertFmtPreservesAst("class Box<T> { value: T; }");
}

test "fmt: interface Pair<T, U> preserves generics" {
	assert assertFmtPreservesAst("interface Pair<T, U> { a: T; b: U; }");
}
