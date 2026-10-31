@wasm
export function bump(xs: Span<int32>, depth: int32, cb: (n: int32) => int32): int32 {
	let seen = 0;
	if (depth > 0) { seen = cb(depth); }
	for (let i = 0; i < xs.length; i += 1) {
		seen += xs[i];
		xs[i] = xs[i] + depth;
	}
	return seen;
}

@wasm
export function weigh(label: string, ws: Readonly<Span<float64>>, flags: Span<boolean>, depth: int32, cb: (n: int32) => int32): float64 {
	let total: float64 = 0;
	if (depth > 0) { total = cb(depth) as float64; }
	for (let i = 0; i < ws.length; i += 1) {
		if (flags[i]) { total += ws[i]; }
		flags[i] = !flags[i];
	}
	return total + (label.length as float64);
}

@wasm
export function feed(n: int32, cb: (xs: Span<int32>) => int32): int32 {
	let xs: Vec<int32> = [];
	for (let i = 0; i < n; i += 1) { xs.push(i + 1); }
	const got = cb(xs);
	return got * 1000 + xs[0];
}

@wasm
export function joined(a: string, b: string, c: string): string {
	return a + "/" + b + "/" + c;
}
