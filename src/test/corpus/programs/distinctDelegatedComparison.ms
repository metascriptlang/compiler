// @stdout: string=false true false true true true
// @stdout: order=true false false false true
// @stdout: struct=false true false
// @stdout: field=true false
// @stdout: nested=true true
// @stdout: int=false true true false
// @stdout: enum=true true
// @stdout: generic=true true
// @stdout: declared=true false true true true false
// @stdout: baseRoutine=true false false true
type Tag = distinct string;
@delegate export function `==`(this a: Tag, b: Tag): boolean;
@delegate function `<`(this a: Tag, b: Tag): boolean;
@delegate function `<=`(this a: Tag, b: Tag): boolean;
type Label = distinct Tag;
@delegate function `==`(this a: Label, b: Label): boolean;
type Id = distinct int32;
@delegate function `==`(this a: Id, b: Id): boolean;
@delegate function `<`(this a: Id, b: Id): boolean;
struct P { x: int32; name: string; }
function `<`(this a: P, b: P): boolean { return a.x < b.x; }
type Q = distinct P;
@delegate function `==`(this a: Q, b: Q): boolean;
@delegate function `<`(this a: Q, b: Q): boolean;
struct Row { tag: Tag; n: int32; }
enum Color { Red, Green }
type Hue = distinct Color;
@delegate function `==`(this a: Hue, b: Hue): boolean;
type Tagged<S> = distinct int32;
@delegate function `==`<S>(this a: Tagged<S>, b: Tagged<S>): boolean;
type Named = distinct string;
function `==`(this a: Named, b: Named): boolean { return (a as string).length == (b as string).length; }
function `<`(this a: Named, b: Named): boolean { return (a as string).length < (b as string).length; }

function joined(a: string, b: string): string { return a + b; }

const ta = "hello" as Tag;
const tb = "world" as Tag;
const tc = joined("hel", "lo") as Tag;
console.log(`string=${ta == tb} ${ta == tc} ${ta != tc} ${ta != tb} ${ta === tc} ${ta !== tb}`);
console.log(`order=${ta < tb} ${ta >= tb} ${ta > tb} ${tb <= ta} ${tc <= ta}`);

const q1 = ({ x: 1, name: "a" } as P) as Q;
const q2 = ({ x: 2, name: "a" } as P) as Q;
const q3 = ({ x: 1, name: joined("", "a") } as P) as Q;
console.log(`struct=${q1 == q2} ${q1 == q3} ${q1 != q3}`);

const r1: Row = { tag: ta, n: 1 };
const r2: Row = { tag: tc, n: 1 };
const r3: Row = { tag: tb, n: 1 };
console.log(`field=${r1 == r2} ${r1 == r3}`);

console.log(`nested=${(ta as Label) == (tc as Label)} ${(ta as Label) != (tb as Label)}`);

const i1 = 1 as Id;
const i2 = 2 as Id;
console.log(`int=${i1 == i2} ${i1 != i2} ${i1 < i2} ${i1 > i2}`);

console.log(`enum=${(Color.Red as Hue) == (Color.Red as Hue)} ${(Color.Red as Hue) != (Color.Green as Hue)}`);
console.log(`generic=${(1 as Tagged<P>) == (1 as Tagged<P>)} ${(1 as Tagged<P>) != (2 as Tagged<P>)}`);

const n1 = "ab" as Named;
const n2 = "cd" as Named;
const n3 = "xyz" as Named;
console.log(`declared=${n1 == n2} ${n1 != n2} ${n1 != n3} ${n1 < n3} ${n3 > n1} ${n1 > n3}`);

console.log(`baseRoutine=${q1 < q2} ${q2 < q1} ${q1 > q2} ${q2 > q1}`);
