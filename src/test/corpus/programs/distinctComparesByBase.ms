// @stdout: string=false true true false true
// @stdout: order=true false false false true
// @stdout: struct=false true true false
// @stdout: field=true false
// @stdout: nested=true false
// @stdout: number=false true false true
type Tag = distinct string;
type Label = distinct Tag;
struct P { x: int32; name: string; }
type Q = distinct P;
struct Row { tag: Tag; n: int32; }
type Id = distinct int32;

function joined(a: string, b: string): string { return a + b; }

const ta = "hello" as Tag;
const tb = "world" as Tag;
const tc = joined("hel", "lo") as Tag;
const td = ta;
console.log(`string=${ta == tb} ${ta == tc} ${ta == td} ${ta != tc} ${ta != tb}`);
console.log(`order=${ta < tb} ${ta >= tb} ${ta > tb} ${tb <= ta} ${tc <= ta}`);

const q1 = ({ x: 1, name: "a" } as P) as Q;
const q2 = ({ x: 2, name: "a" } as P) as Q;
const q3 = ({ x: 1, name: joined("", "a") } as P) as Q;
const q4 = q1;
console.log(`struct=${q1 == q2} ${q1 == q3} ${q1 == q4} ${q1 != q3}`);

const r1: Row = { tag: ta, n: 1 };
const r2: Row = { tag: tc, n: 1 };
const r3: Row = { tag: tb, n: 1 };
console.log(`field=${r1 == r2} ${r1 == r3}`);

const l1 = ta as Label;
const l2 = tc as Label;
const l3 = tb as Label;
console.log(`nested=${l1 == l2} ${l1 == l3}`);

const i1 = 1 as Id;
const i2 = 2 as Id;
const i3 = 1 as Id;
console.log(`number=${i1 == i2} ${i1 == i3} ${i1 != i3} ${i1 < i2}`);
