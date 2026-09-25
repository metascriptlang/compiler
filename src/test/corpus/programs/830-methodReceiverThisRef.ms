// @stdout: receiver-ok s=10 o=10 c=10 g=10 let=11 field=11 elem=21 nested=12
// note: a method-form call relates its receiver as argument 0: `v.f()` gives what `f(v)` gives, and a `this ref` receiver writes through to the caller's place on every backend.

import { exit } from "std/process";

struct S { n: int32; }
type O = { n: int32 };
class C { n: int32 = 10; }
struct Holder { s: S; }
struct Outer { h: Holder; }

function getS(this x: S): int32 { return x.n; }
function getO(this x: O): int32 { return x.n; }
function getC(this x: C): int32 { return x.n; }
function first<T>(this xs: T[]): T { return xs[0]; }
function bump(this ref x: S): void { x.n = x.n + 1; }

const s: S = { n: 10 };
const o: O = { n: 10 };
const c = new C();
const g: int32[] = [10, 20];
if (s.getS() != getS(s) || o.getO() != getO(o) || c.getC() != getC(c) || g.first() != first(g)) exit(1);

let v: S = { n: 10 };
v.bump();
let h: Holder = { s: { n: 10 } };
h.s.bump();
let arr: S[2] = [{ n: 10 }, { n: 20 }];
arr[1].bump();
let deep: Outer = { h: { s: { n: 10 } } };
deep.h.s.bump();
deep.h.s.bump();

console.log("receiver-ok s=" + s.getS().toString() + " o=" + o.getO().toString() + " c=" + c.getC().toString()
	+ " g=" + g.first().toString() + " let=" + v.n.toString() + " field=" + h.s.n.toString()
	+ " elem=" + arr[1].n.toString() + " nested=" + deep.h.s.n.toString());
