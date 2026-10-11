// @stdout: field 1 elem 1 list 1 wrap 1
// note: storing an object into a field, an array slot or a new object joins it to the target, so a change made later through the target reaches locals that borrowed from the stored object. The store used to leave the two apart, and a local borrowed from the stored object read freed memory after the target replaced its child.

class Leaf { n: int32; constructor(n: int32) { this.n = n; } }
class Mid { leaf: Leaf; constructor(n: int32) { this.leaf = new Leaf(n); } }
class Top { mid: Mid; mids: Mid[]; constructor() { this.mid = new Mid(0); this.mids = []; } }
class Wrap { m: Mid; constructor(m: Mid) { this.m = m; } }

function fieldStore(): string {
	const t = new Top();
	const m = new Mid(1);
	t.mid = m;
	const z = m.leaf;
	t.mid.leaf = new Leaf(2);
	const reuse = new Leaf(99);
	return String(z.n) + " " + String(m.leaf.n) + " " + String(reuse.n);
}

function elementStore(): string {
	const arr: Mid[] = [new Mid(0)];
	const m = new Mid(1);
	arr[0] = m;
	const z = m.leaf;
	arr[0].leaf = new Leaf(2);
	const reuse = new Leaf(98);
	return String(z.n) + " " + String(m.leaf.n) + " " + String(reuse.n);
}

function listStore(): string {
	const t = new Top();
	const m = new Mid(1);
	t.mids = [m];
	const z = m.leaf;
	t.mids[0].leaf = new Leaf(2);
	const reuse = new Leaf(97);
	return String(z.n) + " " + String(m.leaf.n) + " " + String(reuse.n);
}

function wrapInit(): string {
	const m = new Mid(1);
	const w = new Wrap(m);
	const z = m.leaf;
	w.m.leaf = new Leaf(2);
	const reuse = new Leaf(96);
	return String(z.n) + " " + String(m.leaf.n) + " " + String(reuse.n);
}

const a = fieldStore();
const b = elementStore();
const c = listStore();
const d = wrapInit();
console.log("field " + a.substring(0, 1) + " elem " + b.substring(0, 1) + " list " + c.substring(0, 1) + " wrap " + d.substring(0, 1));
console.log(a);
console.log(b);
console.log(c);
console.log(d);
