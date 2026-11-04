class Box {
	w: int64;
	h: int64;
	constructor(w: int64, h: int64) {
		this.w = w;
		this.h = h;
	}
}

function inc(x: int64): int64 {
	return x + 1;
}

function half(x: float64): float64 {
	return x * 0.5 + 1.0;
}

function area(b: Box): int64 {
	return b.w * b.h;
}

function rim(this b: Box): int64 {
	return 2 * (b.w + b.h);
}

function twice(x: int64): int64 {
	return inc(x) * 2;
}

function small(x: int64): boolean {
	return x < 10 && x > -10;
}

function digits(n: int64): int64 {
	const t = `${n}`;
	return t.length;
}

@noinline
function kept(x: int64): int64 {
	return x - 1;
}

const sumTo = (n: int64): int64 => {
	let s: int64 = 0;
	for (let i: int64 = 0; i < n; i = i + 1) s = s + inc(i);
	return s;
};

function shapes(n: int64): string {
	const b = new Box(n, 3);
	const total = area(b) + b.rim() + twice(n);
	return `${total} ${half(n as float64)}`;
}

function guarded(n: int64): string {
	let picked = 0;
	for (let i: int64 = -12; i < n; i = i + 4) {
		if (small(i)) picked = picked + 1;
	}
	return `${picked} ${digits(n * 1000)} ${kept(n)}`;
}

console.log(`${sumTo(1000)}`);
console.log(shapes(4));
console.log(guarded(12));
console.log(`${inc(inc(41))} ${twice(-3)}`);
