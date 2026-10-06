// @stdout: 2,1 13,4,6,5 s4 10,1 7,1,1,7 5,10,10,5,6,5
// note: an object literal assigned to a local, its field or its sized-array element is built in place; one that reads the destination, through the binding, a span over it, a narrowed union or a closure that captured it, still sees the old value. Same output on every lane.
struct Pair { x: int64; y: int64; }
struct Box { p: Pair; arr: Pair[3]; n: int64; }
struct C { kind: "c"; r: int64; }
struct S { kind: "s"; w: int64; }
type Shape = C | S;

function swapped(a: int64): string {
	let p: Pair = { x: a, y: a + 1 };
	p = { x: p.y, y: p.x };
	return `${p.x},${p.y}`;
}
function throughSpan(): string {
	let b: Box = { p: { x: 1, y: 2 }, arr: [{ x: 3, y: 4 }, { x: 5, y: 6 }, { x: 7, y: 8 }], n: 9 };
	const s: Span<Pair> = b.arr;
	b.arr[1] = { x: s[1].y, y: s[1].x };
	b.arr[0] = { x: s[2].x + s[1].x, y: b.arr[0].y };
	return `${b.arr[0].x},${b.arr[0].y},${b.arr[1].x},${b.arr[1].y}`;
}
function narrowed(): string {
	let u: Shape = { kind: "c", r: 3 };
	if (u.kind == "c") {
		const c = u as C;
		u = { kind: "s", w: c.r + 1 };
	}
	return u.kind == "s" ? `s${(u as S).w}` : "c";
}
function captured(): string {
	let p: Pair = { x: 1, y: 2 };
	const readX = (): int64 => p.x;
	p = { x: 10, y: readX() };
	return `${p.x},${p.y}`;
}
function sibling(): string {
	let b: Box = { p: { x: 1, y: 2 }, arr: [{ x: 0, y: 0 }, { x: 0, y: 0 }, { x: 0, y: 0 }], n: 7 };
	b.p = { x: b.n, y: b.p.x };
	b.arr[2] = { x: b.p.y, y: b.n };
	return `${b.p.x},${b.p.y},${b.arr[2].x},${b.arr[2].y}`;
}
function fresh(i: int32, a: int64): string {
	let b: Box = { p: { x: 0, y: 0 }, arr: [{ x: 0, y: 0 }, { x: 0, y: 0 }, { x: 0, y: 0 }], n: 0 };
	let q: Pair = { x: 0, y: 0 };
	q = { x: a, y: a * 2 };
	b.p = { x: q.y, y: q.x };
	b.arr[i] = { x: a + 1, y: q.x };
	return `${q.x},${q.y},${b.p.x},${b.p.y},${b.arr[i].x},${b.arr[i].y}`;
}
console.log(`${swapped(1)} ${throughSpan()} ${narrowed()} ${captured()} ${sibling()} ${fresh(2, 5)}`);
