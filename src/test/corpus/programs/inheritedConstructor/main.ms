// @stdout: 14 x 5 | 16/p:8 | 6 p:3 5 m | 41 ib | g 9 | 105 7 | 4/p:2
// note: a subclass that declares no constructor runs its parent's with the arguments of its `new` (TypeScript's implicit `constructor(...args) { super(...args); }`): the parent's body runs before the subclass's field initializers, a default of the parent's constructor fills a missing argument from the parent's module and may read an earlier argument, through two levels, below a generic class instance, and as a generic class itself; `super(...)` of a parent imported under another name runs that parent, and an explicit `super(...)` that leaves an argument out takes the parent's default. Same output on every lane.
import { Base, Box, Slot as Renamed } from "./shapes";

class Sub extends Base { n: int32 = 5; }
class Sub2 extends Sub { m: string = "m"; }
class IntBox extends Box<int32> { tag: string = "ib"; }
class GenBox<U> extends Box<U> { k: int32 = 9; }

class Explicit extends Base { constructor(u: int32) { super(u); } }

class Child extends Renamed {
	c: int32 = 3;
	constructor(c: int32) { super(c + 1); this.c = c; }
}

const a = new Sub(7, "x");
const b = new Sub(8);
const c = new Sub2(3);
const d = new IntBox(41);
const e = new GenBox<string>("g");
const g = new Child(4);
const h = new Explicit(2);
console.log(`${a.u} ${a.w} ${a.n} | ${b.describe()} | ${c.u} ${c.w} ${c.n} ${c.m} | ${d.v} ${d.tag} | ${e.v} ${e.k} | ${g.s} ${g.c + 3} | ${h.describe()}`);
