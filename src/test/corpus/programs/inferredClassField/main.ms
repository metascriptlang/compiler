// @xfail(raiser): the Raiser cannot read a static class field ('cannot evaluate 'P' at comptime: symbol kind is Class') (inbox 2026-10-09-raiser-cannot-read-a-static-class-field)
// Differential program: a class field typed only by its initializer has that
// type for every reader: a direct read, a read through a narrowed `P | null`,
// a read before the class is declared, and a read from a
// generic class, a read of an imported class and through a Readonly view. stdout is the contract on C and JS.
import { Q } from "./lib";

function early(p: P | null): int32 {
	if (p != null) return p.tag;
	return 0;
}

class P {
	tag = 7;
	name = "p";
	on = true;
	box = { n: 5 };
	bump = (x: number): number => x + 1;
	static count = 3;
}

class G<T> {
	size = 4;
	item: T;
	constructor(item: T) { this.item = item; }
}

const p = new P();
console.log(p.tag, p.name, p.on, p.box.n, p.bump(2), P.count);
console.log(early(p), early(null));
const g = new G<string>("s");
console.log(g.size, g.item);
const q = new Q();
const view: Readonly<Q> = q;
console.log(q.id, q.label, view.id);

class Z { z = new W().tag; }
class W { tag = 11; }
class Base { v = 3; static s = 5; }
class Kid extends Base { w = 1; }
function readKid(k: Kid): int32 { return k.v + k.w + Kid.s; }
console.log(new Z().z, readKid(new Kid()));
