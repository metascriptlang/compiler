// @stdout: circle 2 6
// @stdout: square 2.5
// @stdout: 6
// @stdout: circle 1 circle
// @stdout: true lib
// @stdout: x a
// note: `{…} as const` takes the contextual type of the assertion, as TypeScript does: under an object type T every literal member keeps its own type in T's fields and order and the whole value is read-only, so it reaches Readonly<T>. Covered: `as const satisfies`, an annotated Readonly<T>, a nested literal, boolean, enum and string members, a union target (keeps T).
type Kind = "circle" | "square";
interface Shape { kind: Kind; size: number }
type Circle = { kind: "circle"; size: number };
interface Outer { inner: { kind: Kind }; n: number }
enum K { A, B }
interface Tagged { k: K; ok: boolean; name: string }
type U = { kind: "a"; n: number } | { kind: "b"; s: string };

function onlyCircle(k: "circle"): string { return k; }
function takeCircle(c: Readonly<Circle>): number { return c.size; }
function area(s: Readonly<Shape>): number { return s.kind == "circle" ? s.size * 3 : s.size; }
function readOuter(o: Readonly<Outer>): string { return o.inner.kind; }
function show(u: Readonly<U>): string { return u.kind == "a" ? "a" : u.s; }

const p = { kind: "circle", size: 2 } as const satisfies Shape;
console.log(onlyCircle(p.kind), takeCircle(p), area(p));
const f = { kind: "square", size: 2.5 } as const satisfies Shape;
const fs: 2.5 = f.size;
console.log(f.kind, fs);
const r: Readonly<Shape> = { kind: "circle", size: 2 } as const;
console.log(area(r));
const o = { inner: { kind: "circle" }, n: 1 } as const satisfies Outer;
console.log(onlyCircle(o.inner.kind), o.n, readOuter(o));
const t = { k: K.A, ok: true, name: "lib" } as const satisfies Tagged;
const a: K.A = t.k;
const yes: true = t.ok;
const nm: "lib" = t.name;
console.log(a == K.A && yes, nm);
const u = { kind: "b", s: "x" } as const satisfies U;
const w: Readonly<U> = { kind: "a", n: 1 } as const;
console.log(show(u), show(w));
