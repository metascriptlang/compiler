// @stdout: 6 6 3 2 9 3 2
// note: readonly Unowned<P>[] takes a strong P[] as well as an Unowned one: it reads, slices into an edge array and hands an element to a mutable P parameter; nullable elements too.
class P { n: int32; constructor(n: int32) { this.n = n; } }
class H { ups: Unowned<P>[] = []; }
function bump(p: P): void { p.n += 1; }
function sum(xs: readonly Unowned<P>[]): int32 { let s = 0; for (const x of xs) s += x.n; return s; }
function at(xs: readonly Unowned<P>[], i: int32): int32 { return xs[i].n; }
function keepTail(h: H, xs: readonly Unowned<P>[]): int32 { h.ups = xs.slice(1); return h.ups.length; }
function sumMaybe(xs: readonly (Unowned<P> | null)[]): int32 { let s = 0; for (const x of xs) if (x != null) s += x.n; return s; }
function bumpFirst(xs: readonly Unowned<P>[]): void { bump(xs[0]); }
const ps: P[] = [new P(1), new P(2), new P(3)];
const h = new H();
const tail = keepTail(h, ps);
const maybes: (P | null)[] = [ps[2], null, ps[2], ps[2]];
const line = sum(ps).toString() + " " + sum([ps[0], ps[1], ps[2]]).toString() + " " + at(ps, 2).toString() + " " + tail.toString() + " " + sumMaybe(maybes).toString();
bumpFirst(h.ups);
bumpFirst(ps);
console.log(line + " " + ps[1].n.toString() + " " + ps[0].n.toString());
