// @stdout: helper 1 array 1 method 1
// @xfail(raiser): the Raiser VM has no host function msStringSubstring
// note: passing an object, or an array that holds it, to a function counts as a possible change to everything reachable from it. A local that borrowed a field or element before the call used to stay a borrow, so a callee that replaced that field or element freed what the local still read.

class Box { n: int32; constructor(n: int32) { this.n = n; } }
class Holder { child: Box; constructor(n: int32) { this.child = new Box(n); } }
class Replacer { replace(h: Holder): void { h.child = new Box(3); } }

function replaceChild(h: Holder): void { h.child = new Box(2); }
function replaceFirst(arr: Box[]): void { arr[0] = new Box(2); }

function viaHelper(): string {
	const h = new Holder(1);
	const c = h.child;
	replaceChild(h);
	const reuse = new Box(99);
	return String(c.n) + " " + String(h.child.n) + " " + String(reuse.n);
}

function viaArray(): string {
	const boxes: Box[] = [];
	boxes.push(new Box(1));
	const b = boxes[0];
	replaceFirst(boxes);
	const reuse = new Box(98);
	return String(b.n) + " " + String(boxes[0].n) + " " + String(reuse.n);
}

function viaMethodArg(): string {
	const h = new Holder(1);
	const r = new Replacer();
	const c = h.child;
	r.replace(h);
	const reuse = new Box(97);
	return String(c.n) + " " + String(h.child.n) + " " + String(reuse.n);
}

const x = viaHelper();
const y = viaArray();
const z = viaMethodArg();
console.log("helper " + x.substring(0, 1) + " array " + y.substring(0, 1) + " method " + z.substring(0, 1));
console.log(x);
console.log(y);
console.log(z);
