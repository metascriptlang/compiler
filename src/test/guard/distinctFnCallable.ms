// nim-guard: a `distinct` over a function type is called, widened and copied through its base on BOTH backends
//
// INVARIANT (reference skipTypes({tyDistinct, tyGenericInst}) before a call, a conversion or a
//   lifted hook): the callee goes through a hidden conversion to the base function type
//   (callResolve), the value copies with the closure's own hooks (classify/destructorLifting),
//   and the C call is a closure call — a generic instance `Thunk<number>` and a struct field or
//   array element of that type behave exactly like the base closure.
//
// WHAT IT CATCHES: C emitting a direct call on an msClosure, hook names spelled after the
//   distinct instance (undefined _Thunk__numberCopy), a member callee going untyped, or the
//   js lane regressing while native passes.
//
// RED MEANS: exit != 0, or GUARD-OK missing on either lane.
//
// GUARD-JS

type Thunk<T> = distinct (() => T);
interface Box { f: Thunk<number>; }
function make(n: number): Thunk<number> { return (() => n) as Thunk<number>; }
function keep(x: Thunk<number>): Thunk<number> { const y = x; return y; }

const t = make(7);
const f: () => number = t;
const k = keep(t);
const b: Box = { f: make(9) };
const c = b;
const xs: Thunk<number>[] = [make(1), make(2)];
let sum: number = 0;
for (const x of xs) sum = sum + x();
if (t() == 7 && f() == 7 && k() == 7 && c.f() == 9 && b.f() == 9 && sum == 3) {
	console.log("GUARD-OK");
} else {
	console.log("GUARD-FAIL " + t().toString() + " " + c.f().toString() + " " + sum.toString());
}
