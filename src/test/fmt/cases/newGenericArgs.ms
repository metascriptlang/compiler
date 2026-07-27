// Generic type arguments on `new` expressions.
//
// Symptom:    `new HashSet<string>()` formats to `new HashSet()` —
//             the `<string>` clause is silently dropped, and the
//             checker then errors that explicit type args are required.
// Root cause: The parser captures the type arg string and stashes it
//             on `Node.typeArg`, but printNewExpr doesn't read that
//             field — only the callee is printed.
// Fix:        printNewExpr emits `<...>` from Node.typeArg between the
//             callee and `(`.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: new T<U>() preserves type args" {
	assert assertFmtPreservesAst("class Box<T> { constructor() {} } const a = new Box<string>();");
}

test "fmt: new T<U, V>(args) preserves type args + args" {
	assert assertFmtPreservesAst("class Pair<T, U> { constructor(a: T, b: U) {} } const a = new Pair<string, number>(\"x\", 1);");
}
