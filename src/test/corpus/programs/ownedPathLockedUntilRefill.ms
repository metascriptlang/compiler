// note: a path moved out of an owned slot is put back before anything reads it or its holder, by a later statement, on each branch, after another move out of the same holder, or by a call that takes the moved value; nothing reads the slot in between (the refusals are pinned in src/test/c/ownedEdge.ms).
// @stdout: + 2 1 2
// @stdout: -1 1
// @stdout: 9
// @stdout: 1
// @stdout: 12 -1 9 1 1
class T {
	v: int32 = 0;
	kids: Vec<Owned<T>> = [];
	constructor(v: int32) { this.v = v; }
}
class Bin {
	op: string = "+";
	left: Owned<T>;
	right: Owned<T>;
	constructor(sink l: Owned<T>, sink r: Owned<T>) { this.left = move l; this.right = move r; }
}
function wrap(sink n: Owned<T>): Owned<T> { const w: Owned<T> = new T(-1); w.kids.push(move n); return move w; }
function use(b: Bin): int32 { return b.left.v; }
function mk(): Owned<Bin> { const b: Owned<Bin> = new Bin(new T(1), new T(2)); return move b; }
function swapSides(b: Owned<Bin>): Owned<Bin> {
	const l = move b.left;
	const r = move b.right;
	const op = b.op;
	b.left = move r;
	b.right = move l;
	console.log(op, b.left.v, b.right.v, use(b));
	return move b;
}
function consume(sink b: Owned<Bin>): int32 {
	const l = move b.left;
	const r = move b.right;
	return l.v * 10 + r.v;
}
function wrapLeft(b: Owned<Bin>): Owned<Bin> {
	const l = move b.left;
	b.left = wrap(move l);
	console.log(b.left.v, b.left.kids[0].v);
	return move b;
}
function branches(b: Owned<Bin>, flip: boolean): Owned<Bin> {
	const l = move b.left;
	if (flip) { b.left = new T(9); } else { b.left = move l; }
	console.log(b.left.v);
	return move b;
}
const s = swapSides(mk());
console.log(consume(mk()), wrapLeft(mk()).left.v, branches(mk(), true).left.v, branches(mk(), false).left.v, s.right.v);
