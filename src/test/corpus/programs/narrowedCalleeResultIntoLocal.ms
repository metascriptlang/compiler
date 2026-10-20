// @xfail(raiser): typeof cannot tell a function from an object on Raiser: 'object' and 'function' variants share Raiser value kind 6, card .inbox/compiler/2026-10-15-raiser-typeof-cannot-tell-a-function-from-an-object
// @stdout: setter=1,11
// @stdout: generic=8,8
// @stdout: nullable=3,1
// @stdout: span=6,9
// note: a call whose struct result initializes a local, including the temp that `box.set(next(box.get()))` hoists its inner call into, passes each argument by the parameter ABI of a narrowed function value (`T | ((prev: T) => T)` or a nullable callback): a large struct by address, a Span as data and length. Before, the C backend read the parameters from the callee's union-typed symbol, found none, and passed the struct by value or the Span unexpanded, which the C compiler refused.
struct Payload {
	a: int32;
	b: int32;
	c: int32;
	d: int32;
	e: int32;
	f: int32;
	g: int32;
	h: int32;
}

class Box {
	value: Payload;
	constructor(value: Payload) { this.value = value; }
	get(): Payload { return this.value; }
	set(value: Payload): void { this.value = value; }
}

function setter(box: Box): (next: Payload | ((value: Payload) => Payload)) => void {
	return (next: Payload | ((value: Payload) => Payload)): void => {
		if (typeof next === "function") { box.set(next(box.get())); } else { box.set(next); }
	};
}

const initial: Payload = { a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8 };
const box = new Box(initial);
const write = setter(box);
write(initial);
const first = box.get().a;
write((prev: Payload): Payload => {
	let next = prev;
	next.a = prev.a + 10;
	return next;
});
console.log("setter=" + first.toString() + "," + box.get().a.toString());

struct Vec2 {
	x: int32;
	y: int32;
}

struct Vec3 {
	x: int32;
	y: int32;
	z: int32;
}

struct Frame {
	origin: Vec3;
	size: Vec3;
	id: int32;
}

class Cell<T> {
	value: T;
	constructor(value: T) { this.value = value; }
	get(): T { return this.value; }
	set(value: T): void { this.value = value; }
}

function cellSetter<T>(cell: Cell<T>): (next: T | ((value: T) => T)) => void {
	return (next: T | ((value: T) => T)): void => {
		if (typeof next === "function") { cell.set(next(cell.get())); } else { cell.set(next); }
	};
}

const frame: Frame = { origin: { x: 1, y: 2, z: 0 }, size: { x: 3, y: 4, z: 0 }, id: 1 };
const cell = new Cell<Frame>(frame);
const setFrame = cellSetter<Frame>(cell);
setFrame((prev: Frame): Frame => {
	let next = prev;
	next.size = { x: prev.size.x + prev.origin.x, y: prev.size.y, z: prev.size.z };
	return next;
});
const grown = cell.get();
setFrame({ origin: { x: 5, y: 6, z: 7 }, size: { x: 8, y: 9, z: 10 }, id: 2 });
const replaced = cell.get().size.x;
console.log("generic=" + (grown.size.x + grown.size.y).toString() + "," + replaced.toString());

function measure(p: Payload, fn: ((value: Payload) => Vec2) | null): Vec2 {
	if (fn != null) {
		const r = fn(p);
		return r;
	}
	return { x: p.a, y: p.b };
}

const measured = measure(initial, (v: Payload): Vec2 => ({ x: v.c, y: v.a }));
console.log("nullable=" + measured.x.toString() + "," + measured.y.toString());

struct Sum {
	total: int32;
	count: int32;
}

function fold(xs: Span<int32>, fn: Sum | ((items: Span<int32>) => Sum)): int32 {
	if (typeof fn === "function") {
		const s = fn(xs);
		return s.total;
	}
	return fn.total;
}

const data: int32[] = [1, 2, 3];
const folded = fold(data, (items: Span<int32>): Sum => {
	let total: int32 = 0;
	for (const v of items) total += v;
	return { total: total, count: items.length as int32 };
});
console.log("span=" + folded.toString() + "," + fold(data, { total: 9, count: 0 }).toString());
