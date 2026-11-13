// @stdout: 6 6 3 2 9
// note: a read-only Unowned<P>[] parameter takes a strong P[] as well as an Unowned one: it reads and slices into an edge array; nullable elements too.
class P { n: int32; constructor(n: int32) { this.n = n; } }
class H { ups: Unowned<P>[] = []; maybe: (Unowned<P> | null)[] = []; }
function sum(xs: Readonly<Unowned<P>[]>): int32 { let s = 0; for (const x of xs) s += x.n; return s; }
function at(xs: Readonly<Unowned<P>[]>, i: int32): int32 { return xs[i].n; }
function keepTail(h: H, xs: Readonly<Unowned<P>[]>): int32 { h.ups = xs.slice(1); return h.ups.length; }
function sumMaybe(xs: Readonly<(Unowned<P> | null)[]>): int32 { let s = 0; for (const x of xs) if (x != null) s += x.n; return s; }
const ps: P[] = [new P(1), new P(2), new P(3)];
const h = new H();
for (const p of ps) h.ups.push(p);
const tail = keepTail(h, ps);
const maybes: (P | null)[] = [ps[2], null, ps[2], ps[2]];
console.log(sum(ps).toString() + " " + sum([ps[0], ps[1], ps[2]]).toString() + " " + at(ps, 2).toString() + " " + tail.toString() + " " + sumMaybe(maybes).toString());
