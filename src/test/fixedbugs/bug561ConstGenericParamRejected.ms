// bug561 — a `const` generic parameter was read as two type parameters
//
// Symptom:    `class Matrix<const ROWS: int32, const COLS: int32>` counted four type parameters,
//             left ROWS unbound, and failed with unrelated errors ("Undefined variable 'ROWS'",
//             "expected 4, got 2", a float64 narrowing).
// Root cause: the generic parameter capture took `const` and the parameter's type as names.
// Fix:        a `const` generic parameter is refused at the declaration with one diagnostic
//             that names it; generic parameters are types (decision Q19, 2026-09-26).

import { compileToC } from "../helpers";

function errorOf(src: string): string {
	const c = compileToC(src);
	return c.ok ? "" : c.error;
}

test "bug561: a const parameter of a generic class is refused by name" {
	const e = errorOf("class Matrix<const ROWS: int32> { rows(): int32 { return ROWS; } }\nconst m = new Matrix<2>();");
	assert e.indexOf("const generic parameter 'ROWS' is not supported") >= 0;
}

test "bug561: a const parameter of a generic function is refused by name" {
	const e = errorOf("function fill<T, const N: int32>(x: T): T[] { return [x]; }");
	assert e.indexOf("const generic parameter 'N' is not supported") >= 0;
}

test "bug561: the Matrix of two const parameters stops at one diagnostic" {
	const e = errorOf(`
class Matrix<const ROWS: int32, const COLS: int32> {
	getTotalElements(): int32 { return ROWS * COLS; }
}
const a = new Matrix<2, 3>();
console.log(a.getTotalElements());
`);
	assert e.indexOf("const generic parameter 'ROWS' is not supported") >= 0;
	assert e.indexOf("Undefined variable") < 0;
	assert e.indexOf("type arguments") < 0;
}

test "bug561: a type parameter spelled Const is still a type parameter" {
	assert errorOf("function first<T, Const>(x: T, y: Const): T { return x; }\nconsole.log(first(1 as int32, \"s\"));") == "";
}
