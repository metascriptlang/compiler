// @stdout: ret 10
// @stdout: ret0 11
// @stdout: ret2 12 7
// @stdout: three 300
// @stdout: small 5
// @stdout: param 60
// @stdout: param-ret 111
// @stdout: abstract 9
struct Big { a: int64; b: int64; c: int64; }
struct Wide { a: int64; b: int64; c: int64; d: int64; e: int64; }
struct Small { a: int32; }

class Base {
	get(x: int32): Big { return { a: 1, b: 2, c: 3 }; }
	zero(): Big { return { a: 1, b: 2, c: 3 }; }
	two(x: int32, y: int32): Big { return { a: 1, b: 2, c: 3 }; }
	small(x: int32): Small { return { a: 1 }; }
	sum(w: Wide): int64 { return 1; }
	both(w: Wide, k: int32): Wide { return w; }
}
class D extends Base {
	get(x: int32): Big { return { a: 10, b: 20, c: 30 }; }
	zero(): Big { return { a: 11, b: 2, c: 3 }; }
	two(x: int32, y: int32): Big { return { a: x + 10, b: y, c: 3 }; }
	small(x: int32): Small { return { a: x + 4 }; }
	sum(w: Wide): int64 { return w.a + w.b + w.c + w.d + w.e; }
	both(w: Wide, k: int32): Wide { return { a: w.a + k, b: w.b, c: w.c, d: w.d, e: w.e }; }
}
class E extends D {
	get(x: int32): Big { return { a: 300, b: 20, c: 30 }; }
}
abstract class Shape { area(k: int32): Big { return { a: 0, b: 0, c: 0 }; } }
class Sq extends Shape { area(k: int32): Big { return { a: k, b: 0, c: 0 }; } }

const o: Base = new D();
console.log(`ret ${o.get(1).a}`);
console.log(`ret0 ${o.zero().a}`);
const t = o.two(2, 7);
console.log(`ret2 ${t.a} ${t.b}`);
const e: Base = new E();
console.log(`three ${e.get(1).a}`);
console.log(`small ${o.small(1).a}`);
const w: Wide = { a: 10, b: 10, c: 10, d: 10, e: 20 };
console.log(`param ${o.sum(w)}`);
console.log(`param-ret ${o.both(w, 101).a}`);
const s: Shape = new Sq();
console.log(`abstract ${s.area(9).a}`);
