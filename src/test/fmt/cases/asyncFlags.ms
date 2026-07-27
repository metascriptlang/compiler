// `async` / generator / generic flags on function expressions, arrow
// functions, and class methods. The parser stores these in the kind's
// flags field (`funcExprFlags`, `arrowFlags`, `methodFlags`); the
// printers were silently dropping the field, stripping the keyword.
//
// AUDIT-VERIFIED — these all reproduce in the current code:
// - `async function () {}`              → `function () {}`
// - `async (x) => x`                    → `(x) => x`
// - `class Foo { async bar() {} }`      → `class Foo { bar() {} }`
// - `class Foo { process<T>(x: T) {} }` → `class Foo { process(x: T) {} }`

import { assertFmtPreservesAst, assertFmtContains } from "../roundtrip";

test "fmt: async function expression preserves async" {
	const src = "const f = async function (): Promise<number> { return 1; };";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "async function");
}

test "fmt: async arrow function preserves async" {
	const src = "const f = async (x: number): Promise<number> => x + 1;";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "async (");
}

test "fmt: async class method preserves async" {
	const src = "class Foo { async bar(): Promise<void> {} }";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "async bar");
}

test "fmt: generic class method preserves <T>" {
	const src = "class Foo { process<T>(x: T): T { return x; } }";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "process<T>");
}

test "fmt: generator function expression preserves star" {
	const src = "const f = function* (): number { yield 1; return 0; };";
	assert assertFmtPreservesAst(src);
	assert assertFmtContains(src, "function*");
}
