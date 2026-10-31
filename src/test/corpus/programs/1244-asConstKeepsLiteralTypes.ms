// @stdout: got a 5 true
// @stdout: x:x 3 z -1 false
// @stdout: true -3 1.5
type Key = "a" | "b";
function named(k: Key): string { return "got " + k; }
function onlyX(v: "x"): string { return "x:" + v; }
function onlyZ(v: "z"): string { return v; }
function minus3(v: -3): int32 { return v; }
enum Color { Red, Green }
const k = "a" as const;
const n = 5 as const;
const b = true as const;
console.log(named(k), n, b);
const o = { kind: "x", n: 3, inner: { k: "z", v: -1 }, ok: false } as const;
console.log(onlyX(o.kind), o.n, onlyZ(o.inner.k), o.inner.v, o.ok);
const c = Color.Red as const;
const neg = -3 as const;
const f = 1.5 as const;
console.log(c == Color.Red, minus3(neg), f);
