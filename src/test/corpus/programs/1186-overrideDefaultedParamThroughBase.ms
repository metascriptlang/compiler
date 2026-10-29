// @xfail(raiser): the Raiser does not fill the override's defaults through the base (reads an uninitialized slot); card 2026-10-29-raiser-override-through-base-corrupts-heap-and-reads-garbage-defaults
// @skip-js: the callee does not evaluate a default; a call typed as the base passes none, so the override reads undefined
// @stdout: B3,7
// @stdout: B3,7
// @stdout: B3,4
// @stdout: C3,8,9
// @stdout: B5,7
class A { m(x: int32): string { return "A" + x.toString(); } }
class B extends A { m(x: int32, y: int32 = 7): string { return "B" + x.toString() + "," + y.toString(); } }
class C extends B { m(x: int32, y: int32 = 8, z: int32 = 9): string { return "C" + x.toString() + "," + y.toString() + "," + z.toString(); } }

const a: A = new B();
console.log(a.m(3));
console.log(new B().m(3));
console.log(new B().m(3, 4));
const c: A = new C();
console.log(c.m(3));
const b: B = new B();
console.log(b.m(5));
