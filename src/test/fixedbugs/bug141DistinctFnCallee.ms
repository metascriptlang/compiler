// bug141 — a value typed `distinct` over a function type could not be called on the C backend
// Symptom: `t()` with `t: distinct (() => number)` reached clang as "called object type 'msClosure' is not a
//          function"; the checker typed the call as inferred; a generic `Thunk<number>` value failed to link
//          (undefined _Thunk__numberCopy/_Thunk__numberWasMoved); a member callee `c.f()` printed <object>.
// Root cause: the callee read, the widening relation and the hook classifier all stopped at the distinct
//             wrapper where the reference skips it (skipTypes tyDistinct/tyGenericInst) to reach the base.
// Fix: the checker calls through a hidden conversion to the base function type, the relation widens the
//      distinct one way to its base, and hook classification peels the distinct to its substituted body.

type Thunk141<T> = distinct (() => T);
type Th141 = distinct (() => number);
interface Box141 { f: Thunk141<number>; }
function keep141(x: Thunk141<number>): Thunk141<number> { const y: Thunk141<number> = x; return y; }
function make141(n: number): Thunk141<number> { return (() => n) as Thunk141<number>; }

test "a non-generic distinct thunk is callable" {
	const t = (() => 7) as Th141;
	assert t() == 7;
}

test "a generic distinct thunk is callable with the substituted return type" {
	const t = (() => 7) as Thunk141<number>;
	const n: number = t();
	assert n == 7;
}

test "the distinct thunk widens to its base function type" {
	const t = (() => 7) as Thunk141<number>;
	const f: () => number = t;
	assert f() == 7;
}

test "a copied generic distinct thunk links and runs" {
	const t = make141(8);
	const u = keep141(t);
	assert u() == 8;
	assert t() == 8;
}

test "a struct field of distinct thunk type is copied and called through the member" {
	const b: Box141 = { f: make141(9) };
	const c = b;
	assert c.f() == 9;
	assert b.f() == 9;
}

test "an array of distinct thunks is iterated and called" {
	const xs: Thunk141<number>[] = [make141(1), make141(2)];
	let sum: number = 0;
	for (const x of xs) sum = sum + x();
	assert sum == 3;
}

test "a captured closure survives through the distinct wrapper" {
	let hits: number = 0;
	const t = (() => { hits = hits + 1; return hits; }) as Thunk141<number>;
	t();
	t();
	assert hits == 2;
}
