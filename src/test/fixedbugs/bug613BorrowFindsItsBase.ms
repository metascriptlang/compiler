// Symptom: a body-less `this` function on a distinct never became a method, so a distinct type could reach its base's functions and fields only through a hand-written body per function.
// Root cause: the language had no implementation delegation; the parser also joined the overload flag with a space, so a body-less function's receiver read as "Signer overload".
// Fix: `@delegate` on a body-less function resolves, once at its declaration, the function of the same name that takes the distinct's base, and every call is exchanged for that base before any later pass; `@delegate` on a distinct type lets field access read through to the base.
import { compileToCWithStd } from "../helpers";

function compiles613(body: string): boolean {
	const result = compileToCWithStd(`
struct Account613 { address: uint64; lamports: uint64; }
function key(this a: Account613): uint64 { return a.address * 2; }
type Signer613 = distinct Account613;
${body}
`);
	return result.ok;
}

test "bug613: a delegated function and delegated fields compile" {
	assert compiles613(`
@delegate function key(this s: Signer613): uint64;
@delegate type Payer613 = distinct Account613;
const a: Account613 = { address: 21, lamports: 5 };
const k: uint64 = (a as Signer613).key() + key(a as Signer613);
const l: uint64 = (a as Payer613).lamports;
`);
}

test "bug613: without @delegate a distinct has neither its base's methods nor its fields" {
	assert !compiles613("const a: Account613 = { address: 21, lamports: 5 }; const k = (a as Signer613).key();");
	assert !compiles613("const a: Account613 = { address: 21, lamports: 5 }; const l = (a as Signer613).lamports;");
}

test "bug613: delegation needs a distinct parameter, a base of the same name and the same return type" {
	assert !compiles613("@delegate function key(this a: Account613): uint64;");
	assert !compiles613("@delegate function tag(this s: Signer613): uint64;");
	assert !compiles613("@delegate function key(this s: Signer613): int32;");
}

test "bug613: delegation has no body, takes no arguments and applies to a function or a distinct type" {
	assert !compiles613("@delegate function key(this s: Signer613): uint64 { return 1; }");
	assert !compiles613("@delegate(x) function key(this s: Signer613): uint64;");
	assert !compiles613("@delegate type Plain613 = Account613;");
	assert !compiles613("@delegate const k613 = 1;");
}

test "bug613: delegation does not reach a generic base" {
	assert !compiles613(`
type Heap613<T> = distinct T[];
function size613<T>(a: T[]): int32 { return a.length as int32; }
@delegate function size613<T>(h: Heap613<T>): int32;
`);
}

test "bug613: the former decorator spelling is refused" {
	assert !compiles613("@borrow function key(this s: Signer613): uint64;");
}

test "bug613: a missing base names delegation, not borrowing" {
	const result = compileToCWithStd(`
struct Account613 { address: uint64; }
type Signer613 = distinct Account613;
@delegate function tag(this s: Signer613): uint64;
`);
	assert !result.ok;
	if (!result.ok) {
		assert result.error.indexOf("no tag(Account613) to delegate to", 0) >= 0, result.error;
		assert result.error.indexOf("borrow", 0) < 0, result.error;
	}
}
