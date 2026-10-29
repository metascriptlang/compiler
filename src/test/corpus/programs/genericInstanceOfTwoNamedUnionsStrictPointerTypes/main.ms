// @stdout: 7 7 7 7 7
// note: two unions declared with the same members under different names are two types in C, so a generic called with one and then the other is two instances, one per carrier; sharing the first instance passed the second union as a pointer to the first's struct. The second and third unions come from another module. Same output on C, JS and the Raiser.

@passC("-Werror=incompatible-pointer-types");

import { Mark, Twin, mk, twin } from "./lib";

type NamedU = int32 | string;

function first<T>(a: T, b: T): T { return a; }
function nu(n: int32): NamedU { return n; }

class Pair<T> {
	a: T;
	b: T;
	constructor(a: T, b: T) { this.a = a; this.b = b; }
	left(): T { return this.a; }
}

const p = new Pair<NamedU>(nu(7), nu(8));
const q = new Pair<Mark>(mk(7), mk(8));
console.log(`${first(nu(7), nu(8)) as int32} ${first(mk(7), mk(8)) as int32} ${first(twin(7), twin(8)) as int32} ${p.left() as int32} ${q.left() as int32}`);
