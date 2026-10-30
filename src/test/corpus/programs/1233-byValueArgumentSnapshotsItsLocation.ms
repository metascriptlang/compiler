// @xfail(raiser): the Raiser VM binds a by-value struct parameter to the caller's object, so each writer is read through it
// @stdout: flat 1
// @stdout: p.x=5
// @stdout: globalField 1
// @stdout: globalAssign 1
// @stdout: elemAssign 1
// @stdout: elemField 1
// @stdout: nested 1
// @stdout: nestedAssign 1
// @stdout: classAssign 1
// @stdout: classFieldWrite 1
// @stdout: generic 1
// @stdout: method 1
// @stdout: arrow 1
struct P { x: int32; y: int32; }
struct Outer { inner: P; k: int32; }
class Box {
	p: P = { x: 1, y: 1 };
	take(q: P): int32 { this.p = { x: 3, y: 3 }; return q.x; }
}

let g: P = { x: 1, y: 1 };

function refVal(ref a: P, b: P): void { a.x = 5; console.log("flat " + String(b.x)); }
function gField(p: P): void { g.x = 9; console.log("globalField " + String(p.x)); }
function gAssign(p: P): void { g = { x: 7, y: 7 }; console.log("globalAssign " + String(p.x)); }
function overwriteFirst(xs: P[], p: P): void { xs[0] = xs[1]; console.log("elemAssign " + String(p.x)); }
function elemField(xs: P[], p: P): void { xs[0].x = 8; console.log("elemField " + String(p.x)); }
function nested(ref o: Outer, p: P): void { o.inner.x = 6; console.log("nested " + String(p.x)); }
function nestedAssign(ref o: Outer, p: P): void { o.inner = { x: 4, y: 4 }; console.log("nestedAssign " + String(p.x)); }
function classField(b: Box, p: P): void { b.p = { x: 3, y: 3 }; console.log("classAssign " + String(p.x)); }
function classFieldWrite(b: Box, p: P): void { b.p.x = 2; console.log("classFieldWrite " + String(p.x)); }
function viaGeneric<T>(ref a: P, v: T): T { a.x = 5; return v; }

let p: P = { x: 1, y: 1 };
refVal(p, p);
console.log("p.x=" + String(p.x));
gField(g);
g = { x: 1, y: 1 };
gAssign(g);
const xs: P[] = [{ x: 1, y: 1 }, { x: 2, y: 2 }];
overwriteFirst(xs, xs[0]);
const ys: P[] = [{ x: 1, y: 1 }, { x: 2, y: 2 }];
elemField(ys, ys[0]);
let o: Outer = { inner: { x: 1, y: 1 }, k: 0 };
nested(o, o.inner);
let o2: Outer = { inner: { x: 1, y: 1 }, k: 0 };
nestedAssign(o2, o2.inner);
const bx = new Box();
classField(bx, bx.p);
const by = new Box();
classFieldWrite(by, by.p);
let q: P = { x: 1, y: 1 };
console.log("generic " + String(viaGeneric(q, q).x));
const bm = new Box();
console.log("method " + String(bm.take(bm.p)));
const bw = new Box();
const viaArrow = (b: Box, q: P): int32 => { b.p.x = 2; return q.x; };
console.log("arrow " + String(viaArrow(bw, bw.p)));
