// @stdout: 7 7 7 7 9 8 7 5 5
class C {
	v: number = 7;
	get(): number { return this.v; }
}
class Holder {
	items: (C | null)[] = [null, new C()];
}
class Box<T> {
	slots: (T | null)[] = [];
}
function first<T>(xs: (T | null)[]): T { return xs[1]!; }

const ns: (C | null)[] = [null, new C()];
const h = new Holder();
const nested: (C | null)[][] = [[null, new C()]];
const c = ns[1]!;
const out: number[] = [ns[1]!.v, (ns[1] as C).v, c.v, (ns[1]?.v)!];
out.push(ns[1]!.get() + 2);
out.push((nested[0][1] as C).v + 1);
out.push(h.items[1]!.v);
out.push(first<C>(ns).v - 2);
(ns[1] as C).v = 5;
out.push(ns[1]!.v);
console.log(out.join(" "));
