// @stdout: ret=1,2,-1 param=1,2,-1 local=2,-1 plain=1,-1 value=4,-1 pair=2
// note: `Readonly<A | B | null>` is `Readonly<A> | Readonly<B> | null` in every type position: a return, a parameter and a local annotation take either spelling for the other, and so do a single class and a struct with a null member.

class A { n: int32 = 1; }
class B { n: int32 = 2; }
struct Info { name: string; n: int32; }

function viaRead(x: Readonly<A | B | null>): Readonly<A> | Readonly<B> | null { return x; }
function viaWrite(x: Readonly<A> | Readonly<B> | null): Readonly<A | B | null> { return x; }
function nOf(x: Readonly<A | B | null>): int32 { if (x == null) return -1; return x.n; }
function nOf2(x: Readonly<A> | Readonly<B> | null): int32 { if (x == null) return -1; return x.n; }
function one(x: Readonly<A | null>): Readonly<A> | null { return x; }
function oneBack(x: Readonly<A> | null): Readonly<A | null> { return x; }
function nOne(x: Readonly<A | null>): int32 { return x != null ? x.n : -1; }
function valueOf(x: Readonly<Info | null>): Readonly<Info> | null { return x; }
function valueBack(x: Readonly<Info> | null): Readonly<Info | null> { return x; }
function pairOf(x: Readonly<A | B>): Readonly<A> | Readonly<B> { return x; }

const ret = [nOf(viaRead(new A())), nOf2(viaWrite(new B())), nOf(viaRead(null))];
const param = [nOf2(viaRead(new A())), nOf(viaWrite(new B())), nOf2(viaWrite(null))];
const local: Readonly<A | B | null> = viaWrite(new B());
const localBack: Readonly<A> | Readonly<B> | null = viaRead(null);
const plain = [nOne(oneBack(new A())), nOne(one(null))];
const info: Info | null = { name: "t", n: 4 };
const got: Readonly<Info | null> = valueOf(info);
const gotBack: Readonly<Info> | null = valueBack(null);
console.log(`ret=${ret.join(",")} param=${param.join(",")} local=${nOf(local)},${nOf2(localBack)} plain=${plain.join(",")} value=${got != null ? got.n : -1},${gotBack != null ? gotBack.n : -1} pair=${pairOf(new B()).n}`);
