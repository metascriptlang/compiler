// Symptom: a `const` binding could be written: its fields, its elements, the binding itself, and a pass to a `ref` formal were all accepted on C, and a module const folded into a literal reached clang as `1 = 2`.
// Root cause: the checker had no assignability relation; `SymbolFlag.Mutable` was set on every binding but no write site read it.
// Fix: one relation (`assignable.ms`, Nim parampatterns.isAssignable) asked by `=`, compound assignment, `++`/`--` and `ref` arguments; const is deep through a declared `struct`, `T[N]` and `Vec<T>`.
import { compileToCWithStd } from "../helpers";

function constWrite210(body: string): string {
	const result = compileToCWithStd(`
struct In210 { v: int32; }
struct S210 { a: int32; inner: In210; xs: int32[3]; }
function take210(ref s: S210): void { s.a = 1; }
const limit210: int32 = 1;
function main(): int32 {
	const s: S210 = { a: 1, inner: { v: 1 }, xs: [1, 2, 3] };
	const k: int32 = 1;
	${body}
	return 0;
}
process.exit(main());
`);
	return result.ok ? "" : result.error;
}

test "bug210: a field of a const struct cannot be written" {
	const error = constWrite210("s.a = 2;");
	assert error.indexOf("cannot write 's.a' — 's' is const (use 'let')", 0) >= 0, error;
}

test "bug210: a nested field of a const struct cannot be written" {
	const error = constWrite210("s.inner.v = 3;");
	assert error.indexOf("cannot write 's.inner.v' — 's' is const (use 'let')", 0) >= 0, error;
}

test "bug210: a sized-array element inside a const struct cannot be written" {
	const error = constWrite210("s.xs[0] = 4;");
	assert error.indexOf("cannot write 's.xs[…]' — 's' is const (use 'let')", 0) >= 0, error;
}

test "bug210: a const scalar cannot be reassigned" {
	const error = constWrite210("k = 2;");
	assert error.indexOf("cannot assign to 'k' — 'k' is const (use 'let')", 0) >= 0, error;
}

test "bug210: a module const cannot be reassigned, before folding turns it into a literal" {
	const error = constWrite210("limit210 = 2;");
	assert error.indexOf("cannot assign to 'limit210' — 'limit210' is const (use 'let')", 0) >= 0, error;
	assert error.indexOf("not assignable", 0) < 0, error;
}

test "bug210: a const struct cannot be passed to a ref formal" {
	const error = constWrite210("take210(s);");
	assert error.indexOf("cannot pass 's' to a 'ref' parameter — 's' is const (use 'let')", 0) >= 0, error;
}

test "bug210: compound assignment and increment count as writes" {
	const compound = constWrite210("s.a += 1;");
	assert compound.indexOf("cannot write 's.a' — 's' is const (use 'let')", 0) >= 0, compound;
	const increment = constWrite210("k++;");
	assert increment.indexOf("cannot assign to 'k' — 'k' is const (use 'let')", 0) >= 0, increment;
}
