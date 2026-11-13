// @stdout: circle 2 6
// @stdout: circle circle
// @stdout: square 2
// @stdout: true lib
// note: `{…} satisfies T` keeps each literal member its context asks for (a string or number literal under a literal-union member, `true` under `boolean`, a member under its enum), in T's fields and order, as TypeScript does; the value then reads and passes as the narrow type and reaches `Readonly<T>`. Covered: const and let bindings, a nested literal, a member chosen by the other literal, boolean and enum members.
type Kind = "circle" | "square";
interface Shape { kind: Kind; size: number }
type Circle = { kind: "circle"; size: number };
interface Outer { inner: { kind: Kind }; n: number }
enum K { A, B }
interface Tagged { k: K; ok: boolean; name: string }

function onlyCircle(k: "circle"): string { return k; }
function takeCircle(c: Circle): number { return c.size; }
function area(s: Readonly<Shape>): number { return s.kind == "circle" ? s.size * 3 : s.size; }

const p = { kind: "circle", size: 2 } satisfies Shape;
console.log(onlyCircle(p.kind), takeCircle(p), area(p));

let r = { kind: "circle", size: 2 } satisfies Shape;
const o = { inner: { kind: "circle" }, n: 1 } satisfies Outer;
console.log(onlyCircle(r.kind), onlyCircle(o.inner.kind));

const q = { kind: "square", size: 2 } satisfies Shape;
const sq: "square" = q.kind;
console.log(sq, area(q));

const t = { k: K.A, ok: true, name: "lib" } satisfies Tagged;
const a: K.A = t.k;
const yes: true = t.ok;
console.log(a == K.A && yes, t.name);
