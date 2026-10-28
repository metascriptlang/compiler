// @stdout: apply(Box.make)=5
// @stdout: Box.wrap(7, Box.make)=7
// @stdout: Box.wrap(Box.make)=9
// @stdout: apply(Made.make)=11
// @stdout: Iface.open(3): 7 3
// @stdout: Shape.open(3): 7 3
// @stdout: Shape.open as value: 12 10

struct Box { n: int32; }

function make(this typeof Box, value: int32): Box {
	return { n: value };
}

function wrap<T>(this typeof Box, v: T, f: (x: T) => Box): Box {
	return f(v);
}

function apply(f: (value: int32) => Box): int32 {
	return f(5).n;
}

class Made {
	n: int32 = 0;
	static make(value: int32): Made {
		const m = new Made();
		m.n = value;
		return m;
	}
}

function applyMade(f: (value: int32) => Made): int32 {
	return f(11).n;
}

interface Iface {
	open: (n: int32) => int32;
	size: int32;
}

function open(this typeof Iface, n: int32): Iface {
	return { open: (k: int32): int32 => k + n, size: n };
}

struct Shape {
	open: (n: int32) => int32;
	size: int32;
}

function open(this typeof Shape, n: int32): Shape {
	return { open: (k: int32): int32 => k + n, size: n };
}

function build(f: (n: int32) => Shape): Shape {
	return f(10);
}

console.log(`apply(Box.make)=${apply(Box.make)}`);
console.log(`Box.wrap(7, Box.make)=${Box.wrap(7 as int32, Box.make).n}`);
const maker = Box.make;
console.log(`Box.wrap(Box.make)=${Box.wrap(9 as int32, maker).n}`);
console.log(`apply(Made.make)=${applyMade(Made.make)}`);
const i = Iface.open(3);
console.log(`Iface.open(3): ${i.open(4)} ${i.size}`);
const s = Shape.open(3);
console.log(`Shape.open(3): ${s.open(4)} ${s.size}`);
const t = build(Shape.open);
console.log(`Shape.open as value: ${t.open(2)} ${t.size}`);
