// Parity program — `==` and `!=` on a named union compare the active variant: the tag first, then the
// payload (a primitive by value, a string by content, a reference member by identity). The same
// operands behave the same in a plain function, a generic function, a generic class method, a struct
// field and across a module boundary.
//
// @stdout: shape=true,false,false,true,true named=true,false,true,true,false holder=true,false,false cross=true,false
// @exit: 0

import { Mark, markOf, markOfText } from "./marks";

interface Circle { r: number; }
interface Square { s: number; }
type Shape = Circle | Square;
type NamedU = int32 | string;

class Cmp<T> {
	same(a: T, b: T): boolean { return a == b; }
	differ(a: T, b: T): boolean { return a != b; }
}

function g<T>(a: T, b: T): boolean { return a == b; }

struct Holder { u: NamedU; s: Shape; }

function shape(c: Circle): Shape { return c; }
function square(q: Square): Shape { return q; }
function num(n: int32): NamedU { return n; }
function str(s: string): NamedU { return s; }

function main(): void {
	const c1: Circle = { r: 1 };
	const c2: Circle = { r: 1 };
	const q: Square = { s: 2 };
	const a = shape(c1);
	const b = shape(c1);
	const c = shape(c2);
	const d = square(q);
	const cs = new Cmp<Shape>();
	const cn = new Cmp<NamedU>();
	const x = num(3);
	const y = str("3");
	const z = num(3);
	const h1: Holder = { u: x, s: a };
	const h2: Holder = { u: z, s: b };
	const h3: Holder = { u: z, s: c };
	const h4: Holder = { u: y, s: a };
	const m1: Mark = markOf(7);
	const m2: Mark = markOf(7);
	const m3: Mark = markOfText("7");
	console.log(`shape=${g(a, b)},${g(a, c)},${g(a, d)},${cs.same(a, b)},${cs.differ(a, c)} named=${g(x, z)},${g(x, y)},${cn.same(x, z)},${cn.differ(x, y)},${cn.differ(x, z)} holder=${g(h1, h2)},${g(h1, h3)},${g(h1, h4)} cross=${g(m1, m2)},${g(m1, m3)}`);
}
main();
