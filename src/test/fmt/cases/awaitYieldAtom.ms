// Await/Yield wrapping low-precedence inner expressions.
//
// AUDIT-VERIFIED: `await (c ? a : b)` formats to `await c ? a : b` —
// the `await` then binds only to `c`, and the `?:` wraps the whole
// thing. This is a precedence corruption.
//
// Root cause: index.ms inline arms for AwaitExpr/YieldExpr call
// callPrintNode directly instead of printAtom — so the inner
// ConditionalExpr is unwrapped.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: await (cond ? a : b) preserves parens" {
	assert assertFmtPreservesAst("async function f(c: boolean, a: number, b: number): Promise<number> { return await (c ? a : b); }");
}

test "fmt: await (a + b) preserves parens" {
	assert assertFmtPreservesAst("async function f(a: number, b: number): Promise<number> { return await (a + b); }");
}
