// Symptom: a generic called where the caller declared a name its body also uses read the caller's binding: a `const limit242: string` in the caller made the module's `limit242` a string, and a same-typed local made C fail "use of undeclared identifier" and JS throw ReferenceError.
// Root cause: each instance body was checked on top of the caller's innermost scope, so the caller's locals, parameters, loop and lambda bindings shadowed the generic's module names, and an inner generic saw the outer generic's type parameter bound in that scope.
// Fix: an instance body is checked from its module's scope; the checker returns to the caller's scope afterwards.
const limit242: int32 = 10;

struct Box242 { n: int32; }

function clamp242<T>(v: T, n: int32): int32 { return n > limit242 ? limit242 : n; }

function mk242<T>(v: T): Box242 {
	const b: Box242 = { n: 7 };
	return b;
}

function inner242<U>(u: U): int32 {
	const b: Box242 = { n: 4 };
	return b.n;
}

function outer242<Box242>(x: Box242): int32 { return inner242(x); }

function run242(limit242: string): int32 { return clamp242(5 as int64, 42); }

class Counter242<T> {
	total: int32 = 0;
	constructor(v: T) { this.total = limit242; }
}

class Holder242<T> {
	n: int32 = 0;
	get(): int32 { return limit242; }
}

test "bug242: a caller local of another type or of the same type" {
	const limit242: string = "abc";
	assert clamp242(1 as int32, 42) == 10;
	if (true) {
		const limit242: int32 = 99;
		assert clamp242("s", 42) == 10;
	}
}

test "bug242: a caller block, loop, lambda and parameter" {
	if (true) {
		const limit242: string = "x";
		assert clamp242(true, 42) == 10;
	}
	for (const limit242 of ["a"]) {
		assert clamp242(1.5, 42) == 10;
	}
	const f = (limit242: string): int32 => clamp242(7 as uint8, 42);
	assert f("x") == 10;
	assert run242("p") == 10;
}

test "bug242: a caller local named like a type the generic uses" {
	const Box242 = 3;
	assert mk242(2 as int16).n == 7;
}

test "bug242: an inner generic does not see the outer generic's type parameter" {
	assert outer242("s") == 4;
}

test "bug242: a generic class constructor and method" {
	const limit242: string = "c";
	assert new Counter242<int32>(1).total == 10;
	assert new Holder242<boolean>().get() == 10;
}
