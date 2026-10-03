// GUARD-OS solana
// An overloaded function that returns an aggregate links under --os=solana when every call names
// the overload it resolved to: bound by a declaration initializer (arity 1, 2 and 3, and an
// overload set whose second routine returns a scalar) and by a `try` operand. A declaration
// initializer passes its destination to the callee (NIM-REF CK-25). RED MEANS that path named the
// set's first routine: the C compile fails with "too many arguments to function call".
import { instructionData, logU64 } from "std/solana";
struct Pair {
	a: uint64;
	b: uint64;
}
function mk(x: uint64): Pair {
	return { a: x, b: 1 };
}
function mk(x: uint64, y: uint64): Pair {
	return { a: x, b: y };
}
function mk(x: uint64, y: uint64, z: uint64): Pair {
	return { a: x + z, b: y + z };
}
function width(n: uint64): Pair {
	return { a: n, b: 0 };
}
function width(n: uint64, m: uint64): uint64 {
	return n + m;
}
function load(x: uint64): Result<Pair, uint64> {
	return Result.ok({ a: x, b: 1 });
}
function load(x: uint64, y: uint64): Result<Pair, uint64> {
	return Result.ok({ a: x, b: y });
}
function loaded(n: uint64): Result<uint64, uint64> {
	const p = try load(n, n + 1);
	return Result.ok(p.a + p.b);
}
function main(): void {
	const n = instructionData().length;
	const a = mk(n);
	const b = mk(n, 2);
	const c = mk(n, 2, 3);
	const w = width(n, 2);
	const r = loaded(n);
	logU64(a.a + b.b + c.b + w);
	if (r.ok) logU64(r.value);
}
main();
