// @stdout: x:x 7 z
// @stdout: x:x 8
function seven(): number { return 7; }
function eight(): int32 { return 8; }
function onlyX(v: "x"): string { return "x:" + v; }
function onlyZ(v: "z"): string { return v; }
const o = { kind: "x", n: seven(), inner: { k: "z", m: eight() } } as const;
console.log(onlyX(o.kind), o.n, onlyZ(o.inner.k));
const total: int32 = o.inner.m;
console.log(onlyX(o.kind), total);
